import Darwin
import Foundation
import Testing

@Suite("Pomme control stream completion")
struct PommeControlStreamCompletionTests {
    @Test("coalesced stream output and terminal response stay ordered")
    func coalescedEventsAndTerminalState() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        let sockets = try makeSocketPair()
        defer {
            _ = Darwin.close(sockets.client)
            _ = Darwin.close(sockets.peer)
        }

        let first = PommeControlStreamFrame(id: id, sequence: 0, stream: .stdout, data: Data("one".utf8))
        let second = PommeControlStreamFrame(id: id, sequence: 1, stream: .stderr, data: Data("two".utf8))
        let response = PommeControlResponse.success(id: id, result: .object(["exitCode": .integer(0)]))
        let duplicate = PommeControlResponse.success(id: id, result: .object(["exitCode": .integer(1)]))
        let wire = try ControlWireCodec.encodeLine(first)
            + ControlWireCodec.encodeLine(second)
            + ControlWireCodec.encodeLine(response)
            + ControlWireCodec.encodeLine(duplicate)
        try writeAll(wire, to: sockets.peer)

        let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
        guard case .stream(let receivedFirst) = try session.receiveEvent() else {
            Issue.record("the first event was not a stream frame")
            return
        }
        #expect(receivedFirst == first)
        guard case .stream(let receivedSecond) = try session.receiveEvent() else {
            Issue.record("the second event was not a stream frame")
            return
        }
        #expect(receivedSecond == second)
        guard case .response(let receivedResponse) = try session.receiveEvent() else {
            Issue.record("the third event was not the terminal response")
            return
        }
        #expect(receivedResponse == response)

