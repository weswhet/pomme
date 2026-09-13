import Darwin
import Foundation
import Testing

@Suite("Public PTY terminal and control polling", .serialized)
struct PommePublicPTYTerminalBridgeTests {
    @Test("Terminal output is byte-exact and original terminal state returns after child exit")
    func preservesBytesAndRestoresTerminal() throws {
        let terminal = try PublicPTYTestTerminal()
        let original = try terminal.attributes()
        let id = UUID()
        let bytes = Data([0, 255, 10, 13]) + Data("pty-marker".utf8)
        var errors: [Int32] = [-1, -1]
        try #require(pipe(&errors) == 0)
        defer { errors.forEach { _ = Darwin.close($0) } }
        try #require(fcntl(errors[0], F_SETFL, fcntl(errors[0], F_GETFL) | O_NONBLOCK) == 0)
        let errorBytes = Data([255, 0, 10])
        var index = 0
        let events: [PommeControlStreamEvent] = [
            .stream(.init(id: id, sequence: 0, stream: .stdout, data: bytes)),
            .stream(.init(id: id, sequence: 1, stream: .stderr, data: errorBytes)),
            completion(id: id, code: 7),
        ]
        let bridge = PommePublicPTYTerminalBridge(transport: .init(send: { _, _, _, _ in }, receive: { _ in
            defer { index += 1 }
            return events[index]
        }), inputFD: terminal.slave, outputFD: terminal.slave, errorFD: errors[1])
        let result = try bridge.run(timeout: 1)
        #expect(PommeCore.hostExitCode(from: result) == 7)
        #expect(result["foreground"] as? Bool == true)
        #expect(try CLIOutputWriter.foregroundOutput(result).isEmpty)
        #expect(try terminal.output() == bytes)
        var observedErrors = [UInt8](repeating: 0, count: 3)
        #expect(Darwin.read(errors[0], &observedErrors, observedErrors.count) == 3)
        #expect(Data(observedErrors) == errorBytes)
        #expect(try terminal.attributes() == original)
    }

    @Test("Terminal input, interrupt, and changed dimensions reach the stream")
    func forwardsInputAndResize() throws {
        let terminal = try PublicPTYTestTerminal()
        let original = try terminal.attributes()
        let id = UUID()
        var sent: [PommeControlStreamFrame] = []
        var receives = 0
        let bridge = PommePublicPTYTerminalBridge(transport: .init(send: { stream, data, payload, eof in
            sent.append(.init(id: id, sequence: UInt64(sent.count), stream: stream, data: data, payload: payload, eof: eof))
        }, receive: { _ in
            receives += 1
            if receives == 1 {
                try terminal.input(Data([0x61, 0x03, 0x62]))
                var size = winsize(ws_row: 44, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
                #expect(ioctl(terminal.slave, TIOCSWINSZ, &size) == 0)
                return nil
            }
            return completion(id: id, code: 0)
        }), inputFD: terminal.slave, outputFD: terminal.slave)
        _ = try bridge.run(timeout: 1)
        let input = try sent.filter { $0.stream == .stdin }.compactMap { try $0.decodedData() }
        #expect(input == [Data("a".utf8), Data("b".utf8)])
        #expect(sent.filter { $0.stream == .signal }.map { $0.payload?.objectValue?["signal"] } == [.integer(Int64(SIGINT))])
        let sizes = sent.filter { $0.stream == .resize }
        #expect(sizes.count == 2)
        #expect(sizes.first?.payload?.objectValue?["columns"] == .integer(101))
        #expect(sizes.first?.payload?.objectValue?["rows"] == .integer(33))
        #expect(sizes.last?.payload?.objectValue?["columns"] == .integer(120))
        #expect(sizes.last?.payload?.objectValue?["rows"] == .integer(44))
        #expect(try terminal.attributes() == original)
        #expect(try terminal.output().isEmpty)
    }

    @Test("Terminal state returns after stream setup, transport, and malformed-output failures", arguments: ["resize", "transport", "output"])
    func restoresAfterFailure(_ failure: String) throws {
        let terminal = try PublicPTYTestTerminal()
        let original = try terminal.attributes()
        var cancelled = false
        let bridge = PommePublicPTYTerminalBridge(transport: .init(send: { stream, _, _, _ in
            if stream == .cancellation { cancelled = true }
            if failure == "resize", stream == .resize { throw POSIXError(.EIO) }
        }, receive: { _ in
            if failure == "output" { return .stream(.init(id: UUID(), sequence: 0, stream: .stdout)) }
            throw POSIXError(.EIO)
        }), inputFD: terminal.slave, outputFD: terminal.slave)
        #expect(throws: (any Error).self) { try bridge.run(timeout: 1) }
        #expect(cancelled)
        #expect(try terminal.attributes() == original)
    }

    @Test("A host deadline preserves timeout exit 124 when the helper acknowledges cancellation")
    func localTimeoutDoesNotBecomeCancellation() throws {
        let terminal = try PublicPTYTestTerminal()
        let original = try terminal.attributes()
        var cancelled = false
        let bridge = PommePublicPTYTerminalBridge(transport: .init(send: { stream, _, _, _ in
            if stream == .cancellation { cancelled = true }
        }, receive: { timeout in
            if cancelled {
                return .response(.success(id: UUID(), result: .object([
                    "ok": .bool(false), "hostExitCode": .integer(130),
                    "result": .object(["exited": .bool(false), "cancelled": .bool(true)]),
                ])))
            }
            Thread.sleep(forTimeInterval: timeout)
            return nil
        }), inputFD: terminal.slave, outputFD: terminal.slave)
        let result = try bridge.run(timeout: 0.01)
        #expect(result["hostExitCode"] as? Int == 124)
        #expect((result["result"] as? [String: Any])?["timedOut"] as? Bool == true)
        #expect(try terminal.attributes() == original)
    }

    @Test("A silent helper cannot keep the terminal raw indefinitely after timeout")
    func boundsMissingCancellationResponse() throws {
        let terminal = try PublicPTYTestTerminal()
        let original = try terminal.attributes()
        var cancellationCount = 0
        let bridge = PommePublicPTYTerminalBridge(transport: .init(send: { stream, _, _, _ in
            if stream == .cancellation { cancellationCount += 1 }
        }, receive: { timeout in
            Thread.sleep(forTimeInterval: timeout)
            return nil
        }), inputFD: terminal.slave, outputFD: terminal.slave)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) { try bridge.run(timeout: 0.01) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 4)
        #expect(cancellationCount == 1)
        #expect(try terminal.attributes() == original)
    }

