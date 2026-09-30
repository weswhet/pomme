import CryptoKit
import Foundation

/// The production composition boundary for a single, request-bound Recovery
/// operation.  Core owns the Virtualization objects and VM bookkeeping; this
/// type wires those narrow hooks to the Security-owned session lifecycle.
///
/// A factory is intentionally stateless.  `make` creates an integration whose
/// adapter issues its credential and creates its immutable request only when
/// `execute` is called.  This keeps a factory reusable while ensuring that a
/// credential can never be reused for a second payload or final-state request.
enum PommeLiveRecoveryIntegration {
    /// A credential that cannot cover the complete post-launch authentication
    /// window plus this reserve is never submitted to Recovery.  The check is
    /// performed immediately before the one mutating launcher input.
    static let credentialAuthenticationReserve: TimeInterval = 30

    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unsupportedOperation
        case invalidDependencies
        case ownershipMismatch
        case executableMismatch
        case requestBindingRejected
        case credentialRejected
        case launcherRejected
        case runtimeRejected
        case guestRejected
        case cleanupFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedOperation:
                "The Recovery operation is not supported by Pomme."
            case .invalidDependencies:
                "The Pomme Recovery integration dependencies are invalid."
            case .ownershipMismatch:
                "The VM is not the exact Pomme-owned VM bound to this request."
            case .executableMismatch:
                "The signed Pomme executable identity changed."
            case .requestBindingRejected:
                "The Recovery request binding was rejected."
            case .credentialRejected:
                "The one-shot Recovery credential was rejected."
            case .launcherRejected:
                "The bounded Recovery launcher was not verified."
            case .runtimeRejected:
                "The Recovery runtime could not be verified."
            case .guestRejected:
                "The authenticated Recovery operation was rejected."
            case .cleanupFailed:
                "Recovery cleanup could not be proven complete."
            }
        }
    }

    /// Exact host identity resolved by Core before a Recovery VM is built.
    /// `ownership` carries the immutable Pomme provenance marker; the APFS
    /// volume-group identity is needed only by the guest install operation.
    struct VMIdentity: Equatable, Sendable {
        let ownership: PommeVMOwnership
        let targetVolumeGroupUUID: UUID?

        init(ownership: PommeVMOwnership, targetVolumeGroupUUID: UUID? = nil) throws {
            guard ownership.marker == PommeVMOwnership.provenance else {
                throw Error.invalidDependencies
            }
            self.ownership = ownership
            self.targetVolumeGroupUUID = targetVolumeGroupUUID
        }

        func matches(_ reference: VMReference) -> Bool {
            ownership.bundlePath == reference.standardizedPath
                && (reference.name == nil || reference.name == ownership.name)
                && ownership.marker == PommeVMOwnership.provenance
        }
    }

    /// Exact signed executable identity supplied by the host build/install
    /// layer.  The staging builder repeats the inode, signature, and digest
    /// checks immediately before writing the request share.
    struct ExecutableIdentity: Equatable, Sendable {
        let url: URL
        let sha256: String

        init(url: URL, sha256: String) throws {
            let canonical = url.standardizedFileURL
            guard canonical.path == url.path,
                  canonical.path.hasPrefix("/"),
                  !canonical.path.contains("\0"),
                  PommeProvisioningDigest.isSHA256(sha256),
                  sha256 == sha256.lowercased()
            else { throw Error.executableMismatch }
            self.url = canonical
            self.sha256 = sha256
        }
    }

    /// Context covered by the immutable Recovery request and presented to the
    /// one-shot credential issuer. The request builder must serialize both
    /// fields; `PommeRecoverySession` covers them with its admission HMAC.
    struct RequestContext: Equatable, Sendable {
        let payloadSHA256: String
        let finalState: VMFinalState
        let issuedAt: Date
        let lifetime: TimeInterval

        init(payload: Data, finalState: VMFinalState, issuedAt: Date, lifetime: TimeInterval) throws {
            guard payload.count <= PommeAgentProtocol.maximumFrameBytes,
                  PommeProvisioningDigest.isSHA256(PommeProvisioningDigest.sha256(payload)),
                  lifetime > 0,
                  lifetime <= 15 * 60
            else { throw Error.invalidDependencies }
            payloadSHA256 = PommeProvisioningDigest.sha256(payload)
            self.finalState = finalState
            self.issuedAt = issuedAt
            self.lifetime = lifetime
        }
    }

    struct CredentialRequest: Sendable {
        let reference: VMReference
        let identity: VMIdentity
        let operation: PommeRecoveryOperation
        let context: RequestContext
    }

    struct RequestInput: Sendable {
        let requestID: UUID
        let vmUUID: UUID
        let operation: PommeRecoveryOperation
        let issuedAt: Date
        let expiresAt: Date
        let executableSHA256: String
        let credential: PommeRecoveryCredential
        let context: RequestContext
    }

    enum InstallMode: String, Equatable, Sendable {
        case initial
        case repair
    }

    /// Validates the install plan against this Recovery transaction before any
    /// persistent credential is read or a privileged guest operation is sent.
    /// The session has already authenticated and bound the request and payload.
    static func validateInstallPayload(
        _ payload: Data,
        reference: VMReference,
        identity: VMIdentity,
        executable: ExecutableIdentity,
        request: PommeRecoverySessionRequest,
        finalState: VMFinalState,
        installMode: InstallMode?
    ) throws {
        let plan: PommeProvisioningPlan
        do {
            plan = try JSONDecoder().decode(PommeProvisioningPlan.self, from: payload)
        } catch {
            throw PommeRecoverySessionError.requestMismatch
        }
        // Initial installation is an intermediate provisioning phase and must
        // finish stopped. The plan's eventual --boot state is restored only
        // after normal-agent verification, not by this Recovery transaction.
        // Repair instead restores its independently request-bound final state.
        guard plan.digest == PommeProvisioningDigest.sha256(payload),
              plan.vm.uuid == identity.ownership.uuid,
              plan.vm.bundlePath == reference.standardizedPath,
              reference.name == nil || plan.vm.name == reference.name,
              plan.recoveryAgent.executableDigest == executable.sha256,
              plan.recoveryAgent.role == .recovery,
              plan.normalAgent.role == .normal,
              request.requestedFinalState == finalState.rawValue,
              installMode != nil,
              installMode == .initial ? identity.targetVolumeGroupUUID == nil : identity.targetVolumeGroupUUID != nil,
              installMode == .repair || finalState == .stopped
        else { throw PommeRecoverySessionError.requestMismatch }
    }

    /// Core constructs the exact VZ VM/configuration/coordinator through this
    /// value.  The module never reaches into a VM or creates an alternate
    /// guest transport; it only decorates the supplied Recovery effects with
    /// the reviewed keyboard-to-Terminal launch step.
    struct Runtime: @unchecked Sendable {
        let coordinator: PommeAgentVSOCKCoordinator
        let vmPort: any PommeRecoveryVMPort
        let effects: PommeRecoveryRuntimeEffects
        let terminalPort: any PommeRecoveryTerminalPort
        /// Called only after the Recovery coordinator has authenticated the
        /// exact request-bound session and immediately before the privileged
        /// guest operation. Core must detach this request's share and remove
        /// its host staging root here; no other share may be touched.
        let clearHostStagingBeforeOperation: @Sendable () async throws -> Void
        /// A coordinator is accepted only when its binding provider has been
        /// configured for this request's exact VM and session identifiers.
        let verifySessionBinding: @Sendable (PommeRecoverySessionRequest) -> Bool
        /// Restores the exact lifecycle state captured before Core constructed
        /// the request-specific VZ runtime. This is used only when composition
        /// fails before `PommeRecoverySession` takes ownership.
        let restoreCapturedState: @Sendable () async throws -> Void

        init(
            coordinator: PommeAgentVSOCKCoordinator,
            vmPort: any PommeRecoveryVMPort,
            effects: PommeRecoveryRuntimeEffects,
            terminalPort: any PommeRecoveryTerminalPort,
            clearHostStagingBeforeOperation: @escaping @Sendable () async throws -> Void,
            verifySessionBinding: @escaping @Sendable (PommeRecoverySessionRequest) -> Bool,
            restoreCapturedState: @escaping @Sendable () async throws -> Void
        ) {
            self.coordinator = coordinator
            self.vmPort = vmPort
            self.effects = effects
            self.terminalPort = terminalPort
            self.clearHostStagingBeforeOperation = clearHostStagingBeforeOperation
            self.verifySessionBinding = verifySessionBinding
            self.restoreCapturedState = restoreCapturedState
        }
    }

    struct Dependencies: Sendable {
        typealias VMResolver = @Sendable (VMReference) async throws -> VMIdentity
        typealias ExecutableResolver = @Sendable (VMReference, PommeRecoveryOperation) async throws -> ExecutableIdentity
        typealias CredentialIssuer = @Sendable (CredentialRequest) async throws -> PommeRecoveryCredential
        typealias RequestBuilder = @Sendable (RequestInput) throws -> PommeRecoverySessionRequest
        typealias RuntimeBuilder = @Sendable (
            VMReference,
            PommeRecoverySessionRequest,
            PommeRecoveryRuntimeConfiguration,
            Launcher
        ) async throws -> Runtime

        let resolveVM: VMResolver
        let resolveExecutable: ExecutableResolver
        let issueCredential: CredentialIssuer
        let makeRequest: RequestBuilder
        let makeRuntime: RuntimeBuilder
        let stagingParent: @Sendable (VMReference) throws -> URL
        let stagingBuilder: PommeRecoveryStagingBuilder
        let recoveryProfileEvidence: @Sendable (VMReference) async throws -> PommeRecoveryProfileEvidence
        let persistentAgentSecret: @Sendable (VMReference) async throws -> String
        let now: @Sendable () -> Date
        let credentialLifetime: TimeInterval
        let authenticationTimeout: TimeInterval
        let credentialRegistry: PommeRecoveryCredentialRegistry
        /// Initial provisioning has no pre-existing APFS volume-group UUID;
        /// repair must provide the exact UUID recorded for the owned VM.
        let resolveInstallMode: @Sendable (VMReference, Data) throws -> InstallMode

        init(
            resolveVM: @escaping VMResolver,
            resolveExecutable: @escaping ExecutableResolver,
            makeRuntime: @escaping RuntimeBuilder,
            stagingParent: @escaping @Sendable (VMReference) throws -> URL,
            recoveryProfileEvidence: @escaping @Sendable (VMReference) async throws -> PommeRecoveryProfileEvidence,
            persistentAgentSecret: @escaping @Sendable (VMReference) async throws -> String,
            resolveInstallMode: @escaping @Sendable (VMReference, Data) throws -> InstallMode = { _, _ in .initial },
            issueCredential: @escaping CredentialIssuer = Dependencies.defaultIssueCredential,
            makeRequest: @escaping RequestBuilder = Dependencies.defaultMakeRequest,
            stagingBuilder: PommeRecoveryStagingBuilder = .init(),
            now: @escaping @Sendable () -> Date = Date.init,
            credentialLifetime: TimeInterval = 15 * 60,
            authenticationTimeout: TimeInterval = Constants.defaultRecoveryAgentTimeout,
            credentialRegistry: PommeRecoveryCredentialRegistry = .shared
        ) {
            self.resolveVM = resolveVM
            self.resolveExecutable = resolveExecutable
            self.makeRuntime = makeRuntime
            self.stagingParent = stagingParent
            self.stagingBuilder = stagingBuilder
            self.recoveryProfileEvidence = recoveryProfileEvidence
            self.persistentAgentSecret = persistentAgentSecret
            self.issueCredential = issueCredential
            self.makeRequest = makeRequest
            self.now = now
            self.credentialLifetime = credentialLifetime
            self.authenticationTimeout = authenticationTimeout
            self.credentialRegistry = credentialRegistry
            self.resolveInstallMode = resolveInstallMode
        }

        private static let defaultIssueCredential: CredentialIssuer = { input in
            try await PommeRecoveryCredentialIssuer.issue(
                lifetime: input.context.lifetime,
                now: input.context.issuedAt
            )
        }

        private static let defaultMakeRequest: RequestBuilder = { input in
            try .init(
                requestID: input.requestID,
                vmUUID: input.vmUUID,
                operation: input.operation,
                issuedAt: input.issuedAt,
                expiresAt: input.expiresAt,
                executableSHA256: input.executableSHA256,
                payloadSHA256: input.context.payloadSHA256,
                requestedFinalState: input.context.finalState,
                credential: input.credential
            )
        }
    }

    /// Creates a reusable production factory.  No VM is started and no guest
    /// connection is opened by this method.  All effectful work begins in an
    /// integration's per-invocation `execute` call.
    static func factory(dependencies: Dependencies) -> PommeRecoveryIntegrationFactory {
        .init { reference, operation in
            guard operation == .installAgent
                || operation.listenerPort == .operation
            else { throw Error.unsupportedOperation }
            return PommeRecoveryIntegration(
                adapter: LiveAdapter(
                    reference: reference,
                    operation: operation,
                    dependencies: dependencies
                )
            )
        }
    }

    /// Strict, request-specific Recovery Terminal launcher.  The command is
    /// safe to type through the reviewed Tahoe keyboard sequence; all
    /// credential material remains in the 0400 staged file and is never placed
    /// in the command or the process argument list.
    struct Launcher: Equatable, Sendable {
        let capabilityProbes: [PommeRecoveryVirtioFSCapabilityProbe]
        let command: String
        let script: String
        let completionMarker: String
        let tag: String
        let mountedPath: String
        let privateWorkspacePath: String
        let guestStagingPath: String
        let guestTokenPath: String
        let listenerPort: UInt32
        let expiresAt: Date
        let vmID: UUID
        let sessionID: UUID

        init(request: PommeRecoverySessionRequest) throws {
            let plan: PommeRecoveryVirtioFSTerminalPlan
            do { plan = try .init(request: request) }
            catch { throw Error.launcherRejected }
            guard PommeRecoveryTerminalCommand.isKeyboardSafe(plan.command),
                  PommeRecoveryTerminalCommand.isSafeMarker(plan.completionMarker),
                  !plan.script.contains(request.credentialSHA256)
            else { throw Error.launcherRejected }

            capabilityProbes = plan.capabilityProbes
            command = plan.command
            script = plan.script
            completionMarker = plan.completionMarker
            tag = plan.tag
            mountedPath = plan.mountedPath
            privateWorkspacePath = plan.privateWorkspacePath
            guestStagingPath = plan.guestStagingPath
            guestTokenPath = plan.guestTokenPath
            listenerPort = plan.listenerPort
            expiresAt = plan.expiresAt
            vmID = plan.vmID
            sessionID = plan.sessionID
        }
    }

    typealias PommeRecoveryLauncher = Launcher

    /// Composes VM startup and post-proof Terminal launch as distinct effects.
    /// The runtime root owns their ordering and the proof checks between them.
    static func runtimeEffects(
        base: PommeRecoveryRuntimeEffects,
        profile: PommeRecoveryProfileEvidence,
        launcher: Launcher,
        vmName: String,
        terminalPort: any PommeRecoveryTerminalPort,
        authenticationTimeout: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) -> PommeRecoveryRuntimeEffects {
        LiveAdapter.effects(
            base: base, profile: profile, launcher: launcher,
            vmName: vmName,
            terminalPort: terminalPort,
            authenticationTimeout: authenticationTimeout, now: now
        )
    }

    private struct LiveAdapter: PommeRecoveryOperationAdapter, Sendable {
        let reference: VMReference
        let operation: PommeRecoveryOperation
        let dependencies: Dependencies

        func execute(
            operation requestedOperation: PommeRecoveryOperation,
            payload: Data,
            finalState: VMFinalState
        ) async throws -> PommeRecoveryExecutionResult {
            guard requestedOperation == operation else { throw Error.requestBindingRejected }
            guard payload.count <= PommeAgentProtocol.maximumFrameBytes else {
                throw PommeAgentProtocol.Error.frameTooLarge
            }
            guard dependencies.credentialLifetime > 0,
                  dependencies.credentialLifetime <= 15 * 60,
                  dependencies.authenticationTimeout > 0,
                  dependencies.credentialLifetime
                    > dependencies.authenticationTimeout
                        + PommeLiveRecoveryIntegration.credentialAuthenticationReserve
            else { throw Error.invalidDependencies }
            let vmName = Self.loggingVMName(for: reference)
            PommeCore.log("Recovery bootstrap milestone: requestValidated.", vmName: vmName)

            let identity: VMIdentity
            let executable: ExecutableIdentity
            do {
                identity = try await dependencies.resolveVM(reference)
                executable = try await dependencies.resolveExecutable(reference, operation)
            } catch let error as Error {
                throw error
            } catch {
                throw Error.ownershipMismatch
            }
            guard identity.matches(reference),
                  executable.url.path == executable.url.standardizedFileURL.path,
                  PommeProvisioningDigest.isSHA256(executable.sha256)
            else { throw Error.ownershipMismatch }

            // All closed profile/install decisions are proven before issuing
            // credentials, creating staging, stopping the VM, or constructing
            // any auxiliary-storage-backed Virtualization object.
            let profile = try await dependencies.recoveryProfileEvidence(reference)
            switch operation {
            case .sip, .amfi:
                try PommeRecoverySecurityQualification.require(profile: profile)
            case .installAgent:
                break
            case .terminalSession:
                throw Error.unsupportedOperation
            }
            let installMode: InstallMode?
            if case .installAgent = operation {
                installMode = try dependencies.resolveInstallMode(reference, payload)
            } else {
                installMode = nil
            }
            PommeCore.log("Recovery bootstrap milestone: profileAccepted.", vmName: vmName)

            let issuedAt = dependencies.now()
            let context = try RequestContext(
                payload: payload,
                finalState: finalState,
                issuedAt: issuedAt,
                lifetime: dependencies.credentialLifetime
            )
            let credential: PommeRecoveryCredential
            do {
                credential = try await dependencies.issueCredential(
                    .init(reference: reference, identity: identity, operation: operation, context: context)
                )
            } catch let error as Error {
                throw error
            } catch {
                throw Error.credentialRejected
            }
            guard credential.expiresAt > issuedAt,
                  credential.expiresAt.timeIntervalSince(issuedAt) <= 15 * 60
            else { throw Error.credentialRejected }

            let requestID = Self.requestID(
                vmUUID: identity.ownership.uuid,
                operation: operation,
                context: context
            )
            let request = try dependencies.makeRequest(
                .init(
                    requestID: requestID,
                    vmUUID: identity.ownership.uuid,
                    operation: operation,
                    issuedAt: issuedAt,
                    expiresAt: credential.expiresAt,
                    executableSHA256: executable.sha256,
                    credential: credential,
                    context: context
                )
            )
            guard request.requestID == requestID,
                  request.vmUUID == identity.ownership.uuid,
                  request.operation == operation.wireName,
                  request.listenerPort == operation.listenerPort.rawValue,
                  request.issuedAt == issuedAt,
                  request.expiresAt == credential.expiresAt,
                  request.executableSHA256 == executable.sha256,
                  request.payloadSHA256 == context.payloadSHA256,
                  request.requestedFinalState == finalState.rawValue,
                  credential.matches(request: request)
            else { throw Error.requestBindingRejected }

            let launcher = try Launcher(request: request)
            let staging: PommeRecoveryStaging
            do {
                staging = try dependencies.stagingBuilder.build(
                    .init(
                        request: request,
                        signedExecutableURL: executable.url,
                        launcherScript: launcher.script,
                        credential: credential,
                        temporaryParentURL: try dependencies.stagingParent(reference)
                    )
                )
            } catch {
                throw Error.launcherRejected
            }
            PommeCore.log("Recovery bootstrap milestone: hostStagingPrepared.", vmName: vmName)

            var runtime: Runtime?
            var sessionOwnsRuntime = false
            do {
                let configuration = try PommeRecoveryRuntimeConfiguration(
                    request: request,
                    staging: staging,
                    bootMode: .recovery
                )
                runtime = try await dependencies.makeRuntime(
                    reference,
                    request,
                    configuration,
                    launcher
                )
                guard let runtime else { throw Error.runtimeRejected }
                guard runtime.verifySessionBinding(request) else {
                    throw Error.runtimeRejected
                }
                PommeCore.log("Recovery bootstrap milestone: runtimeConstructed.", vmName: vmName)
                let rootEffects = PommeLiveRecoveryIntegration.runtimeEffects(
                    base: runtime.effects,
                    profile: profile,
                    launcher: launcher,
                    vmName: vmName,
                    terminalPort: runtime.terminalPort,
                    authenticationTimeout: dependencies.authenticationTimeout,
                    now: dependencies.now
                )
                let root = try PommeRecoveryRuntimeRootPort(
                    configuration: configuration,
                    coordinator: runtime.coordinator,
                    effects: rootEffects,
                    authenticationTimeout: dependencies.authenticationTimeout
                )
                let guest = LiveGuestPort(
                    root: root,
                    reference: reference,
                    request: request,
                    operation: operation,
                    identity: identity,
                    executable: executable,
                    launcher: launcher,
                    finalState: finalState,
                    installMode: installMode,
                    clearHostStagingBeforeOperation: runtime.clearHostStagingBeforeOperation,
                    verifySessionBinding: runtime.verifySessionBinding,
                    persistentAgentSecret: dependencies.persistentAgentSecret
                )
                let session = try PommeRecoverySession(
                    request: request,
                    credential: credential,
                    root: root,
                    vm: runtime.vmPort,
                    guest: guest,
                    registry: dependencies.credentialRegistry,
                    now: dependencies.now
                )
                sessionOwnsRuntime = true
                PommeCore.log("Recovery bootstrap milestone: sessionStarting.", vmName: vmName)
                return try await PommeRecoverySessionAdapter(
                    session: session,
                    credential: credential
                ).execute(
                    operation: operation,
                    payload: payload,
                    finalState: finalState
                )
            } catch {
                // Once the session owns the runtime, `run` has already
                // attempted authoritative cleanup.  For construction failures
                // before session ownership, clean only this exact share and
                // staging root; unknown cleanup remains a terminal error.
                if !sessionOwnsRuntime, let runtime {
                    do {
                        let cleanup = try await runtime.effects.stopReapAndClean()
                        guard cleanup.isComplete else { throw Error.cleanupFailed }
                        try await runtime.restoreCapturedState()
                    } catch {
                        throw Error.cleanupFailed
                    }
                }
                do { try staging.removeHostArtifacts() }
                catch { throw Error.cleanupFailed }
                throw error
            }
        }

        fileprivate static func effects(
            base: PommeRecoveryRuntimeEffects,
            profile: PommeRecoveryProfileEvidence,
            launcher: Launcher,
            vmName: String,
            terminalPort: any PommeRecoveryTerminalPort,
            authenticationTimeout: TimeInterval,
            now: @escaping @Sendable () -> Date
        ) -> PommeRecoveryRuntimeEffects {
            let progressSink = PommeProgressContext.sink
            return .init(
                verifyVMIdentity: base.verifyVMIdentity,
                startRecovery: {
                    PommeCore.log("Recovery bootstrap milestone: runtimeStarting.", vmName: vmName)
                    progressSink?.step(vm: vmName, "Starting Recovery")
                    try await base.startRecovery()
                    PommeCore.log("Recovery bootstrap milestone: runtimeStarted.", vmName: vmName)
                },
                launchRecoveryAgent: {
                    // The root port proves the completed Recovery start, live
                    // runtime, VM identity, and exact share before this effect.
                    // No observation-driven input belongs in startRecovery.
                    PommeCore.log("Recovery bootstrap milestone: recoveryBootVerified.", vmName: vmName)
                    try await base.launchRecoveryAgent()
                    var interaction = try PommeTahoeRecoveryInteraction(evidence: profile)
                    let disposition = await interaction.driveToTerminalAndLaunch(
                        using: terminalPort,
                        capabilityProbes: launcher.capabilityProbes,
                        launcherCommand: launcher.command,
                        authorizeLauncherSubmission: {
                            guard launcher.expiresAt.timeIntervalSince(now())
                                >= authenticationTimeout
                                    + PommeLiveRecoveryIntegration.credentialAuthenticationReserve
                            else { throw Error.credentialRejected }
                        },
                        onMilestone: { milestone in
                            switch milestone {
                            case .navigationStarted:
                                progressSink?.step(vm: vmName, "Navigating Recovery UI")
                            case .terminalLaunching:
                                progressSink?.step(vm: vmName, "Launching Terminal")
                            case .terminalVerified:
                                progressSink?.step(vm: vmName, "Preparing Recovery agent")
                            case .launcherSubmitted:
                                progressSink?.step(vm: vmName, "Connecting to Recovery agent")
                            default: break
                            }
                            PommeCore.log(
                                "Recovery bootstrap milestone: \(milestone.rawValue).",
                                vmName: vmName
                            )
                        }
                    )
                    switch disposition {
                    case .terminalLauncherSubmitted:
                        break
                    case .observationTimedOut:
                        throw PommeRecoverySessionError.observationTimedOut
                    case .terminalProofFailed:
                        throw PommeRecoverySessionError.terminalProofFailed
                    case .noInputDelivered, .recoveryCleanupRequired:
                        throw Error.launcherRejected
                    }
                },
                verifyRecoveryBoot: base.verifyRecoveryBoot,
                helperIsAlive: base.helperIsAlive,
                verifyBootstrapAttachment: base.verifyBootstrapAttachment,
                stopReapAndClean: base.stopReapAndClean
            )
        }

        private static func loggingVMName(for reference: VMReference) -> String {
            if let name = reference.name, !name.isEmpty {
                return name
            }
            let bundleName = reference.bundle.rootURL
                .deletingPathExtension()
                .lastPathComponent
            return bundleName.isEmpty ? "unknown" : bundleName
        }

        private static func requestID(
            vmUUID: UUID,
            operation: PommeRecoveryOperation,
            context: RequestContext
        ) -> UUID {
            let material = [
                "PommeLiveRecoveryRequest/1",
                vmUUID.uuidString.lowercased(),
                operation.wireName,
                context.payloadSHA256,
                context.finalState.rawValue,
                String(Int64((context.issuedAt.timeIntervalSince1970 * 1_000_000).rounded()))
            ].joined(separator: "\u{1f}")
            let bytes = Array(SHA256.hash(data: Data(material.utf8)))
            let tuple: uuid_t = (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )
            return UUID(uuid: tuple)
        }
    }

    /// The only guest operation adapter created by the live composition.  It
    /// obtains the already-authenticated, VM/session-bound PommeAgent session
    /// from the Recovery root and permits exactly the request operation.
    private actor LiveGuestPort: PommeRecoveryGuestPort {
        let root: PommeRecoveryRuntimeRootPort
        let reference: VMReference
        let request: PommeRecoverySessionRequest
        let operation: PommeRecoveryOperation
        let identity: VMIdentity
        let executable: ExecutableIdentity
        let launcher: Launcher
        let finalState: VMFinalState
        let installMode: InstallMode?
        let clearHostStagingBeforeOperation: @Sendable () async throws -> Void
        let verifySessionBinding: @Sendable (PommeRecoverySessionRequest) -> Bool
        let persistentAgentSecret: @Sendable (VMReference) async throws -> String
        var session: (any PommeAgentSessionProtocol)?

        init(
            root: PommeRecoveryRuntimeRootPort,
            reference: VMReference,
            request: PommeRecoverySessionRequest,
            operation: PommeRecoveryOperation,
            identity: VMIdentity,
            executable: ExecutableIdentity,
            launcher: Launcher,
            finalState: VMFinalState,
            installMode: InstallMode?,
            clearHostStagingBeforeOperation: @escaping @Sendable () async throws -> Void,
            verifySessionBinding: @escaping @Sendable (PommeRecoverySessionRequest) -> Bool,
            persistentAgentSecret: @escaping @Sendable (VMReference) async throws -> String
        ) {
            self.root = root
            self.reference = reference
            self.request = request
            self.operation = operation
            self.identity = identity
            self.executable = executable
            self.launcher = launcher
            self.finalState = finalState
            self.installMode = installMode
            self.clearHostStagingBeforeOperation = clearHostStagingBeforeOperation
            self.verifySessionBinding = verifySessionBinding
            self.persistentAgentSecret = persistentAgentSecret
        }

        func perform(operation requestedOperation: String, requestID: UUID, payload: Data) async throws -> Data {
            guard requestedOperation == operation.wireName,
                  requestID == launcher.sessionID,
                  payload.count <= PommeAgentProtocol.maximumFrameBytes
            else { throw PommeRecoverySessionError.requestMismatch }
            let guestSession: any PommeAgentSessionProtocol
            do {
                guestSession = try root.authenticatedGuestSession()
            } catch {
                throw PommeRecoverySessionError.guestOperationFailed
            }
            session = guestSession
            guard verifySessionBinding(request) else {
                throw PommeRecoverySessionError.requestMismatch
            }

            let value: JSONValue
            if case .installAgent = operation {
                value = try await installPayload(from: payload, requestID: requestID)
            } else {
                value = try decodeBoundedJSON(payload)
            }
            // The host share and staging root are no longer needed once the
            // launcher has copied the fixed artifacts into the guest-private
            // workspace. Detach/remove them before invoking any privileged
            // Recovery operation. The Core hook is exact-request scoped.
            do {
                try await clearHostStagingBeforeOperation()
            } catch {
                throw PommeRecoverySessionError.cleanupFailed
            }
            do {
                let label: String
                switch operation {
                case .installAgent: label = "Bootstrapping Pomme agent for normal boot"
                case .terminalSession: label = "Preparing Recovery shell"
                case .sip(.status): label = "Checking SIP"
                case .sip(.disable): label = "Disabling SIP"
                case .sip(.enable): label = "Enabling SIP"
                case .amfi(.status): label = "Checking AMFI"
                case .amfi(.disable): label = "Disabling AMFI"
                case .amfi(.enable): label = "Enabling AMFI"
                }
                PommeProgressContext.sink?.step(vm: reference.displayName, label)
                let result = try await guestSession.perform(
                    operation: requestedOperation,
                    payload: value,
                    requestID: requestID
                )
                let encoded = try PommeProvisioningCoding.encode(result)
                guard encoded.count <= PommeAgentProtocol.maximumFrameBytes else {
                    throw PommeAgentProtocol.Error.frameTooLarge
                }
                return encoded
            } catch let error as PommeAgentSessionError {
                // Only the closed Recovery security vocabulary crosses this
                // boundary. Unknown agent codes retain the historical generic
                // failure and never expose the transport message.
                if let code = PommeRecoveryGuestFailureCode(rawValue: error.code) {
                    throw PommeRecoveryGuestOperationFailure(code: code)
                }
                throw PommeRecoverySessionError.guestOperationFailed
            } catch let error as PommeRecoverySessionError {
                throw error
            } catch {
                throw PommeRecoverySessionError.guestOperationFailed
            }
        }

        func close() async {
            if let session { await session.close() }
            session = nil
        }

        private func installPayload(from payload: Data, requestID: UUID) async throws -> JSONValue {
            try PommeLiveRecoveryIntegration.validateInstallPayload(
                payload,
                reference: reference,
                identity: identity,
                executable: executable,
                request: request,
                finalState: finalState,
                installMode: installMode
            )

            let token: String
            do { token = try await persistentAgentSecret(reference) }
            catch { throw PommeRecoverySessionError.guestOperationFailed }
            guard (try? PommeAgentAuthentication.normalized(token)) != nil else {
                throw PommeRecoverySessionError.guestOperationFailed
            }
            var result: [String: JSONValue] = [
                "persistentToken": .string(token),
                "requestID": .string(requestID.uuidString.lowercased()),
                "workspacePath": .string(launcher.privateWorkspacePath),
                "installMode": .string(installMode!.rawValue)
            ]
            if let targetVolumeGroupUUID = identity.targetVolumeGroupUUID {
                result["targetVolumeGroupUUID"] = .string(targetVolumeGroupUUID.uuidString.lowercased())
            }
            return .object(result)
        }

        private func decodeBoundedJSON(_ payload: Data) throws -> JSONValue {
            if payload.isEmpty { return .object([:]) }
            do { return try JSONDecoder().decode(JSONValue.self, from: payload) }
            catch { throw PommeRecoverySessionError.requestMismatch }
        }

    }

}
