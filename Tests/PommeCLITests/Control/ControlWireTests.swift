import Darwin
import Foundation
import Testing

@Suite("Pomme control protocol v1")
struct ControlWireTests {
    @Test("Golden v1 hello, request, and response envelopes")
    func goldenEnvelopes() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        #expect(String(decoding: try ControlWireCodec.encodeLine(PommeControlHello()), as: UTF8.self) == #"{"features":["lifecycle","status","streaming","ui"],"protocolVersion":1,"type":"hello"}"# + "\n")
        let request = PommeControlRequest(id: id, command: "status")
        #expect(String(decoding: try ControlWireCodec.encodeLine(request), as: UTF8.self) == #"{"command":"status","id":"00000000-0000-0000-0000-000000000042","protocolVersion":1,"type":"request"}"# + "\n")
        let response = PommeControlResponse.success(id: id, result: .object(["vmState": .string("running")]))
        #expect(try ControlWireCodec.decodeResponse(try ControlWireCodec.encodeLine(response), matching: id) == response)
    }

    @Test("Only Pomme v1 envelopes are accepted")
    func rejectsOtherProtocolVersions() {
        for version in [2, 3, 4] {
            let wire = #"{"command":"status","id":"00000000-0000-0000-0000-000000000042","protocolVersion":\#(version),"type":"request"}"# + "\n"
            #expect(throws: RunnerError.self) { try ControlWireCodec.decodeRequest(Data(wire.utf8)) }
        }
    }

    @Test("Envelope decoding rejects unknown and escaped duplicate keys")
    func rejectsAmbiguousEnvelopeFields() {
        let id = "00000000-0000-0000-0000-000000000042"
        let unknown = "{\"command\":\"status\",\"id\":\"\(id)\",\"protocolVersion\":1,\"type\":\"request\",\"surprise\":true}\n"
        let duplicate = "{\"command\":\"status\",\"id\":\"\(id)\",\"protocolVersion\":1,\"type\":\"request\",\"command\":\"inspect\"}\n"
        let escapedDuplicate = "{\"command\":\"status\",\"id\":\"\(id)\",\"protocolVersion\":1,\"type\":\"request\",\"\\u0063ommand\":\"inspect\"}\n"
        for wire in [unknown, duplicate, escapedDuplicate] {
            #expect(throws: RunnerError.self) { try ControlWireCodec.decodeRequest(Data(wire.utf8)) }
        }
    }

    @Test("Router exposes lifecycle, snapshot, status, and inspect only")
    func routerIsClosed() throws {
        guard case .lifecycle(.pause, _) = try PommeVMControlRouter.route(.init(command: "pause")) else { Issue.record("pause was not routed") ; return }
        guard case .lifecycle(.stop, false) = try PommeVMControlRouter.route(.init(command: "stop")) else {
            Issue.record("a stop without the guest-shutdown field was not routed as false")
            return
        }
        guard case .lifecycle(.stop, true) = try PommeVMControlRouter.route(
            .init(command: "stop", payload: .object(["guestShutdownRequested": .bool(true)]))
        ) else {
            Issue.record("a stop carrying the guest-shutdown field was not routed as true")
            return
        }
        guard case .status = try PommeVMControlRouter.route(.init(command: "status")) else { Issue.record("status was not routed") ; return }
        guard case .snapshotSave(let request) = try PommeVMControlRouter.route(.init(command: "snapshot-save", payload: .object(["stageName": .string(".pomme-snapshot-stage-a")]))) else { Issue.record("snapshot was not routed") ; return }
        #expect(request.stageName == ".pomme-snapshot-stage-a")
        let removedCommands = [
            "guest-" + "exec",
            "guest-" + "copy",
            "guest-" + "health",
            "ensure-" + "recovery-agent",
        ]
        for command in removedCommands {
            #expect(throws: RunnerError.self) { try PommeVMControlRouter.route(.init(command: command)) }
        }
        guard case .agentPerform(let agent, streaming: true) = try PommeVMControlRouter.route(.init(command: "agent.perform", payload: .object(["operation": .string("process.start"), "payload": .object([:])]), streaming: true)) else { Issue.record("agent.perform was not routed") ; return }
        #expect(agent.operation == "process.start")
        for operation in [
            "amfi.normal.disable", "amfi.normal.enable",
            "amfi.normal.verifyDisabled", "amfi.normal.verifyEnabled"
        ] {
            guard case .agentPerform(let normalAMFI, streaming: false) = try PommeVMControlRouter.route(
                .init(command: "agent.perform", payload: .object([
                    "operation": .string(operation),
                    "payload": .object(["volumeGroupUUID": .string(UUID().uuidString.lowercased())])
                ]))
            ) else {
                Issue.record("\(operation) was not routed")
                continue
            }
            #expect(normalAMFI.operation == operation)
        }
        #expect(throws: RunnerError.self) { try PommeVMControlRouter.route(.init(command: "agent.perform", payload: .object(["operation": .string("unknown.operation")])) ) }
    }

    @Test("Bounded stream frames remain correlated and ordered")
    func streamOrderingAndBounds() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        var validator = PommeControlStreamSequenceValidator(id: id)
        try validator.accept(.init(id: id, sequence: 0, stream: .stdin, data: Data([0, 255])))
        try validator.accept(.init(id: id, sequence: 1, stream: .stdin, eof: true))
        #expect(throws: RunnerError.self) { try validator.accept(.init(id: id, sequence: 3, stream: .stdin, eof: true)) }
        #expect(throws: RunnerError.self) { try PommeControlStreamFrame(id: id, sequence: 2, stream: .stdin, data: Data(repeating: 1, count: PommeControlProtocol.maximumStreamChunkBytes + 1)).validate() }
    }

    @Test("Frame reader preserves a coalesced second JSONL frame")
    func frameReaderRetainsTail() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(Darwin.pipe(&descriptors) == 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        let id = UUID()
        let request = try ControlWireCodec.encodeLine(PommeControlRequest(id: id, command: "status"))
        let stream = try ControlWireCodec.encodeLine(PommeControlStreamFrame(id: id, sequence: 0, stream: .cancellation))
        let data = request + stream
        _ = data.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        var reader = ControlWireCodec.FrameReader()
        #expect(try ControlWireCodec.decodeRequest(reader.readFrame(from: descriptors[0])).id == id)
        #expect(try ControlWireCodec.decodeStreamFrame(reader.readFrame(from: descriptors[0])).stream == .cancellation)
    }

    @Test("Oversized and malformed frames fail before dispatch")
    func frameLimits() {
        #expect(throws: RunnerError.self) { try ControlWireCodec.decodeHello(Data(repeating: 0x20, count: PommeControlProtocol.maximumFrameBytes + 1)) }
        #expect(throws: RunnerError.self) { try ControlWireCodec.decodeRequest(Data("not-json\n".utf8)) }
    }

    @Test("Streaming socket round trip retains request correlation")
    func streamingSocketRoundTrip() throws {
        let socket = temporarySocketURL()
        let server = PommeControlServer(socketURL: socket, streamHandler: { request, session in
            guard case .lifecycle(.stop, _) = request else { return "ERROR unexpected command" }
            do {
                let input = try session.receive()
                try session.send(stream: .stdout, data: try input.decodedData())
                return #"{"streamed":true}"#
            } catch { return "ERROR \(error.localizedDescription)" }
        }) { _ in "ERROR unary dispatch should not run" }
        try server.start()
        defer { server.stop() }
        let client = PommeControlSocketClient(identity: .init(socketPath: socket.path, pid: 42, startedAt: "test"))
        let stream = try client.openStream(.init(command: "stop"))
        try stream.send(stream: .stdin, data: Data("hello".utf8))
        #expect(try stream.receive().decodedData() == Data("hello".utf8))
        #expect(try stream.finish().result == .object(["streamed": .bool(true)]))
    }

    @Test("Socket permissions are corrected after a permissive mode")
    func socketPermissionsArePrivate() throws {
        let socket = temporarySocketURL()
        let server = PommeControlServer(socketURL: socket) { _ in "ok" }
        try server.start()
        defer { server.stop() }
        var details = stat()
        #expect(Darwin.lstat(socket.path, &details) == 0)
        #expect(details.st_mode & 0o777 == PommeControlSocketSecurity.privateMode)
        #expect(Darwin.chmod(socket.path, 0o666) == 0)
        try PommeControlSocketSecurity.enforcePrivateMode(at: socket)
        #expect(Darwin.lstat(socket.path, &details) == 0)
        #expect(details.st_mode & 0o777 == PommeControlSocketSecurity.privateMode)
    }

    @Test("Rejected Unix peer is closed before it can send control JSONL")
    func peerAuthorizationRejection() throws {
        let socket = temporarySocketURL()
        let server = PommeControlServer(socketURL: socket, peerAuthorizer: { _ in false }) { _ in "ok" }
        try server.start()
        defer { server.stop() }
        let fd = try connect(socket)
        defer { Darwin.close(fd) }
        // The server is expected to reject this peer immediately. Depending
        // on scheduling, the close can race the client's probe write; the
        // production codec must report EPIPE without terminating the process.
        try? ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(PommeControlHello()), to: fd)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        #expect(Darwin.poll(&descriptor, 1, 1_000) > 0)
        var byte: UInt8 = 0
        #expect(Darwin.read(fd, &byte, 1) == 0)
    }

    private func connect(_ socket: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try throwPOSIX("socket") }
        do {
            try withUnixSocketAddress(path: socket.path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { try throwPOSIX("connect") }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func temporarySocketURL() -> URL {
        let nonce = UUID().uuidString.prefix(12).lowercased()
        return URL(fileURLWithPath: "/tmp/pomme-control-\(nonce).sock")
    }
}
