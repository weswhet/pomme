import Darwin
import Foundation
import Testing

@Suite("Public PTY relay")
struct PommePublicPTYRelayTests {
    private let jobID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    @Test("requires the exact public echo capability before starting a PTY")
    func requiresPublicEchoCapability() {
        #expect(PommePublicPTYRelay.supportsPublicEcho(.object(["publicPTYEchoVersion": .integer(1)])))
        #expect(!PommePublicPTYRelay.supportsPublicEcho(.object([:])))
        #expect(!PommePublicPTYRelay.supportsPublicEcho(.object(["publicPTYEchoVersion": .integer(2)])))
        #expect(!PommePublicPTYRelay.supportsPublicEcho(.object(["publicPTYEchoVersion": .number(1)])))
    }

    @Test("drains initial and status output before the matching exit frame")
    func forwardsOutputAndCompletion() async throws {
        let transport = RelayTransport(
            start: correlated(
                status(exited: false),
                [frame(.stdout, Data([0x00, 0xff])), frame(.stderr, Data("warning".utf8))]
            ),
            statuses: [
                correlated(status(exited: true, exitCode: 7), [frame(.stdout, Data("tail".utf8)), frame(.exit)])
            ]
        )
        let frames = FrameCollector()

        let result = try await run(transport: transport) { values in
            frames.append(values)
        }

        #expect(result.result.objectValue?["exitCode"] == .integer(7))
        #expect(result.result.objectValue?["outputComplete"] == .bool(true))
        #expect(result.streamFrames.isEmpty)
        #expect(transport.operations == ["process.start", "process.status"])
        #expect(frames.bytes(stream: .stdout) == Data([0x00, 0xff]) + Data("tail".utf8))
        #expect(frames.bytes(stream: .stderr) == Data("warning".utf8))
    }

    @Test("forwards host stdin resize and Ctrl-C signal to the same job")
    func forwardsInteractiveControls() async throws {
        let resize = PommeControlStreamFrame(
            id: UUID(), sequence: 0, stream: .resize,
            payload: .object(["columns": .integer(101), "rows": .integer(33)])
        )
        let stdin = PommeControlStreamFrame(
            id: UUID(), sequence: 1, stream: .stdin, data: Data("abc".utf8))
        let signal = PommeControlStreamFrame(
            id: UUID(), sequence: 2, stream: .signal,
            payload: .object(["signal": .integer(Int64(SIGINT))])
        )
        let transport = RelayTransport(
            start: correlated(status(exited: false), []),
            statuses: [
                correlated(status(exited: false), []),
                correlated(status(exited: false), []),
                correlated(status(exited: true, signal: SIGINT), [frame(.exit)])
            ],
            controls: [resize, stdin, signal]
        )

        let result = try await run(transport: transport)

        #expect(result.result.objectValue?["signal"] == .integer(Int64(SIGINT)))
        let calls = transport.streamCalls
        #expect(calls.map(\.stream) == [.resize, .stdin, .signal])
        #expect(calls[0].dimensions?.columns == 101)
        #expect(calls[0].dimensions?.rows == 33)
        #expect(calls[1].data == Data("abc".utf8))
        #expect(calls[2].signal == SIGINT)
    }

    @Test("cancellation sends TERM once and returns a non-success terminal envelope")
    func cancellationTerminatesKnownJob() async throws {
        let cancellation = PommeControlStreamFrame(id: UUID(), sequence: 0, stream: .cancellation)
        let transport = RelayTransport(start: correlated(status(exited: false), []), statuses: [], controls: [cancellation])

        let result = try await run(transport: transport)

        #expect(result.result.objectValue?["cancelled"] == .bool(true))
        #expect(result.result.objectValue?["terminationRequested"] == .bool(true))
        let calls = transport.streamCalls
        #expect(calls.count == 1)
        #expect(calls[0].stream == .signal)
        #expect(calls[0].signal == SIGTERM)
    }

