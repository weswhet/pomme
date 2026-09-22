import Foundation
import Testing
import Synchronization

@Suite("Pomme foreground execution")
struct PommeForegroundExecutionTests {
    @Test("Desktop transport start failures are closed and opt-in", arguments: [true, false])
    func desktopTransportStartDiagnostic(exact: Bool) async throws {
        let messages = Mutex<[String]>([])
        let payload = exact ? try aquaPayload() : .object(["path": .string("/private/do-not-log")])
        try await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
            do {
                _ = try await PommeForegroundExecution.run(
                    payload: payload, timeout: 15,
                    perform: { _, _ in throw RunnerError.guestAgentTimedOut("private-secret") },
                    sendStream: { _, _, _ in Issue.record("No stream after failed start"); return [] })
                Issue.record("Expected original transport error")
            } catch RunnerError.guestAgentTimedOut(let operation) {
                #expect(operation == "private-secret")
            }
        }
        let lines = messages.withLock { $0 }
        if exact {
            let line = try #require(lines.first)
            #expect(lines.count == 1)
            #expect(line.contains("[DEBUG-desktop-transport-20260922] side=helper boundary=start "))
            #expect(line.contains("jobEstablished=false pollCount=0 errorKind=agentTimeout"))
            #expect(line.contains("elapsedMs="))
            #expect(line.contains("private") == false)
        } else { #expect(lines.isEmpty) }
    }

    private let jobID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let startRequestID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    private func aquaPayload() throws -> JSONValue {
        let request = try #require(PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 501))
        return try JSONValue(any: request.agentPayload())
    }

