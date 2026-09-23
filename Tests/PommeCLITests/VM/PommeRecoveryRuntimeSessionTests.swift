import Foundation
import Synchronization
@preconcurrency import Virtualization
import Testing

@Suite("Pomme Recovery VM runtime")
struct PommeRecoveryRuntimeSessionTests {
    @Test("Recovery boot proof requires the requested mode, successful start, and a running VM")
    func recoveryBootProofPolicy() {
        #expect(PommeVMRuntime.recoveryBootIsProven(
            bootMode: .recovery,
            startCompleted: true,
            state: .running
        ))
        #expect(!PommeVMRuntime.recoveryBootIsProven(
            bootMode: .normal,
            startCompleted: true,
            state: .running
        ))
        #expect(!PommeVMRuntime.recoveryBootIsProven(
            bootMode: .recovery,
            startCompleted: false,
            state: .running
        ))
        #expect(!PommeVMRuntime.recoveryBootIsProven(
            bootMode: .recovery,
            startCompleted: true,
            state: .stopped
        ))
    }

    @Test("Configuration accepts one exact Recovery bootstrap share")
    func configurationAppliesExactAttachment() throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        let configuration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: configuration)

        #expect(configuration.directorySharingDevices.count == 1)
        #expect((configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)?.tag == fixture.staging.deviceConfiguration.tag)
        #expect(throws: PommeRecoveryRuntimeError.self) {
            try fixture.configuration.apply(to: configuration)
        }
    }

    @Test("Normal boot and pre-existing shares fail closed")
    func configurationRejectsUnsafeBootOrShare() throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        #expect(throws: PommeRecoveryRuntimeError.self) {
            _ = try PommeRecoveryRuntimeConfiguration(
                request: fixture.request,
                staging: fixture.staging,
                bootMode: .normal
            )
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.directorySharingDevices = [VZVirtioFileSystemDeviceConfiguration(tag: "unreviewed")]
        #expect(throws: PommeRecoveryRuntimeError.self) {
            try fixture.configuration.apply(to: configuration)
        }
    }

    @Test("Bootstrap listener timeout tears down before exact cleanup")
    func bootstrapTimeoutCleansInOrder() async throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        let vmConfiguration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: vmConfiguration)
        let transport = RecoveryRuntimeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in String(repeating: "a", count: 64) })
        let calls = RuntimeCalls()
        let root = try PommeRecoveryRuntimeRootPort(
            configuration: fixture.configuration,
            coordinator: coordinator,
            effects: calls.effects,
            authenticationTimeout: 0.001
        )

        do {
            _ = try await root.prepare(request: fixture.request)
            Issue.record("Expected listener authentication timeout")
        } catch let error as PommeRecoveryRuntimeError {
            #expect(error == .listenerAuthenticationTimedOut)
        }
        #expect(transport.installedPorts == [PommeAgentPort.recoveryBootstrap])
        #expect(transport.removedPorts.contains(PommeAgentPort.recoveryBootstrap))
        #expect(root.runtimeState() == .failed)

        let cleanup = try await root.cleanup(request: fixture.request)
        #expect(cleanup.isComplete)
        #expect(calls.cleanupCalls == 1)
        #expect(root.runtimeState() == .cleaned)
    }

    @Test("Operation requests select only the 505053 listener")
    func operationListenerSelection() async throws {
        let fixture = try RuntimeFixture(port: .operation)
        let vmConfiguration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: vmConfiguration)
        let transport = RecoveryRuntimeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in String(repeating: "a", count: 64) })
        let calls = RuntimeCalls(helperAlive: false)
        let root = try PommeRecoveryRuntimeRootPort(
            configuration: fixture.configuration,
            coordinator: coordinator,
            effects: calls.effects,
            authenticationTimeout: 1
        )

        do {
            _ = try await root.prepare(request: fixture.request)
            Issue.record("Expected helper-exit failure")
        } catch let error as PommeRecoveryRuntimeError {
            #expect(error == .helperExited)
        }
        #expect(transport.installedPorts == [PommeAgentPort.recoveryRuntime])
        #expect(transport.removedPorts.contains(PommeAgentPort.recoveryRuntime))
        _ = try await root.cleanup(request: fixture.request)
    }

    @Test("Every post-start Recovery proof gate blocks agent launch", arguments: RecoveryProofFailure.allCases)
    func failedProofDoesNotLaunchAgent(_ failure: RecoveryProofFailure) async throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        let vmConfiguration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: vmConfiguration)
        let transport = RecoveryRuntimeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in String(repeating: "a", count: 64) }
        )
        let calls = RuntimeCalls(failure: failure)
        let root = try PommeRecoveryRuntimeRootPort(
            configuration: fixture.configuration,
            coordinator: coordinator,
            effects: calls.effects,
            authenticationTimeout: 0.01
        )

        await #expect(throws: PommeRecoveryRuntimeError.self) {
            _ = try await root.prepare(request: fixture.request)
        }
        #expect(calls.startCalls == 1)
        #expect(calls.launchCalls == 0)
        #expect(root.runtimeState() == .failed)
        _ = try await root.cleanup(request: fixture.request)
    }

    @Test("Recovery launch precedes listener authentication")
    func launchPrecedesAuthentication() async throws {
        try await runLaunchPrecedesAuthentication()
    }

    @Test("Recovery launch ordering is independent of delayed authentication admission")
    func delayedLaunchAuthenticationOrdering() async throws {
        try await runLaunchPrecedesAuthentication(authenticationTimeout: 0.05, beforeAuthentication: {
            try? await Task.sleep(for: .milliseconds(120))
        })
    }

    @Test("Recovery authentication ready after the logical deadline still times out")
    func authenticationAfterDeadlineRemainsRejected() async throws {
        try await runLaunchPrecedesAuthentication(authenticationTimeout: 0.05, expireAfterAuthentication: true)
    }

    @Test("Recovery fixture admission wait is bounded and cancellation-aware", arguments: [false, true])
    func fixtureAdmissionWaitFailure(cancelled: Bool) async throws {
        let task = Task {
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            try await Self.waitForFixture(timeout: .zero) { cancelled }
        }
        do {
            try await task.value
            Issue.record("Expected fixture admission wait failure")
        } catch is CancellationError {
            #expect(cancelled)
        } catch FixtureWaitFailure.timedOut {
            #expect(!cancelled)
        }
    }

    private func runLaunchPrecedesAuthentication(
        authenticationTimeout: TimeInterval = 5,
        expireAfterAuthentication: Bool = false,
        beforeAuthentication: (@Sendable () async -> Void)? = nil
    ) async throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        let vmConfiguration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: vmConfiguration)
        let transport = RecoveryRuntimeTransport()
        let token = String(repeating: "a", count: 64)
        let binding = PommeAgentVSOCKBinding(vmID: fixture.request.vmUUID, sessionID: fixture.request.requestID)
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in token },
            bindingProvider: { role in role == .recoveryBootstrap ? binding : nil }
        )
        let calls = RuntimeCalls()
        let logicalNow = Mutex(Date(timeIntervalSince1970: 0))
        let pollEntered = Mutex(false)
        let connection = RecoveryAuthenticatedConnection(
            token: token, events: calls, beforeAuthentication: {
                // Ensure the real root's polling sleeper is exercised even
                // when authentication would otherwise complete immediately.
                try await Self.waitForFixture { pollEntered.withLock { $0 } }
                await beforeAuthentication?()
            }
        )
        calls.onLaunch = {
            transport.connect(
                connection,
                port: PommeAgentPort.recoveryBootstrap
            )
        }
        let root = try PommeRecoveryRuntimeRootPort(
            configuration: fixture.configuration,
            coordinator: coordinator,
            effects: calls.effects,
            authenticationTimeout: authenticationTimeout,
            authenticationNow: { logicalNow.withLock { $0 } },
            authenticationSleep: {
                pollEntered.withLock { $0 = true }
                try await Self.waitForFixture {
                    coordinator.isAuthenticated(as: .recoveryBootstrap)
                }
                if expireAfterAuthentication {
                    logicalNow.withLock { $0 = $0.addingTimeInterval(authenticationTimeout + 1) }
                }
            }
        )

        do {
            let evidence = try await root.prepare(request: fixture.request)
            #expect(!expireAfterAuthentication)
            #expect(evidence.isAcceptable)
            #expect(calls.launchCalls == 1)
            #expect(calls.events == ["start", "launch", "authenticate"])
            _ = try await root.cleanup(request: fixture.request)
            await connection.drainAuthentication()
        } catch {
            if expireAfterAuthentication, let error = error as? PommeRecoveryRuntimeError,
               error == .listenerAuthenticationTimedOut {
                // Observe the root's own failure teardown before fixture
                // cleanup can remove the listener or authenticated session.
                #expect(root.runtimeState() == .failed)
                #expect(!coordinator.isAuthenticated(as: .recoveryBootstrap))
                #expect(transport.removedPorts.contains(PommeAgentPort.recoveryBootstrap))
                #expect(calls.events == ["start", "launch", "authenticate"])
                await connection.drainAuthentication()
                let cleanup = try await root.cleanup(request: fixture.request)
                #expect(cleanup.isComplete)
                #expect(calls.cleanupCalls == 1)
                #expect(root.runtimeState() == .cleaned)
                return
            }
            coordinator.teardown()
            await connection.drainAuthentication()
            throw error
        }
    }

    private enum FixtureWaitFailure: Error { case timedOut }

    private static func waitForFixture(
        timeout: Duration = .seconds(30),
        condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if condition() { return }
            guard ContinuousClock.now < deadline else { throw FixtureWaitFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("Incomplete frame cleanup never produces Recovery cleanup evidence", arguments: [false, true])
    func cleanupMismatchFailsClosed(physicalCleanupComplete: Bool) async throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        let vmConfiguration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: vmConfiguration)
        let transport = RecoveryRuntimeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in String(repeating: "a", count: 64) })
        let calls = RuntimeCalls(cleanupComplete: physicalCleanupComplete, sensitiveFramesCleared: false)
        let root = try PommeRecoveryRuntimeRootPort(
            configuration: fixture.configuration,
            coordinator: coordinator,
            effects: calls.effects,
            authenticationTimeout: 1
        )

        do {
            _ = try await root.cleanup(request: fixture.request)
            Issue.record("Expected cleanup mismatch")
        } catch let error as PommeRecoveryRuntimeError {
            #expect(error == .cleanupMismatch)
        }
        #expect(root.runtimeState() == .failed)
        #expect(calls.cleanupCalls == 1)
    }
}

