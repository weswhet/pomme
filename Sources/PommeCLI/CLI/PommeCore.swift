import CryptoKit
import Darwin
import Foundation
import Security
@preconcurrency import Virtualization

private enum PommeLogContext {
    @TaskLocal static var sink: (@Sendable (String) -> Void)?
}

/// Closed diagnostics deliberately cannot accept any bootstrap data or errors.
struct PommeBootstrapDiagnostics {
    enum Operation: String, CaseIterable {
        case hostKeyScan, sshAuthenticationAndUIDVerification, stagingDirectoryPreparation
        case stagedAgentVerification, stagedManifestVerification
        case agentArtifactTransfer, requestManifestTransfer, installerInvocation
    }

    enum Outcome: String, CaseIterable {
        case started, succeeded, launchFailed, timedOut, exited, channelFailed
    }

    /// Only closed labels and the configured deadline are accepted here. In
    /// particular, subprocess errors and output must never reach this formatter.
    static func process(_ operation: Operation, outcome: Outcome, timeout: TimeInterval) -> String {
        "bootstrap process operation=\(operation.rawValue) outcome=\(outcome.rawValue) timeoutSeconds=\(timeout)"
    }

    enum Stage: String, CaseIterable {
        case started, journalValidated, ownerReferenceVerified, dispatchMarkerVerified
        case agentCredentialAvailable, runtimeRecordAbsent, runtimeStartAttempted, runtimeStartSucceeded
        case workspaceVerified, discoveryStarted, keyPinned, sshUIDVerified
        case discoveryCandidateSelected, discoveryKeyscanSucceeded, discoveryLeaseVerified
        case requestVerified, stagingVerified, installerInvoked, agentConnected
    }

    private(set) var stage: Stage = .started
    private var hostKeyScanReported = false
    private var discoveryCandidateReported = false

    mutating func discoveryCandidateCheckpoint() -> String? {
        let message = checkpoint(.discoveryCandidateSelected)
        guard !discoveryCandidateReported else { return nil }
        discoveryCandidateReported = true
        return message
    }

    /// Discovery retries can run for minutes; report subprocess detail only
    /// for the first attempt while discovery checkpoints record eventual success.
    mutating func nextHostKeyScanOperation() -> Operation? {
        guard !hostKeyScanReported else { return nil }
        hostKeyScanReported = true
        return .hostKeyScan
    }

    mutating func checkpoint(_ stage: Stage) -> String {
        self.stage = stage
        return "bootstrap checkpoint stage=\(stage.rawValue)"
    }

    func failure() -> String { "bootstrap failed stage=\(stage.rawValue)" }
}

private enum PommeProvisioningCredentialReference {
    /// This account is intentionally fixed. The VM UUID is the Keychain
    /// service scope, so callers cannot select an arbitrary credential.
    static let agentAccount = "agent-token"
}

/// Inputs which are safe to persist next to a provisioning journal. The
/// journal itself deliberately contains neither credentials nor mutable
/// transport configuration; this companion record retains only a fixed
/// non-secret Keychain account reference for a resumed operation.
struct PommeProvisioningInput: Codable, Sendable {
    static let schema = 1

    let schema: Int
    let restoreImagePath: String
    let memorySizeBytes: UInt64
    let diskSizeBytes: UInt64
    let hardwareModelData: Data
    let machineIdentifierData: Data
    let agentCredentialAccount: String
    /// The APFS startup volume-group identity is discovered in Recovery. It
    /// is optional during initial planning and is persisted only in the
    /// companion input/metadata records, never in the signed journal or plan.
    let startupVolumeGroupUUID: UUID?
    /// When set, the install phase clones this template bundle's disk,
    /// auxiliary storage, and hardware model instead of restoring
    /// `restoreImagePath` (which then records the image the template came
    /// from). Absent in inputs written before templates existed.
    let templateBundlePath: String?

    init(
        restoreImagePath: String,
        memorySizeBytes: UInt64,
        diskSizeBytes: UInt64,
        hardwareModelData: Data,
        machineIdentifierData: Data,
        agentCredentialAccount: String = PommeProvisioningCredentialReference.agentAccount,
        startupVolumeGroupUUID: UUID? = nil,
        templateBundlePath: String? = nil
    ) {
        schema = Self.schema
        self.restoreImagePath = restoreImagePath
        self.memorySizeBytes = memorySizeBytes
        self.diskSizeBytes = diskSizeBytes
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.agentCredentialAccount = agentCredentialAccount
        self.startupVolumeGroupUUID = startupVolumeGroupUUID
        self.templateBundlePath = templateBundlePath
    }

    func validate(for plan: PommeProvisioningPlan) throws {
        if let templateBundlePath {
            guard !templateBundlePath.isEmpty,
                  URL(fileURLWithPath: templateBundlePath).standardizedFileURL.path == templateBundlePath
            else { throw PommeProvisioningError.invalidPlan }
        }
        guard schema == Self.schema,
              URL(fileURLWithPath: restoreImagePath).standardizedFileURL.path == restoreImagePath,
              !restoreImagePath.isEmpty,
              memorySizeBytes > 0,
              diskSizeBytes > 0,
              hardwareModelData.isEmpty == false,
              machineIdentifierData.isEmpty == false,
              agentCredentialAccount == PommeProvisioningCredentialReference.agentAccount,
              plan.vm.bundlePath.hasPrefix("/")
        else { throw PommeProvisioningError.invalidPlan }
    }

    func settingStartupVolumeGroupUUID(_ value: UUID?) -> Self {
        .init(
            restoreImagePath: restoreImagePath,
            memorySizeBytes: memorySizeBytes,
            diskSizeBytes: diskSizeBytes,
            hardwareModelData: hardwareModelData,
            machineIdentifierData: machineIdentifierData,
            agentCredentialAccount: agentCredentialAccount,
            startupVolumeGroupUUID: value
        )
    }
}

/// A local restore image identity that is safe to expose during direct-create
/// planning. The Virtualization objects used to read it remain private to the
/// provisioning implementation.
struct PommeLocalRestoreImageIdentity: Equatable, Sendable {
    let canonicalPath: String
    let version: String
    let build: String
    let recoveryProfile: PommeCreateRecoveryProfileDescriptor
    /// The guest minimum the image itself reports, so a dry run can apply
    /// the same memory check as the real create.
    let minimumMemoryBytes: UInt64
}

/// Non-secret identity exposed to the request-bound Recovery factory. The
/// durable VM UUID comes from the immutable provisioning plan; the APFS group
/// is optional until Recovery has observed and recorded it.
struct PommeProvisioningRuntimeMetadata: Codable, Equatable, Sendable {
    let vmUUID: UUID
    let startupVolumeGroupUUID: UUID?
}

struct PommeFrameworkProvisionedOwnerContext: Sendable {
    let credentialReference: PommeOwnerCredentialReference
    let generatedUID: UUID
    let startupVolumeGroupUUID: UUID
}

struct PommeProvisioningDispatchMarker: Codable, Equatable, Sendable {
    let vmUUID: UUID
    let planDigest: String
    let attempt: UInt64
}

private final class PommeRetainedRuntime: @unchecked Sendable {
    let runtime: PommeVMRuntime
    let coordinator: PommeAgentVSOCKCoordinator?
    let mode: BootMode

    init(runtime: PommeVMRuntime, coordinator: PommeAgentVSOCKCoordinator?, mode: BootMode) {
        self.runtime = runtime
        self.coordinator = coordinator
        self.mode = mode
    }

    func stop() async throws {
        do {
            try await runtime.stop()
        } catch {
            coordinator?.teardown()
            await runtime.teardown()
            throw error
        }
        coordinator?.teardown()
        await runtime.teardown()
        guard runtime.terminalCleanupIsVerified() else {
            throw RunnerError.virtualMachineState("Recovery terminal cleanup could not be proven complete.")
        }
    }
}

/// Owns the exact in-process Recovery VM and request staging resources.  The
/// value is unchecked-Sendable because every Virtualization access is
/// confined to `queue`; callers receive only closed proof methods.
private final class PommeLiveRecoveryRuntimeResources: @unchecked Sendable {
    let vm: VZVirtualMachine
    let configuration: VZVirtualMachineConfiguration
    let queue: DispatchQueue
    let runtime: PommeVMRuntime
    let coordinator: PommeAgentVSOCKCoordinator
    let staging: PommeRecoveryStaging
    let request: PommeRecoverySessionRequest
    let sensitiveFramesCleared: @Sendable () async -> Bool

    init(
        vm: VZVirtualMachine,
        configuration: VZVirtualMachineConfiguration,
        queue: DispatchQueue,
        runtime: PommeVMRuntime,
        coordinator: PommeAgentVSOCKCoordinator,
        staging: PommeRecoveryStaging,
        request: PommeRecoverySessionRequest,
        sensitiveFramesCleared: @escaping @Sendable () async -> Bool
    ) {
        self.vm = vm
        self.configuration = configuration
        self.queue = queue
        self.runtime = runtime
        self.coordinator = coordinator
        self.staging = staging
        self.request = request
        self.sensitiveFramesCleared = sensitiveFramesCleared
    }

    func isRunningRecovery() -> Bool {
        runtime.provesRunningRecoveryBoot()
    }

    func hasExactBootstrapAttachment() -> Bool {
        queue.sync {
            let matches = vm.directorySharingDevices
                .compactMap { $0 as? VZVirtioFileSystemDevice }
                .filter { $0.tag == PommeRecoveryStagingBuilder.tag(for: request) }
            return matches.count == 1 && matches[0].share != nil
        }
    }

    func clearHostStaging() throws {
        try staging.clearShare(from: vm, on: queue)
        try staging.removeHostArtifacts()
    }

    func stopReapAndClean() async throws -> PommeRecoveryRuntimeCleanup {
        coordinator.teardown()

        var firstError: Error?
        do { try await runtime.stop() }
        catch { firstError = error }

        let stopped = queue.sync { vm.state == .stopped }
        var shareDetached = false
        do {
            try staging.clearShare(from: vm, on: queue)
            shareDetached = true
        } catch {
            if firstError == nil { firstError = error }
        }

        var stagingRemoved = false
        do {
            try staging.removeHostArtifacts()
            stagingRemoved = true
        } catch {
            if firstError == nil { firstError = error }
        }

        if let firstError { throw firstError }
        return .init(
            shareDetached: shareDetached,
            helperStoppedAndReaped: stopped,
            stagingArtifactsRemoved: stagingRemoved,
            sensitiveFramesCleared: await sensitiveFramesCleared(),
            unknownStateRejected: stopped && shareDetached && stagingRemoved
        )
    }
}

/// Captures and stops the pre-operation VM exactly once, then delegates only
/// the requested final-state transition.  `PommeRecoverySession` resolves
/// `.previous` before calling this port and remains the sole policy owner.
private actor PommeLiveRecoveryVMStatePort: PommeRecoveryVMPort {
    typealias Capture = @Sendable () async throws -> PommeRecoveryRunState
    typealias Request = @Sendable (VMFinalState, PommeRecoveryRunState) async throws -> Void
    typealias Prove = @Sendable (VMFinalState, PommeRecoveryRunState) async throws -> Bool

    private let captureEffect: Capture
    private let requestEffect: Request
    private let proveEffect: Prove
    private var captured: PommeRecoveryRunState?

    init(
        capture: @escaping Capture,
        request: @escaping Request,
        prove: @escaping Prove
    ) {
        captureEffect = capture
        requestEffect = request
        proveEffect = prove
    }

    func captureState() async throws -> PommeRecoveryRunState {
        guard captured == nil else { throw PommeRecoverySessionError.invalidLifecycle }
        let state = try await captureEffect()
        captured = state
        return state
    }

    func requestFinalState(_ state: VMFinalState) async throws {
        guard state != .previous, let captured else {
            throw PommeRecoverySessionError.finalStateUnverified
        }
        try await requestEffect(state, captured)
    }

    func proveFinalState(_ state: VMFinalState) async throws -> Bool {
        guard state != .previous, let captured else {
            throw PommeRecoverySessionError.finalStateUnverified
        }
        return try await proveEffect(state, captured)
    }
}

/// Small host-side primitives shared by the command layer and the VM runtime.
/// The command tree owns policy; this type only performs bounded, typed work
/// and reports unavailable integrations without mutating a VM implicitly.
struct PommeCore {
    /// Minimum persistent-agent operations required before a provisioned VM
    /// may be considered usable. Recovery installation and normal-boot
    /// verification intentionally share this exact policy.
    static let requiredProvisioningAgentCapabilities: Set<String> = [
        "process.start",
        "file.open",
        "mdm.enrollment",
        "maintenance"
    ]

    static func supportsProvisioningAgentCapabilities(_ capabilities: [String]) -> Bool {
        Set(capabilities).isSuperset(of: requiredProvisioningAgentCapabilities)
    }

    private static let provisioningEffectsLock = NSLock()
    nonisolated(unsafe) private static var installedProvisioningEffects: PommeProvisioningEffects?
    nonisolated(unsafe) private static var installedProvisioningV2Effects: PommeProvisioningV2Effects?
    private static let provisioningRecoveryAdapterLock = NSLock()
    nonisolated(unsafe) private static var provisioningRecoveryAdapter: (@Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String)?
    private static let retainedRuntimeLock = NSLock()
    nonisolated(unsafe) private static var retainedRuntimes: [String: PommeRetainedRuntime] = [:]

    /// Replace only the external effects.  Planning, journal ordering,
    /// ownership checks, and failure retention remain Core-owned.  Tests and
    /// a host-specific Virtualization adapter can inject deterministic effects
    /// without changing the public command contract.
    static func installProvisioningEffects(_ effects: PommeProvisioningEffects) {
        provisioningEffectsLock.lock()
        installedProvisioningEffects = effects
        provisioningEffectsLock.unlock()
    }

    static func installProvisioningV2Effects(_ effects: PommeProvisioningV2Effects?) {
        provisioningEffectsLock.withLock { installedProvisioningV2Effects = effects }
    }

    static func usesVirtualizationProvisioning(
        guestVersion: String, firstBootEligible: Bool, hostMajor: Int,
        apiAvailable: Bool
    ) -> Bool {
        firstBootEligible && apiAvailable && hostMajor >= 27
            && PommeProvisioningV2RouteSelector.select(
                hostSupportsProvisioning: true, guestVersion: guestVersion) == .virtualization
    }

    static func usesVirtualizationProvisioning(guestVersion: String, firstBootEligible: Bool) -> Bool {
        guard #available(macOS 27, *) else { return false }
        return usesVirtualizationProvisioning(guestVersion: guestVersion,
            firstBootEligible: firstBootEligible,
            hostMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, apiAvailable: true)
    }

    static func provisioningDisclosure(virtualization: Bool) -> [String: String] {
        var fields = ["guestProvisioning": virtualization ? "virtualization" : "recovery",
                      "agentInstallMethod": virtualization ? "ssh-bootstrap" : "recovery",
                      "automaticLogin": virtualization ? "enabled" : "legacy",
                      "remoteLogin": virtualization ? "off" : "legacy"]
        if virtualization { fields["account"] = "pomme" }
        return fields
    }

    /// Runtime disclosure describes proven state, unlike dry-run output which
    /// describes the requested final state. A provision intent is not a proof.
    static func provisioningDisclosure(journal: PommeProvisioningV2Journal) -> [String: String] {
        var fields = provisioningDisclosure(virtualization: true)
        if !journal.events.contains(where: { $0.phase == .verifyNormalAgent && $0.kind == .receipt }) {
            fields["automaticLogin"] = "pending"
            fields["remoteLogin"] = "unknown"
        }
        return fields
    }

    private static func provisioningDisclosure(bundle: BundleLayout) throws -> [String: String] {
        guard try provisioningSchemaIfPresent(bundle: bundle) == 2 else {
            return provisioningDisclosure(virtualization: false)
        }
        return try provisioningDisclosure(journal: loadProvisioningV2(reference: .init(name: nil, bundle: bundle)))
    }

    private static func discloseProvisioningState(_ payload: inout [String: Any], bundle: BundleLayout) throws {
        let fields = try provisioningDisclosure(bundle: bundle)
        payload.merge(fields) { _, new in new }
        if var metadata = payload["metadata"] as? [String: Any] {
            metadata.merge(fields) { _, new in new }
            payload["metadata"] = metadata
        }
    }

    /// Returns the immutable VM identity and the optional APFS startup
    /// volume-group identity recorded by a Recovery integration. The helper
    /// deliberately reads only public metadata; credentials remain confined
    /// to the private provisioning-input companion file.
    static func provisioningRuntimeMetadata(
        for plan: PommeProvisioningPlan
    ) throws -> PommeProvisioningRuntimeMetadata {
        try plan.validate()
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        guard bundle.rootURL.standardizedFileURL.path == plan.vm.bundlePath else {
            throw PommeProvisioningError.ownershipMismatch
        }
        let metadata = try metadataPayload(bundle: bundle)
        guard let rawVMUUID = metadata[Constants.vmUUIDMetadataKey] as? String,
              let metadataVMUUID = UUID(uuidString: rawVMUUID),
              metadataVMUUID == plan.vm.uuid,
              rawVMUUID.lowercased() == plan.vm.uuid.uuidString.lowercased()
        else { throw PommeProvisioningError.ownershipMismatch }

        let startupVolumeGroupUUID: UUID?
        if let rawGroup = metadata["startupVolumeGroupUUID"] {
            guard let value = rawGroup as? String,
                  let group = UUID(uuidString: value),
                  value.lowercased() == group.uuidString.lowercased()
            else { throw PommeProvisioningError.invalidPlan }
            startupVolumeGroupUUID = group
        } else {
            startupVolumeGroupUUID = nil
        }
        return .init(vmUUID: plan.vm.uuid, startupVolumeGroupUUID: startupVolumeGroupUUID)
    }

    /// Persist a Recovery-observed APFS startup volume-group identity without
    /// changing the immutable plan or signed journal. Repeating the same
    /// observation is idempotent; a different identity is an ownership error.
    static func persistProvisioningStartupVolumeGroup(
        _ volumeGroupUUID: UUID,
        for plan: PommeProvisioningPlan
    ) throws {
        let current = try provisioningRuntimeMetadata(for: plan)
        if let existing = current.startupVolumeGroupUUID {
            guard existing == volumeGroupUUID else { throw PommeProvisioningError.ownershipMismatch }
            return
        }
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        var metadata = try metadataPayload(bundle: bundle)
        metadata["startupVolumeGroupUUID"] = volumeGroupUUID.uuidString.lowercased()
        try writeMetadataPayload(metadata, bundle: bundle)
    }

    /// Installs the request-bound Recovery adapter used by the two provisioning
    /// phases that must run outside normal macOS.  The closure is deliberately
    /// typed to the immutable plan and final state; it cannot select a
    /// different VM, role, or transport.  Until the host supplies this adapter
    /// those phases fail closed after their journal intent is committed.
    static func installProvisioningRecoveryAdapter(
        _ adapter: (@Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String)?
    ) {
        provisioningRecoveryAdapterLock.lock()
        provisioningRecoveryAdapter = adapter
        provisioningRecoveryAdapterLock.unlock()
    }

    private static func currentProvisioningRecoveryAdapter() -> (@Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String)? {
        provisioningRecoveryAdapterLock.lock()
        defer { provisioningRecoveryAdapterLock.unlock() }
        return provisioningRecoveryAdapter
    }

    /// Production composition for every request-bound Recovery operation.
    /// Constructing the factory is side-effect free; VM state, credentials,
    /// staging, and Virtualization objects are resolved afresh for one exact
    /// invocation only after the command layer has acquired the VM lease.
    static func makeLiveRecoveryIntegrationFactory() -> PommeRecoveryIntegrationFactory {
        PommeLiveRecoveryIntegration.factory(
            dependencies: .init(
                resolveVM: { reference in
                    let plan = try loadOwnedProvisioningPlan(reference: reference)
                    let metadata = try provisioningRuntimeMetadata(for: plan)
                    return try .init(
                        ownership: plan.vm,
                        targetVolumeGroupUUID: metadata.startupVolumeGroupUUID
                    )
                },
                resolveExecutable: { reference, operation in
                    let identity = try runningExecutableIdentity()
                    if operation == .installAgent {
                        let plan = try loadOwnedProvisioningPlan(reference: reference)
                        let digest = plan.recoveryAgent.executableDigest
                        guard plan.normalAgent.executableDigest == digest else {
                            throw PommeLiveRecoveryIntegration.Error.executableMismatch
                        }
                        if identity.sha256 != digest {
                            let store = PommeAgentArtifactStore(rootURL:
                                try applicationSupportRoot(create: false)
                            )
                            return try .init(url: store.resolve(sha256: digest), sha256: digest)
                        }
                    }
                    return try .init(url: identity.url, sha256: identity.sha256)
                },
                makeRuntime: { reference, request, recoveryConfiguration, launcher in
                    try await makeLiveRecoveryRuntime(
                        reference: reference,
                        request: request,
                        recoveryConfiguration: recoveryConfiguration,
                        launcher: launcher
                    )
                },
                stagingParent: { _ in try liveRecoveryStagingParent() },
                recoveryProfileEvidence: { reference in
                    try await liveRecoveryProfileEvidence(reference: reference)
                },
                persistentAgentSecret: { reference in
                    let plan = try loadOwnedProvisioningPlan(reference: reference)
                    return try existingProvisioningAgentCredential(for: plan)
                },
                resolveInstallMode: { reference, payload in
                    let requested = try JSONDecoder().decode(PommeProvisioningPlan.self, from: payload)
                    let installed = try loadOwnedProvisioningPlan(reference: reference)
                    guard requested == installed else {
                        throw PommeLiveRecoveryIntegration.Error.ownershipMismatch
                    }
                    return try provisioningRuntimeMetadata(for: installed).startupVolumeGroupUUID == nil
                        ? .initial
                        : .repair
                }
            )
        )
    }

    /// Security preparation consumes the immutable creation record without
    /// changing it or replacing the persistent agent it pins.
    static func securityProvisioningPlan(reference: VMReference) throws -> PommeProvisioningPlan {
        let plan = try loadOwnedProvisioningPlan(reference: reference)
        if try provisioningSchema(bundle: reference.bundle) == 2 {
            let journal = try loadProvisioningV2(reference: reference)
            guard journal.plan == plan, journal.events.last?.kind == .receipt,
                  journal.events.last?.phase == .restoreFinalState else {
                throw PommeProvisioningV2Error.invalidJournal
            }
            return plan
        }
        let key = try Data(contentsOf: provisioningKeyURL(bundle: reference.bundle))
        let journal = try provisioningRepository(
            bundleURL: reference.bundle.rootURL,
            signer: PommeProvisioningJournalSigner(key: key)
        ).load()
        guard journal.plan == plan,
              journal.events.last?.kind == .receipt,
              journal.events.last?.phase == .restoreFinalState else {
            throw RunnerError.hostCommandFailed(
                "Complete the retained Pomme creation transaction with `pomme create NAME --resume` before changing security."
            )
        }
        return plan
    }

    /// Classifies the creation transaction for planning. Unlike the loaders
    /// used to run it, this never creates a journal key or advances a
    /// generation high-water mark.
    static func provisioningReadiness(reference: VMReference) -> PommeProvisioningReadiness {
        let bundle = reference.bundle
        let schema: Int?
        do { schema = try provisioningSchemaIfPresent(bundle: bundle) }
        catch { return .blocked(schema: nil, reason: .invalidJournal) }
        guard let schema else { return .blocked(schema: nil, reason: .unmanaged) }
        let keyURL = provisioningKeyURL(bundle: bundle)
        guard isRegularFile(keyURL) else { return .blocked(schema: schema, reason: .invalidJournal) }
        do {
            if schema == 2 {
                let key = try PommeSSHBootstrap.privateRead(keyURL, owner: geteuid(), allowedModes: [0o600])
                let journal = try provisioningV2Repository(bundle: bundle, key: key).inspect()
                guard journal.plan.vm.bundlePath == reference.standardizedPath,
                      reference.name == nil || journal.plan.vm.name == reference.name else {
                    return .blocked(schema: 2, reason: .invalidJournal)
                }
                return PommeProvisioningReadinessClassifier.classify(v2: journal) {
                    try provisioningWasDispatched(plan: journal.plan)
                }
            }
            let key = try Data(contentsOf: keyURL, options: .mappedIfSafe)
            guard key.count >= 32 else { return .blocked(schema: 1, reason: .invalidJournal) }
            let journal = try provisioningRepository(bundleURL: bundle.rootURL,
                signer: PommeProvisioningJournalSigner(key: key)).load()
            guard journal.plan.vm.bundlePath == reference.standardizedPath,
                  reference.name == nil || journal.plan.vm.name == reference.name else {
                return .blocked(schema: 1, reason: .invalidJournal)
            }
            return PommeProvisioningReadinessClassifier.classify(v1: journal)
        } catch {
            return .blocked(schema: schema, reason: .invalidJournal)
        }
    }

    static func expectedProvisionedAgentDigest(reference: VMReference) throws -> String {
        try loadOwnedProvisioningPlan(reference: reference).normalAgent.executableDigest
    }

    static func frameworkProvisionedOwner(reference: VMReference) throws -> PommeFrameworkProvisionedOwnerContext? {
        guard try provisioningSchemaIfPresent(bundle: reference.bundle) == 2 else { return nil }
        let plan = try securityProvisioningPlan(reference: reference)
        let journal = try loadProvisioningV2(reference: reference)
        guard let owner = journal.ownerReference, let generatedUID = owner.generatedUID,
              let group = journal.startupVolumeGroupUUID,
              try provisioningRuntimeMetadata(for: plan).startupVolumeGroupUUID == group else {
            throw PommeProvisioningV2Error.ownershipMismatch
        }
        try validateProvisioningOwnerReference(owner, plan: plan)
        return .init(credentialReference: owner, generatedUID: generatedUID, startupVolumeGroupUUID: group)
    }

    /// Runs one owner-preparation command through the running normal VM helper.
    /// The helper captures an authenticated coordinator pin before
    /// `agent.describe` and reuses it for process start, status, stream, and
    /// cleanup. The password travels only as a post-prompt control-stream
    /// frame; it is never included in the process-start payload.
    static func runSecurityPrivatePTY(
        reference: VMReference,
        expectedExecutableDigest: String,
        command: PommeSecurityOwnerPTYCommand,
        password: String,
        provisioningVerification: Bool = false
    ) async throws -> Int32 {
        guard PommeProvisioningDigest.isSHA256(expectedExecutableDigest),
              expectedExecutableDigest == expectedExecutableDigest.lowercased()
        else { throw PommeSecurityWorkflowError.agentUnverified }

        guard !password.isEmpty else { throw PommePrivatePTYRunner.Error.invalidSecret }
        let plan: PommeProvisioningPlan
        if provisioningVerification {
            let journal = try loadProvisioningV2(reference: reference)
            guard journal.events.last?.phase == .verifyNormalAgent,
                  journal.events.last?.kind == .intent else { throw PommeProvisioningV2Error.invalidJournal }
            plan = try loadOwnedProvisioningPlan(reference: reference)
        } else {
            plan = try securityProvisioningPlan(reference: reference)
        }
        guard plan.normalAgent.protocolVersion == PommeAgentProtocol.version,
              plan.normalAgent.executableDigest == expectedExecutableDigest,
              try stableVMRunState(reference: reference) == .running(.normal)
        else { throw PommeSecurityWorkflowError.agentUnverified }

        let runnerCommand = PommePrivatePTYRunner.Command(
            path: command.executable,
            arguments: command.arguments
        )
        guard var payload = runnerCommand.startPayload.objectValue else {
            throw PommePrivatePTYRunner.Error.invalidCommand
        }
        // These host-only fields are stripped by the helper before the guest
        // process.start request. They carry no credential material.
        payload[privatePTYMarker] = .bool(true)
        payload[privatePTYDigestMarker] = .string(expectedExecutableDigest)
        let controlPayload = PommeControlRequest(
            command: "agent.perform",
            payload: .object([
                "operation": .string("process.start"),
                "payload": .object(payload)
            ]),
            streaming: true
        )
        let record = try runtimeRecord(for: reference.bundle)
        let identity = PommeRuntimeIdentity(
            socketPath: record.socketPath,
            pid: record.pid,
            startedAt: record.startedAt
        )
        let stream = try PommeControlSocketClient(identity: identity).openStream(controlPayload)
        var secret = Data(password.utf8)
        defer {
            secret.resetBytes(in: 0..<secret.count)
        }

        let prompt = privatePTYPrompt(for: command)
        var promptTranscript = Data()
        // sysadminctl can refuse automatic login while returning status zero.
        // Keep its bounded output private and expose only closed refusal codes
        // after verified completion; never forward a native transcript to logs.
        let inspectAutologin = runnerCommand.autologinOwner != nil
        var autologinTranscript = Data()
        defer { autologinTranscript.resetBytes(in: 0..<autologinTranscript.count) }
        var promptSatisfied = false
        var inputClosed = false
        let deadline = Date().addingTimeInterval(PommePrivatePTYRunner.defaultProcessTimeout + 15)
        do {
            while Date() < deadline {
                let remaining = max(0.001, deadline.timeIntervalSinceNow)
                switch try stream.receiveEvent(timeout: remaining) {
                case .stream(let frame):
                    switch frame.stream {
                    case .stdout, .stderr:
                        let data = try frame.decodedData() ?? Data()
                        if inspectAutologin {
                            guard autologinTranscript.count + data.count <= PommePrivatePTYRunner.maximumBufferedOutputBytes else {
                                throw PommePrivatePTYRunner.Error.promptOutputLimit
                            }
                            autologinTranscript.append(data)
                        }
                        guard !promptSatisfied else { continue }
                        guard promptTranscript.count + data.count <= PommePrivatePTYRunner.maximumPromptTranscriptBytes else {
                            throw PommePrivatePTYRunner.Error.promptOutputLimit
                        }
                        promptTranscript.append(data)
                        switch prompt.observe(promptTranscript) {
                        case .unsafe:
                            throw PommePrivatePTYRunner.Error.unsafePrompt
                        case .password:
                            promptSatisfied = true
                            // The helper runner appends the terminal newline
                            // only after validating this raw secret. Sending
                            // it here would make the provider receive a
                            // newline-bearing value and fail closed.
                            try stream.send(stream: .stdin, data: secret)
                            try stream.closeInput()
                            inputClosed = true
                        case .none:
                            break
                        }
                    case .progress:
                        // The helper reports exit as progress before its
                        // terminal response. Keep reading so the terminal
                        // response remains the completion proof.
                        continue
                    case .stdin, .resize, .signal, .cancellation:
                        throw PommePrivatePTYRunner.Error.invalidCompletion
                    }
                case .response(let response):
                    if let envelope = response.result?.objectValue, envelope["ok"] == .bool(false) {
                        throw PommeSecurityPrivatePTYDiagnostic.decode(envelope["failureCode"])
                    }
                    guard response.ok,
                          let envelope = response.result?.objectValue,
                          envelope["ok"] != .bool(false),
                          let values = envelope["result"]?.objectValue,
                          values["exited"] == .bool(true),
                          values["outputComplete"] == .bool(true),
                          values["promptSatisfied"] == .bool(true),
                          values["stdoutTruncated"] != .bool(true),
                          values["stderrTruncated"] != .bool(true)
                    else { throw PommePrivatePTYRunner.Error.invalidCompletion }
                    if case .integer(let code)? = values["exitCode"], (0...255).contains(code), values["signal"] == nil,
                       let code = Int32(exactly: code) {
                        if inspectAutologin,
                           let refusal = PommeSecurityOwnerAutologinRefusal.classify(autologinTranscript) {
                            throw PommeSecurityOwnerPreparationError.autoLoginRefused(refusal)
                        }
                        if inspectAutologin, code == 0,
                           case .integer(let processID)? = values["pid"], processID > 0,
                           let refusal = try? PommeSecurityNormalAgent(
                            reference: reference, expectedExecutableDigest: expectedExecutableDigest
                           ).autologinSessionRefusal(processID: processID) {
                            throw PommeSecurityOwnerPreparationError.autoLoginRefused(refusal)
                        }
                        return code
                    }
                    if case .integer(let signal)? = values["signal"], (1...127).contains(signal), values["exitCode"] == nil,
                       let signal = Int32(exactly: signal) {
                        return 128 + signal
                    }
                    throw PommePrivatePTYRunner.Error.invalidCompletion
                }
            }
            throw PommePrivatePTYRunner.Error.processTimedOut
        } catch {
            if !(error is PommeSecurityOwnerPreparationError) {
                warning(
                    "Private owner PTY failed: \(PommeSecurityPrivatePTYDiagnostic(error).rawValue).",
                    vmName: reference.displayName
                )
            }
            if !inputClosed {
                try? stream.send(stream: .cancellation)
                try? stream.closeInput()
            }
            throw error
        }
    }

