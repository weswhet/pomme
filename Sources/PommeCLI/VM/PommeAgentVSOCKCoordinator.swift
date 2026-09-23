import Darwin
import Foundation
@preconcurrency import Virtualization

enum PommeAgentVSOCKRole: Hashable, Sendable {
    case normal
    case recoveryBootstrap
    case recoveryRuntime

    var port: UInt32 {
        switch self {
        case .normal: PommeAgentPort.persistentNormal
        case .recoveryBootstrap: PommeAgentPort.recoveryBootstrap
        case .recoveryRuntime: PommeAgentPort.recoveryRuntime
        }
    }

    var statusRole: GuestAgentStatusV1.Role {
        self == .normal ? .normal : .recovery
    }
}

/// The identity a bounded Recovery listener is permitted to authenticate.
/// UUIDs are kept in their canonical lowercase textual form because that is
/// the form carried by the daemon launcher and the authentication envelope.
struct PommeAgentVSOCKBinding: Equatable, Sendable {
    let vmID: String
    let sessionID: String

    init(vmID: UUID, sessionID: UUID) {
        self.vmID = vmID.uuidString.lowercased()
        self.sessionID = sessionID.uuidString.lowercased()
    }

    init(vmID: String, sessionID: String) throws {
        guard let vm = UUID(uuidString: vmID),
              let session = UUID(uuidString: sessionID),
              vm.uuidString.lowercased() == vmID,
              session.uuidString.lowercased() == sessionID
        else { throw PommeAgentVSOCKError.invalidBinding }
        self.vmID = vmID
        self.sessionID = sessionID
    }
}

enum PommeAgentVSOCKError: Error, Equatable, Sendable {
    case invalidBinding
    case missingBinding
    case sessionReplaced
}

protocol PommeAgentVSOCKConnection: AnyObject, Sendable {
    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data
    func close()
}

/// Testable attachment surface. The Virtualization adapter is the only type
/// that knows VZ listener APIs; the coordinator owns connection lifetime.
protocol PommeAgentVSOCKTransport: AnyObject, Sendable {
    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws
    func remove(port: UInt32)
}

final class PommeAgentVSOCKCoordinator: @unchecked Sendable {
    typealias SecretProvider = @Sendable (PommeAgentVSOCKRole) throws -> String
    typealias BindingProvider = @Sendable (PommeAgentVSOCKRole) throws -> PommeAgentVSOCKBinding?

    // Recovery security handlers may run several native commands, each with
    // its own bounded guest-side deadline. Keep one practical overall
    // transport window so the host can receive the closed result envelope
    // without claiming that every native command and rollback fits inside
    // this single value. If it expires, the Recovery journal must be
    // reconciled before a retry. Ordinary agent traffic retains
    // `Constants.agentRoundTripTimeout` (or the caller-supplied value).
    static let recoverySecurityExchangeTimeout: TimeInterval = 300

    // A normal-role AMFI operation is a closed, credential-free guest
    // transaction. Give its bounded native work enough time to finish while
    // keeping ordinary normal-agent requests on their existing short budget.
    // If this window expires, the durable guest receipt must be reconciled
    // before a retry.
    static let normalAMFIExchangeTimeout: TimeInterval = 300

    private enum Phase { case disconnected, connecting(PommeAgentVSOCKRole), connected(PommeAgentVSOCKRole), failed(PommeAgentVSOCKRole) }

    private let transport: any PommeAgentVSOCKTransport
    private let secretProvider: SecretProvider
    private let bindingProvider: BindingProvider
    private let exchangeTimeout: TimeInterval
    private let lock = NSLock()
    private var attached: Set<PommeAgentVSOCKRole> = []
    private var phase: Phase = .disconnected
    private var lastRole: PommeAgentVSOCKRole = .normal
    private var pending: (role: PommeAgentVSOCKRole, connection: any PommeAgentVSOCKConnection)?
    private var active: (role: PommeAgentVSOCKRole, connection: any PommeAgentVSOCKConnection, session: PommeAgentSession)?