enum RecoveryProofFailure: String, CaseIterable, Sendable {
    case identity
    case boot
    case helper
    case attachment
}

private struct RuntimeFixture {
    let request: PommeRecoverySessionRequest
    let staging: PommeRecoveryStaging
    let configuration: PommeRecoveryRuntimeConfiguration

    init(port: PommeRecoveryListenerPort) throws {
        let credential = try PommeRecoveryCredential(
            secret: Data(repeating: 7, count: 32),
            expiresAt: Date().addingTimeInterval(120)
        )
        let operation: PommeRecoveryOperation = port == .bootstrap ? .installAgent : .sip(.status)
        request = try PommeRecoverySessionRequest(
            vmUUID: UUID(),
            operation: operation,
            expiresAt: Date().addingTimeInterval(60),
            executableSHA256: String(repeating: "a", count: 64),
            credential: credential
        )
        let device = VZVirtioFileSystemDeviceConfiguration(tag: "pomme-test-\(UUID().uuidString.prefix(8))")
        device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: "/private/tmp"), readOnly: true))
        let proof = PommeRecoveryStagingProof(
            requestID: request.requestID,
            vmUUID: request.vmUUID,
            readOnly: true,
            signatureVerified: true,
            digestVerified: true,
            inodeVerified: true,
            modeVerified: true,
            launcherInstalled: true
        )
        staging = .init(request: request, rootURL: URL(fileURLWithPath: "/private/tmp/pomme-test"), deviceConfiguration: device, proof: proof)
        configuration = try .init(request: request, staging: staging, bootMode: .recovery)
    }
}

