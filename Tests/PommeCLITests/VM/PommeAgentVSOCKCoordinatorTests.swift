import Foundation
import Synchronization
import Testing

@Suite("Pomme agent VSOCK coordinator")
struct PommeAgentVSOCKCoordinatorTests {
    @Test("VM queue executor confines calls and permits queue-local reentry")
    func vmQueueExecutorConfinement() {
        let queue = DispatchQueue(label: "com.github.weswhet.pomme.tests.vsock-queue")
        let executor = PommeVMQueueExecutor(queue: queue)

        let dispatched = executor.sync {
            dispatchPrecondition(condition: .onQueue(queue))
            return 1
        }
        let reentered = queue.sync {
            executor.sync {
                dispatchPrecondition(condition: .onQueue(queue))
                return 2
            }
        }

        #expect(dispatched == 1)
        #expect(reentered == 2)
    }

    private static let token = String(repeating: "a", count: 64)
    private static let vmID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let sessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private static let recoveryBinding = try! PommeAgentVSOCKBinding(vmID: vmID, sessionID: sessionID)

    @Test("Port bindings map only to normal and bounded Recovery roles")
    func portRoleMapping() throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachNormal()
        try coordinator.attachRecoveryBootstrap()
        try coordinator.attachRecoveryRuntime()
        #expect(transport.installedPorts == [PommeAgentPort.persistentNormal, PommeAgentPort.recoveryBootstrap, PommeAgentPort.recoveryRuntime])
        coordinator.teardown()
        #expect(transport.removedPorts == Set(transport.installedPorts))
    }

    @Test("Only authenticated Recovery security operations receive the bounded transaction window")
    func recoverySecurityExchangeTimeoutSelection() {
        let ordinary = 0.25
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .recoveryRuntime,
                operation: "amfi.disable",
                defaultTimeout: ordinary
            ) == PommeAgentVSOCKCoordinator.recoverySecurityExchangeTimeout
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .recoveryRuntime,
                operation: "sip.status",
                defaultTimeout: ordinary
            ) == PommeAgentVSOCKCoordinator.recoverySecurityExchangeTimeout
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .recoveryRuntime,
                operation: "process.start",
                defaultTimeout: ordinary
            ) == ordinary
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .recoveryBootstrap,
                operation: "amfi.disable",
                defaultTimeout: ordinary
            ) == ordinary
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .normal,
                operation: "amfi.disable",
                defaultTimeout: ordinary
            ) == ordinary
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .normal,
                operation: "amfi.normal.disable",
                defaultTimeout: ordinary
            ) == PommeAgentVSOCKCoordinator.normalAMFIExchangeTimeout
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .normal,
                operation: "amfi.normal.verifyEnabled",
                defaultTimeout: ordinary
            ) == PommeAgentVSOCKCoordinator.normalAMFIExchangeTimeout
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .normal,
                operation: "amfi.normal.unsupported",
                defaultTimeout: ordinary
            ) == ordinary
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .recoveryRuntime,
                operation: "amfi.normal.disable",
                defaultTimeout: ordinary
            ) == ordinary
        )
        #expect(
            PommeAgentVSOCKCoordinator.exchangeTimeout(
                for: .recoveryRuntime,
                operation: nil,
                defaultTimeout: ordinary
            ) == ordinary
        )
        #expect(PommeAgentVSOCKCoordinator.recoverySecurityExchangeTimeout == 300)
        #expect(PommeAgentVSOCKCoordinator.normalAMFIExchangeTimeout == 300)
    }

    @Test("Recovery security error envelopes survive the extended exchange budget")
    func recoverySecurityErrorEnvelopeUsesExtendedTimeout() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in Self.token },
            bindingProvider: { role in role == .normal ? nil : Self.recoveryBinding },
            exchangeTimeout: 0.25
        )
        try coordinator.attachRecoveryRuntime()
        let connection = FakeConnection(
            token: Self.token,
            vmID: Self.vmID,
            sessionID: Self.sessionID,
            operationFailureCode: "recovery-command-failed",
            operationFailureOperation: "amfi.disable"
        )
        transport.connect(connection, port: PommeAgentPort.recoveryRuntime)
        let connected = await eventually { await coordinator.status() }
        #expect(connected.connection == .connected)

        do {
            _ = try await coordinator.performCorrelated(operation: "amfi.disable", payload: .object([:]))
            Issue.record("Expected the closed Recovery error envelope to be thrown.")
        } catch let error as PommeAgentSessionError {
            #expect(error.code == "recovery-command-failed")
            #expect(error.message == "closed test failure")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(connection.timeouts.last == PommeAgentVSOCKCoordinator.recoverySecurityExchangeTimeout)
        coordinator.teardown()
    }

    @Test("Authenticated connection exposes the closed normal status")
    func authenticatedStatus() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachNormal()
        let connection = FakeConnection(token: Self.token)
        transport.connect(connection, port: PommeAgentPort.persistentNormal)
        let status = await eventually { await coordinator.status() }
        #expect(status.connection == .connected)
        #expect(status.role == .normal)
        #expect(status.protocolVersion == PommeAgentProtocol.version)
        #expect(status.executableDigest == String(repeating: "c", count: 64))
        #expect(status.capabilities == ["process.start", "file.open"])
        coordinator.teardown()
        #expect(connection.closed)
    }

    @Test("Recovery authentication requires the injected exact VM and request binding")
    func recoveryBinding() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in Self.token },
            bindingProvider: { role in role == .normal ? nil : Self.recoveryBinding }
        )
        try coordinator.attachRecoveryRuntime()
        let accepted = FakeConnection(token: Self.token, vmID: Self.vmID, sessionID: Self.sessionID)
        transport.connect(accepted, port: PommeAgentPort.recoveryRuntime)
        let connected = await eventually { await coordinator.status() }
        #expect(connected.connection == .connected)
        #expect(!accepted.closed)
        coordinator.teardown()

        let wrongTransport = FakeTransport()
        let wrongCoordinator = PommeAgentVSOCKCoordinator(
            transport: wrongTransport,
            secretProvider: { _ in Self.token },
            bindingProvider: { role in role == .normal ? nil : Self.recoveryBinding }
        )
        try wrongCoordinator.attachRecoveryRuntime()
        let wrong = FakeConnection(token: Self.token, vmID: "cccccccc-cccc-cccc-cccc-cccccccccccc", sessionID: Self.sessionID)
        wrongTransport.connect(wrong, port: PommeAgentPort.recoveryRuntime)
        let rejected = await eventually { await wrongCoordinator.status() }
        #expect(rejected.connection == .failed)
        #expect(wrong.closed)
        wrongCoordinator.teardown()
    }

    @Test("Recovery authentication is refused when no binding is supplied")
    func missingRecoveryBinding() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachRecoveryBootstrap()
        let connection = FakeConnection(token: Self.token, vmID: Self.vmID, sessionID: Self.sessionID)
        transport.connect(connection, port: PommeAgentPort.recoveryBootstrap)
        let status = await eventually { await coordinator.status() }
        #expect(status.connection == .failed)
        #expect(connection.closed)
        coordinator.teardown()
    }

    @Test("The normal role stays unbound even when the provider has Recovery bindings")
    func normalRemainsUnbound() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in Self.token },
            bindingProvider: { _ in Self.recoveryBinding }
        )
        try coordinator.attachNormal()
        let connection = FakeConnection(token: Self.token)
        transport.connect(connection, port: PommeAgentPort.persistentNormal)
        let status = await eventually { await coordinator.status() }
        #expect(status.connection == .connected)
        #expect(!connection.closed)
        coordinator.teardown()
    }

    @Test("Authentication failure closes the connection and reports failure")
    func authenticationFailure() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachRecoveryBootstrap()
        let connection = FakeConnection(token: Self.token, invalidProof: true)
        transport.connect(connection, port: PommeAgentPort.recoveryBootstrap)
        let status = await eventually { await coordinator.status() }
        #expect(status.connection == .failed)
        #expect(status.role == .recovery)
        #expect(connection.closed)
    }

    @Test("Reconnect replaces and closes the prior connection")
    func reconnect() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachNormal()
        let first = FakeConnection(token: Self.token)
        transport.connect(first, port: PommeAgentPort.persistentNormal)
        _ = await eventually { await coordinator.status() }
        let second = FakeConnection(token: Self.token)
        transport.connect(second, port: PommeAgentPort.persistentNormal)
        for _ in 0..<100 where !first.closed {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let status = await eventually { await coordinator.status() }
        #expect(first.closed)
        #expect(status.connection == .connected)
        coordinator.teardown()
        #expect(second.closed)
    }

    @Test("Unauthenticated candidate cannot replace a working session")
    func failedCandidatePreservesActiveSession() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachNormal()
        let active = FakeConnection(token: Self.token)
        transport.connect(active, port: PommeAgentPort.persistentNormal)
        _ = await eventually { await coordinator.status() }

        let candidate = FakeConnection(token: Self.token, invalidProof: true)
        transport.connect(candidate, port: PommeAgentPort.persistentNormal)
        for _ in 0..<100 where !candidate.closed { try? await Task.sleep(nanoseconds: 5_000_000) }
        let status = await coordinator.status()
        #expect(candidate.closed)
        #expect(!active.closed)
        #expect(status.connection == .connected)
        coordinator.teardown()
    }

    @Test("Coordinator provides the session dynamically after guest connection")
    func dynamicProvider() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        let provider: any PommeAgentSessionProvider = coordinator
        #expect(provider.session() == nil)
        try coordinator.attachNormal()
        transport.connect(FakeConnection(token: Self.token), port: PommeAgentPort.persistentNormal)
        _ = await eventually { await provider.status() }
        #expect(provider.session() != nil)
        provider.teardown()
    }

    @Test("Guest stream frames stay correlated with their unary response")
    func correlatedGuestStreams() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachNormal()
        transport.connect(FakeConnection(token: Self.token, streamsProcessStart: true), port: PommeAgentPort.persistentNormal)
        _ = await eventually { await coordinator.status() }
        let result = try await coordinator.performCorrelated(operation: "process.start", payload: .object([:]))
        #expect(result.result.objectValue?["jobID"]?.stringValue != nil)
        #expect(result.streamFrames.count == 1)
        #expect(result.streamFrames[0].frame.stream == .stdout)
        #expect(result.streamFrames[0].frame.data == Data("ready".utf8))
        coordinator.teardown()
    }

    @Test("Disconnect changes status and a new connection restores it")
    func disconnectAndReconnect() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token })
        try coordinator.attachNormal()
        let first = FakeConnection(token: Self.token, disconnectAfterAuthentication: true)
        transport.connect(first, port: PommeAgentPort.persistentNormal)
        _ = await eventually { await coordinator.status() }
        let session = try #require(coordinator.session())
        await #expect(throws: (any Error).self) { try await session.perform(operation: "status", payload: nil) }
        let disconnected = await eventually { await coordinator.status() }
        #expect(disconnected.connection == .disconnected)
        #expect(first.closed)

        let replacement = FakeConnection(token: Self.token)
        transport.connect(replacement, port: PommeAgentPort.persistentNormal)
        let reconnected = await eventually { await coordinator.status() }
        #expect(reconnected.connection == .connected)
        coordinator.teardown()
    }

    @Test("Exchange timeout fails closed and teardown removes the listener")
    func timeoutAndCleanup() async throws {
        let transport = FakeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.token }, exchangeTimeout: 0.01)
        try coordinator.attachRecoveryRuntime()
        let connection = FakeConnection(token: Self.token, timeout: true)
        transport.connect(connection, port: PommeAgentPort.recoveryRuntime)
        let status = await eventually { await coordinator.status() }
        #expect(status.connection == .failed)
        coordinator.teardown()
        #expect(transport.removedPorts.contains(PommeAgentPort.recoveryRuntime))
        #expect(connection.closed)
    }

    private func eventually(_ poll: @escaping @Sendable () async -> GuestAgentStatusV1) async -> GuestAgentStatusV1 {
        for _ in 0..<100 {
            let value = await poll()
            if value.connection != .connecting && value.connection != .disconnected { return value }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await poll()
    }
}