    /// Selects the transport budget only for the closed Recovery security
    /// vocabulary on the authenticated Recovery runtime listener. Keeping
    /// this selector independent of envelope decoding makes malformed or
    /// unrelated requests fall back to the existing ordinary budget.
    static func exchangeTimeout(
        for role: PommeAgentVSOCKRole,
        operation: String?,
        defaultTimeout: TimeInterval
    ) -> TimeInterval {
        guard let operation else { return defaultTimeout }
        if role == .recoveryRuntime, isRecoverySecurityOperation(operation) {
            return recoverySecurityExchangeTimeout
        }
        if role == .normal, isNormalAMFIOperation(operation) {
            return normalAMFIExchangeTimeout
        }
        return defaultTimeout
    }

    private static func isRecoverySecurityOperation(_ operation: String) -> Bool {
        switch operation {
        case "sip.status", "sip.disable", "sip.enable",
             "amfi.status", "amfi.disable", "amfi.enable":
            return true
        default:
            return false
        }
    }

    private static func isNormalAMFIOperation(_ operation: String) -> Bool {
        switch operation {
        case "amfi.normal.disable", "amfi.normal.enable",
             "amfi.normal.verifyDisabled", "amfi.normal.verifyEnabled":
            return true
        default:
            return false
        }
    }

    private static func exchangeTimeout(
        for request: Data,
        role: PommeAgentVSOCKRole,
        defaultTimeout: TimeInterval
    ) -> TimeInterval {
        guard request.last == 0x0A,
              let envelope = try? PommeAgentProtocol.decode(Data(request.dropLast()))
        else { return defaultTimeout }
        return exchangeTimeout(
            for: role,
            operation: envelope.operation,
            defaultTimeout: defaultTimeout
        )
    }

    init(transport: any PommeAgentVSOCKTransport, secretProvider: @escaping SecretProvider,
         bindingProvider: @escaping BindingProvider = { _ in nil },
         exchangeTimeout: TimeInterval = Constants.agentRoundTripTimeout) {
        self.transport = transport
        self.secretProvider = secretProvider
        self.bindingProvider = bindingProvider
        self.exchangeTimeout = exchangeTimeout
    }

    convenience init(socketDevice: VZVirtioSocketDevice, queue: DispatchQueue,
                     secretProvider: @escaping SecretProvider,
                     bindingProvider: @escaping BindingProvider = { _ in nil },
                     exchangeTimeout: TimeInterval = Constants.agentRoundTripTimeout) {
        self.init(
            transport: PommeVirtualizationVSOCKTransport(
                socketDevice: socketDevice,
                queue: queue
            ),
            secretProvider: secretProvider,
            bindingProvider: bindingProvider,
            exchangeTimeout: exchangeTimeout
        )
    }

    func attach(_ role: PommeAgentVSOCKRole) throws {
        try lock.withLock { () throws in
            guard !attached.contains(role) else { return }
            try transport.install(port: role.port) { [weak self] connection in self?.accept(connection, as: role) }
            attached.insert(role)
            lastRole = role
        }
    }

    func attachNormal() throws { try attach(.normal) }
    func attachRecoveryBootstrap() throws { try attach(.recoveryBootstrap) }
    func attachRecoveryRuntime() throws { try attach(.recoveryRuntime) }

    /// A Recovery runtime must only advance once the exact listener role has
    /// completed protocol authentication.  Merely accepting a VSOCK
    /// connection is intentionally not sufficient evidence.
    func isAuthenticated(as role: PommeAgentVSOCKRole) -> Bool {
        lock.withLock {
            guard case .connected(let connectedRole) = phase else { return false }
            return connectedRole == role && active?.role == role
        }
    }

    func detach(_ role: PommeAgentVSOCKRole) {
        let closing: (connections: [(any PommeAgentVSOCKConnection)], session: PommeAgentSession?) = lock.withLock {
            guard attached.remove(role) != nil else { return ([], nil) }
            transport.remove(port: role.port)
            var connections: [(any PommeAgentVSOCKConnection)] = []
            let session = active?.role == role ? active?.session : nil
            if active?.role == role, let connection = active?.connection { connections.append(connection); active = nil }
            if pending?.role == role, let connection = pending?.connection { connections.append(connection); pending = nil }
            phase = .disconnected
            return (connections, session)
        }
        closing.connections.forEach { $0.close() }
        close(closing.session)
    }