        // A terminal response consumes the stream even when another response
        // is already buffered in the same read. Every read API must fail
        // closed instead of accepting a duplicate terminal envelope.
        #expect(throws: RunnerError.self) { try session.receiveEvent() }
        #expect(throws: RunnerError.self) { try session.receive() }
        #expect(throws: RunnerError.self) { try session.receiveResponse() }
    }

    @Test("fragmented JSONL writes use one reader for streams and response")
    func fragmentedEvents() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000043"))
        let sockets = try makeSocketPair()
        defer { _ = Darwin.close(sockets.client) }

        let stream = PommeControlStreamFrame(id: id, sequence: 0, stream: .stdout, data: Data("fragmented".utf8))
        let response = PommeControlResponse.success(id: id, result: .object(["done": .bool(true)]))
        let wire = try ControlWireCodec.encodeLine(stream) + ControlWireCodec.encodeLine(response)
        let midpoint = wire.count / 2
        let writer = FragmentedWriter(
            fileDescriptor: sockets.peer,
            chunks: [Data(wire.prefix(1)), Data(wire[1..<midpoint]), Data(wire[midpoint...])]
        )
        writer.start()
        defer { writer.wait() }

        let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
        guard case .stream(let receivedStream) = try session.receiveEvent() else {
            Issue.record("the fragmented stream frame was not received")
            return
        }
        #expect(receivedStream == stream)
        guard case .response(let receivedResponse) = try session.receiveEvent() else {
            Issue.record("the fragmented terminal response was not received")
            return
        }
        #expect(receivedResponse == response)
    }

    @Test("terminal error responses remain correlated and typed")
    func terminalErrorResponse() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000044"))
        let sockets = try makeSocketPair()
        defer {
            _ = Darwin.close(sockets.client)
            _ = Darwin.close(sockets.peer)
        }
        let response = PommeControlResponse.failure(id: id, code: "command-failed", message: "redacted failure")
        try writeAll(try ControlWireCodec.encodeLine(response), to: sockets.peer)

        let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
        guard case .response(let received) = try session.receiveEvent() else {
            Issue.record("the error response was not delivered as a response event")
            return
        }
        #expect(received == response)
        #expect(received.ok == false)
        #expect(received.result == nil)
        #expect(received.error?.code == "command-failed")
        #expect(throws: RunnerError.self) { try session.receiveEvent() }
    }

    @Test("wrong IDs and stream sequences are rejected before acceptance")
    func rejectsCorrelationAndOrdering() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000045"))

        do {
            let sockets = try makeSocketPair()
            defer {
                _ = Darwin.close(sockets.client)
                _ = Darwin.close(sockets.peer)
            }
            let wrongResponse = PommeControlResponse.success(id: UUID(), result: .object(["ok": .bool(true)]))
            try writeAll(try ControlWireCodec.encodeLine(wrongResponse), to: sockets.peer)
            let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
            #expect(throws: RunnerError.self) { try session.receiveEvent() }
        }

        do {
            let sockets = try makeSocketPair()
            defer {
                _ = Darwin.close(sockets.client)
                _ = Darwin.close(sockets.peer)
            }
            let wrongStreamID = PommeControlStreamFrame(id: UUID(), sequence: 0, stream: .stdout, data: Data("wrong-id".utf8))
            try writeAll(try ControlWireCodec.encodeLine(wrongStreamID), to: sockets.peer)
            let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
            #expect(throws: RunnerError.self) { try session.receiveEvent() }
        }

        do {
            let sockets = try makeSocketPair()
            defer {
                _ = Darwin.close(sockets.client)
                _ = Darwin.close(sockets.peer)
            }
            let wrongSequence = PommeControlStreamFrame(id: id, sequence: 1, stream: .stdout, data: Data("wrong-sequence".utf8))
            try writeAll(try ControlWireCodec.encodeLine(wrongSequence), to: sockets.peer)
            let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
            #expect(throws: RunnerError.self) { try session.receiveEvent() }
        }
    }

    @Test("unknown event envelopes fail closed")
    func rejectsUnknownEnvelopeType() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046"))
        let sockets = try makeSocketPair()
        defer {
            _ = Darwin.close(sockets.client)
            _ = Darwin.close(sockets.peer)
        }
        let unknown = "{\"id\":\"\(id.uuidString.lowercased())\",\"protocolVersion\":1,\"type\":\"event\"}\n"
        try writeAll(Data(unknown.utf8), to: sockets.peer)

        let session = PommeControlStreamSession(id: id, fileDescriptor: sockets.client)
        #expect(throws: RunnerError.self) { try session.receiveEvent() }
    }

    @Test("socket stream exposes typed events and separate input half-close")
    func socketStreamEventAPI() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000047"))
        let sockets = try makeSocketPair()
        defer { _ = Darwin.close(sockets.peer) }

        let stream = PommeControlSocketStream(id: id, fileDescriptor: sockets.client)
        try stream.closeInput()
        try stream.closeInput()
        let response = PommeControlResponse.success(id: id, result: .object(["closed": .bool(true)]))
        try writeAll(try ControlWireCodec.encodeLine(response), to: sockets.peer)
        guard case .response(let received) = try stream.receiveEvent() else {
            Issue.record("socket stream did not expose a response event")
            return
        }
        #expect(received == response)
        #expect(throws: RunnerError.self) { try stream.receiveEvent() }
    }

    @Test("queued completion survives a peer disconnect during input close")
    func closeInputAfterPeerDisconnectPreservesResponse() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000048"))
        let sockets = try makeSocketPair()
        let stream = PommeControlSocketStream(id: id, fileDescriptor: sockets.client)
        let response = PommeControlResponse.success(id: id, result: .object(["queued": .bool(true)]))

        try writeAll(try ControlWireCodec.encodeLine(response), to: sockets.peer)
        _ = Darwin.close(sockets.peer)

        // shutdown(SHUT_WR) can report ENOTCONN after the peer has gone away.
        // That means the input half is already closed; it must not discard the
        // response bytes that remain queued in the opposite direction.
        try stream.closeInput()
        guard case .response(let received) = try stream.receiveEvent() else {
            Issue.record("queued response was not delivered after peer disconnect")
            return
        }
        #expect(received == response)
    }

    private func makeSocketPair() throws -> (client: Int32, peer: Int32) {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            try throwPOSIX("socketpair")
        }
        return (client: sockets[0], peer: sockets[1])
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
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

    private final class FragmentedWriter: @unchecked Sendable {
        private let fileDescriptor: Int32
        private let chunks: [Data]
        private let done = DispatchSemaphore(value: 0)

        init(fileDescriptor: Int32, chunks: [Data]) {
            self.fileDescriptor = fileDescriptor
            self.chunks = chunks
        }

        func start() {
            Thread.detachNewThread { [self] in
                defer {
                    _ = Darwin.close(fileDescriptor)
                    done.signal()
                }
                for chunk in chunks {
                    try? writeAll(chunk, to: fileDescriptor)
                    usleep(1_000)
                }
            }
        }

        func wait() {
            _ = done.wait(timeout: .now() + .seconds(2))
        }

        private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
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
}
