import Darwin
import Foundation
import Testing

@Suite("Foreground helper completion and CLI output")
struct PommeForegroundControlTests {
    @Test("Actual guest exit codes and signals reach the CLI", arguments: [0, 7, 127, 255])
    func preservesGuestExit(_ code: Int) throws {
        let result = PommeAgentCorrelatedResult(requestID: UUID(), result: .object([
            "exited": .bool(true), "exitCode": .integer(Int64(code))
        ]), streamFrames: [])
        let line = try PommeCore.foregroundResultJSON(result)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["hostExitCode"] as? Int == code)
        #expect(object["ok"] as? Bool == (code == 0))
    }

    @Test("Termination and timeout never report launch success")
    func incompleteOrSignalledExecution() throws {
        for (terminal, expected) in [
            (["exited": JSONValue.bool(true), "signal": .integer(15)], 143),
            (["exited": .bool(false), "timedOut": .bool(true)], 124),
            (["exited": .bool(false), "cancelled": .bool(true)], 130),
        ] {
            let line = try PommeCore.foregroundResultJSON(.init(requestID: UUID(), result: .object(terminal), streamFrames: []))
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["hostExitCode"] as? Int == expected)
            #expect(object["ok"] as? Bool == false)
        }
        #expect(throws: PommeAgentProtocol.Error.invalidResponse) {
            try PommeCore.foregroundResultJSON(.init(requestID: UUID(), result: .object(["exited": .bool(false)]), streamFrames: []))
        }
    }

    @Test("Output larger than a single control frame survives to the terminal response")
    func collectsUntilTerminalResponse() throws {
        // Arrange: each frame is legal even when their total exceeds 256 KiB.
        let id = UUID()
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        var events = (0..<6).map { index in
            PommeControlStreamEvent.stream(.init(id: id, sequence: UInt64(index), stream: .stdout, data: chunk))
        }
        events.append(.stream(.init(id: id, sequence: 6, stream: .stderr, data: Data([0x00, 0xff, 0x0a]))))
        events.append(.response(.success(id: id, result: .object([
            "ok": .bool(false), "hostExitCode": .integer(7),
            "result": .object(["exited": .bool(true), "exitCode": .integer(7)])
        ]))))
        var index = 0

        // Act: consume the same event stream used by the CLI adapter.
        let result = try PommeCore.collectForegroundResponse {
            defer { index += 1 }
            return events[index]
        }
        let outputs = try CLIOutputWriter.foregroundOutput(result)

        // Assert: no synthetic text/newline, no stderr merging, and no lost exit.
        #expect(index == events.count)
        #expect(PommeCore.hostExitCode(from: result) == 7)
        #expect(result["ok"] as? Bool == false)
        #expect(outputs.filter { $0.descriptor == STDOUT_FILENO }.reduce(0) { $0 + $1.data.count } == 6 * chunk.count)
        #expect(outputs.last?.descriptor == STDERR_FILENO)
        #expect(outputs.last?.data == Data([0x00, 0xff, 0x0a]))
    }

    @Test("Silent commands return no output bytes")
    func silentCommand() throws {
        let result = try PommeCore.collectForegroundResponse {
            .response(.success(id: UUID(), result: .object([
                "ok": .bool(true), "hostExitCode": .integer(0),
                "result": .object(["exited": .bool(true), "exitCode": .integer(0)])
            ])))
        }
        #expect(try CLIOutputWriter.foregroundOutput(result).isEmpty)
    }

    @Test("The collector rejects output beyond its explicit buffer budget")
    func rejectsOverflow() throws {
        let frame = PommeControlStreamFrame(id: UUID(), sequence: 0, stream: .stdout, data: Data([1, 2]))
        #expect(throws: RunnerError.self) {
            try PommeCore.collectForegroundResponse(maximumOutputBytes: 1) { .stream(frame) }
        }
    }

    @Test("Socket closure without completion never becomes success")
    func missingCompletionFails() {
        #expect(throws: RunnerError.self) {
            try PommeCore.collectForegroundResponse { throw RunnerError.guestAgentDisconnected }
        }
    }

    @Test("A silent foreground peer is bounded by the transport deadline")
    func silentPeerTimesOut() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
        }
        let session = PommeControlStreamSession(
            id: UUID(), fileDescriptor: sockets[0])
        let partialResponse = Data("{\"type\":\"response\"".utf8)
        let written = partialResponse.withUnsafeBytes { bytes in
            Darwin.write(sockets[1], bytes.baseAddress, bytes.count)
        }
        #expect(written == partialResponse.count)
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: RunnerError.self) {
            try PommeCore.collectForegroundResponse(
                timeout: 0.05,
                receive: { remaining in
                    try session.receiveEventIfAvailable(timeout: remaining)
                }
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }

    @Test("A peer that eventually closes cannot hold the bounded collector")
    func delayedPeerShutdownIsBounded() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
        }
        let session = PommeControlStreamSession(
            id: UUID(), fileDescriptor: sockets[0])
        let partialResponse = Data("{\"type\":\"response\"".utf8)
        let written = partialResponse.withUnsafeBytes { bytes in
            Darwin.write(sockets[1], bytes.baseAddress, bytes.count)
        }
        #expect(written == partialResponse.count)

        let peer = sockets[1]
        let peerDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { peerDone.signal() }
            usleep(1_100_000)
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
        defer { _ = peerDone.wait(timeout: .now() + .seconds(2)) }

        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: RunnerError.self) {
            try PommeCore.collectForegroundResponse(
                timeout: 0.05,
                receive: { remaining in
                    try session.receiveEventIfAvailable(timeout: remaining)
                }
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.5)
    }

    @Test("A terminal frame after the guest deadline still fits the transport grace")
    func delayedTerminalFrameFitsGrace() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
        }
        let id = UUID()
        let session = PommeControlStreamSession(id: id, fileDescriptor: sockets[0])
        let response = try ControlWireCodec.encodeLine(
            PommeControlResponse.success(
                id: id,
                result: .object(["exited": .bool(true)])
            )
        )
        let writerDone = DispatchSemaphore(value: 0)
        let peer = sockets[1]
        let nominalGuestDeadline = 0.05
        Thread.detachNewThread {
            defer { writerDone.signal() }
            usleep(100_000)
            _ = response.withUnsafeBytes {
                Darwin.write(peer, $0.baseAddress, $0.count)
            }
        }
        defer { _ = writerDone.wait(timeout: .now() + .seconds(1)) }

        let result = try PommeCore.collectForegroundResponse(
            timeout: nominalGuestDeadline + 0.2,
            receive: { remaining in
                try session.receiveEventIfAvailable(timeout: remaining)
            }
        )
        #expect(result["exited"] as? Bool == true)
    }

    @Test("Malformed binary output is not decoded with replacement bytes")
    func malformedOutputFails() {
        #expect(throws: RunnerError.self) {
            try CLIOutputWriter.foregroundOutput(["streamFrames": [["stream": "stdout", "dataBase64": "bad!"]]])
        }
    }
}
