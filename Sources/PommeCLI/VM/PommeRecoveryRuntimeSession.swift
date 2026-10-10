import Foundation
@preconcurrency import Virtualization

/// Errors intentionally name a failed proof rather than exposing guest,
/// credential, or staging details in a host diagnostic.
enum PommeRecoveryRuntimeError: PommeDescribedError, Equatable, Sendable {
    case requestBindingRejected
    case recoveryBootRequired
    case attachmentConflict
    case attachmentNotApplied
    case attachmentUnverified
    case invalidListener
    case listenerAuthenticationRejected
    case listenerAuthenticationTimedOut
    case helperExited
    case invalidLifecycle
    case cleanupMismatch

    var code: PommeErrorCode {
        switch self {
        case .requestBindingRejected, .invalidListener: .recoveryRequestRejected
        case .recoveryBootRequired: .vmStartFailed
        case .attachmentConflict, .attachmentNotApplied, .attachmentUnverified, .invalidLifecycle:
            .recoverySessionInvalid
        case .listenerAuthenticationRejected: .recoveryAuthenticationFailed
        case .listenerAuthenticationTimedOut: .recoveryTimedOut
        case .helperExited: .helperStartFailed
        case .cleanupMismatch: .recoveryCleanupUnverified
        }
    }

    var errorDescription: String? {
        switch self {
        case .requestBindingRejected: "The Recovery request doesn't match the files that Pomme staged for it."
        case .recoveryBootRequired: "The VM isn't configured to start, or didn't start, in macOS Recovery."
        case .attachmentConflict: "The VM already has a directory share, so Pomme didn't attach its Recovery files."
        case .attachmentNotApplied: "Pomme's Recovery directory share wasn't attached to the VM."
        case .attachmentUnverified: "Pomme couldn't confirm that its Recovery directory share is attached to the VM."
        case .invalidListener: "The Recovery agent tried to connect on a port that Pomme didn't assign."
        case .listenerAuthenticationRejected: "The Recovery agent's connection didn't authenticate."
        case .listenerAuthenticationTimedOut: "The Recovery agent didn't connect and authenticate within the time limit."
        case .helperExited: "The VM helper exited before the Recovery agent authenticated."
        case .invalidLifecycle: "The Recovery runtime ran a step out of order or more than once."
        case .cleanupMismatch: "Pomme couldn't confirm that the Recovery runtime's directory share and files were removed."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .attachmentConflict, .recoveryBootRequired:
            "Run `pomme stop NAME`, then run the same command again."
        case .listenerAuthenticationRejected, .listenerAuthenticationTimedOut:
            "Run `pomme stop NAME`, then run the same command again to start a new Recovery session."
        case .helperExited:
            "Run `pomme bug-report NAME` to collect the helper log for a bug report."
        case .cleanupMismatch:
            "Run `pomme stop NAME`, then run the same command again; Pomme cleans up the earlier session first."
        default:
            nil
        }
    }
}

/// Pre-VM-construction configuration for exactly one Recovery request.  It
/// attaches the staging directory once and refuses to coexist with an
/// unreviewed VirtioFS share.
final class PommeRecoveryRuntimeConfiguration: @unchecked Sendable {
    let request: PommeRecoverySessionRequest
    let staging: PommeRecoveryStaging

    private let lock = NSLock()
    private var applied = false

    init(request: PommeRecoverySessionRequest, staging: PommeRecoveryStaging, bootMode: BootMode) throws {
        guard bootMode == .recovery else { throw PommeRecoveryRuntimeError.recoveryBootRequired }
        guard request.isWellFormed,
              staging.request.requestID == request.requestID,
              staging.request.vmUUID == request.vmUUID,
              staging.request.listenerPort == request.listenerPort,
              staging.proof.requestID == request.requestID,
              staging.proof.vmUUID == request.vmUUID,
              staging.proof.isComplete
        else { throw PommeRecoveryRuntimeError.requestBindingRejected }
        self.request = request
        self.staging = staging
    }

    /// Call while constructing the `VZVirtualMachineConfiguration`, before a
    /// VM is made from it.  An existing share would make cleanup non-exact.
    func apply(to configuration: VZVirtualMachineConfiguration) throws {
        try lock.withLock {
            guard !applied else { throw PommeRecoveryRuntimeError.attachmentNotApplied }
            guard configuration.directorySharingDevices.isEmpty else {
                throw PommeRecoveryRuntimeError.attachmentConflict
            }
            configuration.directorySharingDevices = staging.directorySharingDevices
            guard configuration.directorySharingDevices.count == 1,
                  let device = configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration,
                  device.tag == staging.deviceConfiguration.tag,
                  device.share != nil
            else { throw PommeRecoveryRuntimeError.attachmentNotApplied }
            applied = true
        }
    }