    @Test("refuses an echo-disabled agent receipt before forwarding terminal controls")
    func rejectsOldEchoReceipt() async throws {
        let transport = RelayTransport(
            start: correlated(status(exited: false, echoDisabled: true), []),
            statuses: [],
            controls: [
                .init(id: UUID(), sequence: 0, stream: .resize,
                      payload: .object(["columns": .integer(101), "rows": .integer(33)])),
                .init(id: UUID(), sequence: 1, stream: .stdin, data: Data("must-not-forward".utf8)),
            ]
        )

        await #expect(throws: PommePublicPTYRelay.Error.publicEchoUnavailable) {
            _ = try await run(transport: transport)
        }
        let calls = transport.streamCalls
        #expect(calls.count == 1)
        #expect(calls[0].stream == .signal)
        #expect(calls[0].signal == SIGTERM)
    }

    @Test("rejects control output and terminates the known job")
    func rejectsUnexpectedControlOutput() async throws {
        let invalid = PommeControlStreamFrame(id: UUID(), sequence: 0, stream: .stdout, data: Data("no".utf8))
        let transport = RelayTransport(start: correlated(status(exited: false), []), statuses: [], controls: [invalid])

        await #expect(throws: PommePublicPTYRelay.Error.invalidControlFrame) {
            _ = try await run(transport: transport)
        }
        let calls = transport.streamCalls
        #expect(calls.count == 1)
        #expect(calls[0].stream == .signal)
        #expect(calls[0].signal == SIGTERM)
    }

    private func run(
        transport: RelayTransport,
        onFrames: @escaping PommePublicPTYRelay.FrameHandler = { _ in }
    ) async throws -> PommeAgentCorrelatedResult {
        try await PommePublicPTYRelay.run(
            payload: .object([
                "path": .string("/bin/sh"), "arguments": .array([]),
                "pty": .bool(true), "detached": .bool(false), "timeout": .integer(1),
            ]),
            timeout: 1,
            perform: { operation, _ in transport.perform(operation) },
            sendStream: { jobID, stream, data, dimensions, signal in
                transport.send(jobID: jobID, stream: stream, data: data, dimensions: dimensions, signal: signal)
            },
            receiveControl: { _ in transport.receiveControl() },
            onFrames: onFrames
        )
    }

    private func status(
        exited: Bool,
        exitCode: Int64? = nil,
        signal: Int32? = nil,
        echoDisabled: Bool = false
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "jobID": .string(jobID.uuidString.lowercased()), "pid": .integer(42),
            "detached": .bool(false), "exited": .bool(exited), "ptyEchoDisabled": .bool(echoDisabled),
        ]
        if let exitCode { values["exitCode"] = .integer(exitCode) }
        if let signal { values["signal"] = .integer(Int64(signal)) }
        return .object(values)
    }

    private func frame(_ stream: PommeAgentProtocol.Stream, _ data: Data? = nil) -> PommeAgentJobStreamFrame {
        try! .init(jobID: jobID, frame: .init(requestID: UUID(), stream: stream, data: data))
    }

    private func correlated(_ result: JSONValue, _ frames: [PommeAgentJobStreamFrame]) -> PommeAgentCorrelatedResult {
        .init(requestID: UUID(), result: result, streamFrames: frames)
    }
}

private final class RelayTransport: @unchecked Sendable {
    struct StreamCall: Sendable {
        let stream: PommeAgentProtocol.Stream
        let data: Data?
        let dimensions: (columns: Int, rows: Int)?
        let signal: Int32?
    }

    let start: PommeAgentCorrelatedResult
    let statuses: [PommeAgentCorrelatedResult]
    private let lock = NSLock()
    private var statusIndex = 0
    private var controls: [PommeControlStreamFrame]
    private var recordedOperations: [String] = []
    private var recordedStreamCalls: [StreamCall] = []

    init(start: PommeAgentCorrelatedResult, statuses: [PommeAgentCorrelatedResult], controls: [PommeControlStreamFrame] = []) {
        self.start = start
        self.statuses = statuses
        self.controls = controls
    }

    var operations: [String] { lock.withLock { recordedOperations } }
    var streamCalls: [StreamCall] { lock.withLock { recordedStreamCalls } }

    func perform(_ operation: String) -> PommeAgentCorrelatedResult {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append(operation)
        if operation == "process.start" { return start }
        if statusIndex < statuses.count {
            defer { statusIndex += 1 }
            return statuses[statusIndex]
        }
        return statuses.last ?? start
    }

    func send(
        jobID: UUID,
        stream: PommeAgentProtocol.Stream,
        data: Data?,
        dimensions: (columns: Int, rows: Int)?,
        signal: Int32?
    ) -> [PommeAgentJobStreamFrame] {
        precondition(jobID == UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        lock.lock()
        recordedStreamCalls.append(.init(stream: stream, data: data, dimensions: dimensions, signal: signal))
        lock.unlock()
        return []
    }

    func receiveControl() -> PommeControlStreamFrame? {
        lock.lock()
        defer { lock.unlock() }
        return controls.isEmpty ? nil : controls.removeFirst()
    }
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PommeAgentJobStreamFrame] = []

    func append(_ values: [PommeAgentJobStreamFrame]) {
        lock.lock()
        frames.append(contentsOf: values)
        lock.unlock()
    }

    func bytes(stream: PommeAgentProtocol.Stream) -> Data {
        lock.lock()
        let values = frames
        lock.unlock()
        return values.filter { $0.frame.stream == stream }.reduce(into: Data()) { result, frame in
            result.append(frame.frame.data ?? Data())
        }
    }
}