    @Test("Desktop transport phases preserve original errors and single cleanup", arguments: ["startValidation", "eof", "status", "statusValidation", "frameAccept", "terminalValidation", "signal"])
    func desktopTransportPhaseDiagnostic(phase: String) async throws {
        let messages = Mutex<[String]>([])
        let operations = Mutex<[String]>([])
        let payload = try aquaPayload()
        try await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
            do {
                _ = try await PommeForegroundExecution.run(
                    payload: payload, timeout: 15,
                    perform: { operation, _ in
                        operations.withLock { $0.append(operation) }
                        if operation == "process.start" {
                            return correlated(requestID: startRequestID,
                                result: phase == "startValidation" ? .object([:]) : started(), frames: [])
                        }
                        if operation == "process.signal" {
                            if phase == "signal" { throw RunnerError.guestAgentError("private-signal") }
                            return correlated(requestID: UUID(), result: .object([:]), frames: [])
                        }
                        if phase == "status" || phase == "signal" { throw RunnerError.guestAgentTimedOut("private-original") }
                        if phase == "statusValidation" {
                            return correlated(requestID: UUID(), result: .object([:]), frames: [])
                        }
                        return correlated(requestID: UUID(),
                            result: status(exited: true, exitCode: phase == "terminalValidation" ? nil : 0),
                            frames: [frame(jobID: jobID, stream: .exit)])
                    }, sendStream: { _, _, _ in
                        if phase == "eof" { throw RunnerError.guestAgentTimedOut("private-original") }
                        return []
                    }, onFrames: { _ in
                        if phase == "frameAccept" { throw RunnerError.guestAgentTimedOut("private-original") }
                    })
                Issue.record("Expected original error")
            } catch RunnerError.guestAgentTimedOut(let value) {
                #expect(["eof", "status", "frameAccept", "signal"].contains(phase))
                #expect(value == "private-original")
            } catch let error as PommeForegroundExecution.Error {
                #expect(["startValidation", "statusValidation", "terminalValidation"].contains(phase))
                #expect(error == .invalidCompletion)
            }
        }
        let lines = messages.withLock { $0 }
        #expect(lines.count == (phase == "signal" ? 2 : 1))
        let line = try #require(lines.last)
        #expect(line.contains("boundary=\(phase) "))
        #expect(line.contains("jobEstablished=\(phase != "startValidation")"))
        #expect(line.contains("pollCount=\(["startValidation", "eof"].contains(phase) ? 0 : 1)"))
        #expect(lines.allSatisfy { $0.contains("private") == false && $0.contains(jobID.uuidString.lowercased()) == false })
        let calls = operations.withLock { $0 }
        #expect(calls.filter { $0 == "process.start" }.count == 1)
        #expect(calls.filter { $0 == "process.signal" }.count == (phase == "startValidation" ? 0 : 1))
    }

    @Test("Temporary Aqua timing records success only for the exact probe", arguments: ["exact", "user", "environment", "stdinDataBase64", "pty", "arguments", "path"])
    func temporaryAquaTimingOptIn(variant: String) async throws {
        var payload = try #require(aquaPayload().objectValue)
        if variant != "exact" { payload[variant] = variant == "pty" ? .bool(false) : .string("private-mismatch") }
        if variant == "stdinDataBase64" { payload[variant] = .string("") }
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [correlated(requestID: UUID(), result: status(exited: true, exitCode: 0),
                                 frames: [frame(jobID: jobID, stream: .exit)])]
        )
        let result = try await run(payload: .object(payload), transport: transport)
        let diagnostic = result.result.objectValue?["_pommeDebugAqua20260922"]?.objectValue
        if variant == "exact" {
            let diagnostic = try #require(diagnostic)
            #expect(diagnostic["statusCount"] == .integer(1))
            #expect(diagnostic["lastExited"] == .bool(true))
            #expect(diagnostic["exitFrameBeforeSignal"] == .bool(true))
            #expect(diagnostic["validPositiveStartPID"] == .bool(true))
            assertTotalTiming(diagnostic)
            #expect(diagnostic.values.allSatisfy { value in
                if case .integer(let count) = value { return count >= 0 }
                if case .bool = value { return true }
                return false
            })
        } else { #expect(diagnostic == nil) }
        #expect(await transport.operationNames == ["process.start", "process.status"])
    }

    @Test("Temporary Aqua signal exit evidence never turns a timeout into success")
    func temporaryAquaSignalExitStaysFailure() async throws {
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []), statuses: [],
            signalFrames: [frame(jobID: jobID, stream: .exit)]
        )
        let result = try await run(payload: aquaPayload(), transport: transport, timeout: 0.03)
        let values = try #require(result.result.objectValue)
        let diagnostic = try #require(values["_pommeDebugAqua20260922"]?.objectValue)
        #expect(diagnostic["lastExited"] == .bool(false))
        #expect(diagnostic["exitFrameBeforeSignal"] == .bool(false))
        #expect(diagnostic["signalExitFrame"] == .bool(true))
        assertTotalTiming(diagnostic)
        #expect(values["timedOut"] == .bool(true))
        #expect(values["outputComplete"] == .bool(false))
        #expect(values["exited"] == .bool(false))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    private func assertTotalTiming(_ diagnostic: [String: JSONValue]) {
        guard case .integer(let total)? = diagnostic["totalMicros"] else {
            Issue.record("Expected total elapsed microseconds")
            return
        }
        let measured = ["startMicros", "eofMicros", "statusTotalMicros", "signalMicros"].reduce(Int64(0)) {
            if case .integer(let value)? = diagnostic[$1] { return $0 + value }
            return $0
        }
        #expect(total >= measured)
        #expect(total >= 0)
    }

    @Test("Cleanup receipts are limited to the three exact desktop probes", arguments: ["console", "aqua", "ps"], ["exact", "user", "uid", "environment", "stdinDataBase64", "attachStdin", "pty", "cwd", "arguments", "path", "unknown"])
    func desktopCleanupGate(stage: String, variant: String) async throws {
        let request: GuestCommandRequest
        switch stage {
        case "console": request = .init(path: "/usr/bin/stat", arguments: ["-f", "%Su:%u", "/dev/console"], timeout: 15)
        case "ps": request = .init(path: "/bin/ps", arguments: ["-axo", "uid=,comm="], timeout: 15)
        default: request = try #require(PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 501))
        }
        var payload = try #require(JSONValue(any: request.agentPayload()).objectValue)
        if variant != "exact" {
            payload[variant] = .string("mismatch")
            if variant == "stdinDataBase64" { payload[variant] = .string("") }
            if variant == "pty" || variant == "attachStdin" { payload[variant] = .bool(false) }
        }
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []), statuses: [],
            signalFrames: [frame(jobID: jobID, stream: .exit, signal: 15)]
        )
        let result = try await run(payload: .object(payload), transport: transport, timeout: 0.03)
        #expect((result.result.objectValue?[PommeForegroundExecution.desktopCleanupReceiptKey] != nil) == (variant == "exact"))
        #expect(result.result.objectValue?["timedOut"] == .bool(true))
        #expect(result.result.objectValue?["outputComplete"] == .bool(false))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    @Test("Aqua cleanup receipt requires validated host-observed same-job exit", arguments: ["valid", "falseAckExit", "signalExit", "badSignal", "priorExit", "ackOnly", "wrongJob", "malformedExit", "foreignOutput", "forged", "ordinary"])
    func aquaCleanupReceiptBoundary(mode: String) async throws {
        var start = try #require(started().objectValue)
        if mode == "forged" {
            start[PommeForegroundExecution.desktopCleanupReceiptKey] = .object([
                "jobID": .string(jobID.uuidString), "reapedAndDrained": .bool(true)
            ])
        }
        var frames: [PommeAgentJobStreamFrame] = []
        if mode != "ackOnly" && mode != "forged" && mode != "priorExit" {
            frames = [frame(jobID: mode == "wrongJob" ? UUID() : jobID, stream: .exit,
                            data: mode == "malformedExit" ? Data("invalid".utf8) : nil,
                            signal: mode == "signalExit" ? 15 : (mode == "badSignal" ? 128 : nil))]
            if mode == "foreignOutput" { frames.append(frame(jobID: UUID(), stream: .stdout, data: Data())) }
        }
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: .object(start),
                              frames: mode == "priorExit" ? [frame(jobID: jobID, stream: .exit)] : []),
            statuses: [], signalFrames: frames, signalAcknowledged: mode != "falseAckExit"
        )
        let payload: JSONValue = mode == "ordinary" ? .object(["path": .string("/usr/bin/true")]) : try aquaPayload()
        let result = try await run(payload: payload, transport: transport, timeout: 0.03)
        let values = try #require(result.result.objectValue)
        #expect(values["timedOut"] == .bool(true))
        #expect(values["outputComplete"] == .bool(mode == "priorExit"))
        #expect((values[PommeForegroundExecution.desktopCleanupReceiptKey] != nil) == ["valid", "falseAckExit", "signalExit", "priorExit"].contains(mode))
        #expect(await transport.signalCalls == 1)
    }

    @Test("Temporary Aqua wait snapshot is closed and optional for old guests", arguments: ["valid", "absent", "malformed"])
    func temporaryAquaWaitSnapshot(variant: String) async throws {
        var completed = try #require(status(exited: true, exitCode: 0).objectValue)
        if variant != "absent" {
            completed["_pommeDebugAquaWait20260922"] = .object([
                "waitRunningCount": variant == "valid" ? .integer(2) : .string("private-path"),
                "waitReapedCount": .integer(1), "waitInterruptedCount": .integer(3),
                "waitNoChildCount": .integer(0), "waitOtherErrorCount": .integer(0),
                "waitLastOutcome": variant == "valid" ? .integer(1) : .integer(99),
                "secret": .string("private-path")
            ])
        }
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [correlated(requestID: UUID(), result: .object(completed), frames: [frame(jobID: jobID, stream: .exit)])]
        )
        let result = try await run(payload: aquaPayload(), transport: transport)
        let diagnostic = try #require(result.result.objectValue?["_pommeDebugAqua20260922"]?.objectValue)
        #expect(result.result.objectValue?["outputComplete"] == .bool(true))
        #expect(diagnostic["secret"] == nil)
        if variant == "valid" {
            #expect(diagnostic["waitRunningCount"] == .integer(2))
            #expect(diagnostic["waitInterruptedCount"] == .integer(3))
            #expect(diagnostic["waitLastOutcome"] == .integer(1))
        } else {
            #expect(diagnostic["waitRunningCount"] == nil)
            #expect(diagnostic["waitLastOutcome"] == nil)
        }
    }

    @Test("polls until output is complete and retains stderr and exit status")
    func delayedOutputAndCompletion() async throws {
        // Given
        let firstStatus = correlated(
            requestID: UUID(),
            result: status(exited: false),
            frames: [frame(jobID: jobID, stream: .stdout, data: Data("early".utf8))]
        )
        let finalStatus = correlated(
            requestID: UUID(),
            result: status(exited: true, exitCode: 7),
            frames: [
                frame(jobID: jobID, stream: .stdout, data: Data("late".utf8)),
                frame(jobID: jobID, stream: .stderr, data: Data("warning".utf8)),
                frame(jobID: jobID, stream: .exit)
            ]
        )
        let transport = ForegroundTransport(
            start: correlated(
                requestID: startRequestID,
                result: started(),
                frames: []
            ),
            statuses: [firstStatus, finalStatus]
        )

        // When
        let result = try await run(transport: transport)

        // Then
        #expect(result.requestID == startRequestID)
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["exited"] == .bool(true))
        #expect(result.result.objectValue?["exitCode"] == .integer(7))
        #expect(result.streamFrames.filter { $0.frame.stream == .stdout }.count == 2)
        #expect(result.streamFrames.contains { $0.frame.stream == .stderr && $0.frame.data == Data("warning".utf8) })
        #expect(await transport.operationNames == ["process.start", "process.status", "process.status"])
        #expect(await transport.streamCalls.map(\.stream) == [.eof])
    }

    @Test("sends supplied input in bounded chunks followed by one EOF")
    func suppliedInputIsChunkedAndClosed() async throws {
        // Given
        let input = Data(repeating: 0x61, count: PommeAgentProtocol.maximumStreamChunkBytes * 2 + 7)
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [frame(jobID: jobID, stream: .exit)]
                )
            ]
        )

        // When
        _ = try await run(
            payload: .object([
                "path": .string("/bin/cat"),
                "arguments": .array([]),
                "stdinDataBase64": .string(input.base64EncodedString())
            ]),
            transport: transport
        )

        // Then
        let calls = await transport.streamCalls
        #expect(calls.map(\.stream) == [.stdin, .stdin, .stdin, .eof])
        #expect(calls.dropLast().map { $0.data?.count } == [PommeAgentProtocol.maximumStreamChunkBytes, PommeAgentProtocol.maximumStreamChunkBytes, 7])
        #expect(calls.last?.data == nil)
    }

    @Test("bounds unary output while preserving the terminal frame")
    func boundedOutput() async throws {
        // Given
        let chunk = Data(repeating: 0x62, count: PommeAgentProtocol.maximumStreamChunkBytes)
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [
                        frame(jobID: jobID, stream: .stdout, data: chunk),
                        frame(jobID: jobID, stream: .stdout, data: chunk),
                        frame(jobID: jobID, stream: .stdout, data: chunk),
                        frame(jobID: jobID, stream: .exit)
                    ]
                )
            ]
        )

        // When
        let result = try await run(transport: transport)

        // Then
        let stdoutBytes = result.streamFrames
            .filter { $0.frame.stream == .stdout }
            .compactMap { $0.frame.data?.count }
            .reduce(0, +)
        #expect(stdoutBytes == PommeForegroundExecution.maximumBufferedOutputBytes)
        #expect(result.result.objectValue?["stdoutTruncated"] == .bool(true))
        #expect(result.streamFrames.contains { $0.frame.stream == .exit })
    }

    @Test("callback mode forwards all frames and does not return a second copy")
    func callbackMode() async throws {
        // Given
        let collector = FrameCollector()
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [
                        frame(jobID: jobID, stream: .stdout, data: Data("out".utf8)),
                        frame(jobID: jobID, stream: .stderr, data: Data("err".utf8)),
                        frame(jobID: jobID, stream: .exit)
                    ]
                )
            ]
        )

        // When
        let result = try await run(transport: transport) { frames in
            await collector.append(frames)
        }

        // Then
        #expect(result.streamFrames.isEmpty)
        #expect(await collector.frames.count == 3)
        #expect(await collector.frames.contains { $0.frame.stream == .stderr })
        #expect(result.result.objectValue?["stdoutTruncated"] == .bool(false))
        #expect(result.result.objectValue?["stderrTruncated"] == .bool(false))
    }

    @Test("timeout sends SIGTERM once and reports the still-owned job")
    func timeoutDoesNotRestart() async throws {
        // Given
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: []
        )

        // When
        let result = try await run(transport: transport, timeout: 0.03)

        // Then
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["exited"] == .bool(false))
        #expect(result.result.objectValue?["timedOut"] == .bool(true))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    @Test("cancellation sends SIGTERM once and reports the still-owned job")
    func cancellationDoesNotRestart() async throws {
        // Given
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: []
        )
        let task = Task {
            try await run(transport: transport, timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(20))

        // When
        task.cancel()
        let result = try await task.value

        // Then
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["cancelled"] == .bool(true))
        #expect(result.result.objectValue?["timedOut"] == .bool(false))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    @Test("rejects a stream frame for another job and terminates the known job once")
    func unrelatedJobFrameIsRejected() async throws {
        // Given
        let otherJob = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [frame(jobID: otherJob, stream: .stdout, data: Data("wrong".utf8))]
                )
            ]
        )

        // When / Then
        do {
            _ = try await run(transport: transport)
            Issue.record("Expected an unrelated-job stream frame to be rejected.")
        } catch let error as PommeForegroundExecution.Error {
            #expect(error == .unrelatedJobFrame)
        }
        #expect(await transport.signalCalls == 1)
    }

    @Test("rejects detached payloads before starting a process")
    func detachedPayloadIsRejected() async throws {
        // Given
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: []
        )

        // When / Then
        do {
            _ = try await run(
                payload: .object(["detached": .bool(true)]),
                transport: transport
            )
            Issue.record("Expected detached execution to be rejected.")
        } catch let error as PommeForegroundExecution.Error {
            #expect(error == .detachedPayload)
        }
        #expect(await transport.operationNames.isEmpty)
    }

    private func run(
        payload: JSONValue = .object([
            "path": .string("/bin/true"),
            "arguments": .array([])
        ]),
        transport: ForegroundTransport,
        // This is only the fixture's operation budget. The implementation's
        // bounded deadline behavior is covered by the explicit short-timeout
        // tests below; the larger default avoids starvation under the full
        // parallel suite.
        timeout: TimeInterval = 5,
        onFrames: PommeForegroundExecution.FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        try await PommeForegroundExecution.run(
            payload: payload,
            timeout: timeout,
            perform: { operation, payload in
                try await transport.perform(operation: operation, payload: payload)
            },
            sendStream: { jobID, stream, data in
                try await transport.sendStream(jobID: jobID, stream: stream, data: data)
            },
            onFrames: onFrames
        )
    }

    private func started() -> JSONValue {
        .object([
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(false)
        ])
    }

    private func status(exited: Bool, exitCode: Int64? = nil, signal: Int64? = nil) -> JSONValue {
        var values: [String: JSONValue] = [
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(exited)
        ]
        if let exitCode { values["exitCode"] = .integer(exitCode) }
        if let signal { values["signal"] = .integer(signal) }
        return .object(values)
    }

    private func frame(
        jobID: UUID,
        stream: PommeAgentProtocol.Stream,
        data: Data? = nil,
        signal: Int32? = nil
    ) -> PommeAgentJobStreamFrame {
        try! .init(jobID: jobID, frame: .init(requestID: UUID(), stream: stream, data: data, signal: signal))
    }

    private func correlated(
        requestID: UUID,
        result: JSONValue,
        frames: [PommeAgentJobStreamFrame]
    ) -> PommeAgentCorrelatedResult {
        .init(requestID: requestID, result: result, streamFrames: frames)
    }
}