    func requireApplied() throws {
        guard lock.withLock({ applied }) else { throw PommeRecoveryRuntimeError.attachmentNotApplied }
    }
}

struct PommeRecoveryRuntimeCleanup: Sendable {
    /// The effect must detach the exact request tag, reap the Recovery helper,
    /// remove only the request staging artifacts, and clear sensitive receipt
    /// buffers before it returns this proof.
    let shareDetached: Bool
    let helperStoppedAndReaped: Bool
    let stagingArtifactsRemoved: Bool
    let sensitiveFramesCleared: Bool
    let unknownStateRejected: Bool

    var isComplete: Bool {
        shareDetached
            && helperStoppedAndReaped
            && stagingArtifactsRemoved
            && sensitiveFramesCleared
            && unknownStateRejected
    }
}

/// VM-side effects deliberately stop at runtime construction and process
/// lifetime. Guest operation semantics remain owned by Pomme guest transport;
/// final-state selection remains owned by `PommeRecoverySession`.
struct PommeRecoveryRuntimeEffects: Sendable {
    /// Proves that the already-constructed VM is the UUID bound into the
    /// immutable request; a bundle path or display name is not identity.
    let verifyVMIdentity: @Sendable () -> Bool
    let startRecovery: @Sendable () async throws -> Void
    /// Starts the request's Recovery launcher only after every post-start proof
    /// has passed. The launcher may be what makes the listener authenticate.
    let launchRecoveryAgent: @Sendable () async throws -> Void
    /// Checked after `startRecovery` so a helper that starts normal macOS is
    /// rejected before the launcher can send guest input.
    let verifyRecoveryBoot: @Sendable () -> Bool
    let helperIsAlive: @Sendable () -> Bool
    let verifyBootstrapAttachment: @Sendable () -> Bool
    let stopReapAndClean: @Sendable () async throws -> PommeRecoveryRuntimeCleanup
}

enum PommeRecoveryRuntimeState: Equatable, Sendable {
    case configured
    case waitingForAuthentication
    case connected
    case cleaning
    case cleaned
    case failed
}

/// Production root port for a bounded Recovery VM. The primary composes this
/// with the Security-owned session and a Guest-transport-owned guest port.
/// It never exposes a normal listener, arbitrary port, or alternate protocol.
final class PommeRecoveryRuntimeRootPort: PommeRecoveryRootPort, @unchecked Sendable {
    private let configuration: PommeRecoveryRuntimeConfiguration
    private let coordinator: PommeAgentVSOCKCoordinator
    private let effects: PommeRecoveryRuntimeEffects
    private let authenticationTimeout: TimeInterval
    private let authenticationNow: @Sendable () -> Date
    private let authenticationSleep: @Sendable () async throws -> Void
    private let lock = NSLock()
    private var state: PommeRecoveryRuntimeState = .configured

    init(
        configuration: PommeRecoveryRuntimeConfiguration,
        coordinator: PommeAgentVSOCKCoordinator,
        effects: PommeRecoveryRuntimeEffects,
        authenticationTimeout: TimeInterval = Constants.defaultRecoveryAgentTimeout,
        authenticationNow: @escaping @Sendable () -> Date = { Date() },
        authenticationSleep: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    ) throws {
        guard authenticationTimeout > 0 else { throw PommeRecoveryRuntimeError.listenerAuthenticationTimedOut }
        self.configuration = configuration
        self.coordinator = coordinator
        self.effects = effects
        self.authenticationTimeout = authenticationTimeout
        self.authenticationNow = authenticationNow
        self.authenticationSleep = authenticationSleep
    }