private final class FakeTransport: PommeAgentVSOCKTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var accepts: [UInt32: @Sendable (any PommeAgentVSOCKConnection) -> Void] = [:]
    private var storedInstalledPorts: [UInt32] = []
    private var storedRemovedPorts: Set<UInt32> = []

    var installedPorts: [UInt32] { lock.withLock { storedInstalledPorts } }
    var removedPorts: Set<UInt32> { lock.withLock { storedRemovedPorts } }

    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
        lock.withLock { accepts[port] = accept; storedInstalledPorts.append(port) }
    }
    func remove(port: UInt32) { lock.withLock { accepts.removeValue(forKey: port); storedRemovedPorts.insert(port) } }
    func connect(_ connection: any PommeAgentVSOCKConnection, port: UInt32) { lock.withLock { accepts[port] }?(connection) }
}

private final class FakeConnection: PommeAgentVSOCKConnection, @unchecked Sendable {
    private let token: String
    private let invalidProof: Bool
    private let timeout: Bool
    private let disconnectAfterAuthentication: Bool
    private let streamsProcessStart: Bool
    private let operationFailureCode: String?
    private let operationFailureOperation: String
    private let lock = NSLock()
    private var storedClosed = false
    private var storedTimeouts: [TimeInterval] = []
    var closed: Bool { lock.withLock { storedClosed } }
    var timeouts: [TimeInterval] { lock.withLock { storedTimeouts } }