private actor FrameCollector {
    private(set) var frames: [PommeAgentJobStreamFrame] = []

    func append(_ values: [PommeAgentJobStreamFrame]) { frames.append(contentsOf: values) }
}

private actor ForegroundTransport {
    struct StreamCall: Sendable {
        let jobID: UUID
        let stream: PommeAgentProtocol.Stream
        let data: Data?
    }

    let start: PommeAgentCorrelatedResult
    let statuses: [PommeAgentCorrelatedResult]
    let signalFrames: [PommeAgentJobStreamFrame]
    let signalAcknowledged: Bool
    private var statusIndex = 0
    private(set) var operationNames: [String] = []
    private(set) var streamCalls: [StreamCall] = []
    private(set) var signalCalls = 0

    init(start: PommeAgentCorrelatedResult, statuses: [PommeAgentCorrelatedResult], signalFrames: [PommeAgentJobStreamFrame] = [], signalAcknowledged: Bool = true) {
        self.start = start
        self.statuses = statuses
        self.signalFrames = signalFrames
        self.signalAcknowledged = signalAcknowledged
    }

    func perform(operation: String, payload: JSONValue) -> PommeAgentCorrelatedResult {
        operationNames.append(operation)
        switch operation {
        case "process.start": return start
        case "process.status":
            if statusIndex < statuses.count {
                defer { statusIndex += 1 }
                return statuses[statusIndex]
            }
            return .init(
                requestID: UUID(),
                result: .object([
                    "jobID": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                    "pid": .integer(42),
                    "detached": .bool(false),
                    "exited": .bool(false)
                ]),
                streamFrames: []
            )
        case "process.signal":
            signalCalls += 1
            return .init(requestID: UUID(), result: .object([
                "jobID": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), "signalled": .bool(signalAcknowledged)
            ]), streamFrames: signalFrames)
        default:
            return .init(requestID: UUID(), result: .object([:]), streamFrames: [])
        }
    }

    func sendStream(jobID: UUID, stream: PommeAgentProtocol.Stream, data: Data?) -> [PommeAgentJobStreamFrame] {
        streamCalls.append(.init(jobID: jobID, stream: stream, data: data))
        return []
    }
}
@Suite("Foreground interruption messages")
struct PommeForegroundInterruptionMessageTests {
    @Test("A signalled timeout says the process was stopped, not that it is listed")
    func timedOutAndSignalled() {
        let text = PommeForegroundExecution.interruptionMessage(timedOut: true, terminationRequested: true)

        #expect(text == "Foreground command timed out; the guest process was signalled to stop."
                + " Use --detach to run a command that outlives the request.")
        // A foreground job is never in `jobs list`, so it must not be suggested.
        #expect(!text.contains("jobs list"))
    }

    @Test("An unsignalled timeout admits the process may still be running")
    func timedOutWithoutSignal() {
        for requested in [false, Bool?.none] {
            let text = PommeForegroundExecution.interruptionMessage(timedOut: true, terminationRequested: requested)

            #expect(text == "Foreground command timed out and the guest process could not be signalled;"
                    + " it may still be running in the guest.")
            #expect(!text.contains("jobs list"))
        }
    }

    @Test("Cancellation reads the same way without the detach hint")
    func cancelled() {
        #expect(PommeForegroundExecution.interruptionMessage(timedOut: false, terminationRequested: true)
                == "Foreground command was cancelled; the guest process was signalled to stop.")
        #expect(PommeForegroundExecution.interruptionMessage(timedOut: false, terminationRequested: false)
                == "Foreground command was cancelled and the guest process could not be signalled;"
                + " it may still be running in the guest.")
    }
}