    private func completion(id: UUID, code: Int) -> PommeControlStreamEvent {
        .response(.success(id: id, result: .object([
            "ok": .bool(code == 0), "hostExitCode": .integer(Int64(code)),
            "result": .object(["exited": .bool(true), "exitCode": .integer(Int64(code)), "outputComplete": .bool(true)]),
        ])))
    }

    @Test("An incomplete frame yields while preserving bytes for the next poll")
    func partialFrameDoesNotBlockTerminalPolling() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        let id = UUID()
        let session = PommeControlStreamSession(id: id, fileDescriptor: pair[0])
        let frame = PommeControlStreamFrame(id: id, sequence: 0, stream: .stdout, data: Data("marker".utf8))
        let encoded = try ControlWireCodec.encodeLine(frame)
        let split = encoded.count / 2
        try ControlWireCodec.writeFrame(Data(encoded.prefix(split)), to: pair[1])
        let writer = pair[1]
        let remainder = Data(encoded.dropFirst(split))
        let continuation = DispatchGroup()
        continuation.enter()
        defer { continuation.wait() }
        // The delayed continuation also bounds this regression if polling accidentally blocks.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            defer { continuation.leave() }
            try? ControlWireCodec.writeFrame(remainder, to: writer)
        }
        let first = try session.receiveEventIfAvailable(timeout: 0.02)
        #expect(first == nil)
        guard first == nil else { return }
        guard case .stream(let received)? = try session.receiveEventIfAvailable(timeout: 1) else {
            Issue.record("Expected the reassembled output frame")
            return
        }
        #expect(try received.decodedData() == Data("marker".utf8))
    }

    @Test("Buffered terminal responses do not wait for more socket bytes")
    func bufferedResponseRemainsAvailable() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        let id = UUID()
        let session = PommeControlStreamSession(id: id, fileDescriptor: pair[0])
        let frame = PommeControlStreamFrame(id: id, sequence: 0, stream: .stdout, data: Data("marker".utf8))
        let response = PommeControlResponse.success(id: id, result: .object(["hostExitCode": .integer(7)]))
        let bytes = try ControlWireCodec.encodeLine(frame) + ControlWireCodec.encodeLine(response)
        try ControlWireCodec.writeFrame(bytes, to: pair[1])
        guard case .stream? = try session.receiveEventIfAvailable(timeout: 0.1) else {
            Issue.record("Expected output before the terminal response")
            return
        }
        guard case .response(let received)? = try session.receiveEventIfAvailable(timeout: 0.02) else {
            Issue.record("Expected the already-buffered terminal response")
            return
        }
        #expect(received.id == id)
    }
}

/// A real terminal pair with nonblocking observation, isolated from the test runner's terminal.
private final class PublicPTYTestTerminal: @unchecked Sendable {
    let master: Int32
    let slave: Int32

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
        self.master = master
        self.slave = slave
        guard fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) == 0 else {
            throw POSIXError(.EIO)
        }
        var size = winsize(ws_row: 33, ws_col: 101, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(slave, TIOCSWINSZ, &size) == 0 else { throw POSIXError(.EIO) }
    }

    deinit {
        _ = Darwin.close(master)
        _ = Darwin.close(slave)
    }

    func attributes() throws -> [UInt64] {
        var state = termios()
        guard tcgetattr(slave, &state) == 0 else { throw POSIXError(.EIO) }
        let controls = withUnsafeBytes(of: state.c_cc) { $0.map(UInt64.init) }
        // Darwin sets PENDIN when canonical mode is restored. It is pending-input
        // state (sys/termios.h), not a changed terminal configuration.
        return [UInt64(state.c_iflag), UInt64(state.c_oflag), UInt64(state.c_cflag),
                UInt64(state.c_lflag & ~tcflag_t(PENDIN)), UInt64(cfgetispeed(&state)), UInt64(cfgetospeed(&state))] + controls
    }

    func output() throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(master, &bytes, bytes.count)
            if count > 0 { result.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return result }
            else if errno != EINTR { throw POSIXError(.EIO) }
        }
    }

    func input(_ data: Data) throws {
        let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == data.count else { throw POSIXError(.EIO) }
    }
}