private final class RecoveryRuntimeTransport: PommeAgentVSOCKTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedInstalledPorts: [UInt32] = []
    private var storedRemovedPorts: Set<UInt32> = []
    private var accepts: [UInt32: @Sendable (any PommeAgentVSOCKConnection) -> Void] = [:]

    var installedPorts: [UInt32] { lock.withLock { storedInstalledPorts } }
    var removedPorts: Set<UInt32> { lock.withLock { storedRemovedPorts } }

    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
        lock.withLock {
            accepts[port] = accept
            storedInstalledPorts.append(port)
        }
    }

    func remove(port: UInt32) {
        lock.withLock {
            accepts.removeValue(forKey: port)
            storedRemovedPorts.insert(port)
        }
    }

    func connect(_ connection: any PommeAgentVSOCKConnection, port: UInt32) {
        lock.withLock { accepts[port] }?(connection)
    }
}

private final class RuntimeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private let isHelperAlive: Bool
    private let isCleanupComplete: Bool
    private let areSensitiveFramesCleared: Bool
    private let identityChecks: BoolSequence
    private let bootChecks: BoolSequence
    private let attachmentChecks: BoolSequence
    private var storedCleanupCalls = 0
    private var storedStartCalls = 0
    private var storedLaunchCalls = 0
    private var storedEvents: [String] = []
    private var storedOnLaunch: (@Sendable () -> Void)?

    var onLaunch: (@Sendable () -> Void)? {
        get { lock.withLock { storedOnLaunch } }
        set { lock.withLock { storedOnLaunch = newValue } }
    }

    init(
        helperAlive: Bool = true,
        cleanupComplete: Bool = true,
        sensitiveFramesCleared: Bool = true,
        failure: RecoveryProofFailure? = nil
    ) {
        isHelperAlive = helperAlive && failure != .helper
        isCleanupComplete = cleanupComplete
        areSensitiveFramesCleared = sensitiveFramesCleared
        identityChecks = .init(values: failure == .identity ? [true, false] : [true, true])
        bootChecks = .init(values: failure == .boot ? [false] : [true])
        attachmentChecks = .init(values: failure == .attachment ? [true, false] : [true, true])
    }

    var cleanupCalls: Int { lock.withLock { storedCleanupCalls } }
    var startCalls: Int { lock.withLock { storedStartCalls } }
    var launchCalls: Int { lock.withLock { storedLaunchCalls } }
    var events: [String] { lock.withLock { storedEvents } }

    var effects: PommeRecoveryRuntimeEffects {
        .init(
            verifyVMIdentity: { self.identityChecks.next() },
            startRecovery: {
                self.record("start")
                self.lock.withLock { self.storedStartCalls += 1 }
            },
            launchRecoveryAgent: {
                self.record("launch")
                self.lock.withLock { self.storedLaunchCalls += 1 }
                self.onLaunch?()
            },
            verifyRecoveryBoot: { self.bootChecks.next() },
            helperIsAlive: { self.isHelperAlive },
            verifyBootstrapAttachment: { self.attachmentChecks.next() },
            stopReapAndClean: {
                self.lock.withLock { self.storedCleanupCalls += 1 }
                return .init(
                    shareDetached: self.isCleanupComplete,
                    helperStoppedAndReaped: self.isCleanupComplete,
                    stagingArtifactsRemoved: self.isCleanupComplete,
                    sensitiveFramesCleared: self.isCleanupComplete && self.areSensitiveFramesCleared,
                    unknownStateRejected: self.isCleanupComplete
                )
            }
        )
    }

    func record(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class BoolSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(values: [Bool]) { self.values = values }

    func next() -> Bool {
        lock.withLock {
            guard !values.isEmpty else { return true }
            if values.count == 1 { return values[0] }
            return values.removeFirst()
        }
    }
}