    private static let privatePTYMarker = "_pommeSecurityPrivatePTY"
    private static let privatePTYDigestMarker = "_pommeExpectedExecutableSHA256"

    private static func privatePTYPrompt(for command: PommeSecurityOwnerPTYCommand) -> PommePrivatePTYRunner.Prompt {
        if let owner = PommePrivatePTYRunner.Command(
            path: command.executable, arguments: command.arguments
        ).autologinOwner {
            return .sysadminctlPassword(for: owner)
        }
        guard command.executable == "/usr/sbin/sysadminctl" else { return .sysadminctlPassword }
        return .sysadminctlPassword(for: sysadminctlOwner(in: command.arguments) ?? "")
    }

    /// Extracts the owner named by the closed sysadminctl command forms used
    /// by owner preparation. Unknown forms intentionally produce no marker,
    /// causing the PTY runner to refuse any password prompt.
    private static func sysadminctlOwner(in arguments: [String]) -> String? {
        for flag in ["-addUser", "-secureTokenOn", "-userName"] {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { continue }
            return arguments[index + 1]
        }
        return nil
    }

    static func stableVMRunState(reference: VMReference) throws -> VMRunStateSnapshot {
        switch try liveRecoveryRunState(from: vmStatusPayload(reference: reference)) {
        case .stopped: return .stopped
        case .running(let mode): return .running(mode)
        case .paused(let mode): return .paused(previousBootMode: mode)
        }
    }

    static func restoreStableVMRunState(
        _ desired: VMRunStateSnapshot,
        reference: VMReference
    ) async throws {
        // A restore that is already satisfied changes nothing, so it must not
        // replace the label of the step that called it.
        if (try? stableVMRunState(reference: reference)) != desired {
            PommeProgressContext.sink?.step(vm: reference.name, "Restoring VM run state")
        }
        let finalState: VMFinalState
        let captured: PommeRecoveryRunState
        switch desired {
        case .stopped:
            finalState = .stopped
            captured = .stopped
        case .running(let mode):
            finalState = mode == .normal ? .normal : .recovery
            captured = .running(mode)
        case .paused(let mode):
            finalState = .paused
            captured = .paused(previousBootMode: mode)
        }
        try await PommeSecurityRunStateRestoration.restore(
            desired: desired,
            observe: { try stableVMRunState(reference: reference) },
            // A mode change stops only to boot the other mode next; a Recovery
            // target must not be preceded by an agent-driven shutdown.
            stop: {
                try await stopForLiveRecovery(
                    reference: reference, allowAgentShutdown: desired == .stopped)
            },
            start: { _ in
                try await requestLiveRecoveryFinalState(
                    finalState,
                    captured: captured,
                    reference: reference
                )
            }
        )
    }

    static func provesStableVMRunState(
        _ desired: VMRunStateSnapshot,
        reference: VMReference
    ) throws -> Bool {
        try stableVMRunState(reference: reference) == desired
    }

    private static func makeLiveRecoveryRuntime(
        reference: VMReference,
        request: PommeRecoverySessionRequest,
        recoveryConfiguration: PommeRecoveryRuntimeConfiguration,
        launcher: PommeLiveRecoveryIntegration.Launcher
    ) async throws -> PommeLiveRecoveryIntegration.Runtime {
        let plan = try loadOwnedProvisioningPlan(reference: reference)
        guard request.vmUUID == plan.vm.uuid,
              request.requestID == launcher.sessionID,
              request.vmUUID == launcher.vmID,
              request.listenerPort == launcher.listenerPort,
              recoveryConfiguration.request == request,
              recoveryConfiguration.staging.request == request
        else { throw PommeLiveRecoveryIntegration.Error.requestBindingRejected }

        // Capture and stop before constructing any VZ object backed by this
        // VM's auxiliary storage. The session receives this immutable capture
        // and remains the sole owner of the requested final-state policy.
        let capturedState = try await captureAndStopForLiveRecovery(reference: reference)
        do {
        try await waitForLiveRecoveryAuxiliaryStorageRelease(
            at: reference.bundle.auxiliaryStorageURL,
            vmName: plan.vm.name
        )

        // Load the one-shot token through an owner-only, no-follow descriptor
        // before the guest is started. The coordinator retains only the
        // normalized in-memory value and never reopens staging after detach.
        let recoverySecret = try readLiveRecoveryCredential(
            from: recoveryConfiguration.staging
        )
        let expectedRole: PommeAgentVSOCKRole
        switch PommeRecoveryListenerPort(rawValue: request.listenerPort) {
        case .bootstrap: expectedRole = .recoveryBootstrap
        case .operation: expectedRole = .recoveryRuntime
        case nil: throw PommeLiveRecoveryIntegration.Error.requestBindingRejected
        }
        let binding = PommeAgentVSOCKBinding(
            vmID: request.vmUUID,
            sessionID: request.requestID
        )

        let configuration = try makeProvisioningVMConfiguration(
            for: plan,
            recoveryConfiguration: recoveryConfiguration
        )
        let queue = DispatchQueue(
            label: "com.github.weswhet.pomme.recovery-runtime.\(request.requestID.uuidString.lowercased())"
        )
        let vm = VZVirtualMachine(configuration: configuration, queue: queue)
        guard let socketDevice = queue.sync(execute: {
            vm.socketDevices.first as? VZVirtioSocketDevice
        }) else {
            throw PommeLiveRecoveryIntegration.Error.runtimeRejected
        }
        let coordinator = PommeAgentVSOCKCoordinator(
            socketDevice: socketDevice,
            queue: queue,
            secretProvider: { role in
                guard role == expectedRole else { throw PommeAgentVSOCKError.invalidBinding }
                return recoverySecret
            },
            bindingProvider: { role in
                guard role == expectedRole else { throw PommeAgentVSOCKError.invalidBinding }
                return binding
            },
            exchangeTimeout: Constants.agentRoundTripTimeout
        )
        let bundle = reference.bundle
        let vmRuntime = PommeVMRuntime(
            vm: vm,
            configuration: configuration,
            queue: queue,
            saveStateURL: bundle.saveStateURL,
            snapshotsURL: bundle.snapshotsURL,
            requiredSnapshotRestoreURL: bundle.requiredSnapshotRestoreURL,
            agentProvider: coordinator,
            bootMode: .recovery
        )
        let backend = VirtualizationPrivateHeadlessBackend(
            virtualMachine: vm,
            configuration: configuration,
            queue: queue
        )
        let screenshotRecorder = PommeRecoveryDebugContext.screenshotsEnabled
            ? PommeRecoveryNavigationScreenshotRecorder(
                vmName: plan.vm.name,
                capture: { timeout in try await backend.recoveryFrame(timeout: timeout) }
            )
            : nil
        let terminal = PommeRecoveryVirtualizationKeyboardPort(
            backend: backend,
            timeout: Constants.defaultRecoveryAgentTimeout,
            screenshotRecorder: screenshotRecorder
        )
        let resources = PommeLiveRecoveryRuntimeResources(
            vm: vm,
            configuration: configuration,
            queue: queue,
            runtime: vmRuntime,
            coordinator: coordinator,
            staging: recoveryConfiguration.staging,
            request: request,
            sensitiveFramesCleared: { await terminal.sensitiveFramesCleared() }
        )
        let vmPort = PommeLiveRecoveryVMStatePort(
            capture: {
                capturedState
            },
            request: { finalState, captured in
                try await requestLiveRecoveryFinalState(
                    finalState,
                    captured: captured,
                    reference: reference
                )
            },
            prove: { finalState, captured in
                try await proveLiveRecoveryFinalState(
                    finalState,
                    captured: captured,
                    reference: reference
                )
            }
        )
        let effects = PommeRecoveryRuntimeEffects(
            verifyVMIdentity: {
                request.vmUUID == plan.vm.uuid
                    && plan.vm.bundlePath == reference.standardizedPath
            },
            startRecovery: { try await resources.runtime.start() },
            launchRecoveryAgent: {},
            verifyRecoveryBoot: { resources.isRunningRecovery() },
            helperIsAlive: { resources.isRunningRecovery() },
            verifyBootstrapAttachment: { resources.hasExactBootstrapAttachment() },
            stopReapAndClean: { try await resources.stopReapAndClean() }
        )
        return .init(
            coordinator: coordinator,
            vmPort: vmPort,
            effects: effects,
            terminalPort: terminal,
            clearHostStagingBeforeOperation: {
                try resources.clearHostStaging()
            },
            verifySessionBinding: { candidate in
                candidate == request
                    && binding.vmID == candidate.vmUUID.uuidString.lowercased()
                    && binding.sessionID == candidate.requestID.uuidString.lowercased()
            },
            restoreCapturedState: {
                try await restoreCapturedLiveRecoveryState(
                    capturedState,
                    reference: reference
                )
            }
        )
        } catch {
            try await restoreCapturedLiveRecoveryState(
                capturedState,
                reference: reference
            )
            throw error
        }
    }

    private static func restoreCapturedLiveRecoveryState(
        _ captured: PommeRecoveryRunState,
        reference: VMReference
    ) async throws {
        let finalState: VMFinalState
        switch captured {
        case .stopped: finalState = .stopped
        case .running(.normal): finalState = .normal
        case .running(.recovery): finalState = .recovery
        case .paused: finalState = .paused
        }
        try await requestLiveRecoveryFinalState(
            finalState,
            captured: captured,
            reference: reference
        )
        guard try await proveLiveRecoveryFinalState(
            finalState,
            captured: captured,
            reference: reference
        ) else { throw PommeRecoverySessionError.finalStateUnverified }
    }

    static func loadOwnedProvisioningPlan(
        reference: VMReference
    ) throws -> PommeProvisioningPlan {
        let bundle = reference.bundle
        let keyURL = provisioningKeyURL(bundle: bundle)
        guard isRegularFile(keyURL)
        else { throw PommeProvisioningError.ownershipMismatch }
        let key = try Data(contentsOf: keyURL, options: .mappedIfSafe)
        guard key.count >= 32 else { throw PommeProvisioningError.integrityFailure }
        let plan: PommeProvisioningPlan
        if try provisioningSchema(bundle: bundle) == 2 {
            plan = try provisioningV2Repository(bundle: bundle, key: key).load().plan
        } else {
            plan = try provisioningRepository(bundleURL: bundle.rootURL,
                signer: PommeProvisioningJournalSigner(key: key)).load().plan
        }
        try plan.validate()
        guard plan.vm.bundlePath == reference.standardizedPath,
              reference.name == nil || plan.vm.name == reference.name
        else { throw PommeProvisioningError.ownershipMismatch }
        let ownershipData = try Data(
            contentsOf: provisioningOwnershipURL(bundle: bundle),
            options: .mappedIfSafe
        )
        guard try JSONDecoder().decode(PommeVMOwnership.self, from: ownershipData) == plan.vm else {
            throw PommeProvisioningError.ownershipMismatch
        }
        return plan
    }

    private static func liveRecoveryProfileEvidence(
        reference: VMReference
    ) async throws -> PommeRecoveryProfileEvidence {
        let plan = try loadOwnedProvisioningPlan(reference: reference)
        guard try await verifyProvisioningOwnership(plan.vm) == plan.vm else {
            throw PommeRecoveryInputQualificationError.ownershipUnverified
        }
        try VirtualizationPrivateABIPreflight.validateRuntime()
        return try recoveryProfileEvidence(for: plan)
    }

    /// Binds navigation to the exact durable restore identity, without claiming
    /// a reviewed OS profile for an experimental attempt. The live caller must
    /// separately prove current ownership and the host input ABI first.
    static func recoveryProfileEvidence(
        for plan: PommeProvisioningPlan
    ) throws -> PommeRecoveryProfileEvidence {
        try plan.validate()
        if plan.profile.qualification == .experimental {
            let descriptor = try PommeRecoveryProfileSelector.descriptor(
                version: plan.restore.version,
                build: plan.restore.build
            )
            return .init(
                build: .experimental(version: plan.restore.version, build: plan.restore.build),
                locale: .english,
                geometry: .pixels1280x800,
                privateHostABI: .qualifiedRecoveryInputV1,
                manifestHash: .experimentalProfile(descriptor.digest),
                ownership: .verified
            )
        }
        guard plan.profile == .tahoe else {
            throw PommeRecoveryInputQualificationError.unsupportedBuild
        }
        return .init(
            build: .tahoe2660Build25G72,
            locale: .english,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .tahoe2660Build25G72,
            ownership: .verified
        )
    }

    private static func liveRecoveryStagingParent() throws -> URL {
        let parent = try applicationSupportRoot()
            .appendingPathComponent("RecoveryStaging", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard chmod(parent.path, mode_t(0o700)) == 0 else {
            throw PommeRecoveryStagingError.unsafeParent
        }
        var info = stat()
        guard lstat(parent.path, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700,
              parent.path == parent.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw PommeRecoveryStagingError.unsafeParent }
        return parent
    }

    private static func readLiveRecoveryCredential(
        from staging: PommeRecoveryStaging
    ) throws -> String {
        let name = PommeRecoveryArtifactNames.credential
        let rootFD = Darwin.open(
            staging.rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFD >= 0 else { throw PommeLiveRecoveryIntegration.Error.credentialRejected }
        defer { _ = Darwin.close(rootFD) }

        let descriptor = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PommeLiveRecoveryIntegration.Error.credentialRejected }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o400,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= 4_096
        else { throw PommeLiveRecoveryIntegration.Error.credentialRejected }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        while data.count < Int(info.st_size) {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    min(bytes.count, Int(info.st_size) - data.count)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PommeLiveRecoveryIntegration.Error.credentialRejected }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == Int(info.st_size),
              let raw = String(data: data, encoding: .utf8)
        else { throw PommeLiveRecoveryIntegration.Error.credentialRejected }
        do { return try PommeAgentAuthentication.normalized(raw) }
        catch { throw PommeLiveRecoveryIntegration.Error.credentialRejected }
    }

    private static func provisioningEffects() -> PommeProvisioningEffects {
        provisioningEffectsLock.lock()
        defer { provisioningEffectsLock.unlock() }
        if let installedProvisioningEffects {
            return installedProvisioningEffects
        }
        return makeLiveProvisioningEffects()
    }

    // MARK: Public argument and output helpers

    static func normalizedPublicArguments(_ arguments: [String]) -> [String] {
        arguments
    }

    static func absoluteHostPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return url.standardizedFileURL.path
    }