    /// Removes every installed listener and closes the exact accepted session.
    func teardown() {
        let closing: (connections: [(any PommeAgentVSOCKConnection)], session: PommeAgentSession?) = lock.withLock {
            for role in attached { transport.remove(port: role.port) }
            attached.removeAll()
            let connections = [active?.connection, pending?.connection].compactMap { $0 }
            let session = active?.session
            active = nil
            pending = nil
            phase = .disconnected
            return (connections, session)
        }
        closing.connections.forEach { $0.close() }
        close(closing.session)
    }

    func session() -> (any PommeAgentSessionProtocol)? {
        lock.withLock { active?.session }
    }

    /// A candidate that is already authenticating becomes usable in moments,
    /// which is worth telling a caller apart from an agent that is absent.
    var unavailableFailure: RunnerError {
        if case .connecting = lock.withLock({ phase }) { return .guestAgentConnecting }
        return .guestAgentUnavailable
    }

    /// Captures the currently authenticated session for a security operation.
    /// Every operation made through the returned pin verifies that this exact
    /// session remains active, so a candidate connection cannot replace the
    /// transport between describe, process start, and stream frames.
    func captureAuthenticatedSession(as role: PommeAgentVSOCKRole) throws -> PommeAuthenticatedAgentSession {
        let session: PommeAgentSession? = lock.withLock {
            guard let active, active.role == role else { return nil }
            return active.session
        }
        guard let session else {
            throw unavailableFailure
        }
        return .init(coordinator: self, session: session, role: role)
    }

    fileprivate func isCurrent(_ session: PommeAgentSession, as role: PommeAgentVSOCKRole) -> Bool {
        lock.withLock {
            guard let active, active.role == role else { return false }
            return active.session === session
        }
    }

    func status() async -> GuestAgentStatusV1 {
        let snapshot = lock.withLock { (phase, lastRole, active) }
        if let active = snapshot.2 {
            // A bounded Recovery listener is allowlisted for exactly one
            // security/bootstrap operation. Asking it for agent.describe would
            // violate that contract and consume a one-shot session, so report
            // connection state without issuing a Recovery operation.
            if active.role != .normal {
                return .init(
                    connection: .connected,
                    role: active.role.statusRole,
                    protocolVersion: PommeAgentProtocol.version,
                    executableDigest: nil,
                    capabilities: [],
                    updateState: .unknown
                )
            }
            do {
                let description = try await active.session.perform(operation: "agent.describe", payload: nil)
                if let status = GuestAgentStatusV1.described(description, role: active.role.statusRole) { return status }
                return .init(connection: .connected, role: active.role.statusRole, protocolVersion: nil, executableDigest: nil, capabilities: [], updateState: .unavailable)
            } catch {
                connectionDidDisconnect(active.connection, as: active.role)
            }
        }
        switch snapshot.0 {
        case .disconnected: return .offline(role: snapshot.1.statusRole)
        case .connecting(let role): return .init(connection: .connecting, role: role.statusRole, protocolVersion: nil, executableDigest: nil, capabilities: [], updateState: .unknown)
        case .connected(let role): return .init(connection: .disconnected, role: role.statusRole, protocolVersion: nil, executableDigest: nil, capabilities: [], updateState: .unknown)
        case .failed(let role): return .init(connection: .failed, role: role.statusRole, protocolVersion: nil, executableDigest: nil, capabilities: [], updateState: .failed)
        }
    }

    private func accept(_ connection: any PommeAgentVSOCKConnection, as role: PommeAgentVSOCKRole) {
        let previous: (connections: [(any PommeAgentVSOCKConnection)], session: PommeAgentSession?) = lock.withLock {
            guard attached.contains(role) else { return ([connection], nil) }
            // A candidate must authenticate before it can displace a working
            // session; otherwise arbitrary guest connects become a DoS.
            let connections = [pending?.connection].compactMap { $0 }
            let session: PommeAgentSession? = nil
            pending = (role, connection)
            if active == nil { phase = .connecting(role) }
            return (connections, session)
        }
        previous.connections.forEach { $0.close() }
        close(previous.session)
        Task { [weak self, connection] in await self?.authenticate(connection, as: role) }
    }

