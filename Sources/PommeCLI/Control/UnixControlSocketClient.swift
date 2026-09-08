import Darwin
import Foundation
import Synchronization

struct PommeRuntimeIdentity: Hashable, Sendable {
    let socketPath: String
    let pid: Int32
    let startedAt: String
}

struct PommeControlSocketClient: Sendable {
    private static let helloCache = Mutex<[PommeRuntimeIdentity: PommeControlHello]>([:])
    let identity: PommeRuntimeIdentity

    func send(_ request: PommeControlRequest, timeout: TimeInterval? = nil) throws -> JSONValue {
        let deadline: TimeInterval?
        if let timeout {
            guard timeout.isFinite, timeout > 0 else { throw POSIXError(.ETIMEDOUT) }
            deadline = ProcessInfo.processInfo.systemUptime + timeout
        } else { deadline = nil }
        let hello = try negotiatedHello(deadline: deadline)
        let routed = try PommeVMControlRouter.route(request)
        guard hello.features.contains(routed.requiredFeature) else { throw RunnerError.controlCapabilityUnavailable(routed.requiredFeature.rawValue) }
        let responseData = try exchange(try ControlWireCodec.encodeLine(request), deadline: deadline)
        let response: PommeControlResponse
        do { response = try ControlWireCodec.decodeResponse(responseData, matching: request.id) }
        catch { throw incompatibleError(from: responseData) }
        guard response.ok, let result = response.result else {
            let error = response.error ?? .init(code: "control-error", message: "The Pomme helper rejected the request.")
            throw RunnerError.controlCommandFailed("\(error.code): \(error.message)")
        }
        return result
    }

    func negotiatedHello(deadline: TimeInterval? = nil) throws -> PommeControlHello {
        if let cached = Self.helloCache.withLock({ $0[identity] }) { return cached }
        let data = try exchange(try ControlWireCodec.encodeLine(PommeControlHello(features: [])), deadline: deadline)
        let hello: PommeControlHello
        do { hello = try ControlWireCodec.decodeHello(data) }
        catch { throw incompatibleError(from: data) }
        Self.helloCache.withLock { $0[identity] = hello }
        return hello
    }

    func openStream(_ request: PommeControlRequest) throws -> PommeControlSocketStream {
        guard try negotiatedHello().features.contains(.streaming) else { throw RunnerError.controlCapabilityUnavailable(PommeControlFeature.streaming.rawValue) }
        let fd = try connect()
        let streaming = PommeControlRequest(id: request.id, command: request.command, payload: request.payload, streaming: true)
        do {
            try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(streaming), to: fd)
            return .init(id: streaming.id, fileDescriptor: fd)
        } catch { Darwin.close(fd); throw error }
    }

    private func incompatibleError(from data: Data) -> RunnerError {
        .incompatibleHelperProtocol(expected: PommeControlProtocol.version, actual: ControlWireCodec.protocolVersion(in: data))
    }

    private func exchange(_ frame: Data, deadline: TimeInterval? = nil) throws -> Data {
        let fd = try connect(deadline: deadline)
        defer { Darwin.close(fd) }
        try ControlWireCodec.writeFrame(frame, to: fd, deadline: deadline)
        Darwin.shutdown(fd, SHUT_WR)
        var reader = ControlWireCodec.FrameReader()
        return try reader.readFrame(from: fd, deadline: deadline)
    }

    private func connect(deadline: TimeInterval? = nil) throws -> Int32 {
        let url = URL(fileURLWithPath: identity.socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try throwPOSIX("socket") }
        do {
            if deadline != nil {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { try throwPOSIX("fcntl") }
            }
            try withUnixSocketAddress(path: identity.socketPath) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    if let deadline, errno == EINPROGRESS {
                        try ControlWireCodec.waitForDescriptor(fd, events: Int16(POLLOUT), deadline: deadline)
                        var status: Int32 = 0
                        var size = socklen_t(MemoryLayout<Int32>.size)
                        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &size) == 0 else { try throwPOSIX("getsockopt") }
                        if status == 0 { return }
                        throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
                    }
                    if errno == ENOENT || errno == ECONNREFUSED { throw RunnerError.noRunningVM(url) }
                    try throwPOSIX("connect")
                }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}

final class PommeControlSocketStream: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let session: PommeControlStreamSession

    init(id: UUID, fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        session = .init(id: id, fileDescriptor: fileDescriptor)
    }
    deinit { Darwin.close(fileDescriptor) }
    func send(stream: PommeControlStreamFrame.Stream, data: Data? = nil, payload: JSONValue? = nil, eof: Bool? = nil) throws { try session.send(stream: stream, data: data, payload: payload, eof: eof) }
    func receive() throws -> PommeControlStreamFrame { try session.receive() }
    func receive(timeout: TimeInterval) throws -> PommeControlStreamFrame { try session.receive(timeout: timeout) }
    func receiveEvent() throws -> PommeControlStreamEvent { try session.receiveEvent() }
    func receiveEvent(timeout: TimeInterval) throws -> PommeControlStreamEvent { try session.receiveEvent(timeout: timeout) }
    func closeInput() throws { try session.closeInput() }
    func finish() throws -> PommeControlResponse { try session.closeInput(); return try session.receiveResponse() }
}