    func prepare(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryRootEvidence {
        try requireExactRequest(request)
        try configuration.requireApplied()
        guard lock.withLock({ state == .configured }) else { throw PommeRecoveryRuntimeError.invalidLifecycle }
        guard effects.verifyVMIdentity() else { throw PommeRecoveryRuntimeError.requestBindingRejected }
        guard effects.verifyBootstrapAttachment() else { throw PommeRecoveryRuntimeError.attachmentUnverified }

        do {
            let role = try recoveryRole(for: request.listenerPort)
            try attach(role)
            try await effects.startRecovery()
            // Starting a VZ runtime is not proof that it booted the requested
            // Recovery system. Recheck every immutable binding after the
            // asynchronous start, immediately before allowing the launcher to
            // send any guest input.
            guard effects.verifyVMIdentity() else { throw PommeRecoveryRuntimeError.requestBindingRejected }
            guard effects.verifyRecoveryBoot() else { throw PommeRecoveryRuntimeError.recoveryBootRequired }
            guard effects.helperIsAlive() else { throw PommeRecoveryRuntimeError.helperExited }
            guard effects.verifyBootstrapAttachment() else { throw PommeRecoveryRuntimeError.attachmentUnverified }
            try await effects.launchRecoveryAgent()
            lock.withLock { state = .waitingForAuthentication }
            try await waitForAuthentication(role: role)
            lock.withLock { state = .connected }
            return try configuration.staging.rootEvidence(listenerReady: true)
        } catch {
            coordinator.teardown()
            lock.withLock { state = .failed }
            throw error
        }
    }

    func cleanup(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryCleanupEvidence {
        try requireExactRequest(request)
        let current = lock.withLock { state }
        guard current != .cleaned && current != .cleaning else { throw PommeRecoveryRuntimeError.invalidLifecycle }
        lock.withLock { state = .cleaning }

        // Listener/session closure comes before the helper and staging teardown
        // so an accepted connection cannot outlive its request workspace.
        coordinator.teardown()
        do {
            let cleanup = try await effects.stopReapAndClean()
            guard cleanup.isComplete else { throw PommeRecoveryRuntimeError.cleanupMismatch }
            lock.withLock { state = .cleaned }
            return .init(
                shareRemoved: cleanup.shareDetached,
                launcherRemoved: cleanup.stagingArtifactsRemoved,
                credentialRemoved: cleanup.stagingArtifactsRemoved,
                listenerClosed: true,
                sensitiveFramesCleared: cleanup.sensitiveFramesCleared,
                unknownStateRejected: cleanup.unknownStateRejected
            )
        } catch {
            lock.withLock { state = .failed }
            throw error
        }
    }

    /// The primary may pass this exact authenticated session to a
    /// Guest-transport-owned `PommeRecoveryGuestPort` adapter. No operation is
    /// dispatched here, which prevents the VM runtime from creating a second
    /// guest command protocol.
    func authenticatedGuestSession() throws -> any PommeAgentSessionProtocol {
        let role = try recoveryRole(for: configuration.request.listenerPort)
        guard lock.withLock({ state == .connected }),
              coordinator.isAuthenticated(as: role),
              let session = coordinator.session()
        else { throw PommeRecoveryRuntimeError.invalidLifecycle }
        return session
    }

    func runtimeState() -> PommeRecoveryRuntimeState { lock.withLock { state } }

    private func requireExactRequest(_ request: PommeRecoverySessionRequest) throws {
        let expected = configuration.request
        guard request == expected
        else { throw PommeRecoveryRuntimeError.requestBindingRejected }
    }

    private func recoveryRole(for port: UInt32) throws -> PommeAgentVSOCKRole {
        switch PommeRecoveryListenerPort(rawValue: port) {
        case .bootstrap: .recoveryBootstrap
        case .operation: .recoveryRuntime
        case nil: throw PommeRecoveryRuntimeError.invalidListener
        }
    }

    private func attach(_ role: PommeAgentVSOCKRole) throws {
        switch role {
        case .recoveryBootstrap: try coordinator.attachRecoveryBootstrap()
        case .recoveryRuntime: try coordinator.attachRecoveryRuntime()
        case .normal: throw PommeRecoveryRuntimeError.invalidListener
        }
    }

    private func waitForAuthentication(role: PommeAgentVSOCKRole) async throws {
        let deadline = authenticationNow().addingTimeInterval(authenticationTimeout)
        while authenticationNow() < deadline {
            guard effects.helperIsAlive() else { throw PommeRecoveryRuntimeError.helperExited }
            if coordinator.isAuthenticated(as: role) { return }
            if await coordinator.status().connection == .failed {
                throw PommeRecoveryRuntimeError.listenerAuthenticationRejected
            }
            try Task.checkCancellation()
            try await authenticationSleep()
        }
        guard effects.helperIsAlive() else { throw PommeRecoveryRuntimeError.helperExited }
        throw PommeRecoveryRuntimeError.listenerAuthenticationTimedOut
    }
}