    private func authenticate(_ connection: any PommeAgentVSOCKConnection, as role: PommeAgentVSOCKRole) async {
        let binding: PommeAgentVSOCKBinding?
        do {
            if role == .normal {
                // The persistent normal agent is intentionally never
                // request-bound, even when a caller's provider can describe
                // bindings for other roles.
                binding = nil
            } else {
                binding = try bindingProvider(role)
                if binding == nil { throw PommeAgentVSOCKError.missingBinding }
            }
        } catch {
            lock.withLock {
                guard attached.contains(role) else { return }
                if pending.map({ sameConnection($0.connection, connection) }) == true {
                    pending = nil
                }
                phase = active.map { .connected($0.role) } ?? .failed(role)
            }
            connection.close()
            return
        }
        let session = PommeAgentSession(exchange: { [weak self, exchangeTimeout] request in
            let requestTimeout = Self.exchangeTimeout(
                for: request,
                role: role,
                defaultTimeout: exchangeTimeout
            )
            do {
                return try await connection.exchange(request, timeout: requestTimeout)
            } catch {
                self?.connectionDidDisconnect(connection, as: role)
                throw error
            }
        }, role: role.statusRole, vmBinding: binding?.vmID, sessionBinding: binding?.sessionID)
        do {
            // The token is never logged, retained by the coordinator, or added
            // to a protocol diagnostic.
            try await session.authenticate(token: try secretProvider(role))
        } catch {
            let shouldClose = lock.withLock { () -> Bool in
                guard attached.contains(role) else { return true }
                if pending.map({ sameConnection($0.connection, connection) }) == true {
                    pending = nil
                }
                phase = active.map { .connected($0.role) } ?? .failed(role)
                return true
            }
            if shouldClose { connection.close() }
            return
        }

        let replaced: (connections: [(any PommeAgentVSOCKConnection)], session: PommeAgentSession?) = lock.withLock {
            guard attached.contains(role), pending.map({ sameConnection($0.connection, connection) }) == true else { return ([connection], nil) }
            let previous = [active?.connection].compactMap { $0 }
            let previousSession = active?.session
            active = (role, connection, session)
            pending = nil
            phase = .connected(role)
            return (previous, previousSession)
        }
        replaced.connections.forEach { $0.close() }
        close(replaced.session)
    }

    /// A connection has no independent close callback in Virtualization. An
    /// exchange failure is therefore the authoritative disconnect signal.
    private func connectionDidDisconnect(_ connection: any PommeAgentVSOCKConnection, as role: PommeAgentVSOCKRole) {
        let session: PommeAgentSession? = lock.withLock {
            if active?.role == role, let activeConnection = active?.connection,
               sameConnection(activeConnection, connection) {
                let session = active?.session
                active = nil
                phase = .disconnected
                return session
            }
            if pending?.role == role, let pendingConnection = pending?.connection,
               sameConnection(pendingConnection, connection) {
                pending = nil
                phase = .disconnected
            }
            return nil
        }
        connection.close()
        close(session)
    }

    private func sameConnection(_ left: any PommeAgentVSOCKConnection, _ right: any PommeAgentVSOCKConnection) -> Bool {
        (left as AnyObject) === (right as AnyObject)
    }

    private func close(_ session: PommeAgentSession?) {
        if let session { Task { await session.close() } }
    }
}

extension PommeAgentVSOCKCoordinator: PommeAgentSessionProvider {}

/// A request/stream surface bound to one coordinator session.  The session is
/// intentionally opaque to callers; only this pin can invoke the operations
/// needed by a security PTY, and each call fails if the coordinator replaced
/// the authenticated connection.
struct PommeAuthenticatedAgentSession: Sendable {
    private let coordinator: PommeAgentVSOCKCoordinator
    private let session: PommeAgentSession
    let role: PommeAgentVSOCKRole

    fileprivate init(coordinator: PommeAgentVSOCKCoordinator, session: PommeAgentSession, role: PommeAgentVSOCKRole) {
        self.coordinator = coordinator
        self.session = session
        self.role = role
    }