private final class RecoveryAuthenticatedConnection: PommeAgentVSOCKConnection, @unchecked Sendable {
    private let beforeAuthentication: (@Sendable () async throws -> Void)?
    private let token: String
    private let events: RuntimeCalls
    private let lock = NSLock()
    private var storedClosed = false
    private var authenticationRunning = false
    private var authenticationWaiters: [CheckedContinuation<Void, Never>] = []

    init(token: String, events: RuntimeCalls, beforeAuthentication: (@Sendable () async throws -> Void)? = nil) {
        self.beforeAuthentication = beforeAuthentication
        self.token = token
        self.events = events
    }

    func exchange(_ request: Data, timeout _: TimeInterval) async throws -> Data {
        guard lock.withLock({
            guard !storedClosed else { return false }
            authenticationRunning = true
            return true
        }) else { throw PommeAgentProtocol.Error.invalidRequest }
        defer {
            let waiters = lock.withLock {
                authenticationRunning = false
                let waiters = authenticationWaiters
                authenticationWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
        try await beforeAuthentication?()
        guard request.last == 0x0A else { throw PommeAgentProtocol.Error.malformedFrame }
        let envelope = try PommeAgentProtocol.decode(Data(request.dropLast()))
        guard envelope.operation == "authenticate",
              let challenge = envelope.payload.objectValue?["challenge"]?.stringValue
        else { throw PommeAgentProtocol.Error.invalidRequest }
        events.record("authenticate")
        let proof = try PommeAgentAuthentication.proof(token: token, challenge: challenge)
        let response = try PommeAgentProtocol.encode(.response(
            to: envelope,
            result: .object(["proof": .string(proof)])
        ))
        return response
    }

    func close() {
        lock.withLock { storedClosed = true }
    }
    func drainAuthentication() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock {
                guard authenticationRunning else { return true }
                authenticationWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }
}
