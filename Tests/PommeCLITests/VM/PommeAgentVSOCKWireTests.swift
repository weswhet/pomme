import Darwin
import Foundation
import Testing

@Suite("Pomme agent VSOCK wire")
struct PommeAgentVSOCKWireTests {
    @Test("Signal exchange requires its response even after a correlated exit stream", arguments: ["response", "silent", "exitOnly"])
    func signalResponseDeadlineCharacterization(mode: String) throws {
        let jobID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let request = PommeAgentProtocol.Envelope.request(
            operation: "process.signal",
            payload: .object(["jobID": .string(jobID), "signal": .integer(15)])
        )
        let response = PommeAgentProtocol.Envelope.response(
            to: request, result: .object(["jobID": .string(jobID), "signalled": .bool(true)])
        )
        let exit = PommeAgentProtocol.Envelope(
            kind: .stream, requestID: request.requestID, operation: "process.exit",
            payload: .object(["jobID": .string(jobID), "stream": .string("exit"), "signal": .integer(15)])
        )
        let ready = DispatchSemaphore(value: 0)
        let exchangeFinished = DispatchSemaphore(value: 0)
        try Self.withWire(peer: { fileDescriptor in
            // Queue the exit before starting the deadline, so this case does
            // not depend on scheduling the peer within a short timeout.
            if mode == "exitOnly" {
                try Self.writeAll(try PommeAgentProtocol.encode(exit), to: fileDescriptor)
            }
            ready.signal()
            // One-byte reads leave any duplicate request bytes on the socket.
            let received = try PommeAgentProtocol.decode(Self.readLine(from: fileDescriptor, maximumReadBytes: 1))
            guard received == request else { throw WireTestError.unexpectedRequest }
            if mode == "response" {
                try Self.writeAll(try PommeAgentProtocol.encode(response), to: fileDescriptor)
            }
            guard exchangeFinished.wait(timeout: .now() + .seconds(2)) == .success else {
                throw WireTestError.peerTimedOut
            }
            var byte: UInt8 = 0
            let count = Darwin.recv(fileDescriptor, &byte, 1, MSG_DONTWAIT)
            let savedErrno = errno
            #expect(count == -1)
            #expect(savedErrno == EAGAIN || savedErrno == EWOULDBLOCK)
        }) { wire in
            defer { exchangeFinished.signal() }
            try #require(ready.wait(timeout: .now() + .seconds(2)) == .success)
            if mode == "response" {
                let delivered = try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 1)
                let lines = delivered.split(separator: 0x0A, omittingEmptySubsequences: true)
                try #require(lines.count == 1)
                #expect(try PommeAgentProtocol.decode(Data(lines[0])) == response)
            } else {
                do {
                    _ = try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 0.05)
                    Issue.record("Withheld signal response must time out, never return partial exit frames")
                } catch RunnerError.guestAgentTimedOut(let operation) {
                    #expect(operation == "Pomme agent exchange")
                }
            }
        }
    }

    @Test("stream input returns a response without synthetic output")
    func streamInputZeroOutputAck() throws {
        let request = PommeAgentProtocol.Envelope(
            kind: .stream,
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000051")),
            operation: "process.stdin",
            payload: .object([
                "stream": .string("stdin"),
                "dataBase64": .string(Data("input".utf8).base64EncodedString())
            ])
        )
        let response = PommeAgentProtocol.Envelope.response(
            to: request,
            result: .object(["accepted": .bool(true)])
        )

        let delivered = try Self.withWire(peer: { fileDescriptor in
            let received = try Self.readEnvelope(from: fileDescriptor)
            guard received == request else { throw WireTestError.unexpectedRequest }
            try Self.writeAll(try PommeAgentProtocol.encode(response), to: fileDescriptor)
        }) { wire in
            try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 1)
        }

        let lines = delivered.split(separator: 0x0A, omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        guard let line = lines.first else { return }
        let received = try PommeAgentProtocol.decode(Data(line))
        #expect(received == response)
        #expect(received.kind == .response)
    }

    @Test("a delayed acknowledgement keeps output exchange open until response")
    func delayedAcknowledgementDoesNotFinishEarly() throws {
        let request = PommeAgentProtocol.Envelope.request(
            operation: "process.start",
            payload: .object(["command": .string("/bin/echo")]),
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000052"))
        )
        let output = PommeAgentProtocol.Envelope(
            kind: .stream,
            requestID: request.requestID,
            operation: "process.stdout",
            payload: .object([
                "stream": .string("stdout"),
                "dataBase64": .string(Data("ready\n".utf8).base64EncodedString())
            ])
        )
        let response = PommeAgentProtocol.Envelope.response(
            to: request,
            result: .object(["exitCode": .integer(0)])
        )
        let outputDelayNanoseconds: UInt64 = 150_000_000

        let started = DispatchTime.now().uptimeNanoseconds
        let delivered = try Self.withWire(peer: { fileDescriptor in
            let received = try Self.readEnvelope(from: fileDescriptor)
            guard received == request else { throw WireTestError.unexpectedRequest }
            try Self.writeAll(try PommeAgentProtocol.encode(output), to: fileDescriptor)
            usleep(useconds_t(outputDelayNanoseconds / 1_000))
            try Self.writeAll(try PommeAgentProtocol.encode(response), to: fileDescriptor)
        }) { wire in
            try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 2)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        #expect(elapsed >= outputDelayNanoseconds - 25_000_000)
        let lines = delivered.split(separator: 0x0A, omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(try PommeAgentProtocol.decode(Data(lines[0])).kind == .stream)
        #expect(try PommeAgentProtocol.decode(Data(lines[1])) == response)
    }

    @Test("a response followed by peer shutdown is consumed despite POLLIN and HUP")
    func responseBeforePeerShutdownWrite() throws {
        let request = PommeAgentProtocol.Envelope.request(
            operation: "agent.health",
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000053"))
        )
        let response = PommeAgentProtocol.Envelope.response(
            to: request,
            result: .object(["healthy": .bool(true)])
        )

        let delivered = try Self.withWire(peer: { fileDescriptor in
            let received = try Self.readEnvelope(from: fileDescriptor)
            guard received == request else { throw WireTestError.unexpectedRequest }
            try Self.writeAll(try PommeAgentProtocol.encode(response), to: fileDescriptor)
            guard Darwin.shutdown(fileDescriptor, SHUT_WR) == 0 else { try throwPOSIX("shutdown") }
        }) { wire in
            try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 1)
        }

        let lines = delivered.split(separator: 0x0A, omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        #expect(try PommeAgentProtocol.decode(Data(lines[0])) == response)
    }

    @Test("a response for another request is rejected")
    func wrongCorrelationRejected() throws {
        let request = PommeAgentProtocol.Envelope.request(
            operation: "agent.health",
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000054"))
        )
        let wrongRequest = PommeAgentProtocol.Envelope.request(
            operation: request.operation,
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000055"))
        )
        let response = PommeAgentProtocol.Envelope.response(
            to: wrongRequest,
            result: .object(["healthy": .bool(true)])
        )

        #expect(throws: PommeAgentProtocol.Error.self) {
            try Self.withWire(peer: { fileDescriptor in
                let received = try Self.readEnvelope(from: fileDescriptor)
                guard received == request else { throw WireTestError.unexpectedRequest }
                try Self.writeAll(try PommeAgentProtocol.encode(response), to: fileDescriptor)
            }) { wire in
                try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 1)
            }
        }
    }

    @Test("a disconnected peer write throws without SIGPIPE")
    func disconnectedPeerWriteFails() throws {
        let sockets = try Self.makeSocketPair()
        defer { _ = Darwin.close(sockets.client) }
        _ = Darwin.close(sockets.peer)

        let request = PommeAgentProtocol.Envelope.request(
            operation: "agent.health",
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000056"))
        )
        let wire = PommeAgentVSOCKWire(fileDescriptor: sockets.client)
        #expect(throws: (any Error).self) {
            try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 1)
        }
    }

    @Test("an invalid timeout is rejected before any request bytes are written")
    func invalidTimeoutDoesNotWrite() throws {
        let sockets = try Self.makeSocketPair()
        defer {
            _ = Darwin.close(sockets.client)
            _ = Darwin.close(sockets.peer)
        }

        let request = PommeAgentProtocol.Envelope.request(
            operation: "agent.health",
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000057"))
        )
        let wire = PommeAgentVSOCKWire(fileDescriptor: sockets.client)
        #expect(throws: PommeAgentProtocol.Error.self) {
            try wire.exchange(try PommeAgentProtocol.encode(request), timeout: 0)
        }

        var descriptor = pollfd(fd: sockets.peer, events: Int16(POLLIN), revents: 0)
        #expect(Darwin.poll(&descriptor, 1, 50) == 0)
    }

    private enum WireTestError: Error, Sendable {
        case unexpectedRequest
        case peerTimedOut
        case peerFailed
    }

    private final class PeerThread: @unchecked Sendable {
        private let fileDescriptor: Int32
        private let completion = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var failure: WireTestError?
        private var joined = false

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        func start(operation: @escaping @Sendable () throws -> Void) {
            Thread.detachNewThread { [self] in
                do {
                    try operation()
                } catch let error as WireTestError {
                    lock.withLock { failure = error }
                } catch {
                    lock.withLock { failure = .peerFailed }
                }
                completion.signal()
            }
        }

        func join() throws {
            guard !joined else { return }
            guard completion.wait(timeout: .now() + .seconds(2)) == .success else {
                _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
                guard completion.wait(timeout: .now() + .seconds(1)) == .success else {
                    throw WireTestError.peerTimedOut
                }
                joined = true
                throw WireTestError.peerTimedOut
            }
            joined = true
            if let failure = lock.withLock({ failure }) { throw failure }
        }

        func abortAndJoin() throws {
            guard !joined else { return }
            _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            guard completion.wait(timeout: .now() + .seconds(1)) == .success else {
                throw WireTestError.peerTimedOut
            }
            joined = true
        }

        func closeAfterJoin() {
            guard joined else { return }
            _ = Darwin.close(fileDescriptor)
        }
    }

    private static func withWire<T>(
        peer operation: @escaping @Sendable (Int32) throws -> Void,
        _ body: (PommeAgentVSOCKWire) throws -> T
    ) throws -> T {
        let sockets = try makeSocketPair()
        let peer = PeerThread(fileDescriptor: sockets.peer)
        peer.start { try operation(sockets.peer) }
        let wire = PommeAgentVSOCKWire(fileDescriptor: sockets.client)
        do {
            let value = try body(wire)
            try peer.join()
            peer.closeAfterJoin()
            _ = Darwin.close(sockets.client)
            return value
        } catch {
            do {
                try peer.abortAndJoin()
                peer.closeAfterJoin()
            } catch {
                // Keep the peer descriptor open if its dedicated thread did
                // not join; closing it while the thread is still blocked can
                // race descriptor reuse in a later test.
                _ = Darwin.close(sockets.client)
                throw error
            }
            _ = Darwin.close(sockets.client)
            throw error
        }
    }

    private static func makeSocketPair() throws -> (client: Int32, peer: Int32) {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            try throwPOSIX("socketpair")
        }
        for descriptor in sockets {
            var noSigPipe: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                let savedError = errno
                sockets.forEach { _ = Darwin.close($0) }
                errno = savedError
                try throwPOSIX("setsockopt")
            }
        }
        return (client: sockets[0], peer: sockets[1])
    }

    private static func readEnvelope(from fileDescriptor: Int32) throws -> PommeAgentProtocol.Envelope {
        let line = try readLine(from: fileDescriptor)
        return try PommeAgentProtocol.decode(line)
    }

    private static func readLine(from fileDescriptor: Int32, maximumReadBytes: Int = 4_096) throws -> Data {
        var buffered = Data()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                return Data(buffered[..<newline])
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw WireTestError.peerTimedOut }
            let remainingMilliseconds = max(1, Int32(min(UInt64(Int32.max), (deadline - now) / 1_000_000)))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result == 0 { throw WireTestError.peerTimedOut }
            if result < 0, errno == EINTR { continue }
            guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                throw WireTestError.peerTimedOut
            }
            var bytes = [UInt8](repeating: 0, count: maximumReadBytes)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffered.append(contentsOf: bytes.prefix(Int(count)))
            } else if count == 0 {
                throw WireTestError.peerTimedOut
            } else if errno != EINTR {
                try throwPOSIX("read")
            }
        }
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw WireTestError.peerTimedOut }
                let remainingMilliseconds = max(1, Int32(min(UInt64(Int32.max), (deadline - now) / 1_000_000)))
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, remainingMilliseconds)
                if ready == 0 { throw WireTestError.peerTimedOut }
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, descriptor.revents & Int16(POLLOUT) != 0 else {
                    throw WireTestError.peerTimedOut
                }
                let count = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    try throwPOSIX("write")
                }
            }
        }
    }
}
