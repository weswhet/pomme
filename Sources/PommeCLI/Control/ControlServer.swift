import Darwin
import Foundation
import Synchronization

final class PommeControlServer: Sendable {
    private let socketURL: URL
    private let features: [PommeControlFeature]
    private let handler: @Sendable (PommeVMControlRequest) async -> String
    private let streamHandler: (@Sendable (PommeVMControlRequest, PommeControlStreamSession) async -> String)?
    private let afterResponse: (@Sendable (PommeVMControlRequest, PommeControlResponse) async -> Void)?
    private let queue = DispatchQueue(label: "com.github.weswhet.pomme.control", qos: .utility)
    private let listenFD = Mutex<Int32>(-1)
    private let peerAuthorizer: @Sendable (Int32) -> Bool

    init(socketURL: URL, features: [PommeControlFeature] = PommeControlFeature.allCases,
         afterResponse: (@Sendable (PommeVMControlRequest, PommeControlResponse) async -> Void)? = nil,
         streamHandler: (@Sendable (PommeVMControlRequest, PommeControlStreamSession) async -> String)? = nil,
         peerAuthorizer: @escaping @Sendable (Int32) -> Bool = PommeControlSocketSecurity.authorizeCurrentEffectiveUser,
         handler: @escaping @Sendable (PommeVMControlRequest) async -> String) {
        self.socketURL = socketURL
        self.features = streamHandler == nil ? features.filter { $0 != .streaming } : features
        self.afterResponse = afterResponse
        self.streamHandler = streamHandler
        self.peerAuthorizer = peerAuthorizer
        self.handler = handler
    }

    func start() throws {
        if FileManager.default.fileExists(atPath: socketURL.path) { try FileManager.default.removeItem(at: socketURL) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try throwPOSIX("socket") }
        do {
            try withUnixSocketAddress(path: socketURL.path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else { try throwPOSIX("bind") }
            }
            try PommeControlSocketSecurity.enforcePrivateMode(at: socketURL)
            guard Darwin.listen(fd, 8) == 0 else { try throwPOSIX("listen") }
            listenFD.withLock { $0 = fd }
            queue.async { [self] in acceptLoop() }
        } catch {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }
    }

    func stop() {
        let fd = listenFD.withLock { value -> Int32 in defer { value = -1 }; return value }
        if fd >= 0 { Darwin.close(fd) }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop() {
        while true {
            let currentFD = listenFD.withLock { $0 }
            guard currentFD >= 0 else { return }
            let fd = Darwin.accept(currentFD, nil, nil)
            if fd >= 0 {
                guard peerAuthorizer(fd) else { Darwin.close(fd); continue }
                Thread.detachNewThread { [self] in
                    defer { Darwin.close(fd) }
                    var reader = ControlWireCodec.FrameReader()
                    guard let frame = try? reader.readFrame(from: fd) else { return }
                    if handleHello(frame: frame, fd: fd) { return }
                    let done = DispatchSemaphore(value: 0)
                    Task { await handleRequest(fd: fd, frame: frame, reader: reader); done.signal() }
                    done.wait()
                }
            } else if errno == EBADF || errno == EINVAL { return }
            else if errno != EINTR { return }
        }
    }

    private func handleHello(frame: Data, fd: Int32) -> Bool {
        guard ControlWireCodec.envelopeType(in: frame) == "hello" else { return false }
        do {
            _ = try ControlWireCodec.decodeHello(frame)
            try write(PommeControlHello(features: features), to: fd)
        }
        catch {
            let id = requestID(in: frame) ?? UUID()
            try? write(PommeControlResponse.failure(id: id, code: "incompatible-protocol", message: error.localizedDescription), to: fd)
        }
        return true
    }

    private func handleRequest(fd: Int32, frame: Data, reader: ControlWireCodec.FrameReader) async {
        let request: PommeControlRequest
        do { request = try ControlWireCodec.decodeRequest(frame) }
        catch {
            try? write(PommeControlResponse.failure(id: requestID(in: frame) ?? UUID(), code: "invalid-request", message: error.localizedDescription), to: fd)
            return
        }
        let routed: PommeVMControlRequest
        do { routed = try PommeVMControlRouter.route(request) }
        catch {
            try? write(PommeControlResponse.failure(id: request.id, code: "invalid-command", message: error.localizedDescription), to: fd)
            return
        }
        guard features.contains(routed.requiredFeature) else {
            try? write(PommeControlResponse.failure(id: request.id, code: "feature-unavailable", message: routed.requiredFeature.rawValue), to: fd)
            return
        }
        let value: String
        if request.streaming == true {
            guard let streamHandler else {
                try? write(PommeControlResponse.failure(id: request.id, code: "streaming-unavailable", message: "Pomme control streaming is unavailable."), to: fd)
                return
            }
            value = await streamHandler(routed, .init(id: request.id, fileDescriptor: fd, reader: reader))
        } else { value = await handler(routed) }
        let response = response(id: request.id, value: value)
        do {
            try write(response, to: fd)
        } catch { }
        // Lifecycle cleanup must also finish when the requesting client
        // disconnects after its operation succeeded. Run this only after the
        // response write attempt, so a successful stop cannot race its reply.
        if let afterResponse { await afterResponse(routed, response) }
    }

    private func response(id: UUID, value: String) -> PommeControlResponse {
        if value.hasPrefix("ERROR ") { return .failure(id: id, code: "command-failed", message: String(value.dropFirst(6))) }
        if let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), let json = try? JSONValue(any: object) { return .success(id: id, result: json) }
        return .success(id: id, result: .string(value))
    }

    private func write<T: Encodable & Sendable>(_ value: T, to fd: Int32) throws {
        try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(value), to: fd)
    }

    private func requestID(in data: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["id"] as? String else { return nil }
        return UUID(uuidString: value)
    }
}

/// The helper socket contains VM-control authority. Permissions are explicitly
/// corrected after bind so an ambient umask can never make it group/world
/// accessible. macOS supplies the peer identity directly on AF_UNIX sockets.
enum PommeControlSocketSecurity {
    static let privateMode: mode_t = 0o600

    static func enforcePrivateMode(at url: URL) throws {
        guard Darwin.chmod(url.path, privateMode) == 0 else { try throwPOSIX("chmod") }
        var details = stat()
        guard Darwin.lstat(url.path, &details) == 0,
              (details.st_mode & S_IFMT) == S_IFSOCK,
              (details.st_mode & 0o777) == privateMode
        else { throw RunnerError.invalidControlResponse("Pomme control socket permissions could not be secured.") }
    }

    static func authorizeCurrentEffectiveUser(_ fileDescriptor: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        guard Darwin.getpeereid(fileDescriptor, &uid, &gid) == 0 else { return false }
        return uid == Darwin.geteuid()
    }
}