    static func stringValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as CustomStringConvertible:
            return value.description
        case nil, is NSNull:
            return ""
        default:
            return ""
        }
    }

    static func hostExitCode(from object: [String: Any], default defaultCode: Int32 = 1) -> Int32 {
        if let value = object["hostExitCode"] as? Int { return Int32(value) }
        if let value = object["hostExitCode"] as? Int32 { return value }
        if let value = object["hostExitCode"] as? NSNumber { return value.int32Value }
        if let value = object["exitCode"] as? NSNumber { return value.int32Value }
        return defaultCode
    }

    static func log(_ message: String) {
        let safe = message
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        if let sink = PommeLogContext.sink {
            sink(safe)
            return
        }
        if let sink = PommeProgressContext.sink {
            sink.diagnostic(safe)
            return
        }
        fputs("[\(Date().pommeISO8601String)] \(safe)\n", stderr)
        fflush(stderr)
    }

    static func warning(_ message: String, vmName: String? = nil) {
        let text = vmName.map { "\($0) \(message)" } ?? message
        if PommeLogContext.sink != nil { log(text) }
        else if let sink = PommeProgressContext.sink { sink.warning(text) }
        else { log(text) }
    }

    /// Attributes a diagnostic to one VM without sharing mutable target state.
    static func log(_ message: String, vmName: String) {
        log("\(vmName) \(message)")
    }

    /// Renders the installer's progress using the same VM scope as its plan.
    static func logInstallProgress(fractionCompleted: Double, vmName: String) {
        log("install progress: \(Int(fractionCompleted * 100))%", vmName: vmName)
    }

    static func withLogSink<Result: Sendable>(
        _ sink: @escaping @Sendable (String) -> Void,
        operation: @escaping @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await PommeLogContext.$sink.withValue(sink) {
            try await operation()
        }
    }

    // MARK: Virtualization queue boundaries

    static func start(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async {
                vm.value.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    static func start(
        _ vm: VZVirtualMachine,
        options: VZVirtualMachineStartOptions,
        on queue: DispatchQueue
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let vm = QueueConfined(value: vm)
            let options = QueueConfined(value: options)
            queue.async {
                vm.value.start(options: options.value) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    static func pause(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async {
                vm.value.pause { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    static func resume(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async {
                vm.value.resume { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    static func stop(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let vm = QueueConfined(value: vm)
            queue.async {
                vm.value.stop { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    static func requestStop(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let vm = QueueConfined(value: vm)
            queue.async {
                do {
                    try vm.value.requestStop()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func forceStop(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
        try await stop(vm, on: queue)
    }

    static func saveMachineState(_ vm: VZVirtualMachine, to url: URL, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let vm = QueueConfined(value: vm)
            let url = QueueConfined(value: url)
            queue.async {
                vm.value.saveMachineStateTo(url: url.value) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    static func restoreMachineState(_ vm: VZVirtualMachine, from url: URL, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let vm = QueueConfined(value: vm)
            let url = QueueConfined(value: url)
            queue.async {
                vm.value.restoreMachineStateFrom(url: url.value) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    static func state(of vm: VZVirtualMachine, on queue: DispatchQueue) async -> VZVirtualMachine.State {
        await withCheckedContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async { continuation.resume(returning: vm.value.state) }
        }
    }

    static func canPause(_ vm: VZVirtualMachine, on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async { continuation.resume(returning: vm.value.canPause) }
        }
    }

    static func canResume(_ vm: VZVirtualMachine, on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async { continuation.resume(returning: vm.value.canResume) }
        }
    }

    static func canRequestStop(_ vm: VZVirtualMachine, on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            let vm = QueueConfined(value: vm)
            queue.async { continuation.resume(returning: vm.value.canRequestStop) }
        }
    }

    static func stableVMMACAddress(machineIdentifierData: Data) -> String {
        var octets = Array(SHA256.hash(data: machineIdentifierData).prefix(6))
        octets[0] = (octets[0] & 0b1111_1100) | 0b0000_0010
        return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: Pomme control protocol bridge

    static func sendControlObject(_ payload: [String: Any], bundle: BundleLayout, timeout: TimeInterval? = nil) throws -> [String: Any] {
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        let request = try makeControlRequest(from: payload)
        let record = try runtimeRecord(for: bundle)
        let identity = PommeRuntimeIdentity(
            socketPath: record.socketPath,
            pid: record.pid,
            startedAt: record.startedAt
        )
        let remaining = deadline.map { $0 - ProcessInfo.processInfo.systemUptime }
        let result = try PommeControlSocketClient(identity: identity).send(request, timeout: remaining)
        return normalizedControlObject(result)
    }

    /// Shared by the live control bridge and contract tests; normalization is
    /// not security verification and intentionally preserves the existing shape.
    static func normalizedControlObject(_ result: JSONValue) -> [String: Any] {
        guard let object = result.objectValue else {
            return ["ok": true, "response": result.publicValue, "hostExitCode": 0]
        }
        var output = object.mapValues(\.publicValue)
        output["ok"] = output["ok"] as? Bool ?? true
        output["hostExitCode"] = output["hostExitCode"] ?? 0
        return output
    }

    /// Foreground output consists of bounded stream frames followed by one
    /// completion response; a process-start acknowledgement is not completion.
    static func sendForegroundControlObject(
        _ payload: [String: Any],
        bundle: BundleLayout,
        timeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        let request = try makeControlRequest(from: payload)
        let record = try runtimeRecord(for: bundle)
        let identity = PommeRuntimeIdentity(socketPath: record.socketPath, pid: record.pid, startedAt: record.startedAt)
        let deadline = try timeout.map { value -> TimeInterval in
            guard value.isFinite, value > 0 else {
                throw RunnerError.invalidControlResponse("Pomme control stream timeout is invalid.")
            }
            return ProcessInfo.processInfo.systemUptime + value
        }
        let stream = try PommeControlSocketClient(identity: identity).openStream(
            request,
            timeout: deadline.map { max(0.001, $0 - ProcessInfo.processInfo.systemUptime) }
        )
        try stream.closeInput()
        guard let deadline else {
            return try collectForegroundResponse(receive: stream.receiveEvent)
        }
        return try collectForegroundResponse(
            maximumOutputBytes: 16 * 1024 * 1024,
            until: deadline,
            receive: { remaining in
                try stream.receiveEventIfAvailable(timeout: remaining)
            }
        )
    }

    /// Streams helper-owned guest unified logs directly to the caller. The
    /// client leaves input open so it can cancel a quiet follow request, but
    /// never sends arbitrary guest input and never retains log output.
    static func sendLogControlStream(
        _ payload: [String: Any],
        bundle: BundleLayout,
        shouldCancel: @escaping () -> Bool,
        onOutput: @escaping (Int32, Data) throws -> Void
    ) throws -> [String: Any] {
        let unstreamed = try makeControlRequest(from: payload)
        guard unstreamed.command == "logs.show" || unstreamed.command == "logs.stream" else {
            throw RunnerError.invalidControlCommand(unstreamed.command)
        }
        let request = PommeControlRequest(
            id: unstreamed.id,
            command: unstreamed.command,
            payload: unstreamed.payload,
            streaming: true
        )
        let record = try runtimeRecord(for: bundle)
        let identity = PommeRuntimeIdentity(
            socketPath: record.socketPath,
            pid: record.pid,
            startedAt: record.startedAt
        )
        let stream = try PommeControlSocketClient(identity: identity).openStream(request)
        var cancellationSent = false
        var outputFailure: Error?
        var completionReceived = false

        func cancel() throws {
            guard !cancellationSent else { return }
            try stream.send(stream: .cancellation)
            cancellationSent = true
        }

        do {
            while true {
                if shouldCancel() { try cancel() }
                guard let event = try stream.receiveEventIfAvailable(timeout: 0.025) else { continue }
                switch event {
                case .stream(let frame):
                    switch frame.stream {
                    case .stdout, .stderr:
                        guard let data = try frame.decodedData() else {
                            throw RunnerError.invalidControlResponse("Pomme log output frame is missing data.")
                        }
                        // Once cancellation is on the wire, the helper owns
                        // process cleanup. Do not keep writing guest bytes to
                        // a terminal that may already be gone.
                        if !cancellationSent, outputFailure == nil {
                            let descriptor: Int32 = frame.stream == .stdout ? STDOUT_FILENO : STDERR_FILENO
                            do { try onOutput(descriptor, data) }
                            catch is PommeLogOutputSink.Cancelled {
                                try cancel()
                            } catch {
                                outputFailure = error
                                try cancel()
                            }
                        }
                    case .progress:
                        // The helper uses a progress envelope for the validated
                        // guest exit receipt. It is not user output.
                        break
                    case .stdin, .resize, .signal, .cancellation:
                        throw RunnerError.invalidControlResponse("Unexpected Pomme log output stream.")
                    }
                case .response(let response):
                    completionReceived = true
                    if let outputFailure {
                        guard response.ok,
                              let result = response.result,
                              result.objectValue?["cleanupConfirmed"] == .bool(true)
                        else {
                            throw RunnerError.invalidControlResponse(
                                "Pomme log process cleanup could not be confirmed after host output failed."
                            )
                        }
                        throw outputFailure
                    }
                    guard response.ok, let result = response.result else {
                        let failure = response.error
                        throw RunnerError.controlCommandFailed(
                            failure.map { "\($0.code): \($0.message)" }
                                ?? "Missing Pomme log completion response."
                        )
                    }
                    let normalized = normalizedControlObject(result)
                    if !cancellationSent,
                       normalized["ok"] as? Bool == false,
                       let message = normalized["error"] as? String,
                       !message.isEmpty {
                        throw RunnerError.controlCommandFailed(message)
                    }
                    return normalized
                }
            }
        } catch {
            guard completionReceived else {
                throw RunnerError.invalidControlResponse("Pomme log cleanup could not be confirmed.")
            }
            throw error
        }
    }

    /// A public PTY is a full-duplex terminal bridge, unlike buffered
    /// foreground execution which closes input before collecting output.
    static func sendPublicPTYControlObject(
        _ payload: [String: Any],
        bundle: BundleLayout,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        PommeProgressContext.sink?.suspend()
        let request = try makeControlRequest(from: payload)
        let record = try runtimeRecord(for: bundle)
        let identity = PommeRuntimeIdentity(socketPath: record.socketPath, pid: record.pid, startedAt: record.startedAt)
        let stream = try PommeControlSocketClient(identity: identity).openStream(request, timeout: timeout)
        let bridge = PommePublicPTYTerminalBridge(
            transport: .init(
                send: { kind, data, framePayload, eof in
                    try stream.send(stream: kind, data: data, payload: framePayload, eof: eof)
                },
                receive: { timeout in
                    try stream.receiveEventIfAvailable(timeout: timeout)
                }
            )
        )
        return try bridge.run(timeout: timeout)
    }

    /// Opens a durable terminal attachment.  The setup exchange is bounded;
    /// the attachment itself has no wall-clock deadline and returns only when
    /// the local client detaches or the guest session exits.
    static func sendTerminalAttachControlObject(
        _ payload: [String: Any],
        bundle: BundleLayout,
        setupTimeout: TimeInterval = Constants.agentRoundTripTimeout
    ) throws -> [String: Any] {
        PommeProgressContext.sink?.suspend()
        let request = try makeControlRequest(from: payload)
        guard request.command == "terminal.session",
              payload["operation"] as? String == "terminal.attach"
        else { throw RunnerError.invalidControlCommand("terminal.attach") }
        let record = try runtimeRecord(for: bundle)
        let identity = PommeRuntimeIdentity(socketPath: record.socketPath, pid: record.pid, startedAt: record.startedAt)
        let stream = try PommeControlSocketClient(identity: identity).openStream(request, timeout: setupTimeout)
        return try PommeDurableTerminalBridge(stream: stream).run()
    }

    static func collectForegroundResponse(
        maximumOutputBytes: Int = 16 * 1024 * 1024,
        receive: () throws -> PommeControlStreamEvent
    ) throws -> [String: Any] {
        try collectForegroundResponseLoop(maximumOutputBytes: maximumOutputBytes) {
            .some(try receive())
        }
    }

    /// Collects a foreground response through a monotonic transport deadline.
    /// The receive closure must perform one bounded poll and return `nil` when
    /// that poll elapsed without an event. A silent helper therefore cannot
    /// leave the invoking security workflow suspended indefinitely.
    static func collectForegroundResponse(
        maximumOutputBytes: Int = 16 * 1024 * 1024,
        timeout: TimeInterval,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        receive: (TimeInterval) throws -> PommeControlStreamEvent?
    ) throws -> [String: Any] {
        guard timeout.isFinite, timeout > 0 else {
            throw RunnerError.invalidControlResponse("Pomme control stream timeout is invalid.")
        }
        return try collectForegroundResponse(
            maximumOutputBytes: maximumOutputBytes,
            until: now() + timeout,
            now: now,
            receive: receive
        )
    }

    private static func collectForegroundResponse(
        maximumOutputBytes: Int,
        until deadline: TimeInterval,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        receive: (TimeInterval) throws -> PommeControlStreamEvent?
    ) throws -> [String: Any] {
        try collectForegroundResponseLoop(maximumOutputBytes: maximumOutputBytes) {
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw RunnerError.invalidControlResponse("Pomme control stream receive timed out.")
            }
            return try receive(remaining)
        }
    }

    private static func collectForegroundResponseLoop(
        maximumOutputBytes: Int,
        receive: () throws -> PommeControlStreamEvent?
    ) throws -> [String: Any] {
        var frames: [[String: Any]] = []
        var outputBytes = 0
        while true {
            guard let event = try receive() else { continue }
            switch event {
            case .stream(let frame):
                switch frame.stream {
                case .stdout, .stderr:
                    if let data = try frame.decodedData(), !data.isEmpty {
                        guard data.count <= maximumOutputBytes - outputBytes, frames.count < 16_384 else {
                            throw RunnerError.invalidGuestCommand("Foreground output exceeded the buffered byte or frame limit.")
                        }
                        // Output is buffered here and printed only by the
                        // result writer, which ends progress first. Internal
                        // guest reads (security, owner, and MDM checks) must
                        // not stop the status line of the command they serve.
                        outputBytes += data.count
                        frames.append(["stream": frame.stream.rawValue, "dataBase64": data.base64EncodedString()])
                    }
                case .progress: break
                case .stdin, .resize, .signal, .cancellation:
                    throw RunnerError.invalidControlResponse("Unexpected foreground output stream.")
                }
            case .response(let response):
                guard response.ok, let object = response.result?.objectValue else {
                    let failure = response.error
                    throw RunnerError.controlCommandFailed(failure.map { "\($0.code): \($0.message)" } ?? "Missing foreground completion response.")
                }
                var output = object.mapValues(\.publicValue)
                output["streamFrames"] = frames
                output["foreground"] = true
                return output
            }
        }
    }

    /// Preserves operation-specific fields inside the bounded helper envelope.
    static func makeControlRequest(from payload: [String: Any]) throws -> PommeControlRequest {
        let command = try controlCommand(from: payload)
        var body = payload.filter { key, _ in
            !["type", "command", "operation", "id", "streaming"].contains(key)
        }
        if command == "agent.perform" || command == "guest-ui" {
            guard let operation = payload["operation"] as? String,
                  operation != command
            else { throw RunnerError.invalidControlCommand(command) }
            body["operation"] = operation
        }
        if command == "terminal.session" {
            guard let operation = payload["operation"] as? String,
                  operation != command
            else { throw RunnerError.invalidControlCommand(command) }
            body["operation"] = operation
        }
        if command == "guest-ui", let path = body["hostOutputPath"] as? String {
            guard !path.isEmpty, !path.contains("\0") else {
                throw RunnerError.invalidUICommand("A screenshot requires a valid host output path.")
            }
            // Resolve in the invoking CLI, not the helper's VM-bundle directory.
            body["hostOutputPath"] = URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let requestPayload = body.isEmpty ? nil : try JSONValue(any: body)
        return PommeControlRequest(command: command, payload: requestPayload)
    }

    static func controlCommandPayload(
        _ command: PommeLifecycleCommand,
        reference: VMReference,
        guestShutdownRequested: Bool = false
    ) throws -> [String: Any] {
        var request: [String: Any] = ["command": command.rawValue]
        if guestShutdownRequested { request["guestShutdownRequested"] = true }
        let payload = try sendControlObject(request, bundle: reference.bundle)
        var result = payload
        result["operation"] = command.rawValue
        if let name = reference.name { result["name"] = name }
        result["bundlePath"] = reference.bundle.rootURL.path
        return result
    }

    private static func controlCommand(from payload: [String: Any]) throws -> String {
        let candidate = (payload["command"] as? String) ?? (payload["operation"] as? String)
        guard let candidate, ["pause", "resume", "stop", "force-stop", "status", "inspect", "snapshot-save", "agent.perform", "guest-ui", "terminal.session", "logs.show", "logs.stream"].contains(candidate) else {
            throw RunnerError.invalidControlCommand(candidate ?? "")
        }
        return candidate
    }

    private static func runtimeRecord(for bundle: BundleLayout) throws -> PommeRuntimeRecord {
        let directory = try runtimeDirectory(create: false)
        let expectedPath = bundle.rootURL.standardizedFileURL.path
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(PommeRuntimeRecord.self, from: data),
                  URL(fileURLWithPath: record.bundlePath).standardizedFileURL.path == expectedPath,
                  record.pid > 0 else { continue }
            // An interrupted helper can leave its record behind. Only a
            // proven-dead PID is safe to ignore; permission or other process
            // inspection failures retain the record and fail closed later.
            if Darwin.kill(record.pid, 0) != 0 && errno == ESRCH { continue }
            return record
        }
        throw RunnerError.noRunningVM(bundle.pommeSocketURL)
    }

    // MARK: Status and inspection

    static func listVMsPayload() throws -> [String: Any] {
        let directory = try vmStoreDirectory(create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return ["ok": true, "vms": []]
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let entries = try urls.compactMap { url -> [String: Any]? in
            guard url.pathExtension == "bundle",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard (try? validateVMName(name)) != nil else { return nil }
            let reference = VMReference(name: name, bundle: BundleLayout(rootURL: url))
            return try vmStatusPayload(reference: reference)
        }.sorted { stringValue($0["name"]) < stringValue($1["name"]) }
        return ["ok": true, "vms": entries]
    }

    static func vmStatusPayload(reference: VMReference) throws -> [String: Any] {
        do {
            var payload = try sendControlObject(["command": "status"], bundle: reference.bundle)
            payload["name"] = reference.name ?? stringValue(payload["name"])
            payload["bundlePath"] = reference.bundle.rootURL.path
            if payload["guestAgent"] == nil {
                payload["guestAgent"] = guestAgentPayload(.offline(role: .normal))
            }
            try discloseProvisioningState(&payload, bundle: reference.bundle)
            return payload
        } catch RunnerError.noRunningVM {
            var payload = offlineStatusPayload(bundle: reference.bundle)
            if let name = reference.name { payload["name"] = name }
            try discloseProvisioningState(&payload, bundle: reference.bundle)
            return payload
        }
    }

    static func vmInspectPayload(reference: VMReference) throws -> [String: Any] {
        var payload: [String: Any]
        do {
            payload = try sendControlObject(["command": "inspect"], bundle: reference.bundle)
        } catch RunnerError.noRunningVM {
            payload = offlineStatusPayload(bundle: reference.bundle)
        }
        payload["name"] = reference.name ?? stringValue(payload["name"])
        payload["bundlePath"] = reference.bundle.rootURL.path
        if let metadata = try? metadataPayload(bundle: reference.bundle) { payload["metadata"] = metadata }
        if payload["guestAgent"] == nil { payload["guestAgent"] = guestAgentPayload(.offline(role: .normal)) }
        try discloseProvisioningState(&payload, bundle: reference.bundle)
        return payload
    }

    static func vmHealthPayload(reference: VMReference) throws -> [String: Any] {
        let status = try vmStatusPayload(reference: reference)
        let running = status["helperRunning"] as? Bool == true
        let agent = status["guestAgent"] as? [String: Any]
        let connected = agent?["connection"] as? String == GuestAgentStatusV1.ConnectionState.connected.rawValue
        return [
            "ok": running && connected,
            "healthy": running && connected,
            "hostExitCode": running && connected ? 0 : 1,
            "name": reference.name as Any,
            "checks": [
                ["name": "helper", "ok": running],
                ["name": "guestAgent", "ok": connected]
            ],
            "guestAgent": agent ?? guestAgentPayload(.offline(role: .normal))
        ]
    }

    static func vmCapabilitiesPayload(reference: VMReference) throws -> [String: Any] {
        let status = try vmStatusPayload(reference: reference)
        let agent = status["guestAgent"] as? [String: Any] ?? guestAgentPayload(.offline(role: .normal))
        return [
            "ok": status["ok"] as? Bool ?? false,
            "name": reference.name as Any,
            "guestAgent": agent,
            "capabilities": agent["capabilities"] ?? [],
            "uiCapabilities": PommeUICapabilities.publicPayload,
            "hostExitCode": status["ok"] as? Bool == true ? 0 : 1
        ]
    }

    private static func offlineStatusPayload(bundle: BundleLayout) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "helperRunning": false,
            "vmState": "stopped",
            "bootMode": "none",
            "bundlePath": bundle.rootURL.path,
            "pommeSocket": bundle.pommeSocketURL.path,
            "guestAgent": guestAgentPayload(.offline(role: .normal))
        ]
        if let metadata = try? metadataPayload(bundle: bundle) { payload["metadata"] = metadata }
        return payload
    }

    private static func guestAgentPayload(_ status: GuestAgentStatusV1) -> [String: Any] {
        [
            "connection": status.connection.rawValue,
            "role": status.role.rawValue,
            "protocolVersion": status.protocolVersion.map { $0 as Any } ?? NSNull(),
            "executableDigest": status.executableDigest.map { $0 as Any } ?? NSNull(),
            "capabilities": status.capabilities,
            "updateState": status.updateState.rawValue
        ]
    }

    // MARK: Destructive lifecycle and creation integration

    static func destroyVMPayload(reference: VMReference, confirmation: String?) throws -> [String: Any] {
        guard let name = reference.name else { throw RunnerError.vmDestroyRequiresNamedVM }
        guard confirmation == nil || confirmation == name else {
            throw RunnerError.vmDestroyConfirmationMismatch(name)
        }
        guard FileManager.default.fileExists(atPath: reference.bundle.rootURL.path) else {
            throw RunnerError.namedVMNotFound(name)
        }
        if (try? runtimeRecord(for: reference.bundle)) != nil {
            throw RunnerError.virtualMachineState(
                "Cannot delete VM '\(name)' while its helper is running. " +
                "Run 'pomme stop \(name)' first, then retry deletion."
            )
        }
        let schema = try provisioningSchemaIfPresent(bundle: reference.bundle)
        let ownedPlan = try schema.map { _ in try loadOwnedProvisioningPlan(reference: reference) }
        let credentialUUID = try deletionCredentialUUID(plan: ownedPlan, bundle: reference.bundle)
        // Resolve and authenticate the reference while its owning bundle is
        // still present. A failed credential cleanup must retain the journal.
        var ownerReference: PommeOwnerCredentialReference?
        if schema == 2 {
            let journal = try loadProvisioningV2(reference: reference)
            guard journal.plan == ownedPlan else { throw PommeProvisioningError.ownershipMismatch }
            if let owner = journal.ownerReference {
                try validateProvisioningOwnerReference(owner, plan: journal.plan)
                ownerReference = owner
            }
        }
        let ownerStore = PommeOwnerCredentialStore()
        let agentStore = PommeAgentCredentialStore()
        // Snapshot both exact secrets before the first delete. Restoration uses
        // these bytes only; no random source or provisioned-password generator
        // is reachable from the deletion transaction.
        let ownerSnapshot: PommeOwnerCredential?
        if let ownerReference {
            do { ownerSnapshot = try ownerStore.read(ownerReference) }
            catch PommeOwnerCredentialStoreError.keychainMissing { ownerSnapshot = nil }
        } else { ownerSnapshot = nil }
        let agentSnapshot: String?
        if let credentialUUID {
            do { agentSnapshot = try agentStore.read(vmUUID: credentialUUID, account: PommeProvisioningCredentialReference.agentAccount) }
            catch PommeAgentCredentialStore.Error.credentialMissing { agentSnapshot = nil }
        } else { agentSnapshot = nil }
        try performProvisioningDeletion(cleanupOwner: {
            if let ownerReference { try ownerStore.remove(reference: ownerReference) }
        }, cleanupAgent: {
            if let credentialUUID {
                try agentStore.remove(vmUUID: credentialUUID,
                    account: PommeProvisioningCredentialReference.agentAccount)
            }
        }, removeBundle: { try FileManager.default.removeItem(at: reference.bundle.rootURL) },
        restoreOwner: {
            if let ownerSnapshot {
                let restored = try ownerStore.store(.init(reference: ownerSnapshot.reference, password: ownerSnapshot.password))
                guard restored.reference == ownerSnapshot.reference, restored.password == ownerSnapshot.password else {
                    throw PommeOwnerCredentialStoreError.credentialCollision
                }
            }
        }, restoreAgent: {
            if let credentialUUID, let agentSnapshot {
                let restored = try agentStore.readOrCreate(vmUUID: credentialUUID,
                    account: PommeProvisioningCredentialReference.agentAccount, generate: { agentSnapshot })
                guard restored == agentSnapshot else { throw PommeAgentCredentialStore.Error.unexpectedCredentialData }
            }
        })
        return ["ok": true, "operation": "delete", "name": name, "bundlePath": reference.bundle.rootURL.path, "hostExitCode": 0]
    }

    /// The authenticated provisioning plan owns credential scope. Metadata may
    /// corroborate that UUID but cannot select a different Keychain item or
    /// suppress cleanup by omitting the UUID. Unjournaled legacy VMs keep their
    /// original optional metadata behavior.
    static func deletionCredentialUUID(plan: PommeProvisioningPlan?, bundle: BundleLayout) throws -> UUID? {
        guard let plan else { return vmUUID(for: bundle).flatMap(UUID.init(uuidString:)) }
        guard plan.vm.bundlePath == bundle.rootURL.standardizedFileURL.path else {
            throw PommeProvisioningError.ownershipMismatch
        }
        var info = stat()
        if lstat(bundle.metadataURL.path, &info) != 0 {
            guard errno == ENOENT else { throw PommeProvisioningError.ownershipMismatch }
            return plan.vm.uuid
        }
        do {
            let data = try PommeAgentFileTransaction.readRegular(bundle.metadataURL, maximumBytes: 1024 * 1024)
            guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PommeProvisioningError.ownershipMismatch
            }
            if let raw = metadata[Constants.vmUUIDMetadataKey] {
                guard let text = raw as? String, let uuid = UUID(uuidString: text), uuid == plan.vm.uuid else {
                    throw PommeProvisioningError.ownershipMismatch
                }
            }
        } catch { throw PommeProvisioningError.ownershipMismatch }
        return plan.vm.uuid
    }

    static func performProvisioningDeletion(cleanupOwner: () throws -> Void,
        cleanupAgent: () throws -> Void, removeBundle: () throws -> Void,
        restoreOwner: () throws -> Void, restoreAgent: () throws -> Void) throws {
        do {
            try cleanupOwner()
            try cleanupAgent()
            try removeBundle()
        } catch {
            // A store can report failure after applying its mutation. Restore
            // both snapshots, even when the first removal reports an error.
            var rollbackFailed = false
            do { try restoreOwner() } catch { rollbackFailed = true }
            do { try restoreAgent() } catch { rollbackFailed = true }
            guard !rollbackFailed else {
                throw RunnerError.hostCommandFailed("VM deletion failed and exact credential restoration could not be verified. The retained VM requires credential recovery.")
            }
            throw error
        }
    }

    static func createVMPayload(
        arguments: CLIOptions,
        reference: VMReference,
        lease: VMBundleMutationLease
    ) async throws -> [String: Any] {
        try await createProvisioningPayload(
            config: nil,
            arguments: arguments,
            reference: reference,
            lease: lease
        )
    }

    static func createConfiguredVMPayload(
        config: VMCreationConfigV1,
        arguments: CLIOptions,
        reference: VMReference,
        lease: VMBundleMutationLease
    ) async throws -> [String: Any] {
        try await createProvisioningPayload(
            config: config,
            arguments: arguments,
            reference: reference,
            lease: lease
        )
    }

    static func stopAndStartPayload(
        reference: VMReference,
        bootMode: BootMode,
        user _: String?,
        password _: String?,
        bootstrapOptions _: SIPBootstrapOptions,
        timeout: TimeInterval,
        recoveryAgentEnabled _: Bool = true,
        debug _: Bool = false
    ) throws -> [String: Any] {
        guard timeout > 0 else {
            throw RunnerError.virtualMachineState("Pomme lifecycle timeout must be greater than zero.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let payload = try startRuntimeInBackground(reference: reference, bootMode: bootMode, timeout: timeout)
        // A plain Recovery boot exposes only the terminal bootstrap listener;
        // its agent is admitted lazily by the first terminal session, so only
        // normal boots have an agent to wait for.
        guard bootMode == .normal else { return payload }
        return try waitForGuestAgentConnection(
            reference: reference,
            payload: payload,
            deadline: deadline,
            timeout: timeout
        )
    }

    /// Polls the helper until the guest agent reports connected, so `start`
    /// returns a VM that can already accept guest commands. The VM is left
    /// running on timeout; the error names the status to inspect.
    private static func waitForGuestAgentConnection(
        reference: VMReference,
        payload initial: [String: Any],
        deadline: TimeInterval,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        PommeProgressContext.sink?.step(vm: reference.name, "Waiting for Pomme agent")
        var payload = initial
        while true {
            let agent = payload["guestAgent"] as? [String: Any]
            let connection = GuestAgentStatusV1.ConnectionState(rawValue: stringValue(agent?["connection"]))
            switch connection {
            case .connected:
                return payload
            case .failed:
                throw RunnerError.virtualMachineState(
                    "\(reference.displayName) started but its guest agent failed to connect; run `pomme status` to inspect it."
                )
            default:
                break
            }
            let timedOut = RunnerError.virtualMachineState(
                "\(reference.displayName) started but its guest agent did not connect within \(Int(timeout)) seconds; the VM is still running. Run `pomme status` to inspect it."
            )
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw timedOut }
            Thread.sleep(forTimeInterval: min(0.5, remaining))
            let status: [String: Any]
            do {
                status = try sendControlObject(
                    ["command": "status"],
                    bundle: reference.bundle,
                    timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
                )
            } catch {
                // A status poll that fails only because the deadline elapsed
                // should report the agent wait, not the transport.
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw timedOut }
                throw error
            }
            for key in ["guestAgent", "vmState", "bootMode", "helperRunning"] where status[key] != nil {
                payload[key] = status[key]
            }
        }
    }

    static func startRequiredSnapshotRestorePayload(reference: VMReference) throws -> [String: Any] {
        let bundle = reference.bundle
        guard FileManager.default.fileExists(atPath: bundle.requiredSnapshotRestoreURL.path),
              FileManager.default.fileExists(atPath: bundle.saveStateURL.path)
        else {
            throw RunnerError.virtualMachineState(
                "A required named snapshot restore is incomplete; its saved-state artifacts must be repaired before startup."
            )
        }
        try waitForRequiredSnapshotRestoreHelperStop(reference: reference)
        try waitForRequiredSnapshotRestoreAuxiliaryStorageRelease(reference: reference)
        return try launchRequiredSnapshotRestore(
            launchNormal: {
                try startRuntimeInBackground(
                    reference: reference,
                    bootMode: .normal,
                    timeout: Constants.defaultRecoveryAgentTimeout
                )
            },
            helperIsRunning: { pid in
                do {
                    return try runtimeRecord(for: bundle).pid == pid
                } catch RunnerError.noRunningVM {
                    return false
                }
            },
            pollStatus: { try vmStatusPayload(reference: reference) }
        )
    }

    /// A stopped helper removes its runtime record only after it has written
    /// the lifecycle response. Do not reuse that short-lived helper to start
    /// a required saved-state restore.
    private static func waitForRequiredSnapshotRestoreHelperStop(reference: VMReference) throws {
        let deadline = Date().addingTimeInterval(Constants.gracefulStopTimeoutSeconds)
        while Date() < deadline {
            do {
                _ = try runtimeRecord(for: reference.bundle)
            } catch RunnerError.noRunningVM {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw RunnerError.virtualMachineState(
            "The previous VM helper did not stop before the named snapshot restore."
        )
    }

    /// Runtime-record removal happens before the foreground helper releases
    /// its last Virtualization objects. Probe the same lock used by Recovery
    /// before constructing a replacement helper, with one bounded retry.
    private static func waitForRequiredSnapshotRestoreAuxiliaryStorageRelease(
        reference: VMReference
    ) throws {
        var retries = 0
        while liveRecoveryAuxiliaryStorageHasConflictingLock(reference.bundle.auxiliaryStorageURL) {
            guard retries < 1 else {
                throw RunnerError.virtualMachineState(
                    "The previous VM runtime still owns auxiliary storage; named snapshot restore was not retried."
                )
            }
            retries += 1
            Thread.sleep(forTimeInterval: 2)
        }
    }

    static func launchRequiredSnapshotRestore(
        launchNormal: () throws -> [String: Any],
        helperIsRunning: (Int32) throws -> Bool,
        pollStatus: () throws -> [String: Any]
    ) throws -> [String: Any] {
        let launch = try launchNormal()
        guard let processID = launch["pid"] as? Int,
              let helperPID = Int32(exactly: processID), helperPID > 0
        else {
            throw RunnerError.invalidControlResponse(
                "Snapshot restore helper launch did not identify its process."
            )
        }
        return try waitForRequiredSnapshotRestorePausedNormal(
            helperPID: helperPID,
            helperIsRunning: { try helperIsRunning(helperPID) },
            pollStatus: pollStatus
        )
    }

    static func runInternalHelper(bundlePath: String, name: String?, bootMode: BootMode) async throws {
        try await runForegroundRuntime(
            reference: VMReference(name: name, bundle: BundleLayout(rootURL: URL(fileURLWithPath: bundlePath))),
            bootMode: bootMode
        )
    }

    /// Entry point used by the private runtime process.  The argument grammar
    /// is intentionally closed and has no public aliases.
    static func runInternalHelper(arguments: [String]) async -> Int32 {
        var vmName: String?
        do {
            let values = try parseRuntimeArguments(arguments)
            vmName = values.name
                ?? URL(fileURLWithPath: values.bundlePath).deletingPathExtension().lastPathComponent
            try await runInternalHelper(
                bundlePath: values.bundlePath,
                name: values.name,
                bootMode: values.bootMode
            )
            return 0
        } catch {
            if let vmName {
                log("runtime failed: \(error.localizedDescription)", vmName: vmName)
            } else {
                log("Runtime arguments rejected: \(error.localizedDescription)")
            }
            return 1
        }
    }

    // MARK: Durable provisioning

    private struct ProvisioningPreparation: Sendable {
        let plan: PommeProvisioningPlan
        let input: PommeProvisioningInput
        let signer: PommeProvisioningJournalSigner
        let restoreImage: URL
        let virtualization: Bool
    }

    /// Keeps the configuration requirements beside the durable identity so
    /// provisioning does not reload an image after it has qualified it.
    private struct RestoreImageQualification {
        let identity: PommeLocalRestoreImageIdentity
        let requirements: VZMacOSConfigurationRequirements
    }

    private static func createProvisioningPayload(
        config: VMCreationConfigV1?,
        arguments: CLIOptions,
        reference: VMReference,
        lease: VMBundleMutationLease
    ) async throws -> [String: Any] {
        guard let name = reference.name else {
            throw RunnerError.missingVMNameForCreate
        }
        guard lease.validates(name: name) else {
            throw VMBundleMutationLease.Error.invalidScope(name: name)
        }
        guard !FileManager.default.fileExists(atPath: reference.bundle.rootURL.path) else {
            throw RunnerError.hostCommandFailed(
                "A managed VM named \(name) already exists. Delete it explicitly before creating a replacement."
            )
        }

        PommeProgressContext.sink?.step(vm: name, "Preparing creation")

        // The floor runs before any download so a too-small request costs
        // nothing; the image's exact minimum is checked again once loaded.
        try validateProvisionalMemoryFloor(arguments.sizeOptions.memorySizeBytes)

        // All catalog, profile, image, hardware, and immutable identity checks
        // happen before the bundle is touched.  An unknown build or profile
        // therefore cannot leave a partial VM behind.
        let preparation = try await prepareProvisioning(
            config: config,
            arguments: arguments,
            reference: reference
        )
        let repository = try provisioningRepository(
            bundleURL: reference.bundle.rootURL,
            signer: preparation.signer
        )
        let orchestrator = PommeProvisioningOrchestrator(
            signer: preparation.signer,
            repository: repository,
            effects: provisioningEffects()
        )

        do {
            // The empty bundle is the durable journal anchor.  It is retained
            // on every failure; only the installer phase is allowed to create
            // Virtualization state after the journal exists.
            if FileManager.default.fileExists(atPath: reference.bundle.rootURL.path) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: reference.bundle.rootURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw RunnerError.hostCommandFailed("The Pomme VM bundle path is not a directory.")
                }
            } else {
                try FileManager.default.createDirectory(
                    at: reference.bundle.rootURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try writeProvisioningPreparation(preparation, bundle: reference.bundle)
            if preparation.virtualization {
                let key = try Data(contentsOf: provisioningKeyURL(bundle: reference.bundle))
                try await PommeProvisioningV2Orchestrator(
                    signer: PommeProvisioningV2Signer(key: key),
                    repository: provisioningV2Repository(bundle: reference.bundle, key: key),
                    effects: provisioningV2Effects()
                ).start(preparation.plan)
            } else {
                try await orchestrator.start(preparation.plan)
            }
        } catch {
            // Never delete a failed VM or its journal.  The caller can resume
            // the exact plan after correcting the external integration.
            throw error
        }

        var payload: [String: Any] = [
            "ok": true,
            "operation": "vm-create",
            "hostExitCode": 0,
            "name": name,
            "bundlePath": reference.bundle.rootURL.path,
            "restoreImage": preparation.restoreImage.path,
            "provisioning": [
                "schema": preparation.virtualization ? 2 : 1,
                "planDigest": preparation.plan.digest,
                "finalState": preparation.plan.finalState.rawValue,
                "journal": (preparation.virtualization ? provisioningV2JournalURL(bundle: reference.bundle) : provisioningJournalURL(bundle: reference.bundle)).path
            ]
        ]
        payload.merge(provisioningDisclosure(virtualization: preparation.virtualization)) { _, new in new }
        if let metadata = try? metadataPayload(bundle: reference.bundle) {
            payload["metadata"] = metadata
        }
        PommeProgressContext.sink?.complete(vm: name)
        return payload
    }

    /// Everything that distinguishes a fresh restore from a template clone.
    /// The plan built from it is identical in shape: a template-sourced VM
    /// records the template's restore image digest and runs the same
    /// Recovery bootstrap and verification phases.
    private struct ProvisioningSource {
        let version: String
        let build: String
        let restoreImageDigest: String
        let restoreImage: URL
        let profileDescriptor: PommeCreateRecoveryProfileDescriptor
        let hardwareModelData: Data
        let requirements: VZMacOSConfigurationRequirements?
        let diskSizeBytes: UInt64
        let templateBundlePath: String?
        let firstBootEligible: Bool
    }

    private static func restoreImageSource(
        arguments: CLIOptions,
        vmName: String
    ) async throws -> ProvisioningSource {
        PommeProgressContext.sink?.step(vm: vmName, "Resolving restore image")
        let restoreImageURL = try await resolveCreateRestoreImageURL(arguments, vmName: vmName)
        PommeProgressContext.sink?.step(vm: vmName, "Verifying restore image")
        let restoreQualification = try await qualifyRestoreImage(at: restoreImageURL)
        let canonicalRestoreImage = URL(fileURLWithPath: restoreQualification.identity.canonicalPath)
        let requirements = restoreQualification.requirements
        let disk = arguments.sizeOptions.diskSizeBytes
        guard disk > 0 else {
            throw RunnerError.invalidSize(flag: "--disk-size", value: String(disk))
        }
        return .init(
            version: restoreQualification.identity.version,
            build: restoreQualification.identity.build,
            restoreImageDigest: try restoreImageDigest(at: canonicalRestoreImage),
            restoreImage: canonicalRestoreImage,
            profileDescriptor: restoreQualification.identity.recoveryProfile,
            hardwareModelData: requirements.hardwareModel.dataRepresentation,
            requirements: requirements,
            diskSizeBytes: disk,
            templateBundlePath: nil,
            firstBootEligible: true
        )
    }

    private static func templateSource(
        templateName: String,
        arguments: CLIOptions
    ) throws -> ProvisioningSource {
        let manifest = try PommeTemplateStore.manifest(for: templateName)
        let bundle = try PommeTemplateStore.bundle(for: templateName)
        let requested = arguments.sizeOptions.diskSizeBytes
        guard requested == manifest.diskSizeBytes else {
            throw PommeTemplateError.diskSizeMismatch(template: manifest.diskSizeBytes, requested: requested)
        }
        let hardwareModelData = try Data(contentsOf: bundle.hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData),
              hardwareModel.isSupported
        else { throw RunnerError.invalidHardwareModel }
        return .init(
            version: manifest.version,
            build: manifest.build,
            restoreImageDigest: manifest.restoreImageDigest,
            restoreImage: URL(fileURLWithPath: manifest.restoreImagePath).standardizedFileURL,
            profileDescriptor: try PommeRecoveryProfileSelector.descriptor(
                version: manifest.version,
                build: manifest.build
            ),
            hardwareModelData: hardwareModelData,
            requirements: nil,
            diskSizeBytes: manifest.diskSizeBytes,
            templateBundlePath: bundle.rootURL.standardizedFileURL.path,
            firstBootEligible: !manifest.isProvisioned
        )
    }

    private static func prepareProvisioning(
        config: VMCreationConfigV1?,
        arguments: CLIOptions,
        reference: VMReference
    ) async throws -> ProvisioningPreparation {
        let vmName = reference.name ?? reference.bundle.rootURL.deletingPathExtension().lastPathComponent
        let source: ProvisioningSource
        if let templateName = arguments.templateName {
            source = try templateSource(templateName: templateName, arguments: arguments)
        } else {
            source = try await restoreImageSource(arguments: arguments, vmName: vmName)
        }
        let version = source.version
        let build = source.build
        let profileDescriptor = source.profileDescriptor
        if profileDescriptor.qualification == .experimental {
            warning(
                "Warning: Recovery support for macOS \(version) (\(build)) is experimental. Creation will attempt the observed-screen navigation and stop if it does not match.",
                vmName: vmName
            )
        }

        let memory = arguments.sizeOptions.memorySizeBytes
        try validateMemorySize(memory, requirements: source.requirements)
        let disk = source.diskSizeBytes
        let vmUUID = UUID()
        let ownership = try PommeVMOwnership(
            name: try validateVMName(reference.name ?? ""),
            uuid: vmUUID,
            bundlePath: reference.bundle.rootURL.standardizedFileURL.path
        )
        let executable = try runningExecutableIdentity()
        let profile = try PommeRecoveryProfileContract(descriptor: profileDescriptor)
        let normalAgent = try PommeAgentIdentity(
            identifier: PommeAgentInstall.label,
            executableDigest: executable.sha256,
            role: .normal
        )
        let recoveryAgent = try PommeAgentIdentity(
            identifier: "com.github.weswhet.pomme.recovery",
            executableDigest: executable.sha256,
            role: .recovery
        )
        let finalState: PommeProvisioningFinalState
        if let configBoot = config?.boot {
            finalState = provisioningFinalState(configBoot)
        } else if arguments.start {
            finalState = arguments.bootMode == .normal ? .normalRunning : .recoveryRunning
        } else {
            finalState = .stopped
        }
        let plan = try PommeProvisioningPlan(
            vm: ownership,
            restore: .init(version: version, build: build, restoreImageDigest: source.restoreImageDigest),
            display: .required,
            profile: profile,
            normalAgent: normalAgent,
            recoveryAgent: recoveryAgent,
            finalState: finalState
        )
        let machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
        let input = PommeProvisioningInput(
            restoreImagePath: source.restoreImage.path,
            memorySizeBytes: memory,
            diskSizeBytes: disk,
            hardwareModelData: source.hardwareModelData,
            machineIdentifierData: machineIdentifierData,
            agentCredentialAccount: PommeProvisioningCredentialReference.agentAccount,
            templateBundlePath: source.templateBundlePath
        )
        try input.validate(for: plan)
        let signer = try provisioningSigner(bundleURL: reference.bundle.rootURL)
        return .init(plan: plan, input: input, signer: signer, restoreImage: source.restoreImage,
                     virtualization: usesVirtualizationProvisioning(guestVersion: version,
                         firstBootEligible: source.firstBootEligible))
    }

    private static func provisioningFinalState(_ mode: VMCreationConfigV1.BootMode) -> PommeProvisioningFinalState {
        switch mode {
        case .none: .stopped
        case .normal: .normalRunning
        case .recovery: .recoveryRunning
        }
    }

    private static func makeLiveProvisioningEffects() -> PommeProvisioningEffects {
        .init(
            verifyOwnership: { expected in try await verifyProvisioningOwnership(expected) },
            install: { plan in try await installProvisioningVM(plan) },
            installRecoveryAgent: { plan in try await installRecoveryAgent(plan) },
            verifyNormalAgent: { plan in try await verifyNormalAgent(plan) },
            restoreFinalState: { plan in try await restoreProvisioningFinalState(plan) },
            recoveryRepair: { plan, state in try await repairProvisioningAgent(plan, finalState: state) }
        )
    }

    private static func provisioningV2Effects() -> PommeProvisioningV2Effects {
        if let injected = provisioningEffectsLock.withLock({ installedProvisioningV2Effects }) { return injected }
        return .init(
            verifyOwnership: { try await verifyProvisioningOwnership($0) },
            prepareOwnerReference: { plan in
                let reference = try captureProvisioningOwnerReference(plan: plan)
                _ = try PommeOwnerCredentialStore().readOrCreate(reference: reference)
                return reference
            },
            install: { try await installProvisioningVM($0) },
            provisionGuest: { try await provisionVirtualizationGuest($0) },
            bootstrapNormalAgent: { try await bootstrapNormalAgent($0) },
            verifyNormalAgent: { try await verifyFrameworkProvisioning($0) },
            restoreFinalState: { plan in
                let bundle = provisioningReference(for: plan).bundle
                var metadata = try metadataPayload(bundle: bundle)
                metadata.merge(try provisioningDisclosure(bundle: bundle)) { _, new in new }
                try writeMetadataPayload(metadata, bundle: bundle)
                try cleanupBootstrapWorkspace(plan: plan, completed: true)
                return try await restoreProvisioningFinalState(plan)
            }, provisionGuestWasDispatched: { try provisioningWasDispatched(plan: $0) })
    }

    static func captureProvisioningOwnerReference(plan: PommeProvisioningPlan) throws -> PommeOwnerCredentialReference {
        let bundle = provisioningReference(for: plan).bundle
        let machine = try PommeSSHBootstrap.privateRead(bundle.machineIdentifierURL,
            owner: geteuid(), allowedModes: [0o600, 0o644])
        let descriptor = open(bundle.diskImageURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PommeProvisioningV2Error.ownershipMismatch }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), !machine.isEmpty else {
            throw PommeProvisioningV2Error.ownershipMismatch
        }
        return try .init(vmUUID: plan.vm.uuid,
            machineIdentifierSHA256: PommeProvisioningDigest.sha256(machine),
            diskImageFileResourceID: "\(info.st_dev):\(info.st_ino)")
    }

    static func validateProvisioningOwnerReference(_ reference: PommeOwnerCredentialReference,
                                                    plan: PommeProvisioningPlan) throws {
        let captured = try captureProvisioningOwnerReference(plan: plan)
        guard reference.vmUUID == captured.vmUUID,
              reference.machineIdentifierSHA256 == captured.machineIdentifierSHA256,
              reference.diskImageFileResourceID == captured.diskImageFileResourceID,
              reference.account == captured.account, reference.service == captured.service,
              reference.ownershipMarker == captured.ownershipMarker else {
            throw PommeProvisioningV2Error.ownershipMismatch
        }
    }

    static func persistProvisioningDispatch(_ marker: PommeProvisioningDispatchMarker, at url: URL) throws {
        guard marker.attempt > 0, PommeProvisioningDigest.isSHA256(marker.planDigest) else {
            throw PommeProvisioningV2Error.invalidJournal
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PommeProvisioningV2Error.ambiguousProvisionGuest }
        defer { close(descriptor) }
        try PommeAgentFileTransaction.writeAll(descriptor, data: try JSONEncoder().encode(marker))
        guard fsync(descriptor) == 0 else { throw PommeProvisioningV2Error.ambiguousProvisionGuest }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PommeProvisioningV2Error.ambiguousProvisionGuest }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw PommeProvisioningV2Error.ambiguousProvisionGuest }
    }

    static func provisioningDispatchExists(at url: URL, vmUUID: UUID, planDigest: String) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw PommeProvisioningV2Error.ambiguousProvisionGuest }
            return false
        }
        do {
            let marker = try JSONDecoder().decode(PommeProvisioningDispatchMarker.self,
                from: PommeSSHBootstrap.privateRead(url, owner: geteuid(), allowedModes: [0o600]))
            guard marker.vmUUID == vmUUID, marker.planDigest == planDigest, marker.attempt > 0 else {
                throw PommeProvisioningV2Error.ambiguousProvisionGuest
            }
            return true
        } catch { throw PommeProvisioningV2Error.ambiguousProvisionGuest }
    }

    private static func provisioningWasDispatched(plan: PommeProvisioningPlan) throws -> Bool {
        let bundle = provisioningReference(for: plan).bundle
        return try provisioningDispatchExists(at: provisioningRoot(bundle: bundle)
            .appendingPathComponent("provisioning-v2.dispatched"), vmUUID: plan.vm.uuid, planDigest: plan.digest)
    }

    private static func provisionVirtualizationGuest(_ plan: PommeProvisioningPlan) async throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Provisioning macOS")
        let reference = provisioningReference(for: plan)
        let journal = try loadProvisioningV2(reference: reference)
        guard journal.plan == plan, let event = journal.events.last,
              event.kind == .intent, event.phase == .provisionGuest,
              let owner = journal.ownerReference,
              usesVirtualizationProvisioning(guestVersion: plan.restore.version, firstBootEligible: true),
              retainedRuntime(for: plan.vm.bundlePath) == nil,
              (try? runtimeRecord(for: reference.bundle)) == nil else {
            throw PommeProvisioningV2Error.invalidJournal
        }
        try validateProvisioningOwnerReference(owner, plan: plan)
        if let templatePath = try loadProvisioningInput(for: plan).templateBundlePath {
            guard try !PommeTemplateStore.manifest(in: BundleLayout(rootURL: URL(fileURLWithPath: templatePath))).isProvisioned else {
                throw PommeProvisioningV2Error.invalidJournal
            }
        }
        let password = try PommeOwnerCredentialStore().read(owner).password
        _ = try provisioningAgentCredential(for: plan)
        let marker = PommeProvisioningDispatchMarker(vmUUID: plan.vm.uuid, planDigest: plan.digest, attempt: event.attempt)
        let markerURL = provisioningRoot(bundle: reference.bundle).appendingPathComponent("provisioning-v2.dispatched")
        let intent = PommeMacGuestProvisioningIntent(password: password, guestMajor: 27,
            markDispatched: { try persistProvisioningDispatch(marker, at: markerURL) })
        let retained = try await startProvisioningRuntime(plan: plan, mode: .normal,
            attachAgent: true, guestProvisioningIntent: intent)
        retainRuntime(retained, for: plan.vm.bundlePath)
        return try receiptDigest("provision-guest", plan: plan, bundle: reference.bundle)
    }

    private static func verifyFrameworkProvisioning(_ plan: PommeProvisioningPlan) async throws -> PommeProvisioningV2Verification {
        enum Stage: String {
            case ownerReference, normalRebootAndAgent, authenticate, ownerProof, buddyPreferences, desktopProof
            case persistVolumeIdentity, remoteLoginOff, complete
        }
        var stage = Stage.ownerReference
        func checkpoint(_ next: Stage) {
            stage = next
            log("framework verification checkpoint stage=\(stage.rawValue)")
        }
        checkpoint(.ownerReference)
        do {
        let reference = provisioningReference(for: plan)
        let journal = try loadProvisioningV2(reference: reference)
        guard journal.plan == plan, journal.events.last?.phase == .verifyNormalAgent,
              journal.events.last?.kind == .intent, let owner = journal.ownerReference else {
            throw PommeProvisioningV2Error.invalidJournal
        }
        try validateProvisioningOwnerReference(owner, plan: plan)
        let password = try PommeOwnerCredentialStore().read(owner).password
        // A plain normal boot proves that automatic login survives the one-time
        // framework provisioning options and hands the VM to its durable helper.
        checkpoint(.normalRebootAndAgent)
        _ = try await verifyNormalAgent(plan)
        let normal = PommeSecurityNormalAgent(reference: reference,
            expectedExecutableDigest: plan.normalAgent.executableDigest)
        checkpoint(.authenticate)
        try await normal.authenticate(requirePrivateInput: true)
        checkpoint(.ownerProof)
        let preparation = PommeSecurityOwnerPreparation(
            identity: .init(username: "pomme", expectedVolumeGroupUUID:
                try provisioningRuntimeMetadata(for: plan).startupVolumeGroupUUID),
            executeGuest: { try normal.execute($0) },
            executePrivatePTY: { command, secret in
                try await runSecurityPrivatePTY(reference: reference,
                    expectedExecutableDigest: plan.normalAgent.executableDigest,
                    command: command, password: secret, provisioningVerification: true)
            },
            readBuddyPreferencesStatus: { try normal.buddyPreferencesStatus() },
            readDirectory: { try normal.localDirectory() },
            verifyPassword: { try normal.verifyDirectoryPassword(username: $0, password: $1) })
        let proof = try await preparation.verifyFrameworkProvisionedOwner(password: password,
            expectedGeneratedUID: owner.generatedUID)
        try await normal.verifyOwnerConsole(username: owner.account, uniqueID: proof.owner.uniqueID)
        checkpoint(.buddyPreferences)
        try await PommeBuddyPreferencesGate.failOpen("receipt", log: { warning($0, vmName: plan.vm.name) }) {
            _ = try await preparation.waitForBuddyPreferences(expected: proof.owner)
        }
        checkpoint(.desktopProof)
        // A newly provisioned desktop can take longer than an established security workflow.
        _ = try await normal.verifyConsoleLogin(
            username: owner.account, uniqueID: proof.owner.uniqueID,
            timeout: Constants.defaultRecoveryAgentTimeout)
        checkpoint(.persistVolumeIdentity)
        try persistProvisioningStartupVolumeGroup(proof.owner.startupVolumeGroupUUID, for: plan)
        // systemsetup's setter requires Full Disk Access on macOS 27. Stop
        // this temporary launchd service directly, then independently read back.
        checkpoint(.remoteLoginOff)
        try disableFrameworkRemoteLogin(execute: normal.execute)
        checkpoint(.complete)
        return .init(receiptDigest: try receiptDigest("verify-framework-owner", plan: plan, bundle: reference.bundle),
                     ownerReference: try owner.bindingGeneratedUID(proof.owner.generatedUID),
                     startupVolumeGroupUUID: proof.owner.startupVolumeGroupUUID)
        } catch {
            log("framework verification failed stage=\(stage.rawValue)")
            // These closed error types contain only fixed cases, enum labels,
            // and numeric exit statuses, never guest output or credentials.
            if let known = error as? PommeSecurityOwnerPreparationError { warning(known.localizedDescription) }
            else if let known = error as? PommeSecurityNormalAgentError { warning(known.localizedDescription) }
            else if let known = error as? PommeSecurityWorkflowError { warning(known.localizedDescription) }
            throw error
        }
    }

    static func disableFrameworkRemoteLogin(execute: (GuestCommandRequest) throws -> GuestCommandResult) throws {
        func run(_ path: String, _ arguments: [String]) throws -> GuestCommandResult {
            let result = try execute(.init(path: path, arguments: arguments, timeout: 30))
            guard result.exited, !result.detached, !result.timedOut, result.signal == nil,
                  result.exitCode != nil, !result.stdoutTruncated, !result.stderrTruncated else {
                throw PommeProvisioningV2Error.phaseFailed(.verifyNormalAgent)
            }
            return result
        }
        let service = "system/com.openssh.sshd"
        guard try run("/bin/launchctl", ["disable", service]).exitCode == 0 else {
            throw PommeProvisioningV2Error.phaseFailed(.verifyNormalAgent)
        }
        // Already-unloaded services are valid on resume; the readbacks below
        // determine success independently of bootout's status.
        _ = try run("/bin/launchctl", ["bootout", service])
        let setting = try run("/usr/sbin/systemsetup", ["-getremotelogin"])
        let job = try run("/bin/launchctl", ["print", service])
        guard setting.exitCode == 0,
              String(decoding: setting.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Remote Login: Off",
              job.exitCode != 0,
              String(decoding: job.stderr, as: UTF8.self).contains("Could not find service \"com.openssh.sshd\"") else {
            throw PommeProvisioningV2Error.phaseFailed(.verifyNormalAgent)
        }
    }

    static func bootstrapProcessDiagnostic(vmName: String) -> (String) -> Void {
        { message in
            if PommeRecoveryDebugContext.screenshotsEnabled { log(message, vmName: vmName) }
        }
    }

    /// A bounded private subprocess channel. Raw subprocess diagnostics and
    /// input bytes never enter logs or errors, including launch failures. Debug
    /// output accepts only a closed operation and outcome plus the deadline.
    static func runBootstrapProcess(_ executable: String, arguments: [String],
        environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        input: Data? = nil, timeout: TimeInterval = 30,
        operation: PommeBootstrapDiagnostics.Operation? = nil,
        diagnostic: (String) -> Void = { message in
            if PommeRecoveryDebugContext.screenshotsEnabled { log(message) }
        }) throws -> Data {
        func report(_ outcome: PommeBootstrapDiagnostics.Outcome) {
            guard let operation else { return }
            diagnostic(PommeBootstrapDiagnostics.process(operation, outcome: outcome, timeout: timeout))
        }
        report(.started)
        do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let incoming = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = incoming
        do { try process.run() } catch { throw PommeSSHBootstrapError.processLaunchFailed }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try incoming.fileHandleForWriting.write(contentsOf: input ?? Data())
        try incoming.fileHandleForWriting.close()
        try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw PommeSSHBootstrapError.invalid }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                guard bytes.count + count <= 64 * 1024 else { throw PommeSSHBootstrapError.invalid }
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0, !process.isRunning { break }
            else if count < 0, errno != EAGAIN, errno != EINTR { throw PommeSSHBootstrapError.invalid }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PommeSSHBootstrapError.processTimedOut }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard process.terminationStatus == 0 else { throw PommeSSHBootstrapError.processExited(process.terminationStatus) }
        report(.succeeded)
        return bytes
        } catch {
            switch error as? PommeSSHBootstrapError {
            case .processLaunchFailed: report(.launchFailed)
            case .processTimedOut: report(.timedOut)
            case .processExited: report(.exited)
            default: report(.channelFailed)
            }
            throw error
        }
    }

    private static func bootstrapAgentMatches(_ status: GuestAgentStatusV1,
                                               plan: PommeProvisioningPlan) throws -> Bool {
        guard status.connection == .connected else { return false }
        guard status.role == .normal, status.protocolVersion == plan.normalAgent.protocolVersion,
              status.executableDigest == plan.normalAgent.executableDigest,
              supportsProvisioningAgentCapabilities(status.capabilities),
              status.capabilities.contains("remoteLogin.set") else { throw PommeSSHBootstrapError.invalid }
        return true
    }

    private static func bootstrapNormalAgent(_ plan: PommeProvisioningPlan) async throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Bootstrapping Pomme agent for normal boot")
        var diagnostics = PommeBootstrapDiagnostics()
        log(diagnostics.checkpoint(.started))
        do {
        let reference = provisioningReference(for: plan)
        let journal = try loadProvisioningV2(reference: reference)
        guard journal.plan == plan, journal.events.last?.phase == .bootstrapNormalAgent,
              journal.events.last?.kind == .intent, let owner = journal.ownerReference,
              let provision = journal.events.first(where: { $0.phase == .provisionGuest && $0.kind == .receipt }) else {
            throw PommeProvisioningV2Error.invalidJournal
        }
        log(diagnostics.checkpoint(.journalValidated))
        try validateProvisioningOwnerReference(owner, plan: plan)
        log(diagnostics.checkpoint(.ownerReferenceVerified))
        let root = provisioningRoot(bundle: reference.bundle)
        let marker = try JSONDecoder().decode(PommeProvisioningDispatchMarker.self,
            from: PommeSSHBootstrap.privateRead(root.appendingPathComponent("provisioning-v2.dispatched"),
                owner: geteuid(), allowedModes: [0o600]))
        guard marker == .init(vmUUID: plan.vm.uuid, planDigest: plan.digest, attempt: provision.attempt) else {
            throw PommeProvisioningV2Error.ambiguousProvisionGuest
        }
        log(diagnostics.checkpoint(.dispatchMarkerVerified))
        let token = Data(try existingProvisioningAgentCredential(for: plan).utf8)
        log(diagnostics.checkpoint(.agentCredentialAvailable))
        let retained: PommeRetainedRuntime
        if let existing = retainedRuntime(for: plan.vm.bundlePath) { retained = existing }
        else {
            guard (try? runtimeRecord(for: reference.bundle)) == nil else { throw PommeSSHBootstrapError.invalid }
            log(diagnostics.checkpoint(.runtimeRecordAbsent))
            log(diagnostics.checkpoint(.runtimeStartAttempted))
            retained = try await startProvisioningRuntime(plan: plan, mode: .normal, attachAgent: true)
            log(diagnostics.checkpoint(.runtimeStartSucceeded))
            retainRuntime(retained, for: plan.vm.bundlePath)
        }
        guard let coordinator = retained.coordinator, retained.mode == .normal else { throw PommeSSHBootstrapError.invalid }
        if try await bootstrapAgentMatches(coordinator.status(), plan: plan) {
            log(diagnostics.checkpoint(.agentConnected))
            try await verifyBootstrapBuddyPreferencesPrerequisites(coordinator: coordinator,
                expectedGeneratedUID: owner.generatedUID)
            try cleanupBootstrapWorkspace(plan: plan, completed: false)
            return try receiptDigest("bootstrap-normal-agent", plan: plan, bundle: reference.bundle)
        }
        let workspace = root.appendingPathComponent("ssh-bootstrap", isDirectory: true)
        if !FileManager.default.fileExists(atPath: workspace.path) {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        var workspaceInfo = stat()
        guard lstat(workspace.path, &workspaceInfo) == 0, workspaceInfo.st_mode & S_IFMT == S_IFDIR,
              workspaceInfo.st_uid == geteuid(), workspaceInfo.st_mode & 0o777 == 0o700,
              workspace.resolvingSymlinksInPath().path == workspace.path else { throw PommeSSHBootstrapError.invalid }
        guard Set(try FileManager.default.contentsOfDirectory(atPath: workspace.path))
            .isSubset(of: ["known_hosts", "owner-reference.json", "request.json", "pomme", "agent.token"]) else {
            throw PommeSSHBootstrapError.invalid
        }
        let knownHosts = workspace.appendingPathComponent("known_hosts")
        log(diagnostics.checkpoint(.workspaceVerified))
        let ownerFile = workspace.appendingPathComponent("owner-reference.json")
        try persistBootstrapOwnerReference(owner, at: ownerFile)
        let identity = try runningExecutableIdentity()
        try PommeAgentArtifactStore.Dependencies().verifyCodeSignature(identity.url)
        let machine = try loadProvisioningInput(for: plan).machineIdentifierData
        let mac = stableVMMACAddress(machineIdentifierData: machine)
        let deadline = ProcessInfo.processInfo.systemUptime + PommeSSHBootstrap.firstBootReadinessTimeout
        var discovered: (address: String, key: Data)?
        log(diagnostics.checkpoint(.discoveryStarted))
        while discovered == nil {
            do {
                discovered = try PommeSSHBootstrap.discoverHostKey(stableMAC: mac, readLeases: {
                    try PommeSSHBootstrap.readLeases()
                }, scan: { ip in
                    let output = try runBootstrapProcess("/usr/bin/ssh-keyscan", arguments: ["-T", "5", "-t", "ed25519", ip],
                        operation: diagnostics.nextHostKeyScanOperation(),
                        diagnostic: bootstrapProcessDiagnostic(vmName: plan.vm.name))
                    return String(decoding: output, as: UTF8.self)
                }, onEvent: { event in
                    switch event {
                    case .candidateSelected:
                        if let message = diagnostics.discoveryCandidateCheckpoint() { log(message) }
                    case .keyscanSucceeded: log(diagnostics.checkpoint(.discoveryKeyscanSucceeded))
                    case .leaseVerified: log(diagnostics.checkpoint(.discoveryLeaseVerified))
                    }
                })
            } catch {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw PommeSSHBootstrapError.invalid }
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard let discovered else { throw PommeSSHBootstrapError.invalid }
        let address = discovered.address
        try PommeSSHBootstrap.pinHostKey(discovered.key, at: knownHosts)
        log(diagnostics.checkpoint(.keyPinned))
        func authenticatedProcess(_ executable: String, operation: PommeBootstrapDiagnostics.Operation,
            arguments: [String], sudoSuffix: Data? = nil, timeout: TimeInterval = 30) throws -> Data {
            // Recheck the DHCP target immediately before every credential-bearing
            // operation, including retries and the first connection after keyscan.
            let current = try PommeSSHBootstrap.address(leases: PommeSSHBootstrap.readLeases(), stableMAC: mac)
            guard current == address else { throw PommeSSHBootstrapError.invalid }
            var stdin = Data()
            defer { stdin.resetBytes(in: 0..<stdin.count); stdin.removeAll() }
            if let sudoSuffix {
                stdin = Data(try PommeOwnerCredentialStore().read(owner).password.utf8)
                stdin.append(10); stdin.append(sudoSuffix)
            }
            return try runBootstrapProcess(executable, arguments: arguments,
                environment: PommeBootstrapAskpass.environment(executable: identity.url, ownerReference: ownerFile),
                input: stdin, timeout: timeout, operation: operation,
                diagnostic: bootstrapProcessDiagnostic(vmName: plan.vm.name))
        }
        let uidBytes = try authenticatedProcess("/usr/bin/ssh", operation: .sshAuthenticationAndUIDVerification, arguments: PommeSSHBootstrap.arguments(
            address: address, knownHosts: knownHosts, command: "/usr/bin/id -u"),
            timeout: PommeSSHBootstrap.firstAuthenticationTimeout)
        guard let uid = UInt32(String(decoding: uidBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              uid >= 501 else { throw PommeSSHBootstrapError.invalid }
        log(diagnostics.checkpoint(.sshUIDVerified))
        let requestURL = workspace.appendingPathComponent("request.json")
        let request: PommeBootstrapRequest
        if FileManager.default.fileExists(atPath: requestURL.path) {
            request = try JSONDecoder().decode(PommeBootstrapRequest.self,
                from: PommeSSHBootstrap.privateRead(requestURL, owner: geteuid(), allowedModes: [0o600]))
        } else {
            request = try .init(vmUUID: plan.vm.uuid, requestID: UUID(), planSHA256: plan.digest,
                executableSHA256: plan.normalAgent.executableDigest,
                expiresAt: Int64(Date().timeIntervalSince1970) + 3600, stagingOwner: uid, token: token)
            try persistExactBootstrapFile(try JSONEncoder().encode(request), at: requestURL, mode: 0o600)
        }
        try request.authenticate(token: token, vmUUID: plan.vm.uuid,
            planSHA256: plan.digest, executableSHA256: plan.normalAgent.executableDigest)
        guard request.stagingOwner == uid else { throw PommeSSHBootstrapError.invalid }
        log(diagnostics.checkpoint(.requestVerified))
        let artifact: URL
        if identity.sha256 == plan.normalAgent.executableDigest {
            try PommeAgentArtifactStore.Dependencies().verifyCodeSignature(identity.url)
            artifact = identity.url
        } else {
            artifact = try PommeAgentArtifactStore(rootURL: applicationSupportRoot(create: false))
                .resolve(sha256: plan.normalAgent.executableDigest)
        }
        let executable = try PommeAgentFileTransaction.readRegular(artifact,
            maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes)
        guard PommeBootstrapRequest.digest(executable) == plan.normalAgent.executableDigest else { throw PommeSSHBootstrapError.invalid }
        try persistExactBootstrapFile(executable, at: workspace.appendingPathComponent("pomme"), mode: 0o700)
        let remote = "/private/var/tmp/pomme-bootstrap-\(request.requestID.uuidString.lowercased())"
        let mkdir = "umask 077; if [ -e '\(remote)' ] || [ -L '\(remote)' ]; then [ ! -L '\(remote)' ] && [ -d '\(remote)' ] && [ \"$(/usr/bin/stat -f '%u:%Lp' '\(remote)')\" = '\(uid):700' ] && [ \"$(/bin/ls -A '\(remote)')\" = \"$(/usr/bin/printf 'pomme\\nrequest.json')\" ] && /usr/bin/printf existing; else /bin/mkdir '\(remote)' && /usr/bin/printf new; fi"
        let stagingState = try authenticatedProcess("/usr/bin/ssh", operation: .stagingDirectoryPreparation, arguments: PommeSSHBootstrap.arguments(
            address: address, knownHosts: knownHosts, command: mkdir))
        guard stagingState == Data("new".utf8) || stagingState == Data("existing".utf8) else { throw PommeSSHBootstrapError.invalid }
        for name in ["pomme", "request.json"] {
            let local = workspace.appendingPathComponent(name)
            let mode: mode_t = name == "pomme" ? 0o700 : 0o600
            let bytes = try PommeSSHBootstrap.privateRead(local, owner: geteuid(), allowedModes: [mode],
                maximum: PommeRecoveryStagingBuilder.maximumExecutableBytes)
            let hash = PommeBootstrapRequest.digest(bytes)
            let path = remote + "/" + name
            if stagingState == Data("existing".utf8) {
                let check = "[ ! -L '\(path)' ] && [ -f '\(path)' ] && [ \"$(/usr/bin/stat -f '%u:%Lp:%l' '\(path)')\" = '\(uid):\(String(mode, radix: 8)):1' ] && [ \"$(/usr/bin/shasum -a 256 '\(path)' | /usr/bin/cut -d ' ' -f 1)\" = '\(hash)' ]"
                _ = try authenticatedProcess("/usr/bin/ssh",
                    operation: name == "pomme" ? .stagedAgentVerification : .stagedManifestVerification,
                    arguments: PommeSSHBootstrap.arguments(
                    address: address, knownHosts: knownHosts, command: check))
            } else {
                _ = try authenticatedProcess("/usr/bin/scp",
                    operation: name == "pomme" ? .agentArtifactTransfer : .requestManifestTransfer,
                    arguments: PommeSSHBootstrap.scpArguments(
                    address: address, knownHosts: knownHosts, source: local, requestID: request.requestID),
                    timeout: 120)
            }
        }
        let renewed = try request.renewed(token: token, now: Date(), vmUUID: plan.vm.uuid, planSHA256: plan.digest,
            executableSHA256: plan.normalAgent.executableDigest, requestID: request.requestID, stagingOwner: uid)
        // Renew only in the root-private stream. The authenticated original
        // stays unchanged at both endpoints, so interruption cannot strand two
        // different durable manifests or a half-committed renewal file.
        let stagedRequestHash = PommeBootstrapRequest.digest(try PommeSSHBootstrap.privateRead(requestURL, owner: geteuid(), allowedModes: [0o600]))
        let renewedLine = try JSONEncoder().encode(renewed).base64EncodedString()
        try renewed.verify(token: token, now: Date(), vmUUID: plan.vm.uuid, planSHA256: plan.digest, executableSHA256: plan.normalAgent.executableDigest)
        log(diagnostics.checkpoint(.stagingVerified))
        log(diagnostics.checkpoint(.installerInvoked))
        _ = try authenticatedProcess("/usr/bin/ssh", operation: .installerInvocation, arguments: PommeSSHBootstrap.arguments(
            address: address, knownHosts: knownHosts, command: PommeSSHBootstrap.installerCommand(request: renewed, stagedRequestSHA256: stagedRequestHash)),
            sudoSuffix: Data((String(decoding: token, as: UTF8.self) + "\n" + renewedLine + "\n").utf8), timeout: 120)
        let agentDeadline = ProcessInfo.processInfo.systemUptime + 120
        while !(try await bootstrapAgentMatches(coordinator.status(), plan: plan)) {
            guard ProcessInfo.processInfo.systemUptime < agentDeadline else { throw PommeSSHBootstrapError.invalid }
            try await Task.sleep(for: .milliseconds(250))
        }
        // Keep the authenticated original request and host-key pin for replay.
        log(diagnostics.checkpoint(.agentConnected))
        try await verifyBootstrapBuddyPreferencesPrerequisites(coordinator: coordinator,
            expectedUID: uid, expectedGeneratedUID: owner.generatedUID)
        // The guest received its token only through the root-private stdin path.
        try cleanupBootstrapWorkspace(plan: plan, completed: false)
        return try receiptDigest("bootstrap-normal-agent", plan: plan, bundle: reference.bundle)
        } catch {
            log(diagnostics.failure())
            if let processError = error as? PommeSSHBootstrapError {
                switch processError {
                case .processLaunchFailed, .processTimedOut, .processExited:
                    warning(processError.localizedDescription)
                case .invalid: break
                }
            }
            throw error
        }
    }

    /// Bootstrap proves capability and owner identity. Maintenance waits for the
    /// owner console after the planned reboot and is verified during owner completion.
    private static func verifyBootstrapBuddyPreferencesPrerequisites(
        coordinator: PommeAgentVSOCKCoordinator,
        expectedUID: UInt32? = nil, expectedGeneratedUID: UUID?
    ) async throws {
        // The owner is proved again by SSH UID verification before this and by
        // the full owner proof in verifyNormalAgent after it.
        try await PommeBuddyPreferencesGate.failOpen("bootstrap prerequisites", log: { warning($0) }) {
            try await requireBootstrapBuddyPreferencesPrerequisites(coordinator: coordinator,
                expectedUID: expectedUID, expectedGeneratedUID: expectedGeneratedUID)
        }
    }

    private static func requireBootstrapBuddyPreferencesPrerequisites(
        coordinator: PommeAgentVSOCKCoordinator,
        expectedUID: UInt32?, expectedGeneratedUID: UUID?
    ) async throws {
        let status = await coordinator.status()
        guard status.capabilities.contains("buddy.preferences.status") else {
            throw PommeSecurityOwnerPreparationError.buddyPreferencesAgentRequired
        }
        let currentOwner: PommeBuddyPreferencesOwner
        if status.capabilities.contains(PommeGuestDirectory.readUsersOperation) {
            // Native OpenDirectory read in the agent: no guest process.
            let response = try await coordinator.performCorrelated(
                operation: PommeGuestDirectory.readUsersOperation, payload: .object([:]))
            currentOwner = try PommeBootstrapBuddyPreferences.owner(
                from: PommeGuestDirectorySnapshot(result: response.result.publicValue))
        } else {
        currentOwner = try await PommeBootstrapBuddyPreferences.readOwner { request in
            try request.validate()
            let result = try await PommeForegroundExecution.run(
                payload: JSONValue(any: request.agentPayload()), timeout: request.timeout,
                perform: { operation, payload in
                    try await coordinator.performCorrelated(operation: operation, payload: payload)
                },
                sendStream: { jobID, stream, data in
                    try await coordinator.sendStream(jobID: jobID, stream: stream,
                        requestID: UUID(), data: data, dimensions: nil, signal: nil)
                })
            let response = try JSONSerialization.jsonObject(
                with: Data(foregroundResultJSON(result).utf8))
            guard let object = response as? [String: Any] else {
                throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
            }
            return try PommeSecurityNormalAgent.decodeCompletedCommand(object)
        }
        }
        guard expectedUID == nil || currentOwner.uid == expectedUID,
              expectedGeneratedUID == nil || UUID(uuidString: currentOwner.generatedUID) == expectedGeneratedUID else {
            throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
        }
    }

    private static func cleanupBootstrapWorkspace(plan: PommeProvisioningPlan, completed: Bool) throws {
        let bundle = provisioningReference(for: plan).bundle
        let workspace = provisioningRoot(bundle: bundle).appendingPathComponent("ssh-bootstrap")
        var info = stat()
        if lstat(workspace.path, &info) != 0 {
            guard errno == ENOENT else { throw PommeSSHBootstrapError.invalid }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
              workspace.resolvingSymlinksInPath().path == workspace.path else { throw PommeSSHBootstrapError.invalid }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: workspace.path))
        guard names.isSubset(of: ["pomme", "agent.token", "request.json", "known_hosts", "owner-reference.json"]) else {
            throw PommeSSHBootstrapError.invalid
        }
        let journal = try loadProvisioningV2(reference: provisioningReference(for: plan))
        let token = Data(try existingProvisioningAgentCredential(for: plan).utf8)
        var removals: [URL] = []
        for name in names.sorted() {
            let url = workspace.appendingPathComponent(name)
            let data = try PommeSSHBootstrap.privateRead(url, owner: geteuid(),
                allowedModes: [name == "pomme" ? 0o700 : 0o600], maximum: PommeRecoveryStagingBuilder.maximumExecutableBytes)
            switch name {
            case "pomme":
                guard PommeBootstrapRequest.digest(data) == plan.normalAgent.executableDigest else { throw PommeSSHBootstrapError.invalid }
            case "agent.token":
                guard data == token else { throw PommeSSHBootstrapError.invalid }
            case "owner-reference.json":
                let reference = try JSONDecoder().decode(PommeOwnerCredentialReference.self, from: data)
                try validateProvisioningOwnerReference(reference, plan: plan)
            case "request.json":
                let request = try JSONDecoder().decode(PommeBootstrapRequest.self, from: data)
                // Cleanup authenticates identity without extending request lifetime.
                try request.verify(token: token, now: Date(timeIntervalSince1970: TimeInterval(request.expiresAt - 1)),
                    vmUUID: plan.vm.uuid, planSHA256: plan.digest, executableSHA256: plan.normalAgent.executableDigest)
            case "known_hosts":
                let text = String(decoding: data, as: UTF8.self)
                guard let ip = text.split(whereSeparator: \.isWhitespace).first,
                      try PommeSSHBootstrap.scannedHostKey(text, address: String(ip)) == data else { throw PommeSSHBootstrapError.invalid }
            default: throw PommeSSHBootstrapError.invalid
            }
            if completed || name == "pomme" || name == "agent.token" { removals.append(url) }
        }
        if completed {
            guard journal.events.contains(where: { $0.phase == .verifyNormalAgent && $0.kind == .receipt }) else {
                throw PommeProvisioningV2Error.invalidJournal
            }
        }
        for url in removals { guard unlink(url.path) == 0 else { throw PommeSSHBootstrapError.invalid } }
        if completed { guard rmdir(workspace.path) == 0 else { throw PommeSSHBootstrapError.invalid } }
    }

    /// JSON key order is not identity: a resumed process must accept the same
    /// signed owner reference without rewriting an existing private file.
    static func persistBootstrapOwnerReference(_ owner: PommeOwnerCredentialReference, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(owner)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            guard errno == EEXIST else { throw PommeSSHBootstrapError.invalid }
            let existing = try PommeSSHBootstrap.privateRead(url, owner: geteuid(), allowedModes: [0o600])
            guard let decoded = try? JSONDecoder().decode(PommeOwnerCredentialReference.self, from: existing),
                  decoded == owner else { throw PommeSSHBootstrapError.invalid }
            return
        }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw PommeSSHBootstrapError.invalid }
        try PommeAgentFileTransaction.writeAll(fd, data: data)
        guard fsync(fd) == 0 else { throw PommeSSHBootstrapError.invalid }
    }

    static func persistExactBootstrapFile(_ data: Data, at url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        if fd < 0 {
            guard errno == EEXIST,
                  try PommeSSHBootstrap.privateRead(url, owner: geteuid(), allowedModes: [mode],
                    maximum: max(data.count, 1)) == data else { throw PommeSSHBootstrapError.invalid }
            return
        }
        defer { close(fd) }
        guard fchmod(fd, mode) == 0 else { throw PommeSSHBootstrapError.invalid }
        try PommeAgentFileTransaction.writeAll(fd, data: data)
        guard fsync(fd) == 0 else { throw PommeSSHBootstrapError.invalid }
    }

    private static func resolveCreateRestoreImageURL(_ arguments: CLIOptions, vmName: String) async throws -> URL {
        if let path = arguments.restoreImagePath {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard isRegularFile(url) else {
                throw RunnerError.hostCommandFailed("The restore image does not exist: \(url.path)")
            }
            return url
        }
        let selection = arguments.restoreImageVersionSelection ?? "latest"
        return try await downloadIPSWFirmware(
            selection: selection,
            deviceIdentifier: arguments.ipswDeviceIdentifier,
            vmName: vmName
        ).url
    }

    /// Reads a local restore image without starting creation. This is used only
    /// for direct-create dry runs; execution repeats the check immediately
    /// before it writes a provisioning bundle.
    static func inspectLocalRestoreImage(path: String) async throws -> PommeLocalRestoreImageIdentity {
        try await qualifyRestoreImage(at: URL(fileURLWithPath: path)).identity
    }

    private static func qualifyRestoreImage(at url: URL) async throws -> RestoreImageQualification {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard isRegularFile(canonicalURL) else {
            throw RunnerError.hostCommandFailed("The restore image does not exist: \(canonicalURL.path)")
        }
        let image = try await loadRestoreImage(from: canonicalURL)
        let version = "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)"
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw RunnerError.noSupportedConfiguration
        }
        let identity = PommeLocalRestoreImageIdentity(
            canonicalPath: canonicalURL.path,
            version: version,
            build: image.buildVersion,
            recoveryProfile: try PommeRecoveryProfileSelector.descriptor(
                version: version,
                build: image.buildVersion
            ),
            minimumMemoryBytes: requirements.minimumSupportedMemorySize
        )
        return .init(identity: identity, requirements: requirements)
    }

    /// Every macOS restore image so far has reported this guest minimum. It
    /// is applied before any download so a too-small request fails at once,
    /// and the image's own value is applied as well whenever the image is
    /// present.
    static let provisionalGuestMemoryFloorBytes: UInt64 = 4_294_967_296

    static func validateProvisionalMemoryFloor(_ memorySizeBytes: UInt64) throws {
        try validateMemorySize(memorySizeBytes, requirements: nil)
        guard memorySizeBytes >= provisionalGuestMemoryFloorBytes else {
            throw RunnerError.memoryBelowProvisionalFloor(
                requested: memorySizeBytes,
                minimum: provisionalGuestMemoryFloorBytes
            )
        }
    }

    /// Where a dry run can find a restore image without downloading one.
    enum DryRunRestoreSource {
        case localImage(path: String)
        case firmware(IPSWMEFirmware)
        case template(PommeTemplateManifest)
    }

    struct DryRunMemoryCheck: Equatable {
        let minimumBytes: UInt64
        let provisional: Bool
        let restoreImagePath: String?

        var payload: [String: Any] {
            var value: [String: Any] = ["bytes": minimumBytes, "provisional": provisional]
            if let restoreImagePath { value["restoreImage"] = restoreImagePath }
            return value
        }
    }

    /// Applies the memory checks a real create would apply, without the
    /// download. The floor runs first and offline; the image's exact minimum
    /// follows when the image is already on disk.
    static func dryRunMemoryCheck(
        memoryBytes: UInt64,
        source: DryRunRestoreSource,
        vmName: String
    ) async throws -> DryRunMemoryCheck {
        try validateProvisionalMemoryFloor(memoryBytes)
        let localPath: String?
        switch source {
        case .localImage(let path):
            localPath = path
        case .firmware(let firmware):
            localPath = (try? cachedRestoreImageURL(for: firmware))?.path
        case .template(let manifest):
            localPath = isRegularFile(URL(fileURLWithPath: manifest.restoreImagePath)) ? manifest.restoreImagePath : nil
        }
        guard let localPath else {
            log("Memory check is provisional: the restore image is not present locally, so only the \(byteCountText(provisionalGuestMemoryFloorBytes)) floor was applied.", vmName: vmName)
            return DryRunMemoryCheck(minimumBytes: provisionalGuestMemoryFloorBytes, provisional: true, restoreImagePath: nil)
        }
        let identity = try await inspectLocalRestoreImage(path: localPath)
        try validateMemorySize(memoryBytes, minimumGuestMemory: identity.minimumMemoryBytes)
        return DryRunMemoryCheck(minimumBytes: identity.minimumMemoryBytes, provisional: false, restoreImagePath: identity.canonicalPath)
    }

    /// The completed cache file for a catalog entry, if one exists. This is
    /// the same rule the download uses to skip a fetch, kept in one place so
    /// a dry run and the real create agree on what "already present" means.
    static func cachedRestoreImageURL(for firmware: IPSWMEFirmware) throws -> URL? {
        let directory = try applicationSupportRoot().appendingPathComponent(Constants.restoreImageDirectoryName, isDirectory: true)
        return cachedRestoreImageURL(for: firmware, in: directory)
    }

    static func cachedRestoreImageURL(for firmware: IPSWMEFirmware, in directory: URL) -> URL? {
        guard let expectedSize = firmware.filesize, expectedSize > 0,
              let remoteURL = URL(string: firmware.url) else { return nil }
        let fileName = remoteURL.lastPathComponent.isEmpty
            ? "macOS-\(firmware.version)-\(firmware.buildid).ipsw"
            : remoteURL.lastPathComponent
        let destination = directory.appendingPathComponent(fileName)
        return fileSize(destination) == expectedSize ? destination : nil
    }

    private static func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success(let image): continuation.resume(returning: image)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func validateMemorySize(
        _ memorySizeBytes: UInt64,
        requirements: VZMacOSConfigurationRequirements?
    ) throws {
        try validateMemorySize(memorySizeBytes, minimumGuestMemory: requirements?.minimumSupportedMemorySize)
    }

    static func validateMemorySize(_ memorySizeBytes: UInt64, minimumGuestMemory: UInt64?) throws {
        let minimum = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maximum = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        guard memorySizeBytes >= minimum, memorySizeBytes <= maximum else {
            throw RunnerError.memoryOutsideHostLimits(
                requested: memorySizeBytes,
                minimum: minimum,
                maximum: maximum
            )
        }
        if let minimumGuestMemory, memorySizeBytes < minimumGuestMemory {
            throw RunnerError.memoryBelowGuestMinimum(
                requested: memorySizeBytes,
                minimum: minimumGuestMemory
            )
        }
    }

    private static func sha256File(_ url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { try throwPOSIX("open") }
        defer { Darwin.close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 { try throwPOSIX("read") }
            if count == 0 { break }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes.prefix(count)))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// File identity that changes whenever the restore image is replaced or
    /// rewritten. `ctime` cannot be reset by `touch`, so a same-size,
    /// same-mtime substitution still invalidates a cached digest.
    private struct RestoreImageIdentity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(path: String) throws {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw PommeProvisioningError.invalidPlan
            }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private struct RestoreImageDigestRecord: Codable, Equatable {
        let identity: RestoreImageIdentity
        let sha256: String
    }

    private static let restoreImageDigestLock = NSLock()
    nonisolated(unsafe) private static var restoreImageDigestCache: [String: RestoreImageDigestRecord] = [:]

    private static func restoreImageDigestSidecarURL(for url: URL) -> URL {
        url.appendingPathExtension("sha256.json")
    }

    /// The SHA-256 of a restore image, hashed at most once per file identity.
    /// A 20 GB IPSW takes ~12 s to hash; creation previously did it twice
    /// (plan, then install verification) and again on every later create.
    /// The digest is remembered in-process and in a sidecar next to the image,
    /// and either is trusted only while the file's identity is unchanged.
    static func restoreImageDigest(at url: URL) throws -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let identity = try RestoreImageIdentity(path: canonical.path)
        let cached = restoreImageDigestLock.withLock { restoreImageDigestCache[canonical.path] }
        if let cached, cached.identity == identity { return cached.sha256 }
        let sidecar = restoreImageDigestSidecarURL(for: canonical)
        if let data = try? Data(contentsOf: sidecar),
           let record = try? JSONDecoder().decode(RestoreImageDigestRecord.self, from: data),
           record.identity == identity,
           PommeProvisioningDigest.isSHA256(record.sha256) {
            restoreImageDigestLock.withLock { restoreImageDigestCache[canonical.path] = record }
            return record.sha256
        }
        let digest = try sha256File(canonical)
        // Re-read the identity: a file rewritten while hashing must not bind
        // its new identity to the old bytes' digest.
        let identityAfter = try RestoreImageIdentity(path: canonical.path)
        guard identityAfter == identity else { return digest }
        let record = RestoreImageDigestRecord(identity: identity, sha256: digest)
        restoreImageDigestLock.withLock { restoreImageDigestCache[canonical.path] = record }
        if let encoded = try? JSONEncoder().encode(record) {
            try? encoded.write(to: sidecar, options: .atomic)
        }
        return digest
    }

    /// Binds an installer input to the immutable restore-image digest recorded
    /// in the provisioning plan. Resume must reject a same-version image whose
    /// bytes changed after planning.
    static func verifyRestoreImageDigest(at url: URL, expected: String) throws {
        guard PommeProvisioningDigest.isSHA256(expected),
              try restoreImageDigest(at: url) == expected
        else { throw PommeProvisioningError.invalidPlan }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1
    }

    private static func randomAgentSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RunnerError.hostCommandFailed("Pomme could not create the VM agent credential.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Serialize persistent-agent credential operations. SecItem is blocking
    /// IPC, so callers must not use this synchronous boundary on the UI thread.
    private static let provisioningCredentialQueue = DispatchQueue(
        label: "com.github.weswhet.pomme.provisioning-credential"
    )

    private static func loadProvisioningAgentCredential(
        vmUUID: UUID,
        account: String
    ) throws -> String {
        try provisioningCredentialQueue.sync {
            try PommeAgentCredentialStore().read(vmUUID: vmUUID, account: account)
        }
    }

    /// Returns the UUID-scoped persistent-agent credential, creating it only
    /// after the Recovery-install phase has journaled its intent. The secret
    /// is never returned to public output and is not Codable.
    static func provisioningAgentCredential(for plan: PommeProvisioningPlan) throws -> String {
        let input = try loadProvisioningInput(for: plan)
        return try provisioningCredentialQueue.sync {
            try PommeAgentCredentialStore().readOrCreate(
                vmUUID: plan.vm.uuid,
                account: input.agentCredentialAccount,
                generate: randomAgentSecret
            )
        }
    }

    /// Reads the existing credential without creating or replacing it. Normal
    /// agent authentication uses this strict path so a missing credential
    /// cannot be mistaken for a successful Recovery installation.
    private static func existingProvisioningAgentCredential(
        for plan: PommeProvisioningPlan
    ) throws -> String {
        let input = try loadProvisioningInput(for: plan)
        return try loadProvisioningAgentCredential(
            vmUUID: plan.vm.uuid,
            account: input.agentCredentialAccount
        )
    }

    /// Remove exactly one UUID-scoped persistent-agent credential. Not-found is
    /// an idempotent cleanup success; every other OSStatus is surfaced.
    static func removeProvisioningAgentCredential(for plan: PommeProvisioningPlan) throws {
        try plan.validate()
        try removeProvisioningAgentCredential(
            vmUUID: plan.vm.uuid,
            account: PommeProvisioningCredentialReference.agentAccount
        )
    }

    private static func removeProvisioningAgentCredential(
        vmUUID: UUID,
        account: String
    ) throws {
        try provisioningCredentialQueue.sync {
            try PommeAgentCredentialStore().remove(vmUUID: vmUUID, account: account)
        }
    }

    private static func provisioningRoot(bundle: BundleLayout) -> URL {
        bundle.rootURL.appendingPathComponent(".pomme", isDirectory: true)
    }

    private static func provisioningInputURL(bundle: BundleLayout) -> URL {
        provisioningRoot(bundle: bundle).appendingPathComponent("input-v1.json")
    }

    private static func provisioningOwnershipURL(bundle: BundleLayout) -> URL {
        provisioningRoot(bundle: bundle).appendingPathComponent("ownership-v1.json")
    }

    private static func provisioningKeyURL(bundle: BundleLayout) -> URL {
        provisioningRoot(bundle: bundle).appendingPathComponent("journal.key")
    }

    private static func provisioningHighWaterURL(bundle: BundleLayout) -> URL {
        provisioningRoot(bundle: bundle).appendingPathComponent("generation")
    }

    private static func provisioningJournalURL(bundle: BundleLayout) -> URL {
        provisioningRoot(bundle: bundle).appendingPathComponent("provisioning-v1.json")
    }

    static func provisioningV2JournalURL(bundle: BundleLayout) -> URL {
        provisioningRoot(bundle: bundle).appendingPathComponent("provisioning-v2.json")
    }

    static func provisioningSchemaIfPresent(bundle: BundleLayout) throws -> Int? {
        func exists(_ url: URL) throws -> Bool {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT else { throw PommeProvisioningError.ownershipMismatch }
                return false
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else {
                throw PommeProvisioningError.ownershipMismatch
            }
            return true
        }
        let v1 = try exists(provisioningJournalURL(bundle: bundle))
        let v2 = try exists(provisioningV2JournalURL(bundle: bundle))
        guard !(v1 && v2) else { throw PommeProvisioningError.ownershipMismatch }
        return v2 ? 2 : v1 ? 1 : nil
    }

    static func provisioningSchema(bundle: BundleLayout) throws -> Int {
        guard let schema = try provisioningSchemaIfPresent(bundle: bundle) else {
            throw PommeProvisioningError.ownershipMismatch
        }
        return schema
    }

    static func loadProvisioningV2(reference: VMReference) throws -> PommeProvisioningV2Journal {
        guard try provisioningSchema(bundle: reference.bundle) == 2 else {
            throw PommeProvisioningV2Error.invalidJournal
        }
        let key = try PommeSSHBootstrap.privateRead(provisioningKeyURL(bundle: reference.bundle),
            owner: geteuid(), allowedModes: [0o600])
        let journal = try provisioningV2Repository(bundle: reference.bundle, key: key).load()
        guard journal.plan.vm.bundlePath == reference.standardizedPath,
              reference.name == nil || journal.plan.vm.name == reference.name else {
            throw PommeProvisioningV2Error.ownershipMismatch
        }
        return journal
    }

    static func provisioningV2Repository(bundle: BundleLayout, key: Data) throws -> PommeFileProvisioningV2JournalRepository {
        let highWater = provisioningRoot(bundle: bundle).appendingPathComponent("provisioning-v2.high-water")
        let read: @Sendable () throws -> UInt64 = {
            var info = stat()
            if lstat(highWater.path, &info) != 0 {
                guard errno == ENOENT else { throw PommeProvisioningV2Error.generationFailure }
                return 0
            }
            let bytes = try PommeSSHBootstrap.privateRead(highWater, owner: geteuid(), allowedModes: [0o600])
            guard let value = UInt64(String(decoding: bytes, as: UTF8.self)), value > 0 else {
                throw PommeProvisioningV2Error.generationFailure
            }
            return value
        }
        return .init(journalURL: provisioningV2JournalURL(bundle: bundle),
            signer: try PommeProvisioningV2Signer(key: key), loadHighWater: read,
            advanceHighWater: { previous, next in
                guard try read() == previous, next > previous else { throw PommeProvisioningV2Error.generationFailure }
                try writePrivate(Data(String(next).utf8), to: highWater)
            })
    }

    private static func provisioningSigner(bundleURL: URL) throws -> PommeProvisioningJournalSigner {
        let root = bundleURL.appendingPathComponent(".pomme", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyURL = root.appendingPathComponent("journal.key")
        let key: Data
        if isRegularFile(keyURL) {
            key = try Data(contentsOf: keyURL, options: .mappedIfSafe)
            guard key.count >= 32 else { throw PommeProvisioningError.integrityFailure }
        } else {
            var generated = Data(count: 32)
            let result = generated.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard result == errSecSuccess else { throw PommeProvisioningError.integrityFailure }
            try writePrivate(generated, to: keyURL)
            key = generated
        }
        return try PommeProvisioningJournalSigner(key: key)
    }

    private static func provisioningRepository(
        bundleURL: URL,
        signer: PommeProvisioningJournalSigner
    ) throws -> PommeProvisioningFileJournalRepository {
        let bundle = BundleLayout(rootURL: bundleURL)
        let highWaterURL = provisioningHighWaterURL(bundle: bundle)
        return .init(
            bundleURL: bundleURL,
            signer: signer,
            loadHighWater: {
                guard let data = try? Data(contentsOf: highWaterURL),
                      let value = UInt64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                else { return 0 }
                return value
            },
            advanceHighWater: { previous, next in
                let current: UInt64
                if let data = try? Data(contentsOf: highWaterURL),
                   let value = UInt64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
                    current = value
                } else {
                    current = 0
                }
                guard current == previous, next > previous else {
                    throw PommeProvisioningError.generationFailure
                }
                try writePrivate(Data(String(next).utf8), to: highWaterURL)
            }
        )
    }

    private static func writeProvisioningPreparation(
        _ preparation: ProvisioningPreparation,
        bundle: BundleLayout
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writePrivate(try encoder.encode(preparation.plan.vm), to: provisioningOwnershipURL(bundle: bundle))
        try writePrivate(try encoder.encode(preparation.input), to: provisioningInputURL(bundle: bundle))
    }

    static func loadProvisioningInput(for plan: PommeProvisioningPlan) throws -> PommeProvisioningInput {
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        let data = try Data(contentsOf: provisioningInputURL(bundle: bundle), options: .mappedIfSafe)
        let input = try JSONDecoder().decode(PommeProvisioningInput.self, from: data)
        try input.validate(for: plan)
        guard isRegularFile(URL(fileURLWithPath: input.restoreImagePath)) else {
            throw RunnerError.hostCommandFailed("The restore image for the Pomme provisioning plan is unavailable.")
        }
        return input
    }

    private static func verifyProvisioningOwnership(_ expected: PommeVMOwnership) async throws -> PommeVMOwnership {
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: expected.bundlePath))
        guard isRegularFile(provisioningOwnershipURL(bundle: bundle)) else {
            throw PommeProvisioningError.ownershipMismatch
        }
        let data = try Data(contentsOf: provisioningOwnershipURL(bundle: bundle), options: .mappedIfSafe)
        let actual = try JSONDecoder().decode(PommeVMOwnership.self, from: data)
        guard actual == expected else { throw PommeProvisioningError.ownershipMismatch }
        return actual
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RunnerError.hostCommandFailed("Pomme could not persist provisioning state.")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func installProvisioningVM(_ plan: PommeProvisioningPlan) async throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Preparing macOS installation")
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        let input = try loadProvisioningInput(for: plan)
        if let templateBundlePath = input.templateBundlePath {
            return try installProvisioningVMFromTemplate(
                plan,
                input: input,
                bundle: bundle,
                templateBundlePath: templateBundlePath
            )
        }
        let imageURL = URL(fileURLWithPath: input.restoreImagePath)
        let image = try await loadRestoreImage(from: imageURL)
        let version = "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)"
        guard image.buildVersion == plan.restore.build, version == plan.restore.version else {
            throw PommeProvisioningError.invalidPlan
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration,
              requirements.hardwareModel.dataRepresentation == input.hardwareModelData
        else { throw PommeProvisioningError.invalidPlan }
        try validateMemorySize(input.memorySizeBytes, requirements: requirements)
        try verifyRestoreImageDigest(at: imageURL, expected: plan.restore.restoreImageDigest)

        let hardwareModel: VZMacHardwareModel
        guard let restoredHardwareModel = VZMacHardwareModel(dataRepresentation: input.hardwareModelData),
              restoredHardwareModel.isSupported
        else { throw RunnerError.invalidHardwareModel }
        hardwareModel = restoredHardwareModel
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: input.machineIdentifierData) else {
            throw RunnerError.invalidMachineIdentifier
        }

        try persistExactData(input.hardwareModelData, at: bundle.hardwareModelURL)
        try persistExactData(input.machineIdentifierData, at: bundle.machineIdentifierURL)
        if let existingSize = fileSize(bundle.diskImageURL) {
            guard existingSize == Int64(input.diskSizeBytes) else {
                throw PommeProvisioningError.ownershipMismatch
            }
        } else {
            try bundle.createDiskImage(size: input.diskSizeBytes)
        }

        try writeProvisioningMetadata(plan: plan, input: input, bundle: bundle)

        let auxiliaryStorage: VZMacAuxiliaryStorage
        if FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path) {
            auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        } else {
            auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: bundle.auxiliaryStorageURL,
                hardwareModel: hardwareModel,
                options: []
            )
        }
        let queue = DispatchQueue(label: "com.github.weswhet.pomme.install")
        let configuration = try makeRuntimeConfiguration(
            bundle: bundle,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            auxiliaryStorage: auxiliaryStorage,
            memorySizeBytes: input.memorySizeBytes,
            installer: true
        )
        let installer = queue.sync {
            let vm = VZVirtualMachine(configuration: configuration, queue: queue)
            return VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
        }
        let progressSink = PommeProgressContext.sink
        let logSink = PommeLogContext.sink
        let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            if let progressSink {
                progressSink.measured(vm: plan.vm.name, "Installing macOS", fraction: progress.fractionCompleted)
            } else if let logSink {
                logSink("Install progress: \(Int(progress.fractionCompleted * 100))%")
            } else {
                logInstallProgress(fractionCompleted: progress.fractionCompleted, vmName: plan.vm.name)
            }
        }
        defer { observation.invalidate() }
        try await install(installer, on: queue)
        progressSink?.step(vm: plan.vm.name, "Verifying macOS installation")
        return try receiptDigest("install", plan: plan, bundle: bundle)
    }

    private static func writeProvisioningMetadata(
        plan: PommeProvisioningPlan,
        input: PommeProvisioningInput,
        bundle: BundleLayout
    ) throws {
        var metadata = (try? metadataPayload(bundle: bundle)) ?? [:]
        metadata[Constants.vmUUIDMetadataKey] = plan.vm.uuid.uuidString.lowercased()
        metadata["memorySize"] = input.memorySizeBytes
        metadata["diskSize"] = input.diskSizeBytes
        metadata["buildVersion"] = plan.restore.build
        metadata["osVersion"] = plan.restore.version
        metadata["locale"] = plan.display.locale
        metadata["displayWidth"] = plan.display.width
        metadata["displayHeight"] = plan.display.height
        metadata["provisioningPlanDigest"] = plan.digest
        for (key, value) in try provisioningDisclosure(bundle: bundle) {
            metadata[key] = value
        }
        metadata["guestAgent"] = [
            "identifier": plan.normalAgent.identifier,
            "protocolVersion": plan.normalAgent.protocolVersion,
            "executableDigest": plan.normalAgent.executableDigest
        ]
        if let templateBundlePath = input.templateBundlePath {
            let template = BundleLayout(rootURL: URL(fileURLWithPath: templateBundlePath))
            metadata["template"] = URL(fileURLWithPath: templateBundlePath).deletingPathExtension().lastPathComponent
            // A provisioned template's clone already carries the owner
            // account, so record which one it is. The password is not
            // recorded: the host Keychain item belongs to the VM the template
            // was captured from, and a clone recovers its own from the guest's
            // automatic-login configuration instead.
            if let owner = (try? PommeTemplateStore.manifest(in: template))?.provisionedOwnerAccount {
                metadata[Constants.guestKCPasswordUserMetadataKey] = owner
            }
        }
        try writeMetadataPayload(metadata, bundle: bundle)
    }

    /// The install phase for a template-sourced VM: clone the template's
    /// disk image and auxiliary storage (copy-on-write on APFS) under this
    /// VM's own machine identifier. The template manifest must still match
    /// the immutable plan, so a replaced template cannot satisfy an older
    /// journal. Existing files are kept for `--resume`.
    private static func installProvisioningVMFromTemplate(
        _ plan: PommeProvisioningPlan,
        input: PommeProvisioningInput,
        bundle: BundleLayout,
        templateBundlePath: String
    ) throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Cloning template")
        let template = BundleLayout(rootURL: URL(fileURLWithPath: templateBundlePath))
        let manifest = try PommeTemplateStore.manifest(in: template)
        guard manifest.version == plan.restore.version,
              manifest.build == plan.restore.build,
              manifest.restoreImageDigest == plan.restore.restoreImageDigest,
              manifest.diskSizeBytes == input.diskSizeBytes,
              try Data(contentsOf: template.hardwareModelURL) == input.hardwareModelData
        else { throw PommeProvisioningError.invalidPlan }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: input.hardwareModelData),
              hardwareModel.isSupported
        else { throw RunnerError.invalidHardwareModel }
        guard VZMacMachineIdentifier(dataRepresentation: input.machineIdentifierData) != nil else {
            throw RunnerError.invalidMachineIdentifier
        }

        try persistExactData(input.hardwareModelData, at: bundle.hardwareModelURL)
        try persistExactData(input.machineIdentifierData, at: bundle.machineIdentifierURL)
        if let existingSize = fileSize(bundle.diskImageURL) {
            guard existingSize == Int64(input.diskSizeBytes) else {
                throw PommeProvisioningError.ownershipMismatch
            }
        } else {
            try PommeTemplateStore.clone(template.diskImageURL, to: bundle.diskImageURL)
            guard fileSize(bundle.diskImageURL) == Int64(input.diskSizeBytes) else {
                throw PommeProvisioningError.invalidPlan
            }
        }
        if !FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path) {
            try PommeTemplateStore.clone(template.auxiliaryStorageURL, to: bundle.auxiliaryStorageURL)
        }
        try writeProvisioningMetadata(plan: plan, input: input, bundle: bundle)
        log("cloned template \(manifest.name) (macOS \(manifest.version) \(manifest.build)).", vmName: plan.vm.name)
        return try receiptDigest("install", plan: plan, bundle: bundle)
    }

    /// Creates an installed-but-unprovisioned template: a restored disk image
    /// with its auxiliary storage and hardware model, and a manifest. No
    /// agent, credential, or journal is involved; a failed restore removes
    /// the partial bundle.
    static func createTemplatePayload(name: String, arguments: CLIOptions) async throws -> [String: Any] {
        let validName = try validateIdentifier(name, kind: .template)
        let bundle = try PommeTemplateStore.bundle(for: validName)
        guard !FileManager.default.fileExists(atPath: bundle.rootURL.path) else {
            throw PommeTemplateError.alreadyExists(validName)
        }
        let source = try await restoreImageSource(arguments: arguments, vmName: validName)
        guard let requirements = source.requirements else { throw RunnerError.noSupportedConfiguration }
        let memory = arguments.sizeOptions.memorySizeBytes
        try validateMemorySize(memory, requirements: requirements)
        if source.profileDescriptor.qualification == .experimental {
            warning(
                "Warning: Recovery support for macOS \(source.version) (\(source.build)) is experimental; VMs created from this template will attempt observed-screen navigation.",
                vmName: validName
            )
        }
        try FileManager.default.createDirectory(
            at: bundle.rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let hardwareModel = requirements.hardwareModel
            let machineIdentifier = VZMacMachineIdentifier()
            try writePrivate(hardwareModel.dataRepresentation, to: bundle.hardwareModelURL)
            try writePrivate(machineIdentifier.dataRepresentation, to: bundle.machineIdentifierURL)
            try bundle.createDiskImage(size: source.diskSizeBytes)
            let auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: bundle.auxiliaryStorageURL,
                hardwareModel: hardwareModel,
                options: []
            )
            let queue = DispatchQueue(label: "com.github.weswhet.pomme.template-install")
            let configuration = try makeRuntimeConfiguration(
                bundle: bundle,
                hardwareModel: hardwareModel,
                machineIdentifier: machineIdentifier,
                auxiliaryStorage: auxiliaryStorage,
                memorySizeBytes: memory,
                installer: true
            )
            let installer = queue.sync {
                let vm = VZVirtualMachine(configuration: configuration, queue: queue)
                return VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: source.restoreImage)
            }
            let progressSink = PommeProgressContext.sink
            let logSink = PommeLogContext.sink
            let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                if let progressSink {
                    progressSink.measured(vm: validName, "Installing macOS", fraction: progress.fractionCompleted)
                } else if let logSink {
                    logSink("Install progress: \(Int(progress.fractionCompleted * 100))%")
                } else {
                    logInstallProgress(fractionCompleted: progress.fractionCompleted, vmName: validName)
                }
            }
            defer { observation.invalidate() }
            try await install(installer, on: queue)
            progressSink?.step(vm: validName, "Saving template")
            // The installer's identifier is never reused: every VM cloned
            // from the template generates its own.
            try? FileManager.default.removeItem(at: bundle.machineIdentifierURL)
            let manifest = PommeTemplateManifest(
                name: validName,
                version: source.version,
                build: source.build,
                restoreImageDigest: source.restoreImageDigest,
                restoreImagePath: source.restoreImage.path,
                diskSizeBytes: source.diskSizeBytes
            )
            try PommeTemplateStore.write(manifest, to: bundle)
        } catch {
            try? FileManager.default.removeItem(at: bundle.rootURL)
            throw error
        }
        return [
            "ok": true,
            "operation": "template-create",
            "hostExitCode": 0,
            "name": validName,
            "bundlePath": bundle.rootURL.path,
            "version": source.version,
            "build": source.build,
            "diskSize": source.diskSizeBytes,
            "restoreImage": source.restoreImage.path,
            "restoreImageDigest": source.restoreImageDigest
        ]
    }

    private static func persistExactData(_ data: Data, at url: URL) throws {
        if isRegularFile(url) {
            guard try Data(contentsOf: url, options: .mappedIfSafe) == data else {
                throw PommeProvisioningError.ownershipMismatch
            }
            return
        }
        try writePrivate(data, to: url)
    }

    private static func install(_ installer: VZMacOSInstaller, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let installer = QueueConfined(value: installer)
            queue.async {
                installer.value.install { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private static func receiptDigest(_ phase: String, plan: PommeProvisioningPlan, bundle: BundleLayout) throws -> String {
        var data = Data(phase.utf8)
        data.append(contentsOf: plan.digest.utf8)
        if let metadata = try? metadataPayload(bundle: bundle),
           let encoded = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            data.append(encoded)
        }
        return PommeProvisioningDigest.sha256(data)
    }

    /// Recovery installation is an injectable, request-bound boundary:
    /// callers provide the signed executable, one-shot credential, staging,
    /// and Recovery ports through the installed adapter.  The default
    /// adapter refuses the phase after the intent is durable, preserving the
    /// exact VM/journal for a configured Recovery integration.
    private static func installRecoveryAgent(_ plan: PommeProvisioningPlan) async throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Bootstrapping Pomme agent in Recovery")
        try await stopRetainedRuntime(for: plan.vm.bundlePath)
        guard let adapter = currentProvisioningRecoveryAdapter() else {
            throw PommeProvisioningError.unavailableIntegration("request-bound Recovery agent installation")
        }
        // The Recovery installer receives this credential through the
        // request-bound application adapter. Ensure it exists before entering
        // Recovery, but never copy it into the plan, journal, or staging
        // metadata. A failed phase keeps the exact VM/journal and this
        // UUID-scoped Keychain item available for an explicit resume/repair.
        _ = try provisioningAgentCredential(for: plan)
        // Recovery installation must leave the exact VM stopped. Normal-agent
        // verification and the plan's requested final state are separate
        // subsequent journal phases; collapsing them here can make a failed
        // bootstrap look complete and can boot an unverified agent.
        return try await adapter(plan, .stopped)
    }

    /// Boots the verified guest through the background VM helper, the same
    /// runtime `pomme start` uses, so the boot that proves the agent is also
    /// the boot a `normal` final state keeps: no second start is needed and
    /// the VM outlives this process.
    private static func verifyNormalAgent(_ plan: PommeProvisioningPlan) async throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Verifying Pomme agent")
        try await stopRetainedRuntime(for: plan.vm.bundlePath)
        let reference = provisioningReference(for: plan)
        let deadline = Date().addingTimeInterval(Constants.defaultRecoveryAgentTimeout)
        _ = try startRuntimeInBackground(
            reference: reference,
            bootMode: .normal,
            timeout: Constants.defaultRecoveryAgentTimeout
        )
        while true {
            let status = try await provisioningAgentStatus(name: plan.vm.name)
            if status.connection == .connected,
               status.role == .normal,
               status.protocolVersion == plan.normalAgent.protocolVersion,
               status.executableDigest == plan.normalAgent.executableDigest,
               supportsProvisioningAgentCapabilities(status.capabilities) {
                break
            }
            guard Date() < deadline else {
                throw PommeProvisioningError.phaseFailed(.verifyNormalAgent)
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return try receiptDigest("verify-normal-agent", plan: plan, bundle: reference.bundle)
    }

    private static func provisioningReference(for plan: PommeProvisioningPlan) -> VMReference {
        VMReference(
            name: plan.vm.name,
            bundle: BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        )
    }

    /// Asks the running guest to shut itself down through the helper. A
    /// guest at Setup Assistant ignores the framework's stop request, so
    /// without this the helper stop waits out its graceful timeout.
    /// True when the guest can be asked to shut itself down: a running,
    /// normal-booted VM whose persistent agent is connected. recoveryOS has no
    /// agent, and a paused or stopping VM cannot run anything.
    static func shouldRequestGuestShutdown(status: [String: Any]) -> Bool {
        stringValue(status["vmState"]) == "running"
            && stringValue(status["bootMode"]) == BootMode.normal.rawValue
            && normalGuestAgentConnected(status)
    }

    static func requestGuestShutdownThroughHelper(reference: VMReference) {
        let request = GuestCommandRequest(path: "/sbin/shutdown", arguments: ["-h", "now"], timeout: 10)
        guard let payload = try? request.validatedControlPayload(detached: true) else { return }
        _ = try? sendControlObject(payload, bundle: reference.bundle, timeout: 10)
    }

    /// True only when the status payload reports the persistent guest agent
    /// connected, so an agent-driven shutdown request can actually be
    /// delivered before falling back to the framework's graceful stop.
    static func normalGuestAgentConnected(_ payload: [String: Any]) -> Bool {
        let agent = payload["guestAgent"] as? [String: Any]
        return GuestAgentStatusV1.ConnectionState(rawValue: stringValue(agent?["connection"])) == .connected
    }

    private static func restoreProvisioningFinalState(_ plan: PommeProvisioningPlan) async throws -> String {
        try await restoreProvisioningState(plan, finalState: plan.finalState)
    }

    private static func restoreProvisioningState(
        _ plan: PommeProvisioningPlan,
        finalState: PommeProvisioningFinalState
    ) async throws -> String {
        try await stopRetainedRuntime(for: plan.vm.bundlePath)
        let reference = provisioningReference(for: plan)
        // The verified normal boot already runs in the background helper.
        // A `normal` final state keeps it; `stopped` shuts the guest down
        // through the agent and then stops the helper; `recovery` stops the
        // helper and starts it again in Recovery, whose terminal credential
        // and agent are admitted lazily by the first terminal session.
        switch finalState {
        case .normalRunning:
            try await restoreStableVMRunState(.running(.normal), reference: reference)
        case .stopped:
            if try stableVMRunState(reference: reference) == .running(.normal) {
                requestGuestShutdownThroughHelper(reference: reference)
            }
            try await restoreStableVMRunState(.stopped, reference: reference)
        case .recoveryRunning:
            if try stableVMRunState(reference: reference) == .running(.normal) {
                requestGuestShutdownThroughHelper(reference: reference)
            }
            try await restoreStableVMRunState(.running(.recovery), reference: reference)
        }
        let observed = try liveRecoveryRunState(from: vmStatusPayload(reference: reference))
        switch (finalState, observed) {
        case (.stopped, .stopped),
             (.normalRunning, .running(.normal)),
             (.recoveryRunning, .running(.recovery)):
            break
        default:
            throw PommeRecoverySessionError.finalStateUnverified
        }
        return try receiptDigest("restore-final-state", plan: plan, bundle: reference.bundle)
    }

    private static func repairProvisioningAgent(
        _ plan: PommeProvisioningPlan,
        finalState: PommeProvisioningFinalState
    ) async throws -> String {
        PommeProgressContext.sink?.step(vm: plan.vm.name, "Repairing Pomme agent")
        // A repair is deliberately Recovery-only.  The adapter constructs a
        // request-bound PommeRecoverySession; no normal agent is accepted as
        // a repair authority.
        guard let adapter = currentProvisioningRecoveryAdapter() else {
            throw PommeProvisioningError.unavailableIntegration("authenticated Recovery agent repair")
        }
        let primary: Result<String, Error>
        do {
            // Installation ends stopped so normal-agent verification cannot be
            // skipped by a requested stopped/Recovery final state.
            let installationReceipt = try await adapter(plan, .stopped)
            let verificationReceipt = try await verifyNormalAgent(plan)
            primary = .success(PommeProvisioningDigest.sha256(
                Data((installationReceipt + verificationReceipt).utf8)
            ))
        } catch {
            primary = .failure(error)
        }

        // Repair owns final-state restoration even when installation or
        // verification fails; success is reported only after both the agent
        // and the requested lifecycle state are proven.
        _ = try await restoreProvisioningState(plan, finalState: finalState)
        return try primary.get()
    }

    private static func startProvisioningRuntime(
        plan: PommeProvisioningPlan,
        mode: BootMode,
        attachAgent: Bool,
        guestProvisioningIntent: PommeMacGuestProvisioningIntent? = nil
    ) async throws -> PommeRetainedRuntime {
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        let input = try loadProvisioningInput(for: plan)
        let hardwareModel = try loadHardwareModel(input.hardwareModelData)
        guard hardwareModel.isSupported else { throw RunnerError.unsupportedHardwareModel }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: input.machineIdentifierData) else {
            throw RunnerError.invalidMachineIdentifier
        }
        let auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        let queue = DispatchQueue(label: "com.github.weswhet.pomme.runtime")
        let terminalBootstrapShare: PommeRecoveryTerminalBootstrapShare?
        if mode == .recovery, !attachAgent {
            terminalBootstrapShare = try PommeRecoveryTerminalBootstrapShare(
                parentURL: try applicationSupportRoot(create: true)
                    .appendingPathComponent("RecoveryTerminalBootstrap", isDirectory: true),
                vmUUID: plan.vm.uuid
            )
        } else {
            terminalBootstrapShare = nil
        }

        let configuration: VZVirtualMachineConfiguration
        do {
            configuration = try makeRuntimeConfiguration(
                bundle: bundle,
                hardwareModel: hardwareModel,
                machineIdentifier: machineIdentifier,
                auxiliaryStorage: auxiliaryStorage,
                memorySizeBytes: input.memorySizeBytes,
                ordinaryRecoveryBootstrapShare: terminalBootstrapShare
            )
        } catch {
            try? terminalBootstrapShare?.removeHostRoot()
            throw error
        }
        let vm = VZVirtualMachine(configuration: configuration, queue: queue)
        let terminalAdmissionState = terminalBootstrapShare.map { _ in
            PommeRecoveryTerminalAdmissionState()
        }
        let coordinator: PommeAgentVSOCKCoordinator?
        do {
            if attachAgent || terminalBootstrapShare != nil {
                guard let socketDevice = queue.sync(execute: { vm.socketDevices.first as? VZVirtioSocketDevice }) else {
                    throw RunnerError.hostCommandFailed("Pomme could not attach the VM agent socket.")
                }
                let provider = PommeAgentVSOCKCoordinator(
                    socketDevice: socketDevice,
                    queue: queue,
                    secretProvider: { role in
                        if let terminalAdmissionState {
                            return try terminalAdmissionState.secret(for: role)
                        }
                        return try existingProvisioningAgentCredential(for: plan)
                    },
                    bindingProvider: { role in
                        if let terminalAdmissionState {
                            return try terminalAdmissionState.sessionBinding(for: role)
                        }
                        return nil
                    }
                )
                switch mode {
                case .normal: try provider.attachNormal()
                case .recovery: try provider.attachRecoveryRuntime()
                }
                coordinator = provider
            } else {
                coordinator = nil
            }
        } catch {
            try? terminalBootstrapShare?.removeHostRoot()
            throw error
        }

        let terminalAdmission: PommeRecoveryTerminalAdmission?
        if let terminalBootstrapShare,
           let terminalAdmissionState,
           let coordinator {
            let virtualization = PommeRecoveryTerminalVirtualizationContext(
                vm: vm,
                configuration: configuration,
                queue: queue
            )
            terminalAdmission = PommeRecoveryTerminalAdmission(
                plan: plan,
                profileResolver: { try PommeCore.recoveryProfileEvidence(for: plan) },
                virtualization: virtualization,
                coordinator: coordinator,
                state: terminalAdmissionState,
                bootstrapShare: terminalBootstrapShare,
                executableResolver: {
                    try PommeAgentArtifactStore(
                        rootURL: try applicationSupportRoot(create: false)
                    ).resolve(sha256: plan.recoveryAgent.executableDigest)
                }
            )
        } else {
            terminalAdmission = nil
        }

        let terminalAdmissionEffect: (@Sendable (UUID, Bool) async throws -> PommeRecoveryDebugScreenshotMetadata?)?
        let terminalAdmissionCleanup: (@Sendable () async -> Bool)?
        if let terminalAdmission {
            terminalAdmissionEffect = { sessionID, recoveryDebugScreenshots in
                try await terminalAdmission.ensure(
                    sessionID: sessionID,
                    recoveryDebugScreenshots: recoveryDebugScreenshots
                )
            }
            terminalAdmissionCleanup = {
                await terminalAdmission.cleanup()
            }
        } else {
            terminalAdmissionEffect = nil
            terminalAdmissionCleanup = nil
        }
        let runtime = PommeVMRuntime(
            vm: vm,
            configuration: configuration,
            queue: queue,
            saveStateURL: bundle.saveStateURL,
            snapshotsURL: bundle.snapshotsURL,
            requiredSnapshotRestoreURL: bundle.requiredSnapshotRestoreURL,
            agentProvider: coordinator,
            bootMode: mode,
            terminalAdmission: terminalAdmissionEffect,
            terminalAdmissionCleanup: terminalAdmissionCleanup,
            guestProvisioningIntent: guestProvisioningIntent
        )
        do {
            try await runtime.start()
        } catch {
            coordinator?.teardown()
            await runtime.teardown()
            throw error
        }
        return .init(runtime: runtime, coordinator: coordinator, mode: mode)
    }

    /// Build the exact Pomme VM configuration for one immutable provisioning
    /// plan. A request-bound Recovery configuration, when supplied, is
    /// applied before this method returns so callers can construct
    /// `VZVirtualMachine` only after the exclusive staging share is attached.
    /// No credential-bearing input is returned by this hook.
    static func makeProvisioningVMConfiguration(
        for plan: PommeProvisioningPlan,
        recoveryConfiguration: PommeRecoveryRuntimeConfiguration? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let bundle = BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        let input = try loadProvisioningInput(for: plan)
        let hardwareModel = try loadHardwareModel(input.hardwareModelData)
        guard hardwareModel.isSupported else { throw RunnerError.unsupportedHardwareModel }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: input.machineIdentifierData) else {
            throw RunnerError.invalidMachineIdentifier
        }
        let auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        return try makeRuntimeConfiguration(
            bundle: bundle,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            auxiliaryStorage: auxiliaryStorage,
            memorySizeBytes: input.memorySizeBytes,
            recoveryConfiguration: recoveryConfiguration
        )
    }

    private static func loadHardwareModel(_ data: Data) throws -> VZMacHardwareModel {
        guard let model = VZMacHardwareModel(dataRepresentation: data) else {
            throw RunnerError.invalidHardwareModel
        }
        return model
    }

    private static func retainRuntime(_ runtime: PommeRetainedRuntime, for bundlePath: String) {
        retainedRuntimeLock.lock()
        retainedRuntimes[bundlePath] = runtime
        retainedRuntimeLock.unlock()
    }

    private static func retainedRuntime(for bundlePath: String) -> PommeRetainedRuntime? {
        retainedRuntimeLock.lock()
        defer { retainedRuntimeLock.unlock() }
        return retainedRuntimes[bundlePath]
    }

    private static func removeRetainedRuntime(for bundlePath: String) -> PommeRetainedRuntime? {
        retainedRuntimeLock.lock()
        defer { retainedRuntimeLock.unlock() }
        return retainedRuntimes.removeValue(forKey: bundlePath)
    }

    private static func stopRetainedRuntime(for bundlePath: String) async throws {
        guard let retained = removeRetainedRuntime(for: bundlePath) else { return }
        await requestGuestShutdown(retained)
        try await retained.stop()
    }

    /// A workflow that leaves the VM running normally should hand back a VM
    /// that can already take guest commands, the way `start` does; otherwise
    /// the next command fails for as long as the guest takes to boot. The
    /// security result is authoritative, so an agent that does not connect in
    /// time is logged rather than failing the workflow that already succeeded.
    private static func waitForFinalStateGuestAgent(reference: VMReference, payload: [String: Any]) {
        do {
            _ = try waitForGuestAgentConnection(
                reference: reference,
                payload: payload,
                deadline: ProcessInfo.processInfo.systemUptime + Constants.defaultRecoveryAgentTimeout,
                timeout: Constants.defaultRecoveryAgentTimeout
            )
        } catch {
            warning(
                "Final-state guest agent wait did not complete: \(error.localizedDescription)",
                vmName: reference.displayName
            )
        }
    }

    /// A freshly provisioned guest sitting in Setup Assistant ignores the
    /// framework's stop request, so `runtime.stop()` would wait out the full
    /// graceful timeout before forcing. When the normal agent is connected,
    /// ask the guest to shut itself down first; the following stop then
    /// observes a stopped VM within seconds. Failures fall through to the
    /// ordinary stop path.
    private static func requestGuestShutdown(_ retained: PommeRetainedRuntime) async {
        guard retained.mode == .normal, let coordinator = retained.coordinator else { return }
        do {
            let session = try coordinator.captureAuthenticatedSession(as: .normal)
            let request = GuestCommandRequest(path: "/sbin/shutdown", arguments: ["-h", "now"], timeout: 10)
            _ = try await session.request(
                operation: "process.start",
                payload: try JSONValue(any: request.agentPayload(detached: true))
            )
        } catch {
            return
        }
    }

    private static func makeRuntimeConfiguration(
        bundle: BundleLayout,
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier,
        auxiliaryStorage: VZMacAuxiliaryStorage,
        memorySizeBytes: UInt64,
        recoveryConfiguration: PommeRecoveryRuntimeConfiguration? = nil,
        ordinaryRecoveryBootstrapShare: PommeRecoveryTerminalBootstrapShare? = nil,
        installer: Bool = false
    ) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxiliaryStorage

        // The installer VM exists only to restore the image once; a failed
        // restore is retried from scratch. That is the case Apple documents
        // for `.none`: no synchronization with permanent storage, so guest
        // flushes during the ~20 GB restore do not become host F_FULLFSYNCs.
        // Every later boot keeps the durable default.
        let disk = installer
            ? try VZDiskImageStorageDeviceAttachment(
                url: bundle.diskImageURL,
                readOnly: false,
                cachingMode: .automatic,
                synchronizationMode: .none
            )
            : try VZDiskImageStorageDeviceAttachment(url: bundle.diskImageURL, readOnly: false)
        let block = VZVirtioBlockDeviceConfiguration(attachment: disk)
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        let machineData = try Data(contentsOf: bundle.machineIdentifierURL, options: .mappedIfSafe)
        guard let mac = VZMACAddress(string: stableVMMACAddress(machineIdentifierData: machineData)) else {
            throw RunnerError.hostCommandFailed("Pomme could not derive a stable VM network address.")
        }
        network.macAddress = mac

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)
        ]
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        // The restore is partly CPU-bound in the guest and the CPU count is
        // not persisted by the installed OS, so the installer VM gets every
        // host core; ordinary boots keep four.
        let preferredCPUCount = installer ? ProcessInfo.processInfo.activeProcessorCount : 4
        configuration.cpuCount = min(
            max(preferredCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        configuration.memorySize = memorySizeBytes
        configuration.storageDevices = [block]
        configuration.networkDevices = [network]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration(), VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.graphicsDevices = [graphics]
        if let ordinaryRecoveryBootstrapShare {
            guard recoveryConfiguration == nil else {
                throw RunnerError.hostCommandFailed("Recovery bootstrap shares cannot be combined.")
            }
            configuration.directorySharingDevices = [ordinaryRecoveryBootstrapShare.deviceConfiguration]
        }
        if let recoveryConfiguration {
            try recoveryConfiguration.apply(to: configuration)
            try recoveryConfiguration.requireApplied()
        }
        try configuration.validate()
        return configuration
    }

    private static func captureAndStopForLiveRecovery(
        reference: VMReference
    ) async throws -> PommeRecoveryRunState {
        let payload: [String: Any]
        if let retained = retainedRuntime(for: reference.standardizedPath) {
            if await retained.runtime.hasLiveTerminalSessions() {
                throw RunnerError.virtualMachineState(
                    "Recovery security workflows are unavailable while a terminal session is active. Terminate it first."
                )
            }
            payload = await retained.runtime.statusPayload(
                bundle: reference.bundle,
                inspect: false
            )
        } else {
            payload = try vmStatusPayload(reference: reference)
        }
        let state = try liveRecoveryRunState(from: payload)
        // This stop exists only to free the VM for the Recovery boot that
        // immediately follows it, so it keeps the framework stop.
        try await stopForLiveRecovery(reference: reference, allowAgentShutdown: false)
        guard try liveRecoveryRunState(
            from: vmStatusPayload(reference: reference)
        ) == .stopped else {
            throw PommeRecoverySessionError.finalStateUnverified
        }
        return state
    }

    /// `allowAgentShutdown` must be false whenever this stop precedes a
    /// Recovery boot. An agent-driven `shutdown -h now` is far faster than VZ's
    /// power-button request, but a Recovery boot that follows one was observed
    /// to reach Recovery Utilities without presenting the language chooser the
    /// reviewed navigation route expects, which desynchronizes navigation. The
    /// fast path is therefore limited to stops whose target is a stopped VM;
    /// every Recovery transition keeps the framework stop.
    private static func stopForLiveRecovery(
        reference: VMReference,
        allowAgentShutdown: Bool
    ) async throws {
        try await stopRetainedRuntime(for: reference.standardizedPath)
        if (try? runtimeRecord(for: reference.bundle)) != nil {
            PommeProgressContext.sink?.step(vm: reference.name, "Stopping VM")
        }
        // A normal-booted guest with a connected agent can shut itself down in
        // a few seconds. VZ's requestStop behaves like a power button, which a
        // freshly booted macOS guest may take the full graceful window to
        // honor, so ask the agent to `shutdown -h now` first and let the
        // following helper stop observe an already-powering-down guest. This is
        // the same agent-driven shutdown provisioning uses. recoveryOS has no
        // such agent, and an agentless or non-normal guest simply falls through
        // to the ordinary graceful stop below.
        if allowAgentShutdown,
           let payload = try? vmStatusPayload(reference: reference),
           shouldRequestGuestShutdown(status: payload) {
            requestGuestShutdownThroughHelper(reference: reference)
        }
        do {
            _ = try sendControlObject(
                ["command": PommeLifecycleCommand.stop.rawValue],
                bundle: reference.bundle
            )
        } catch RunnerError.noRunningVM {
            return
        }

        let deadline = Date().addingTimeInterval(Constants.gracefulStopTimeoutSeconds)
        while Date() < deadline {
            if (try? runtimeRecord(for: reference.bundle)) == nil { return }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard (try? runtimeRecord(for: reference.bundle)) == nil else {
            throw RunnerError.virtualMachineState(
                "The Pomme VM helper did not stop before Recovery."
            )
        }
    }

    /// A helper can report stopped just before Virtualization releases its
    /// auxiliary-storage descriptor. Permit one contained wait, then fail
    /// closed. Every VZ object is still constructed only after this proof, so
    /// no failed VM instance is ever retried.
    static func waitForLiveRecoveryAuxiliaryStorageRelease(
        at url: URL,
        vmName: String,
        maxRetries: Int = 1,
        retryDelayNanoseconds: UInt64 = 2_000_000_000,
        hasConflict: @escaping @Sendable (URL) -> Bool = liveRecoveryAuxiliaryStorageHasConflictingLock,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) async throws {
        let retryBudget = max(0, maxRetries)
        var retries = 0
        while hasConflict(url) {
            guard retries < retryBudget else {
                throw PommeLiveRecoveryIntegration.Error.runtimeRejected
            }
            retries += 1
            log(
                "Recovery bootstrap milestone: auxiliaryStorageReleaseWait "
                    + "\(retries)/\(retryBudget).",
                vmName: vmName
            )
            if retryDelayNanoseconds > 0 {
                try await sleep(retryDelayNanoseconds)
            }
        }
    }

    static func liveRecoveryAuxiliaryStorageHasConflictingLock(_ url: URL) -> Bool {
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        // This is a security proof, not a best-effort contention hint.  Any
        // inability to open or validate the exact auxiliary-storage inode is
        // indistinguishable from a conflicting owner and therefore fails
        // closed through the bounded wait above.
        guard descriptor >= 0 else { return true }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0
        else { return true }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return true
    }

    private static func requestLiveRecoveryFinalState(
        _ state: VMFinalState,
        captured: PommeRecoveryRunState,
        reference: VMReference
    ) async throws {
        switch state {
        case .stopped:
            // A requested stopped final state boots nothing afterwards.
            try await stopForLiveRecovery(reference: reference, allowAgentShutdown: true)
        case .normal:
            let payload = try startRuntimeInBackground(
                reference: reference,
                bootMode: .normal,
                timeout: Constants.defaultRecoveryAgentTimeout
            )
            waitForFinalStateGuestAgent(reference: reference, payload: payload)
        case .recovery:
            _ = try startRuntimeInBackground(
                reference: reference,
                bootMode: .recovery,
                timeout: Constants.defaultRecoveryAgentTimeout
            )
        case .paused:
            guard case .paused(let previousMode) = captured else {
                throw PommeRecoverySessionError.finalStateUnverified
            }
            _ = try startRuntimeInBackground(
                reference: reference,
                bootMode: previousMode,
                timeout: Constants.defaultRecoveryAgentTimeout
            )
            _ = try sendControlObject(
                ["command": PommeLifecycleCommand.pause.rawValue],
                bundle: reference.bundle
            )
        case .previous:
            throw PommeRecoverySessionError.finalStateUnverified
        }
    }

    private static func proveLiveRecoveryFinalState(
        _ state: VMFinalState,
        captured: PommeRecoveryRunState,
        reference: VMReference
    ) async throws -> Bool {
        _ = captured
        let observed = try liveRecoveryRunState(
            from: vmStatusPayload(reference: reference)
        )
        switch (state, observed) {
        case (.stopped, .stopped),
             (.normal, .running(.normal)),
             (.recovery, .running(.recovery)):
            return true
        case (.paused, .paused(let observedMode)):
            guard case .paused(let expectedMode) = captured else { return false }
            return observedMode == expectedMode
        default:
            return false
        }
    }

    private static func liveRecoveryRunState(
        from payload: [String: Any]
    ) throws -> PommeRecoveryRunState {
        let helperRunning = payload["helperRunning"] as? Bool == true
        let state = stringValue(payload["vmState"])
        if !helperRunning, state == "stopped" { return .stopped }
        guard helperRunning,
              let mode = BootMode(rawValue: stringValue(payload["bootMode"]))
        else {
            throw RunnerError.virtualMachineState(
                "The Pomme VM is not in a stable lifecycle state."
            )
        }
        switch state {
        case "running": return .running(mode)
        case "paused": return .paused(previousBootMode: mode)
        default:
            throw RunnerError.virtualMachineState(
                "The Pomme VM is not in a stable lifecycle state."
            )
        }
    }

    private struct RuntimeArguments: Sendable {
        let bundlePath: String
        let name: String?
        let bootMode: BootMode
    }

    private static func parseRuntimeArguments(_ arguments: [String]) throws -> RuntimeArguments {
        guard arguments.first == "--pomme-runtime" else {
            throw RunnerError.invalidControlCommand(arguments.first ?? "")
        }
        var bundlePath: String?
        var name: String?
        var bootMode: BootMode = .normal
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--bundle":
                guard index + 1 < arguments.count, bundlePath == nil else { throw RunnerError.usage }
                bundlePath = arguments[index + 1]
                index += 2
            case "--name":
                guard index + 1 < arguments.count, name == nil else { throw RunnerError.usage }
                name = arguments[index + 1]
                index += 2
            case "--mode":
                guard index + 1 < arguments.count, let parsed = BootMode(rawValue: arguments[index + 1]) else { throw RunnerError.usage }
                bootMode = parsed
                index += 2
            default:
                throw RunnerError.usage
            }
        }
        guard let bundlePath, !bundlePath.isEmpty else { throw RunnerError.usage }
        let canonical = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        guard canonical == bundlePath else { throw RunnerError.usage }
        if let name { _ = try validateVMName(name) }
        return .init(bundlePath: bundlePath, name: name, bootMode: bootMode)
    }

    private static func startRuntimeInBackground(
        reference: VMReference,
        bootMode: BootMode,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        PommeProgressContext.sink?.step(vm: reference.name, bootMode == .recovery ? "Starting Recovery" : "Starting macOS")
        let bundle = reference.bundle
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if let existing = try? runtimeRecord(for: bundle) {
            var status = try sendControlObject(
                ["command": "status"],
                bundle: bundle,
                timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
            )
            let runningMode = stringValue(status["bootMode"])
            guard runningMode == bootMode.rawValue else {
                throw RunnerError.virtualMachineState(
                    "\(reference.displayName) is already running in \(runningMode) boot mode. Stop it before starting \(bootMode.rawValue) boot mode."
                )
            }
            status["reused"] = true
            status["pid"] = Int(existing.pid)
            return status
        }
        try bundle.validateForRun()
        let executable = try runningExecutableIdentity().url
        let logHandle: FileHandle
        if !FileManager.default.fileExists(atPath: bundle.helperLogURL.path) {
            FileManager.default.createFile(atPath: bundle.helperLogURL.path, contents: nil)
        }
        logHandle = try FileHandle(forWritingTo: bundle.helperLogURL)
        try logHandle.truncate(atOffset: 0)
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--pomme-runtime", "--bundle", bundle.rootURL.path,
            "--mode", bootMode.rawValue
        ] + (reference.name.map { ["--name", $0] } ?? [])
        process.currentDirectoryURL = bundle.rootURL
        // Owner credentials are consumed by the invoking security workflow;
        // a long-lived VM helper must never inherit that environment pair.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !["POMME_AUTHORIZED_USER", "POMME_AUTHORIZED_PASSWORD"].contains($0.key)
        }
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        try waitForRuntime(
            process: process,
            bundle: bundle,
            timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
        )
        try? logHandle.close()
        let status = try sendControlObject(
            ["command": "status"],
            bundle: bundle,
            timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
        )
        var payload = status
        payload["operation"] = bootMode == .normal ? "start-normal" : "start-recovery"
        payload["name"] = reference.name as Any
        payload["pid"] = Int(process.processIdentifier)
        payload["hostExitCode"] = 0
        return payload
    }

    private static func waitForRuntime(process: Process, bundle: BundleLayout, timeout: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard process.isRunning else {
                process.waitUntilExit()
                throw RunnerError.backgroundStartFailed(status: process.terminationStatus, logURL: bundle.helperLogURL)
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0,
               (try? sendControlObject(
                   ["command": "status"], bundle: bundle, timeout: remaining
               )) != nil {
                return
            }
            let sleepInterval = min(
                0.1, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            Thread.sleep(forTimeInterval: sleepInterval)
        }
        throw RunnerError.backgroundStartTimedOut(pid: process.processIdentifier, logURL: bundle.helperLogURL)
    }

    private static func runForegroundRuntime(reference: VMReference, bootMode: BootMode) async throws {
        guard VZVirtualMachine.isSupported else { throw RunnerError.unsupportedHost }
        let bundle = reference.bundle
        try bundle.validateForRun()
        let plan = try loadOwnedProvisioningPlan(reference: reference)
        guard plan.vm.bundlePath == bundle.rootURL.standardizedFileURL.path,
              plan.vm.name == (reference.name ?? plan.vm.name)
        else { throw PommeProvisioningError.ownershipMismatch }
        // Ordinary Recovery boots carry only the empty terminal bootstrap
        // share. No credential or launcher is staged until the first
        // terminal session requests admission.
        let retained = try await startProvisioningRuntime(
            plan: plan,
            mode: bootMode,
            attachAgent: bootMode == .normal
        )
        let exitSignal = ExitSignal()
        let server = PommeControlServer(
            socketURL: bundle.pommeSocketURL,
            afterResponse: { request, _ in
                guard case .lifecycle(let command, _) = request,
                      command == .stop || command == .forceStop
                else { return }
                await exitSignal.endExitHold()
            },
            streamHandler: { request, stream in
                await runtimeStreamResponse(
                    request,
                    stream: stream,
                    runtime: retained.runtime,
                    normalGuest: bootMode == .normal
                )
            },
            handler: { request in
                await runtimeControlResponse(
                    request,
                    runtime: retained.runtime,
                    exitSignal: exitSignal,
                    bundle: bundle
                )
            }
        )
        try server.start()
        let recordURL = try writeRuntimeRecord(name: reference.name, bundle: bundle)
        await exitSignal.wait()
        // The CLI process must not exit while teardown and record removal
        // are merely queued in an unstructured task. Otherwise the next
        // security boot can find a dead helper's retained record.
        server.stop()
        await retained.runtime.teardown()
        retained.coordinator?.teardown()
        guard retained.runtime.terminalCleanupIsVerified() else {
            throw RunnerError.virtualMachineState("Recovery terminal cleanup could not be proven complete.")
        }
        let record = try JSONDecoder().decode(
            PommeRuntimeRecord.self, from: Data(contentsOf: recordURL))
        guard record.pid == Darwin.getpid(),
              record.bundlePath == bundle.rootURL.standardizedFileURL.path,
              record.socketPath == bundle.pommeSocketURL.path else {
            throw RunnerError.virtualMachineState("The VM helper's runtime record changed during teardown.")
        }
        try FileManager.default.removeItem(at: recordURL)
    }

    private static func runtimeRecordURL(for bundle: BundleLayout) throws -> URL {
        try runtimeDirectory().appendingPathComponent(
            "\(stableIdentifier(for: bundle.rootURL.standardizedFileURL.path)).json"
        )
    }

    private static func writeRuntimeRecord(name: String?, bundle: BundleLayout) throws -> URL {
        let record = PommeRuntimeRecord(
            id: UUID().uuidString.lowercased(),
            name: name,
            bundlePath: bundle.rootURL.standardizedFileURL.path,
            socketPath: bundle.pommeSocketURL.path,
            pid: Darwin.getpid(),
            startedAt: Date().pommeISO8601String
        )
        let url = try runtimeRecordURL(for: bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(try encoder.encode(record), to: url)
        return url
    }

    /// The helper's reply to a lifecycle command. `changed` is false when the
    /// VM was already in the requested state; `stopMethod` says whether the
    /// guest shut itself down or was powered off.
    static func lifecycleReply(
        _ command: PommeLifecycleCommand,
        changed: Bool,
        stopOutcome: VMStopOutcome? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true, "operation": command.rawValue, "changed": changed, "hostExitCode": 0
        ]
        if let stopOutcome { payload["stopMethod"] = stopOutcome.rawValue }
        return payload
    }

    private static func runtimeControlResponse(
        _ request: PommeVMControlRequest,
        runtime: PommeVMRuntime,
        exitSignal: ExitSignal,
        bundle: BundleLayout
    ) async -> String {
        do {
            switch request {
            case .lifecycle(let command, let guestShutdownRequested):
                let changed: Bool
                var stopOutcome: VMStopOutcome?
                switch command {
                case .pause: changed = try await runtime.pause()
                case .resume: changed = try await runtime.resume()
                case .stop, .forceStop:
                    await exitSignal.beginExitHold()
                    // The response-completion hook releases this hold after
                    // success or failure is written. A concurrent guest-stop
                    // notification remains pending until then as well.
                    let outcome = command == .forceStop
                        ? try await runtime.forceStopNow()
                        : try await runtime.stop(expectingGuestShutdown: guestShutdownRequested)
                    stopOutcome = outcome
                    changed = outcome.changedState
                    await exitSignal.requestExit()
                }
                return try jsonLine(lifecycleReply(command, changed: changed, stopOutcome: stopOutcome))
            case .snapshotSave(let request):
                try await runtime.saveSnapshotMachineState(in: request.stageName)
                return try jsonLine(["ok": true, "operation": "snapshot-save", "hostExitCode": 0])
            case .status:
                return try jsonLine(await runtime.statusPayload(bundle: bundle, inspect: false))
            case .inspect:
                return try jsonLine(await runtime.statusPayload(bundle: bundle, inspect: true))
            case .guestUI(let request):
                let payload = try await runtime.performUI(request)
                return try jsonLine(payload.mapValues(\.publicValue))
            case .terminalSession(let request, let streaming):
                guard !streaming, request.operation != "terminal.attach" else {
                    throw RunnerError.invalidControlCommand("terminal.session")
                }
                return try await terminalSessionControlResponse(request, runtime: runtime)
            case .agentPerform(let request, _):
                if PommeSecurityDesktopCleanup.handles(request) {
                    return try await securityDesktopCleanupControlResponse(request, runtime: runtime)
                }
                if isSecurityNormalAMFI(request) {
                    return await securityNormalAMFIControlResponse(request, runtime: runtime)
                }
                if isBufferedForeground(request) {
                    return try await foregroundControlResponse(request, runtime: runtime)
                }
                let result = try await runtime.performGuestOperationCorrelated(request.operation, payload: request.payload)
                return try correlatedResultJSON(result)
            case .logsShow, .logsStream:
                throw RunnerError.invalidControlCommand("Pomme log requires a streaming control request.")
            }
        } catch {
            var payload: [String: Any] = ["ok": false, "error": error.localizedDescription, "hostExitCode": 1]
            if let diagnosticFailure = error as? PommeRecoveryTerminalAdmissionControlFailure {
                payload.merge(diagnosticFailure.debugMetadata.controlPayload, uniquingKeysWith: { _, new in new })
            }
            return (try? jsonLine(payload))
                ?? "{\"ok\":false,\"hostExitCode\":1}"
        }
    }

    private static func terminalSessionControlResponse(
        _ request: PommeTerminalSessionControlRequest,
        runtime: PommeVMRuntime
    ) async throws -> String {
        let payload: [String: Any]
        switch request.operation {
        case "terminal.create":
            payload = try await runtime.terminalSessionCreate(payload: request.payload)
        case "terminal.list":
            let pageToken: String?
            if let value = request.payload["pageToken"] {
                guard let token = value.stringValue else { throw RunnerError.invalidControlCommand("terminal.session") }
                pageToken = token
            } else {
                pageToken = nil
            }
            let pageSize: Int
            if let value = request.payload["pageSize"] {
                guard case .integer(let raw) = value, raw > 0, let parsed = Int(exactly: raw) else {
                    throw RunnerError.invalidControlCommand("terminal.session")
                }
                pageSize = parsed
            } else {
                pageSize = 128
            }
            payload = try await runtime.terminalSessionList(pageToken: pageToken, pageSize: pageSize)
        case "terminal.inspect":
            payload = try await runtime.terminalSessionInspect(id: terminalSessionID(from: request.payload))
        case "terminal.logs":
            let id = try terminalSessionID(from: request.payload)
            let offset = try optionalOffset(request.payload["offset"]) ?? 0
            do {
                payload = try await runtime.terminalSessionLogs(id: id, offset: offset)
            } catch PommeDurableTerminalError.offsetBeyondEnd(let offset, let length) {
                // Carry both numbers so the CLI can name the valid range
                // without a second inspect round trip.
                return try jsonLine([
                    "ok": false,
                    "error": PommeDurableTerminalError.offsetBeyondEnd(offset: offset, length: length).localizedDescription,
                    "hostExitCode": 1,
                    "fromOffset": offset,
                    "transcriptOffset": length
                ])
            }
        case "terminal.terminate":
            let id = try terminalSessionID(from: request.payload)
            let force = try strictBoolean(request.payload["force"], default: false)
            payload = try await runtime.terminalSessionTerminate(id: id, force: force)
        case "terminal.delete":
            payload = try await runtime.terminalSessionDelete(id: terminalSessionID(from: request.payload))
        case "terminal.attach":
            throw RunnerError.invalidControlCommand("terminal.attach")
        default:
            throw RunnerError.invalidControlCommand(request.operation)
        }
        return try jsonLine(payload)
    }

    private static func terminalSessionID(from payload: [String: JSONValue]) throws -> UUID {
        guard let raw = payload["sessionID"]?.stringValue,
              let id = UUID(uuidString: raw),
              id.uuidString.lowercased() == raw.lowercased()
        else { throw RunnerError.invalidControlCommand("terminal.session") }
        return id
    }

    private static func optionalOffset(_ value: JSONValue?) throws -> UInt64? {
        guard let value else { return nil }
        guard case .integer(let raw) = value, raw >= 0,
              let offset = UInt64(exactly: raw)
        else { throw RunnerError.invalidControlCommand("terminal.session") }
        return offset
    }

    private static func strictBoolean(_ value: JSONValue?, default defaultValue: Bool) throws -> Bool {
        guard let value else { return defaultValue }
        guard case .bool(let result) = value else {
            throw RunnerError.invalidControlCommand("terminal.session")
        }
        return result
    }

    private static func runtimeStreamResponse(
        _ request: PommeVMControlRequest,
        stream: PommeControlStreamSession,
        runtime: PommeVMRuntime,
        normalGuest: Bool
    ) async -> String {
        if case .terminalSession(let operation, let streaming) = request {
            guard streaming, operation.operation == "terminal.attach" else {
                return "ERROR Pomme terminal streaming requires terminal.attach."
            }
            do {
                let sessionID = try Self.terminalSessionID(from: operation.payload)
                let takeover = try Self.strictBoolean(operation.payload["takeover"], default: false)
                let offset = try Self.optionalOffset(operation.payload["offset"])
                let result = try await runtime.terminalSessionAttach(
                    id: sessionID,
                    offset: offset,
                    takeover: takeover,
                    stream: stream
                )
                return try jsonLine(result)
            } catch {
                // The stream's terminal response is the control-plane error
                // channel.  Returning an `ok: false` JSON payload here would
                // make ControlServer wrap it in a successful response, so a
                // takeover/reconnect failure would look like a clean detach
                // to the CLI bridge.
                return "ERROR \(error.localizedDescription)"
            }
        }
        do {
            switch request {
            case .logsShow(let log):
                return try await logControlResponse(
                    payload: log.processPayload,
                    timeout: log.timeout,
                    stream: stream,
                    runtime: runtime,
                    normalGuest: normalGuest
                )
            case .logsStream(let log):
                return try await logControlResponse(
                    payload: log.processPayload,
                    timeout: nil,
                    stream: stream,
                    runtime: runtime,
                    normalGuest: normalGuest
                )
            case .agentPerform(let operation, _):
                return try await agentPerformStreamResponse(operation, stream: stream, runtime: runtime)
            default:
                return "ERROR Pomme control streaming is limited to agent.perform, Pomme log, or terminal.attach."
            }
        } catch {
            return (try? jsonLine(["ok": false, "error": error.localizedDescription, "hostExitCode": 1]))
                ?? "{\"ok\":false,\"hostExitCode\":1}"
        }
    }

    private static func agentPerformStreamResponse(
        _ operation: PommeAgentPerformRequest,
        stream: PommeControlStreamSession,
        runtime: PommeVMRuntime
    ) async throws -> String {
            if PommeSecurityDesktopCleanup.handles(operation) {
                return try await securityDesktopCleanupControlResponse(operation, runtime: runtime)
            }
            if isSecurityNormalAMFI(operation) {
                return await securityNormalAMFIControlResponse(operation, runtime: runtime)
            }
            if isSecurityPrivatePTY(operation) {
                return await securityPrivatePTYControlResponse(
                    operation,
                    stream: stream,
                    runtime: runtime
                )
            }
            if isPublicPTY(operation) {
                return try await publicPTYControlResponse(
                    operation,
                    stream: stream,
                    runtime: runtime
                )
            }
            if isBufferedForeground(operation) {
                do {
                    return try await foregroundControlResponse(operation, runtime: runtime) { frames in
                        try sendControlFrames(frames, through: stream)
                    }
                } catch {
                    if let diagnostic = desktopTransportFailureObject(error, payload: operation.payload) {
                        return try jsonLine(diagnostic)
                    }
                    throw error
                }
            }
            let result = try await runtime.performGuestOperationCorrelated(operation.operation, payload: operation.payload)
            guard let jobText = result.result.objectValue?["jobID"]?.stringValue,
                  let jobID = UUID(uuidString: jobText)
            else { return try correlatedResultJSON(result) }
            while true {
                let frame = try stream.receive()
                let data = try frame.decodedData()
                let guestStream: PommeAgentProtocol.Stream
                switch frame.stream {
                case .stdin: guestStream = frame.eof == true ? .eof : .stdin
                case .resize: guestStream = .resize
                case .signal: guestStream = .signal
                case .cancellation: guestStream = .eof
                case .stdout, .stderr, .progress: continue
                }
                let forwarded = try await runtime.sendGuestStream(
                    jobID: jobID,
                    stream: guestStream,
                    requestID: frame.id,
                    data: data,
                    dimensions: dimensions(from: frame.payload),
                    signal: signal(from: frame.payload)
                )
                try sendControlFrames(forwarded, through: stream)
                if frame.eof == true || frame.stream == .cancellation { break }
            }
            return try correlatedResultJSON(result)
    }

    /// A small synchronous probe state shared with the asynchronous log
    /// runner. Any malformed inbound client frame or socket read failure is
    /// retained so it cannot be misreported as a clean cancellation.
    private final class PommeLogInboundProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: Error?

        func shouldCancel(stream: PommeControlStreamSession) -> Bool {
            do {
                guard let frame = try stream.receiveIfAvailable(timeout: 0.025) else { return false }
                guard frame.stream == .cancellation else {
                    record(RunnerError.invalidControlResponse("Unexpected Pomme log input stream."))
                    return true
                }
                return true
            } catch {
                record(error)
                return true
            }
        }

        func recordedFailure() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        private func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if failure == nil { failure = error }
        }
    }

    /// Runs the closed `/usr/bin/log` request through one pinned persistent
    /// agent session. Recovery has no persistent agent and is rejected before
    /// the process-start exchange.
    private static func logControlResponse(
        payload: JSONValue,
        timeout: TimeInterval?,
        stream: PommeControlStreamSession,
        runtime: PommeVMRuntime,
        normalGuest: Bool
    ) async throws -> String {
        guard normalGuest else {
            throw RunnerError.guestAgentError("Pomme log is unavailable while the VM is booted in Recovery.")
        }
        let pinned = try runtime.captureAuthenticatedAgentSession(as: .normal)
        let description = try await pinned.request(operation: "agent.describe")
        guard supportsPommeLog(description) else {
            throw RunnerError.guestAgentError(
                "The running guest agent does not support Pomme log streaming. Start the VM with a current normal guest agent."
            )
        }
        let inbound = PommeLogInboundProbe()
        do {
            let result = try await PommeLogStreamExecution.run(
                payload: payload,
                timeout: timeout,
                perform: { operation, values in
                    try await pinned.requestCorrelated(operation: operation, payload: values)
                },
                sendStream: { jobID, kind, data in
                    try await pinned.sendStream(
                        jobID: jobID,
                        stream: kind,
                        requestID: UUID(),
                        data: data
                    )
                },
                shouldCancel: {
                    inbound.shouldCancel(stream: stream)
                },
                onFrames: { frames in
                    try sendControlFrames(frames, through: stream)
                }
            )
            if let failure = inbound.recordedFailure() { throw failure }
            return try logResultJSON(result, cleanupConfirmed: true)
        } catch {
            if let failure = inbound.recordedFailure() { throw failure }
            if let logError = error as? PommeLogStreamExecution.Error {
                switch logError {
                case .interrupted(let reason):
                    let code = reason == .timedOut ? 124 : 130
                    return try jsonLine([
                        "ok": false,
                        "error": logError.localizedDescription,
                        "hostExitCode": code,
                        "cleanupConfirmed": true,
                    ])
                case .cleanupUnconfirmed:
                    return try jsonLine([
                        "ok": false,
                        "error": logError.localizedDescription,
                        "hostExitCode": 1,
                        "cleanupConfirmed": false,
                    ])
                default:
                    break
                }
            }
            throw error
        }
    }

    /// This checks the describe receipt before process creation. A helper can
    /// be newer than its installed guest agent, so the control command must
    /// not assume `process.start` will be accepted just because the VM runs.
    static func supportsPommeLog(_ description: JSONValue) -> Bool {
        guard let object = description.objectValue,
              object["role"] == .string("persistent"),
              object["protocol"] == .string(PommeAgentProtocol.name),
              object["version"] == .integer(Int64(PommeAgentProtocol.version)),
              case .array(let rawCapabilities)? = object["capabilities"],
              rawCapabilities.allSatisfy({ $0.stringValue != nil })
        else { return false }
        return Set(rawCapabilities.compactMap(\.stringValue)).isSuperset(of: [
            "process.start", "process.status", "process.signal",
        ])
    }

    private static func logResultJSON(
        _ result: PommeAgentCorrelatedResult,
        cleanupConfirmed: Bool
    ) throws -> String {
        guard let terminal = result.result.objectValue,
              terminal["exited"] == .bool(true)
        else { throw PommeAgentProtocol.Error.invalidResponse }
        let exitCode: Int
        if case .integer(let value)? = terminal["exitCode"], (0...255).contains(value), terminal["signal"] == nil {
            exitCode = Int(value)
        } else if case .integer(let value)? = terminal["signal"], (1...127).contains(value), terminal["exitCode"] == nil {
            exitCode = 128 + Int(value)
        } else {
            throw PommeAgentProtocol.Error.invalidResponse
        }
        return try jsonLine([
            "ok": exitCode == 0,
            "requestID": result.requestID.uuidString.lowercased(),
            "result": result.result.publicValue,
            "hostExitCode": exitCode,
            "cleanupConfirmed": cleanupConfirmed,
        ])
    }

    private static func securityDesktopCleanupControlResponse(
        _ request: PommeAgentPerformRequest, runtime: PommeVMRuntime
    ) async throws -> String {
        let response = await PommeSecurityDesktopCleanup.perform(
            operation: request.operation, payload: request.payload,
            capture: { try runtime.captureAuthenticatedAgentSession(as: .normal) }
        )
        guard let object = response.objectValue else {
            throw RunnerError.invalidControlResponse("Desktop cleanup envelope is invalid.")
        }
        return try jsonLine(object.mapValues(\.publicValue))
    }

    private static func isSecurityPrivatePTY(_ request: PommeAgentPerformRequest) -> Bool {
        request.operation == "process.start"
            && request.payload?.objectValue?[privatePTYMarker] == .bool(true)
    }

    private static func isSecurityNormalAMFI(_ request: PommeAgentPerformRequest) -> Bool {
        PommeSecurityNormalAgent.normalAMFIOperations.contains(request.operation)
    }

    /// Verifies the exact normal-agent describe receipt. This is intentionally
    /// JSONValue-native so booleans, strings, and fractional numbers cannot be
    /// accepted as capability/version integers through Foundation coercions.
    static func normalAMFICapabilityReceipt(
        _ description: JSONValue,
        expectedExecutableDigest: String
    ) -> Bool {
        guard PommeProvisioningDigest.isSHA256(expectedExecutableDigest),
              expectedExecutableDigest == expectedExecutableDigest.lowercased(),
              let object = description.objectValue,
              object["role"] == .string("persistent"),
              object["protocol"] == .string(PommeAgentProtocol.name),
              object["version"] == .integer(Int64(PommeAgentProtocol.version)),
              object["executableSHA256"] == .string(expectedExecutableDigest),
              object["normalAMFIWorkflowVersion"] == .integer(Int64(PommeSecurityNormalAgent.normalAMFIWorkflowVersion)),
              case .array(let rawCapabilities)? = object["capabilities"],
              rawCapabilities.allSatisfy({ $0.stringValue != nil })
        else { return false }
        return Set(rawCapabilities.compactMap(\.stringValue))
            .isSuperset(of: PommeSecurityNormalAgent.normalAMFIOperations)
    }

    /// Validates and strips the host-only digest marker after the pinned
    /// session's describe receipt has been verified. The forwarded guest
    /// payload is exactly the volume-group UUID, with no host control fields.
    static func normalAMFIForwardPayload(
        operation: String,
        payload: JSONValue,
        expectedExecutableDigest: String
    ) throws -> JSONValue {
        guard PommeSecurityNormalAgent.normalAMFIOperations.contains(operation),
              PommeProvisioningDigest.isSHA256(expectedExecutableDigest),
              expectedExecutableDigest == expectedExecutableDigest.lowercased(),
              let object = payload.objectValue,
              Set(object.keys) == [
                  PommeSecurityNormalAgent.normalAMFIDigestMarker,
                  "volumeGroupUUID",
              ],
              object[PommeSecurityNormalAgent.normalAMFIDigestMarker]
                  == .string(expectedExecutableDigest),
              let rawUUID = object["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawUUID),
              volumeGroupUUID.uuidString.lowercased() == rawUUID
        else { throw PommeSecurityNormalAgentError.invalidAMFIOperation }

        return .object(["volumeGroupUUID": .string(rawUUID)])
    }

    /// Handles a closed, credential-free normal-agent AMFI stage. The marker
    /// is checked before connection use but is removed only after a single
    /// authenticated session proves the persistent role, protocol, digest,
    /// capability version, and exact operation vocabulary.
    private static func securityNormalAMFIControlResponse(
        _ request: PommeAgentPerformRequest,
        runtime: PommeVMRuntime
    ) async -> String {
        do {
            guard let payload = request.payload?.objectValue,
                  Set(payload.keys) == [
                      PommeSecurityNormalAgent.normalAMFIDigestMarker,
                      "volumeGroupUUID",
                  ],
                  let expectedDigest = payload[PommeSecurityNormalAgent.normalAMFIDigestMarker]?.stringValue,
                  PommeProvisioningDigest.isSHA256(expectedDigest),
                  expectedDigest == expectedDigest.lowercased()
            else { throw PommeSecurityNormalAgentError.invalidAMFIOperation }

            let pinned = try runtime.captureAuthenticatedAgentSession(as: .normal)
            let description = try await pinned.request(
                operation: "agent.describe",
                payload: .object(["includeNormalAMFICapabilities": .bool(true)])
            )
            guard Self.normalAMFICapabilityReceipt(
                description, expectedExecutableDigest: expectedDigest
            ) else {
                throw PommeSecurityNormalAgentError.unsupportedAMFIWorkflow
            }

            // Keep this call after the same-session describe check. It is the
            // only point where the host marker is removed from the payload.
            let forwarded = try Self.normalAMFIForwardPayload(
                operation: request.operation,
                payload: .object(payload),
                expectedExecutableDigest: expectedDigest
            )
            let result = try await pinned.request(
                operation: request.operation, payload: forwarded
            )
            guard let object = result.objectValue,
                  object["operation"] == .string(request.operation),
                  object["verified"] == .bool(true)
            else { throw PommeSecurityNormalAgentError.unverifiedAMFIResponse }

            return try jsonLine([
                "ok": true,
                "operation": request.operation,
                "result": result.publicValue,
                "hostExitCode": 0,
            ])
        } catch {
            return Self.normalAMFIErrorResponse(error)
        }
    }

    private static func normalAMFIErrorResponse(_ error: Error) -> String {
        let code: String
        if let error = error as? PommeSecurityNormalAgentError {
            switch error {
            case .invalidAMFIOperation:
                code = "invalid-operation"
            case .unsupportedAMFIWorkflow:
                code = "unsupported-operation"
            case .unverifiedAMFIResponse:
                code = "normal-amfi-unverified"
            case .invalidRebootTimeout, .bootIdentityUnavailable, .rebootRequestFailed,
                 .rebootDidNotStop, .rebootStartFailed, .rebootBootIdentityUnchanged,
                 .rebootAgentUnverified, .unverifiedSIPClear:
                code = "normal-amfi-unverified"
            }
        } else if let error = error as? PommeAgentSessionError {
            if error.code == "unsupported-operation" || error.code == "invalid-operation" {
                code = error.code
            } else if PommeRecoveryGuestFailureCode(rawValue: error.code) != nil {
                code = error.code
            } else {
                code = "normal-amfi-failed"
            }
        } else {
            code = "normal-amfi-failed"
        }
        return (try? jsonLine([
            "ok": false,
            "error": "Normal AMFI operation failed.",
            "failureCode": code,
            "hostExitCode": 1,
        ])) ?? "{\"ok\":false,\"error\":\"Normal AMFI operation failed.\",\"failureCode\":\"normal-amfi-failed\",\"hostExitCode\":1}"
    }

    /// Handles the host-side private PTY request inside the VM helper. The
    /// guest sees only the sanitized process.start payload. A concrete
    /// persistent session is pinned before its describe proof and all runner
    /// operations use that pin.
    private static func securityPrivatePTYControlResponse(
        _ request: PommeAgentPerformRequest,
        stream: PommeControlStreamSession,
        runtime: PommeVMRuntime
    ) async -> String {
        do {
            guard var payload = request.payload?.objectValue,
                  payload[privatePTYMarker] == .bool(true),
                  let expectedDigest = payload[privatePTYDigestMarker]?.stringValue,
                  PommeProvisioningDigest.isSHA256(expectedDigest),
                  expectedDigest == expectedDigest.lowercased(),
                  let path = payload["path"]?.stringValue,
                  case .array(let rawArguments)? = payload["arguments"],
                  payload["pty"] == .bool(true),
                  payload["detached"] == .bool(false)
            else { throw PommePrivatePTYRunner.Error.invalidCommand }
            let arguments = rawArguments.compactMap(\.stringValue)
            guard arguments.count == rawArguments.count else {
                throw PommePrivatePTYRunner.Error.invalidCommand
            }
            payload.removeValue(forKey: privatePTYMarker)
            payload.removeValue(forKey: privatePTYDigestMarker)

            let pinned = try runtime.captureAuthenticatedAgentSession(as: .normal)
            let transport = PommePrivatePTYRunner.Transport(
                perform: { operation, values in
                    try await pinned.requestCorrelated(operation: operation, payload: values)
                },
                sendStream: { jobID, kind, data, signal in
                    try await pinned.sendStream(
                        jobID: jobID,
                        stream: kind,
                        requestID: UUID(),
                        data: data,
                        dimensions: nil,
                        signal: signal
                    )
                },
                validateSession: {
                    let description = try await pinned.request(
                        operation: "agent.describe",
                        payload: .object(["includePrivatePTYCapabilities": .bool(true)])
                    )
                    guard let object = description.objectValue,
                          object["role"] == .string("persistent"),
                          object["protocol"] == .string(PommeAgentProtocol.name),
                          object["version"] == .integer(Int64(PommeAgentProtocol.version)),
                          object["executableSHA256"] == .string(expectedDigest),
                          object["privatePTYInputVersion"] == .integer(Int64(PommeAgent.privatePTYInputVersion)),
                          case .array(let capabilities)? = object["capabilities"],
                          Set(capabilities.compactMap(\.stringValue)).isSuperset(of: [
                              "process.start", "process.status", "process.signal"
                          ])
                    else { throw PommePrivatePTYRunner.Error.invalidCompletion }
                }
            )

            let command = PommePrivatePTYRunner.Command(path: path, arguments: arguments)
            let prompt = privatePTYPrompt(for: .init(executable: path, arguments: arguments))
            let terminal = try await PommePrivatePTYRunner.run(
                command: command,
                secretProvider: {
                    let frame = try stream.receive(timeout: PommePrivatePTYRunner.defaultPromptTimeout)
                    guard frame.stream == .stdin, frame.eof != true,
                          let data = try frame.decodedData(),
                          let secret = String(data: data, encoding: .utf8)
                    else { throw PommePrivatePTYRunner.Error.transportFailure }
                    return secret
                },
                prompt: prompt,
                promptTimeout: PommePrivatePTYRunner.defaultPromptTimeout,
                processTimeout: PommePrivatePTYRunner.defaultProcessTimeout,
                transport: transport,
                onFrames: { frames in
                    try sendControlFrames(frames, through: stream)
                }
            )
            return try correlatedResultJSON(terminal)
        } catch {
            // Keep command output and credentials out of the host response.
            return (try? jsonLine([
                "ok": false,
                "error": "Private PTY request failed.",
                "failureCode": PommeSecurityPrivatePTYDiagnostic(error).rawValue,
                "hostExitCode": 1
            ])) ?? "{\"ok\":false,\"hostExitCode\":1}"
        }
    }

    private static func isBufferedForeground(_ request: PommeAgentPerformRequest) -> Bool {
        request.operation == "process.start"
            && request.payload?.objectValue?["detached"] != .bool(true)
            && request.payload?.objectValue?["pty"] != .bool(true)
    }

    private static func isPublicPTY(_ request: PommeAgentPerformRequest) -> Bool {
        request.operation == "process.start"
            && request.payload?.objectValue?["detached"] != .bool(true)
            && request.payload?.objectValue?["pty"] == .bool(true)
            && !isSecurityPrivatePTY(request)
    }

    private static func publicPTYControlResponse(
        _ request: PommeAgentPerformRequest,
        stream: PommeControlStreamSession,
        runtime: PommeVMRuntime
    ) async throws -> String {
        guard var values = request.payload?.objectValue else {
            throw RunnerError.invalidGuestCommand("Invalid public PTY command payload.")
        }
        // Interactive commands must retain normal terminal echo. The guest
        // defaults to echo-disabled PTYs for the private credential runner;
        // the relay verifies the matching start receipt before input flows.
        values["ptyEcho"] = .bool(true)
        let payload = JSONValue.object(values)
        let capability = try await runtime.performGuestOperationCorrelated(
            "agent.describe",
            payload: .object(["includePublicPTYCapabilities": .bool(true)])
        )
        guard PommePublicPTYRelay.supportsPublicEcho(capability.result) else {
            // An older persistent agent may otherwise reject ptyEcho only
            // after process.start routing. Refuse before any guest process is
            // created and require the explicit capability plus its start
            // receipt below.
            throw PommePublicPTYRelay.Error.publicEchoUnavailable
        }
        let timeout: TimeInterval
        switch payload.objectValue?["timeout"] {
        case .number(let value): timeout = value
        case .integer(let value): timeout = TimeInterval(value)
        case nil: timeout = Constants.defaultGuestCommandTimeout
        default: throw RunnerError.invalidGuestCommand("Invalid public PTY command timeout.")
        }
        let result = try await PommePublicPTYRelay.run(
            payload: payload,
            timeout: timeout,
            perform: { operation, values in
                try await runtime.performGuestOperationCorrelated(operation, payload: values)
            },
            sendStream: { jobID, kind, data, dimensions, signal in
                try await runtime.sendGuestStream(
                    jobID: jobID,
                    stream: kind,
                    requestID: UUID(),
                    data: data,
                    dimensions: dimensions,
                    signal: signal
                )
            },
            receiveControl: { timeout in
                try stream.receiveIfAvailable(timeout: timeout)
            },
            onFrames: { frames in
                try sendControlFrames(frames, through: stream)
            }
        )
        return try foregroundResultJSON(result)
    }

    private static func foregroundControlResponse(
        _ request: PommeAgentPerformRequest,
        runtime: PommeVMRuntime,
        onFrames: PommeForegroundExecution.FrameHandler? = nil
    ) async throws -> String {
        let payload = request.payload ?? .object([:])
        let timeout: TimeInterval
        switch payload.objectValue?["timeout"] {
        case .number(let value): timeout = value
        case .integer(let value): timeout = TimeInterval(value)
        case nil: timeout = Constants.defaultGuestCommandTimeout
        default: throw RunnerError.invalidGuestCommand("Invalid foreground command timeout.")
        }
        let result = try await PommeForegroundExecution.run(
            payload: payload,
            timeout: timeout,
            perform: { operation, values in
                try await runtime.performGuestOperationCorrelated(operation, payload: values)
            },
            sendStream: { jobID, kind, data in
                try await runtime.sendGuestStream(jobID: jobID, stream: kind, requestID: UUID(), data: data)
            },
            onFrames: onFrames
        )
        return try foregroundResultJSON(result)
    }

    /// Preserve the existing helper failure envelope while adding a closed
    /// cause only for exact desktop-proof commands. No error text is logged.
    static func desktopTransportFailureObject(
        _ error: Error,
        payload: JSONValue?
    ) -> [String: Any]? {
        guard let object = payload?.objectValue,
              PommeForegroundExecution.isDesktopProofPayload(object)
        else { return nil }
        return [
            "ok": false,
            "error": error.localizedDescription,
            "hostExitCode": 1,
            "desktopTransportCause": PommeSecurityNormalAgent.transportCause(for: error).rawValue,
        ]
    }

    static func foregroundResultJSON(_ result: PommeAgentCorrelatedResult) throws -> String {
        guard let terminal = result.result.objectValue else { throw PommeAgentProtocol.Error.invalidResponse }
        let exitCode: Int
        let error: String?
        let terminationRequested = terminal["terminationRequested"].flatMap { value -> Bool? in
            if case .bool(let requested) = value { return requested }
            return nil
        }
        if terminal["timedOut"] == .bool(true) {
            exitCode = 124
            error = PommeForegroundExecution.interruptionMessage(
                timedOut: true, terminationRequested: terminationRequested
            )
        } else if terminal["cancelled"] == .bool(true) {
            exitCode = 130
            error = PommeForegroundExecution.interruptionMessage(
                timedOut: false, terminationRequested: terminationRequested
            )
        } else if terminal["stdoutTruncated"] == .bool(true) || terminal["stderrTruncated"] == .bool(true) {
            exitCode = 1
            error = "Foreground output exceeded the buffered limit; output is incomplete."
        } else {
            guard terminal["exited"] == .bool(true) else { throw PommeAgentProtocol.Error.invalidResponse }
            if case .integer(let value)? = terminal["exitCode"], (0...255).contains(value), terminal["signal"] == nil {
                exitCode = Int(value)
            } else if case .integer(let value)? = terminal["signal"], (1...127).contains(value), terminal["exitCode"] == nil {
                exitCode = 128 + Int(value)
            } else { throw PommeAgentProtocol.Error.invalidResponse }
            error = nil
        }
        var object: [String: Any] = [
            "ok": exitCode == 0,
            "requestID": result.requestID.uuidString.lowercased(),
            "result": result.result.publicValue,
            "streamFrames": result.streamFrames.map(agentStreamPayload),
            "hostExitCode": exitCode,
        ]
        if let error { object["error"] = error }
        return try jsonLine(object)
    }

    private static func correlatedResultJSON(_ result: PommeAgentCorrelatedResult) throws -> String {
        let frames = result.streamFrames.map(agentStreamPayload)
        return try jsonLine([
            "ok": true,
            "requestID": result.requestID.uuidString.lowercased(),
            "result": result.result.publicValue,
            "streamFrames": frames,
            "hostExitCode": 0
        ])
    }

    static func agentStreamPayload(_ frame: PommeAgentJobStreamFrame) -> [String: Any] {
        var payload: [String: Any] = [
            "jobID": frame.jobID.uuidString.lowercased(),
            "requestID": frame.frame.requestID.uuidString.lowercased(),
            "stream": frame.frame.stream.rawValue
        ]
        if let data = frame.frame.data { payload["dataBase64"] = data.base64EncodedString() }
        if let dimensions = frame.frame.dimensions {
            payload["columns"] = dimensions.columns
            payload["rows"] = dimensions.rows
        }
        if let signal = frame.frame.signal { payload["signal"] = signal }
        return payload
    }

    private static func sendControlFrames(
        _ frames: [PommeAgentJobStreamFrame],
        through stream: PommeControlStreamSession
    ) throws {
        for frame in frames {
            let controlStream: PommeControlStreamFrame.Stream
            let eof: Bool?
            let payload: JSONValue?
            switch frame.frame.stream {
            case .stdout: controlStream = .stdout; eof = nil; payload = nil
            case .stderr: controlStream = .stderr; eof = nil; payload = nil
            case .eof: controlStream = .stdout; eof = true; payload = nil
            case .exit:
                controlStream = .progress
                eof = nil
                payload = .object(["jobID": .string(frame.jobID.uuidString.lowercased()), "stream": .string("exit")])
            case .stdin, .resize, .signal: continue
            }
            try stream.send(stream: controlStream, data: frame.frame.data, payload: payload, eof: eof)
        }
    }

    private static func dimensions(from payload: JSONValue?) -> (columns: Int, rows: Int)? {
        guard let object = payload?.objectValue,
              case .integer(let columns)? = object["columns"],
              case .integer(let rows)? = object["rows"],
              let columns = Int(exactly: columns), let rows = Int(exactly: rows)
        else { return nil }
        return (columns, rows)
    }

    private static func signal(from payload: JSONValue?) -> Int32? {
        guard let object = payload?.objectValue,
              case .integer(let value)? = object["signal"] else { return nil }
        return Int32(exactly: value)
    }

    static func resumeProvisioning(
        name: String,
        lease: VMBundleMutationLease
    ) async throws -> PommeOperationResult {
        PommeProgressContext.sink?.step(vm: name, "Resuming creation")
        guard lease.validates(name: name) else {
            throw VMBundleMutationLease.Error.invalidScope(name: name)
        }
        let reference = try namedVMReference(name, requireExists: true)
        if try provisioningSchema(bundle: reference.bundle) == 2 {
            let journal = try loadProvisioningV2(reference: reference)
            _ = try loadOwnedProvisioningPlan(reference: reference)
            let key = try PommeSSHBootstrap.privateRead(provisioningKeyURL(bundle: reference.bundle),
                owner: geteuid(), allowedModes: [0o600])
            try await PommeProvisioningV2Orchestrator(
                signer: PommeProvisioningV2Signer(key: key),
                repository: provisioningV2Repository(bundle: reference.bundle, key: key),
                effects: provisioningV2Effects()).resume(expectedPlan: journal.plan)
            var payload: [String: Any] = ["ok": true, "operation": "create-resume", "name": name,
                "bundlePath": reference.standardizedPath, "hostExitCode": 0,
                "provisioning": ["schema": 2, "planDigest": journal.plan.digest,
                    "finalState": journal.plan.finalState.rawValue,
                    "journal": provisioningV2JournalURL(bundle: reference.bundle).path]]
            payload.merge(provisioningDisclosure(virtualization: true)) { _, new in new }
            PommeProgressContext.sink?.complete(vm: name)
            return .init(title: "Resume Create", vmName: name, ok: true, hostExitCode: 0,
                text: "OK resumed Pomme provisioning for \(name).", payload: payload)
        }
        let signer = try provisioningSigner(bundleURL: reference.bundle.rootURL)
        let repository = try provisioningRepository(bundleURL: reference.bundle.rootURL, signer: signer)
        let journal = try repository.load()
        guard journal.plan.vm.name == name,
              journal.plan.vm.bundlePath == reference.bundle.rootURL.standardizedFileURL.path
        else { throw PommeProvisioningError.ownershipMismatch }
        let orchestrator = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: provisioningEffects()
        )
        try await orchestrator.resume(expectedPlan: journal.plan)
        var payload: [String: Any] = [
            "ok": true,
            "operation": "create-resume",
            "name": name,
            "bundlePath": reference.bundle.rootURL.path,
            "provisioning": [
                "planDigest": journal.plan.digest,
                "finalState": journal.plan.finalState.rawValue,
                "journal": provisioningJournalURL(bundle: reference.bundle).path
            ],
            "hostExitCode": 0
        ]
        payload.merge(provisioningDisclosure(virtualization: false)) { _, new in new }
        PommeProgressContext.sink?.complete(vm: name)
        return PommeOperationResult(
            title: "Resume Create",
            vmName: name,
            ok: true,
            hostExitCode: 0,
            text: "OK resumed Pomme provisioning for \(name).",
            payload: payload
        )
    }

    static func provisioningAgentStatus(name: String) async throws -> PommeAgentClosedStatus {
        let reference = try namedVMReference(name, requireExists: true)
        let payload = try vmStatusPayload(reference: reference)
        let agent = payload["guestAgent"] as? [String: Any]
        let connection = GuestAgentStatusV1.ConnectionState(rawValue: stringValue(agent?["connection"])) == .connected
            ? PommeAgentClosedStatus.Connection.connected
            : .disconnected
        let role = PommeProvisioningAgentRole(rawValue: stringValue(agent?["role"])) ?? .normal
        return .init(
            connection: connection,
            role: role,
            protocolVersion: Int(agent?["protocolVersion"] as? Int ?? 1),
            executableDigest: stringValue(agent?["executableDigest"]),
            capabilities: agent?["capabilities"] as? [String] ?? [],
            updateState: stringValue(agent?["updateState"])
        )
    }

    static func repairProvisioning(
        name: String,
        finalState: PommeAgentRepairFinalState,
        lease: VMBundleMutationLease
    ) async throws -> PommeOperationResult {
        guard lease.validates(name: name) else {
            throw VMBundleMutationLease.Error.invalidScope(name: name)
        }
        let reference = try namedVMReference(name, requireExists: true)
        let schema = try provisioningSchema(bundle: reference.bundle)
        let effects = provisioningEffects()
        if schema == 2 {
            let journal = try loadProvisioningV2(reference: reference)
            let plan = try loadOwnedProvisioningPlan(reference: reference)
            guard plan == journal.plan,
                  try await effects.verifyOwnership(plan.vm) == plan.vm else {
                throw PommeProvisioningError.ownershipMismatch
            }
            if try PommeProvisioningV2Coordinator.nextPhase(in: journal) == nil,
               let result = try alreadyHealthyAgentRepairResult(
                   name: name,
                   status: vmStatusPayload(reference: reference),
                   hostExecutableDigest: runningExecutableIdentity().sha256
               ) {
                return result
            }
        }
        try validateProvisioningRepairSchema(schema)
        let signer = try provisioningSigner(bundleURL: reference.bundle.rootURL)
        let repository = try provisioningRepository(bundleURL: reference.bundle.rootURL, signer: signer)
        let journal = try repository.load()
        let ownership = try await effects.verifyOwnership(journal.plan.vm)
        guard ownership == journal.plan.vm,
              journal.plan.vm.bundlePath == reference.standardizedPath,
              journal.plan.vm.name == name else {
            throw PommeProvisioningError.ownershipMismatch
        }
        let next: (phase: PommeProvisioningPhase, attempt: UInt64)
        do {
            next = try PommeProvisioningCoordinator.repairPhase(in: journal)
        } catch PommeProvisioningError.nothingToRepair {
            guard let result = try alreadyHealthyAgentRepairResult(
                name: name,
                status: vmStatusPayload(reference: reference),
                hostExecutableDigest: runningExecutableIdentity().sha256
            ) else {
                throw PommeProvisioningError.nothingToRepair(vmName: name)
            }
            return result
        }

        let state: PommeProvisioningFinalState
        switch finalState {
        case .previous:
            // `previous` is the state observed immediately before this
            // repair invocation, not the create plan's desired end state.
            // The latter is often `.normalRunning` even when a failed
            // bootstrap left the VM stopped.
            state = try capturedProvisioningFinalState(reference: reference)
        }

        // Repair is an external Recovery effect too: journal its intent before
        // starting it, then reconcile the failed phase with a receipt on
        // success. This makes a subsequent resume continue with verification
        // instead of repeating agent installation.
        let intent = try PommeProvisioningCoordinator.appendingIntent(
            to: journal,
            phase: next.phase,
            attempt: next.attempt,
            signer: signer
        )
        try repository.commit(intent, replacing: journal.generation)
        do {
            let receipt = try await effects.recoveryRepair(intent.plan, state)
            guard PommeProvisioningDigest.isSHA256(receipt) else {
                throw PommeProvisioningError.phaseFailed(.installRecoveryAgent)
            }
            let completed = try PommeProvisioningCoordinator.appendingResult(
                to: intent,
                kind: .receipt,
                phase: next.phase,
                attempt: next.attempt,
                receiptDigest: receipt,
                signer: signer
            )
            try repository.commit(completed, replacing: intent.generation)
        } catch {
            // Repair reports the same redacted failure code the orchestrator
            // logs, so the command that exists to diagnose a retained journal
            // does not say strictly less than `create --resume` about the same
            // failure.
            warning(
                "provisioning phase \(next.phase.rawValue) failed "
                    + "[code=\(PommeProvisioningFailureDiagnostic.code(for: error))].",
                vmName: intent.plan.vm.name
            )
            let digest = PommeProvisioningDigest.sha256(Data(String(describing: error).utf8))
            let failed = try PommeProvisioningCoordinator.appendingResult(
                to: intent,
                kind: .failure,
                phase: next.phase,
                attempt: next.attempt,
                receiptDigest: digest,
                signer: signer
            )
            try repository.commit(failed, replacing: intent.generation)
            throw PommeProvisioningError.phaseFailed(next.phase, vmName: intent.plan.vm.name)
        }
        let payload: [String: Any] = [
            "ok": true,
            "operation": "agent-repair",
            "name": name,
            "finalState": state.rawValue,
            "journalReconciled": true,
            "role": PommeProvisioningAgentRole.recovery.rawValue,
            "hostExitCode": 0
        ]
        return PommeOperationResult(
            title: "Agent Repair",
            vmName: name,
            ok: true,
            hostExitCode: 0,
            text: "OK repaired the Pomme agent through Recovery for \(name).",
            payload: payload
        )
    }

    /// Call only after verifying ownership and a completed provisioning journal.
    /// Connected status comes from the helper's authenticated agent session.
    static func alreadyHealthyAgentRepairResult(
        name: String,
        status: [String: Any],
        hostExecutableDigest: String
    ) -> PommeOperationResult? {
        guard let agent = status["guestAgent"] as? [String: Any],
              agent["connection"] as? String == GuestAgentStatusV1.ConnectionState.connected.rawValue,
              agent["role"] as? String == PommeProvisioningAgentRole.normal.rawValue,
              let rawProtocolVersion = agent["protocolVersion"],
              case .integer(let protocolVersion) = try? JSONValue(any: rawProtocolVersion),
              protocolVersion == Int64(PommeAgentProtocol.version),
              PommeProvisioningDigest.isSHA256(hostExecutableDigest),
              agent["executableDigest"] as? String == hostExecutableDigest,
              let capabilities = agent["capabilities"] as? [String],
              supportsProvisioningAgentCapabilities(capabilities) else { return nil }
        return PommeOperationResult(
            title: "Agent Repair",
            vmName: name,
            ok: true,
            hostExitCode: 0,
            text: "Pomme agent is already healthy for \(name).",
            payload: [
                "ok": true,
                "operation": "agent-repair",
                "name": name,
                "alreadyHealthy": true,
                "hostExitCode": 0
            ]
        )
    }

    static func validateProvisioningRepairSchema(_ schema: Int) throws {
        guard schema == 1 else {
            throw RunnerError.hostCommandFailed(
                "Recovery agent repair is unavailable for framework-provisioned VMs. Use `pomme inspect NAME` for diagnosis or `pomme create NAME --resume` to resume incomplete creation."
            )
        }
    }

    /// Convert a status snapshot into the only final-state vocabulary that an
    /// agent-repair request can safely carry. Transient and paused states are
    /// rejected rather than silently changing the caller's requested prior
    /// state; a future paused-state repair must add an explicit journal/schema
    /// representation first.
    static func capturedProvisioningFinalState(
        from status: [String: Any]
    ) throws -> PommeProvisioningFinalState {
        guard let helperRunning = status["helperRunning"] as? Bool else {
            throw RunnerError.virtualMachineState("Pomme could not capture the VM run state before agent repair.")
        }
        guard helperRunning else { return .stopped }

        let vmState = stringValue(status["vmState"])
        if vmState == "stopped" { return .stopped }
        guard vmState == "running" else {
            throw RunnerError.virtualMachineState("Pomme could not capture a stable VM run state before agent repair.")
        }
        switch BootMode(rawValue: stringValue(status["bootMode"])) {
        case .normal: return .normalRunning
        case .recovery: return .recoveryRunning
        case nil:
            throw RunnerError.virtualMachineState("Pomme could not identify the VM boot mode before agent repair.")
        }
    }

    private static func capturedProvisioningFinalState(
        reference: VMReference
    ) throws -> PommeProvisioningFinalState {
        try capturedProvisioningFinalState(from: vmStatusPayload(reference: reference))
    }

    /// The stop response can arrive before its helper exits. Keep deletion
    /// behind proof that the helper is gone, while the caller holds its lease.
    static func waitForDeletionHelperExit(reference: VMReference) throws {
        try waitForDeletionHelperExit {
            do {
                _ = try runtimeRecord(for: reference.bundle)
                return true
            } catch RunnerError.noRunningVM {
                return false
            }
        }
    }

    static func waitForDeletionHelperExit(
        timeout: TimeInterval = Constants.gracefulStopTimeoutSeconds,
        pollInterval: TimeInterval = 0.1,
        helperIsRunning: () throws -> Bool
    ) throws {
        guard timeout.isFinite, timeout >= 0, pollInterval.isFinite, pollInterval > 0 else {
            throw RunnerError.virtualMachineState("Invalid VM deletion helper wait configuration.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while try helperIsRunning() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw RunnerError.virtualMachineState(
                    "Refusing VM deletion because its helper did not exit after stopping."
                )
            }
            Thread.sleep(forTimeInterval: min(pollInterval, remaining))
        }
    }

    static func requireDeletionStopSucceeded(_ payload: [String: Any]) throws {
        guard payload["ok"] as? Bool == true else {
            throw RunnerError.hostCommandFailed(
                "Refusing VM deletion because its helper did not stop cleanly."
            )
        }
    }

    enum RequiredSnapshotRestoreStartupError: Error, Equatable, LocalizedError {
        case invalidPollingConfiguration
        case helperExited(pid: Int32, lastObservation: String)
        case timedOut(pid: Int32, lastObservation: String)

        var errorDescription: String? {
            switch self {
            case .invalidPollingConfiguration:
                "Snapshot restore polling requires a nonnegative timeout and positive interval."
            case let .helperExited(pid, lastObservation):
                "Snapshot restore helper pid \(pid) exited before reaching paused normal state. Last observation: \(lastObservation)"
            case let .timedOut(pid, lastObservation):
                "Timed out waiting for snapshot restore helper pid \(pid) to reach paused normal state. Last observation: \(lastObservation)"
            }
        }
    }

    static func waitForRequiredSnapshotRestorePausedNormal(
        helperPID: Int32,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 0.25,
        helperIsRunning: () throws -> Bool,
        pollStatus: () throws -> [String: Any],
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = Thread.sleep
    ) throws -> [String: Any] {
        guard timeout >= 0, pollInterval > 0 else {
            throw RequiredSnapshotRestoreStartupError.invalidPollingConfiguration
        }

        let deadline = now().addingTimeInterval(timeout)
        var lastObservation = "no control status received"
        while true {
            guard try helperIsRunning() else {
                throw RequiredSnapshotRestoreStartupError.helperExited(
                    pid: helperPID,
                    lastObservation: lastObservation
                )
            }
            do {
                let status = try pollStatus()
                let vmState = status["vmState"] as? String ?? "unknown"
                let bootMode = status["bootMode"] as? String ?? "unknown"
                let helperRunning = (status["helperRunning"] as? Bool).map(String.init) ?? "unknown"
                let operationOK = (status["ok"] as? Bool).map(String.init) ?? "unknown"
                lastObservation = "vmState=\(vmState) bootMode=\(bootMode) helperRunning=\(helperRunning) ok=\(operationOK)"
                if vmState == "paused",
                   bootMode == BootMode.normal.rawValue,
                   (status["helperRunning"] as? Bool) == true,
                   (status["ok"] as? Bool) != false {
                    return status
                }
            } catch {
                lastObservation = "control error: \(error.localizedDescription)"
            }
            let current = now()
            guard current < deadline else {
                throw RequiredSnapshotRestoreStartupError.timedOut(
                    pid: helperPID,
                    lastObservation: lastObservation
                )
            }
            sleep(min(pollInterval, deadline.timeIntervalSince(current)))
        }
    }

    // MARK: Restore-image discovery

    /// The only version normalization accepted at the catalog boundary is a
    /// missing patch component whose value would be zero. In particular,
    /// this intentionally does not use a general semantic-version parser:
    /// `26.6.0.0`, `26.6.1`, and `26.06` must not silently select Tahoe.
    static func ipswVersionMatches(_ selection: String, catalogVersion: String) -> Bool {
        let requested = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = catalogVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, !catalog.isEmpty else { return false }
        if requested.caseInsensitiveCompare(catalog) == .orderedSame { return true }

        let requestedComponents = requested.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let catalogComponents = catalog.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard requestedComponents.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              catalogComponents.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return false }

        if requestedComponents.count == 2,
           catalogComponents.count == 3,
           catalogComponents[2] == "0" {
            return requestedComponents[0] == catalogComponents[0]
                && requestedComponents[1] == catalogComponents[1]
        }
        if requestedComponents.count == 3,
           requestedComponents[2] == "0",
           catalogComponents.count == 2 {
            return requestedComponents[0] == catalogComponents[0]
                && requestedComponents[1] == catalogComponents[1]
        }
        return false
    }

    enum IPSWDownloadResponseDecision: Equatable, Sendable {
        case overwrite
        case append
    }

    enum IPSWDownloadResponseError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedStatus(Int)
        case unexpectedPartialResponse
        case missingContentRange
        case invalidContentRange
        case contentRangeOffsetMismatch(expected: Int64, actual: Int64)
        case contentRangeSizeMismatch(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case let .unsupportedStatus(status):
                "The restore-image server returned HTTP \(status)."
            case .unexpectedPartialResponse:
                "The restore-image server returned a partial response for a fresh download."
            case .missingContentRange:
                "The restore-image server omitted Content-Range for a resumed download."
            case .invalidContentRange:
                "The restore-image server returned an invalid Content-Range header."
            case let .contentRangeOffsetMismatch(expected, actual):
                "The restore-image server resumed at byte \(actual), expected byte \(expected)."
            case let .contentRangeSizeMismatch(expected, actual):
                "The restore-image server advertised \(actual) bytes, expected \(expected)."
            }
        }
    }

    /// Decide whether a response can replace or extend the adjacent partial
    /// file. A server returning 200 after ignoring a Range request is safe to
    /// handle by replacing the partial file; a 206 response is appendable only
    /// when its Content-Range starts at the requested offset and advertises the
    /// expected total size.
    static func ipswDownloadResponseDecision(
        statusCode: Int,
        requestedOffset: Int64,
        contentRange: String?,
        expectedSize: Int64
    ) throws -> IPSWDownloadResponseDecision {
        guard expectedSize > 0 else { throw IPSWDownloadResponseError.invalidContentRange }
        switch statusCode {
        case 200:
            return .overwrite
        case 206:
            guard requestedOffset > 0 else {
                throw IPSWDownloadResponseError.unexpectedPartialResponse
            }
            guard let contentRange else {
                throw IPSWDownloadResponseError.missingContentRange
            }
            guard let parsed = parseIPSWContentRange(contentRange) else {
                throw IPSWDownloadResponseError.invalidContentRange
            }
            guard parsed.start == requestedOffset else {
                throw IPSWDownloadResponseError.contentRangeOffsetMismatch(
                    expected: requestedOffset,
                    actual: parsed.start
                )
            }
            guard parsed.total == expectedSize else {
                throw IPSWDownloadResponseError.contentRangeSizeMismatch(
                    expected: expectedSize,
                    actual: parsed.total
                )
            }
            return .append
        default:
            throw IPSWDownloadResponseError.unsupportedStatus(statusCode)
        }
    }

    static func resolveIPSWFirmware(selection: String, deviceIdentifier: String?) async throws -> IPSWMEFirmware {
        let device = try deviceIdentifier ?? hostModelIdentifier()
        let response = try await fetchIPSWMEDevice(identifier: device)
        return try selectIPSWFirmware(response.firmwares, selection: selection)
    }

    static func listIPSWFirmwares(
        deviceIdentifier: String?,
        limit: Int?
    ) async throws -> (device: IPSWMEDeviceResponse, firmwares: [IPSWMEFirmware]) {
        let device = try deviceIdentifier ?? hostModelIdentifier()
        let response = try await fetchIPSWMEDevice(identifier: device)
        let firmwares = limit.map { Array(response.firmwares.prefix($0)) } ?? response.firmwares
        return (response, firmwares)
    }

    static func downloadIPSWFirmware(
        selection: String,
        deviceIdentifier: String?,
        vmName: String? = nil
    ) async throws -> (firmware: IPSWMEFirmware, url: URL) {
        let firmware = try await resolveIPSWFirmware(selection: selection, deviceIdentifier: deviceIdentifier)
        let url = try await downloadFirmware(firmware, resume: true, vmName: vmName)
        return (firmware, url)
    }

    /// A catalog lookup is not a download: a 404 means the catalog does not
    /// know the device, and any other status is a failed catalog request.
    static func catalogFailure(statusCode: Int, identifier: String) -> RunnerError {
        statusCode == 404
            ? .unknownDeviceIdentifier(identifier)
            : .catalogRequestFailed(statusCode: statusCode)
    }

    private static func fetchIPSWMEDevice(identifier: String) async throws -> IPSWMEDeviceResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.ipsw.me"
        components.path = "/v4/device/\(identifier)"
        components.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
        guard let url = components.url else {
            throw RunnerError.hostCommandFailed("Could not build restore-image catalog URL.")
        }
        let session = makeIPSWURLSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw catalogFailure(statusCode: response.statusCode, identifier: identifier)
        }
        do {
            return try JSONDecoder().decode(IPSWMEDeviceResponse.self, from: data)
        } catch {
            throw RunnerError.hostCommandFailed("The restore-image catalog returned invalid JSON.")
        }
    }

    static func selectIPSWFirmware(_ firmwares: [IPSWMEFirmware], selection: String) throws -> IPSWMEFirmware {
        let value = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RunnerError.hostCommandFailed("A restore-image version is required.") }
        let signedFirmwares = firmwares.filter { $0.signed == true }
        if value.caseInsensitiveCompare("latest") == .orderedSame,
           let firmware = signedFirmwares.first {
            return firmware
        }
        if let firmware = signedFirmwares.first(where: {
            ipswVersionMatches(value, catalogVersion: $0.version)
                || $0.buildid.caseInsensitiveCompare(value) == .orderedSame
        }) {
            return firmware
        }
        throw RunnerError.hostCommandFailed("No signed restore image matched \(value).")
    }

    private static func downloadFirmware(_ firmware: IPSWMEFirmware, resume: Bool, vmName: String?) async throws -> URL {
        let directory = try applicationSupportRoot().appendingPathComponent(Constants.restoreImageDirectoryName, isDirectory: true)
        let session = makeIPSWURLSession()
        defer { session.invalidateAndCancel() }
        return try await downloadFirmware(firmware, resume: resume, vmName: vmName, directory: directory) { request in
            try await session.bytes(for: request)
        }
    }

    /// The production byte loop also accepts synthetic responses for offline validation.
    static func downloadFirmware<Bytes: AsyncSequence>(
        _ firmware: IPSWMEFirmware,
        resume: Bool,
        vmName: String?,
        directory: URL,
        publish: (URL, URL) throws -> Void = publishDownloadedFirmware,
        fetch: (URLRequest) async throws -> (Bytes, URLResponse)
    ) async throws -> URL where Bytes.Element == UInt8 {

        guard firmware.signed == true else {
            throw RunnerError.hostCommandFailed("Refusing to download an unsigned restore image.")
        }
        guard let expectedSize = firmware.filesize, expectedSize > 0 else {
            throw RunnerError.hostCommandFailed("The restore-image catalog did not provide a valid expected size.")
        }
        guard let remoteURL = URL(string: firmware.url), remoteURL.scheme?.hasPrefix("http") == true else {
            throw RunnerError.hostCommandFailed("The restore-image catalog returned an invalid URL.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = remoteURL.lastPathComponent.isEmpty
            ? "macOS-\(firmware.version)-\(firmware.buildid).ipsw"
            : remoteURL.lastPathComponent
        let destination = directory.appendingPathComponent(fileName)
        let partial = directory.appendingPathComponent(".\(fileName).part")
        let fileManager = FileManager.default
        let progressSink = PommeProgressContext.sink
        let logSink = PommeLogContext.sink
        if cachedRestoreImageURL(for: firmware, in: directory) != nil {
            progressSink?.step(vm: vmName, "Using cached IPSW \(firmware.version)")
            // A completed destination wins; remove only the deterministic
            // temporary file owned by this download operation.
            try? fileManager.removeItem(at: partial)
            return destination
        }

        // Older interrupted downloads may have left bytes at the final name.
        // Move that known file beside the destination so all future writes are
        // resumable and the final name is published only after size validation.
        if let currentDestinationSize = fileSize(destination), currentDestinationSize > 0,
           !fileManager.fileExists(atPath: partial.path) {
            try fileManager.moveItem(at: destination, to: partial)
        }
        if fileSize(partial) == expectedSize {
            progressSink?.step(vm: vmName, "Publishing IPSW \(firmware.version)")
            try publish(partial, destination)
            try? fileManager.removeItem(at: partial)
            if progressSink == nil { logSink?("Download progress: 100%") }
            progressSink?.measured(vm: vmName, "Downloaded IPSW \(firmware.version)", fraction: 1,
                completedBytes: expectedSize, totalBytes: expectedSize)
            return destination
        }
        if let partialSize = fileSize(partial), partialSize > expectedSize {
            try fileManager.removeItem(at: partial)
        }

        var request = URLRequest(url: remoteURL)
        var offset: Int64 = 0
        if resume, let current = fileSize(partial), current > 0 {
            offset = current
            request.setValue("bytes=\(current)-", forHTTPHeaderField: "Range")
        }


        progressSink?.step(vm: vmName, "Connecting to server for IPSW \(firmware.version)")
        let (bytes, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else {
            throw RunnerError.hostCommandFailed("The restore-image server returned a non-HTTP response.")
        }
        let decision: IPSWDownloadResponseDecision
        do {
            decision = try ipswDownloadResponseDecision(
                statusCode: http.statusCode,
                requestedOffset: offset,
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                expectedSize: expectedSize
            )
        } catch let error as IPSWDownloadResponseError {
            if case let .unsupportedStatus(status) = error {
                throw RunnerError.downloadFailed(statusCode: status)
            }
            throw RunnerError.hostCommandFailed(error.localizedDescription)
        }

        guard fileManager.fileExists(atPath: partial.path) || fileManager.createFile(
            atPath: partial.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw RunnerError.hostCommandFailed("Could not create the restore-image temporary file.")
        }
        let handle = try FileHandle(forWritingTo: partial)
        var completedBytes = ipswDownloadProgressOffset(decision: decision, requestedOffset: offset)
        var lastLoggedPercent: Int?
        func reportDownload() {
            let percent = Int(min(Double(completedBytes) / Double(expectedSize), 0.999) * 100)
            if progressSink == nil, percent != lastLoggedPercent {
                logSink?("Download progress: \(percent)%")
                lastLoggedPercent = percent
            }
            progressSink?.measured(vm: vmName, "Downloading IPSW \(firmware.version)",
                fraction: min(Double(completedBytes) / Double(expectedSize), 0.999),
                completedBytes: completedBytes, totalBytes: expectedSize)
        }
        reportDownload()
        do {
            if decision == .overwrite {
                try handle.truncate(atOffset: 0)
            } else {
                _ = try handle.seekToEnd()
            }
            var chunk = Data()
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try handle.write(contentsOf: chunk)
                    completedBytes += Int64(chunk.count)
                    reportDownload()
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                completedBytes += Int64(chunk.count)
                reportDownload()
            }
            progressSink?.step(vm: vmName, "Verifying IPSW \(firmware.version)")
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            // Keep the adjacent partial file for a subsequent Range request.
            throw error
        }

        guard fileSize(partial) == expectedSize else {
            throw RunnerError.hostCommandFailed("The restore-image size did not match catalog metadata.")
        }
        try publish(partial, destination)
        if progressSink == nil { logSink?("Download progress: 100%") }
        progressSink?.measured(vm: vmName, "Downloaded IPSW \(firmware.version)", fraction: 1,
            completedBytes: expectedSize, totalBytes: expectedSize)
        // `partial` is normally consumed by move/replace; this cleanup also
        // handles platform implementations that leave a temporary inode.
        try? fileManager.removeItem(at: partial)
        return destination
    }

    static func publishDownloadedFirmware(_ partial: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    /// A server that ignores Range restarts the file and its displayed count.
    static func ipswDownloadProgressOffset(decision: IPSWDownloadResponseDecision, requestedOffset: Int64) -> Int64 {
        decision == .overwrite ? 0 : max(0, requestedOffset)
    }

    private static func parseIPSWContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let fields = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].caseInsensitiveCompare("bytes") == .orderedSame else { return nil }
        let rangeAndTotal = fields[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2, let total = Int64(rangeAndTotal[1]), total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total
        else { return nil }
        return (start, end, total)
    }

    private static func makeIPSWURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        // URL resource values cache a pre-download size across file writes.
        // Read the current filesystem metadata for resume and publication checks.
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else { return nil }
        return metadata.st_size
    }

    private static func hostModelIdentifier() throws -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            throw RunnerError.hostCommandFailed("Could not determine the host model identifier.")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            throw RunnerError.hostCommandFailed("Could not determine the host model identifier.")
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Executable identity

    static func runningExecutableIdentity(
        executableURLProvider: @Sendable () throws -> URL = {
            try PommeExecutableIdentity.currentExecutableURL()
        }
    ) throws -> (url: URL, sha256: String) {
        // CommandLine.arguments.first is only the invocation spelling. A PATH
        // launch can provide a bare name that is not resolvable from the
        // current directory, so use dyld's process-owned executable path and
        // canonicalize any test or launcher symlink before hashing.
        let url = try executableURLProvider().resolvingSymlinksInPath()
        return (url, try PommeExecutableIdentity.executableDigest(at: url))
    }
}