    private let vmID: String?
    private let sessionID: String?

    init(token: String, invalidProof: Bool = false, timeout: Bool = false, disconnectAfterAuthentication: Bool = false, streamsProcessStart: Bool = false, vmID: String? = nil, sessionID: String? = nil, operationFailureCode: String? = nil, operationFailureOperation: String = "amfi.disable") {
        self.token = token
        self.invalidProof = invalidProof
        self.timeout = timeout
        self.disconnectAfterAuthentication = disconnectAfterAuthentication
        self.streamsProcessStart = streamsProcessStart
        self.operationFailureCode = operationFailureCode
        self.operationFailureOperation = operationFailureOperation
        self.vmID = vmID
        self.sessionID = sessionID
    }

    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data {
        lock.withLock { storedTimeouts.append(timeout) }
        if self.timeout { throw RunnerError.guestAgentTimedOut("test exchange") }
        guard request.last == 0x0A else { throw PommeAgentProtocol.Error.malformedFrame }
        let envelope = try PommeAgentProtocol.decode(Data(request.dropLast()))
        if disconnectAfterAuthentication,
           envelope.operation != "authenticate",
           envelope.operation != "agent.describe"
        {
            throw RunnerError.guestAgentDisconnected
        }
        if envelope.operation == "agent.describe" {
            return try PommeAgentProtocol.encode(.response(to: envelope, result: .object([
                "version": .integer(Int64(PommeAgentProtocol.version)),
                "executableSHA256": .string(String(repeating: "c", count: 64)),
                "capabilities": .array([.string("process.start"), .string("file.open")]),
                "updateState": .string("current")
            ])))
        }
        if streamsProcessStart, envelope.operation == "process.start" {
            let jobID = UUID()
            let stream = try PommeAgentJobStreamFrame(jobID: jobID, frame: .init(requestID: envelope.requestID, stream: .stdout, data: Data("ready".utf8)))
            return try PommeAgentProtocol.encode(stream.envelope()) + PommeAgentProtocol.encode(.response(to: envelope, result: .object(["jobID": .string(jobID.uuidString)])))
        }
        if let operationFailureCode, envelope.operation == operationFailureOperation {
            return try PommeAgentProtocol.encode(
                .failure(to: envelope, code: operationFailureCode, message: "closed test failure")
            )
        }
        guard envelope.operation == "authenticate", let challenge = envelope.payload.objectValue?["challenge"]?.stringValue else { throw PommeAgentProtocol.Error.invalidRequest }
        if let vmID {
            guard envelope.payload.objectValue?["vmID"]?.stringValue == vmID,
                  envelope.payload.objectValue?["sessionID"]?.stringValue == sessionID
            else { throw PommeAgentProtocol.Error.invalidRequest }
        } else {
            guard envelope.payload.objectValue?["vmID"] == nil,
                  envelope.payload.objectValue?["sessionID"] == nil
            else { throw PommeAgentProtocol.Error.invalidRequest }
        }
        let proof = invalidProof ? String(repeating: "b", count: 64) : try PommeAgentAuthentication.proof(token: token, challenge: challenge)
        return try PommeAgentProtocol.encode(.response(to: envelope, result: .object(["proof": .string(proof)])))
    }

    func close() { lock.withLock { storedClosed = true } }
}
