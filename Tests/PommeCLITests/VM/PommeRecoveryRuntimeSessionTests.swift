import Foundation
@preconcurrency import Virtualization
import Testing

@Suite("Pomme Recovery VM runtime")
struct PommeRecoveryRuntimeSessionTests {
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

    @Test("Incomplete cleanup never produces Recovery cleanup evidence")
    func cleanupMismatchFailsClosed() async throws {
        let fixture = try RuntimeFixture(port: .bootstrap)
        let vmConfiguration = VZVirtualMachineConfiguration()
        try fixture.configuration.apply(to: vmConfiguration)
        let transport = RecoveryRuntimeTransport()
        let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in String(repeating: "a", count: 64) })
        let calls = RuntimeCalls(cleanupComplete: false)
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

    var installedPorts: [UInt32] { lock.withLock { storedInstalledPorts } }
    var removedPorts: Set<UInt32> { lock.withLock { storedRemovedPorts } }

    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
        lock.withLock { storedInstalledPorts.append(port) }
    }

    func remove(port: UInt32) { lock.withLock { storedRemovedPorts.insert(port) } }
}

private final class RuntimeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private let isHelperAlive: Bool
    private let isCleanupComplete: Bool
    private var storedCleanupCalls = 0

    init(helperAlive: Bool = true, cleanupComplete: Bool = true) {
        isHelperAlive = helperAlive
        isCleanupComplete = cleanupComplete
    }

    var cleanupCalls: Int { lock.withLock { storedCleanupCalls } }

    var effects: PommeRecoveryRuntimeEffects {
        .init(
            verifyVMIdentity: { true },
            startRecovery: {},
            verifyRecoveryBoot: { true },
            helperIsAlive: { self.isHelperAlive },
            verifyBootstrapAttachment: { true },
            stopReapAndClean: {
                self.lock.withLock { self.storedCleanupCalls += 1 }
                return .init(
                    shareDetached: self.isCleanupComplete,
                    helperStoppedAndReaped: self.isCleanupComplete,
                    stagingArtifactsRemoved: self.isCleanupComplete,
                    sensitiveFramesCleared: self.isCleanupComplete,
                    unknownStateRejected: self.isCleanupComplete
                )
            }
        )
    }
}