    func request(operation: String, payload: JSONValue = .object([:])) async throws -> JSONValue {
        try requireCurrent()
        let result = try await session.request(operation: operation, payload: payload)
        try requireCurrent()
        return result
    }

    func requestCorrelated(operation: String, payload: JSONValue = .object([:])) async throws -> PommeAgentCorrelatedResult {
        try requireCurrent()
        let response = try await session.requestCorrelated(operation: operation, payload: payload)
        let frames = await session.drainStreams(requestID: response.requestID)
        try requireCurrent()
        return .init(requestID: response.requestID, result: response.result, streamFrames: frames)
    }

    func sendStream(
        jobID: UUID,
        stream: PommeAgentProtocol.Stream,
        requestID: UUID = UUID(),
        data: Data? = nil,
        dimensions: (columns: Int, rows: Int)? = nil,
        signal: Int32? = nil
    ) async throws -> [PommeAgentJobStreamFrame] {
        try requireCurrent()
        let frames = try await session.sendStream(
            jobID: jobID,
            stream: stream,
            requestID: requestID,
            data: data,
            dimensions: dimensions,
            signal: signal
        )
        try requireCurrent()
        return frames
    }

    private func requireCurrent() throws {
        guard coordinator.isCurrent(session, as: role) else {
            throw PommeAgentVSOCKError.sessionReplaced
        }
    }
}

extension PommeAgentVSOCKCoordinator: PommeAgentStreamingSessionProvider {
    func performCorrelated(operation: String, payload: JSONValue?) async throws -> PommeAgentCorrelatedResult {
        guard let session = lock.withLock({ active?.session }) else { throw unavailableFailure }
        let response = try await session.requestCorrelated(operation: operation, payload: payload ?? .object([:]))
        return .init(requestID: response.requestID, result: response.result, streamFrames: await session.drainStreams(requestID: response.requestID))
    }

    func sendStream(jobID: UUID, stream: PommeAgentProtocol.Stream, requestID: UUID, data: Data?,
                    dimensions: (columns: Int, rows: Int)?, signal: Int32?) async throws -> [PommeAgentJobStreamFrame] {
        guard let session = lock.withLock({ active?.session }) else { throw unavailableFailure }
        return try await session.sendStream(jobID: jobID, stream: stream, requestID: requestID, data: data, dimensions: dimensions, signal: signal)
    }
}

/// Runs a closure on one exact VM queue and permits calls that are already on
/// that queue. Virtualization.framework traps instead of returning an error
/// when a runtime device is touched from any other queue.
final class PommeVMQueueExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: key, value: 1)
    }

    func sync<Value>(_ body: () throws -> Value) rethrows -> Value {
        if DispatchQueue.getSpecific(key: key) == 1 {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}

private final class PommeVirtualizationVSOCKTransport: NSObject, PommeAgentVSOCKTransport, @unchecked Sendable {
    private let socketDevice: VZVirtioSocketDevice
    private let queueExecutor: PommeVMQueueExecutor
    private let lock = NSLock()
    private var listeners: [UInt32: (listener: VZVirtioSocketListener, delegate: PommeVirtualizationVSOCKListenerDelegate)] = [:]

    init(socketDevice: VZVirtioSocketDevice, queue: DispatchQueue) {
        self.socketDevice = socketDevice
        queueExecutor = PommeVMQueueExecutor(queue: queue)
    }

    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
        let delegate = PommeVirtualizationVSOCKListenerDelegate(normalScope: port == PommeAgentPort.persistentNormal, accept: accept)
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        lock.withLock {
            queueExecutor.sync {
                socketDevice.setSocketListener(listener, forPort: port)
            }
            listeners[port] = (listener, delegate)
        }
    }

    func remove(port: UInt32) {
        lock.withLock {
            queueExecutor.sync {
                socketDevice.removeSocketListener(forPort: port)
            }
            listeners[port]?.listener.delegate = nil
            listeners.removeValue(forKey: port)
        }
    }
}

private final class PommeVirtualizationVSOCKListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let accept: @Sendable (any PommeAgentVSOCKConnection) -> Void
    private let normalScope: Bool

    init(normalScope: Bool, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) {
        self.normalScope = normalScope
        self.accept = accept
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        accept(PommeVirtualizationVSOCKConnection(connection: connection, normalScope: normalScope))
        return true
    }
}

private final class PommeVirtualizationVSOCKConnection: @unchecked Sendable, PommeAgentVSOCKConnection {
    private let connection: VZVirtioSocketConnection
    private let wire: PommeAgentVSOCKWire

    init(connection: VZVirtioSocketConnection, normalScope: Bool) {
        self.connection = connection
        wire = .init(fileDescriptor: connection.fileDescriptor, normalScope: normalScope)
    }

    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data {
        try await Task.detached(priority: .utility) { try self.wire.exchange(request, timeout: timeout) }.value
    }

    func close() { connection.close() }
}

/// Synchronous, descriptor-owned exchange engine. The lock covers each entire
/// request/response transaction, including its correlated output frames.
final class PommeAgentVSOCKWire: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var buffered = Data()
    private let signalTraceSink: PommeSignalBoundaryTrace.Sink
    private let desktopStartTraceSink: PommeDesktopStartBoundaryTrace.Sink
    private let statusTraceSink: PommeStatusWireTrace.Sink
    private let normalScope: Bool

    init(fileDescriptor: Int32, signalTraceSink: PommeSignalBoundaryTrace.Sink? = nil,
         desktopStartTraceSink: PommeDesktopStartBoundaryTrace.Sink? = nil,
         statusTraceSink: PommeStatusWireTrace.Sink? = nil, normalScope: Bool = true) {
        self.fileDescriptor = fileDescriptor
        self.signalTraceSink = signalTraceSink ?? PommeSignalBoundaryTrace.hostLog
        self.desktopStartTraceSink = desktopStartTraceSink ?? PommeDesktopStartBoundaryTrace.hostLog
        self.statusTraceSink = statusTraceSink ?? PommeStatusWireTrace.hostLog
        self.normalScope = normalScope
    }

    func exchange(_ request: Data, timeout: TimeInterval) throws -> Data {
        try lock.withLock {
            guard timeout.isFinite, timeout > 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            guard request.last == 0x0A, request.count <= PommeAgentProtocol.maximumFrameBytes else { throw PommeAgentProtocol.Error.frameTooLarge }
            let requestEnvelope = try PommeAgentProtocol.decode(Data(request.dropLast()))
            guard requestEnvelope.kind == .request || requestEnvelope.kind == .stream else { throw PommeAgentProtocol.Error.invalidRequest }
            let deadline = Date().addingTimeInterval(timeout)
            let trace = requestEnvelope.kind == .request && requestEnvelope.operation == "process.signal"
                ? PommeSignalBoundaryTrace(sink: signalTraceSink) : nil
            trace?.emit(.hostExchangeAdmitted)
            let desktopTrace = PommeDesktopStartBoundaryTrace.admits(requestEnvelope)
                ? PommeDesktopStartBoundaryTrace(sink: desktopStartTraceSink) : nil
            desktopTrace?.emit(.exchangeAdmitted)
            let statusTrace = normalScope && requestEnvelope.kind == .request && requestEnvelope.operation == "process.status"
                ? PommeStatusWireTrace(sink: statusTraceSink) : nil
            statusTrace?.emit(.exchangeAdmitted)
            var desktopFailure = PommeDesktopStartBoundaryTrace.Event.writeFailed
            var readState = PommeDesktopStartBoundaryTrace.Event.responseReadNoBytes
            var receivedStreamFrame = false
            var failureEvent = PommeSignalBoundaryTrace.Event.hostWriteFailed
            do {
                var noSigPipe: Int32 = 1
                guard Darwin.setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                        socklen_t(MemoryLayout<Int32>.size)) == 0 else { try throwPOSIX("vsock setsockopt") }
                try writeAll(request, deadline: deadline)
                trace?.emit(.hostWriteCompleted)
                desktopTrace?.emit(.writeCompleted)
                statusTrace?.emit(.writeCompleted)
                desktopFailure = .responseFailed
                failureEvent = .hostResponseFailed
                var delivered = Data()
                var receivedTerminalFrame = false
                while !receivedTerminalFrame {
                    let line = try readLine(deadline: deadline, readState: &readState)
                    let envelope = try PommeAgentProtocol.decode(line)
                    guard envelope.requestID == requestEnvelope.requestID else {
                        throw PommeAgentProtocol.Error.invalidResponse
                    }
                    switch envelope.kind {
                    case .stream:
                        receivedStreamFrame = true
                        try append(line, to: &delivered)
                    case .response:
                        guard envelope.operation == requestEnvelope.operation else {
                            throw PommeAgentProtocol.Error.invalidResponse
                        }
                        try append(line, to: &delivered)
                        trace?.emit(.hostResponseReceived)
                        desktopTrace?.emit(.responseReceived)
                        statusTrace?.emit(.responseReceived)
                        receivedTerminalFrame = true
                    case .request: throw PommeAgentProtocol.Error.invalidResponse
                    }
                }
                // A response is the delimiter for both ordinary requests and
                // input-stream mutations, even when there is no output. Never
                // guess completion from socket readiness or a scheduling delay.
                return delivered
            } catch {
                trace?.emit(failureEvent)
                desktopTrace?.emit(desktopFailure)
                statusTrace?.emit(desktopFailure)
                if desktopFailure == .responseFailed {
                    // A validated correlated stream takes precedence over a
                    // later partial frame. No payload, identifiers, or counts
                    // escape through this closed diagnostic surface.
                    desktopTrace?.emit(receivedStreamFrame ? .responseReadStreamFrames : readState)
                    statusTrace?.emit(receivedStreamFrame ? .responseReadStreamFrames : readState)
                }
                throw error
            }
        }
    }

    private func append(_ line: Data, to delivered: inout Data) throws {
        guard delivered.count + line.count + 1 <= PommeAgentProtocol.maximumFrameBytes else { throw PommeAgentProtocol.Error.frameTooLarge }
        delivered.append(line)
        delivered.append(0x0A)
    }

    private func writeAll(_ data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { try throwPOSIX("vsock write") }
            }
        }
    }

    private func readLine(deadline: Date, readState: inout PommeDesktopStartBoundaryTrace.Event) throws -> Data {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                readState = .responseReadCompleteFrame
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                guard !line.contains(0x0D) else { throw PommeAgentProtocol.Error.malformedFrame }
                guard line.count < PommeAgentProtocol.maximumFrameBytes else { throw PommeAgentProtocol.Error.frameTooLarge }
                return line
            }
            // Includes bytes already buffered by an earlier socket read;
            // this describes available wire data, not its request ownership.
            if !buffered.isEmpty { readState = .responseReadPartialFrame }
            guard buffered.count < PommeAgentProtocol.maximumFrameBytes else { throw PommeAgentProtocol.Error.frameTooLarge }
            try wait(events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: min(4_096, PommeAgentProtocol.maximumFrameBytes - buffered.count))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { buffered.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw RunnerError.guestAgentDisconnected }
            else if errno != EINTR { try throwPOSIX("vsock read") }
        }
    }

    private func wait(events: Int16, deadline: Date) throws {
        var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
        while true {
            let remainingMilliseconds = max(0, deadline.timeIntervalSinceNow * 1_000)
            let milliseconds = Int32(min(Double(Int32.max), remainingMilliseconds))
            guard milliseconds > 0 else { throw RunnerError.guestAgentTimedOut("Pomme agent exchange") }
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                // A peer may close immediately after writing its response.
                // Consume queued readable bytes before interpreting hangup.
                if events & Int16(POLLIN) != 0, descriptor.revents & Int16(POLLIN) != 0,
                   descriptor.revents & Int16(POLLNVAL) == 0 { return }
                let failureEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                guard descriptor.revents & failureEvents == 0 else { throw RunnerError.guestAgentDisconnected }
                if descriptor.revents & events != 0 { return }
                continue
            }
            if result == 0 { throw RunnerError.guestAgentTimedOut("Pomme agent exchange") }
            if errno != EINTR { try throwPOSIX("vsock poll") }
        }
    }
}
