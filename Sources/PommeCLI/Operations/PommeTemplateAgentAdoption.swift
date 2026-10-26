import Foundation

/// The persistent agent that a provisioned template carries, and the host
/// credential that Pomme kept for it when it captured the template.
///
/// A provisioned template is captured from a disposable VM whose agent this
/// host installed and authenticated with a Keychain item scoped to that VM's
/// UUID. That item is deleted with the disposable VM, so the capture copies
/// the same secret into an item scoped to the template instead. A VM cloned
/// from the template boots the same installed agent, so this host can
/// authenticate it in normal macOS with that copy, replace it with the VM's
/// pinned build, and give it a credential of its own, all without Recovery.
struct PommeTemplateAgentReference: Codable, Equatable, Sendable {
    /// Scopes the template's Keychain item. It is generated for one capture
    /// and is unrelated to any VM UUID.
    let credentialID: UUID
    /// SHA-256 of the agent executable installed in the captured disk.
    let executableDigest: String
    /// The APFS volume group of the captured startup disk. Every clone has the
    /// same one, because its disk is a block-for-block copy of the template's.
    let startupVolumeGroupUUID: UUID

    var isValid: Bool {
        PommeProvisioningDigest.isSHA256(executableDigest) && executableDigest == executableDigest.lowercased()
    }
}

/// The host copy of a provisioned template's agent credential, in the user's
/// login Keychain. It reuses the persistent-agent store, so it has the same
/// explicit Keychain targeting, unlock requirement, and no-replace semantics
/// as a VM's own credential, under a distinct account name.
struct PommeTemplateAgentCredentialStore {
    /// Distinct from a VM's `agent-token` account, so a template's item is
    /// never read, replaced, or deleted as a VM's.
    static let account = "template-agent-token"

    private let store: PommeAgentCredentialStore

    init(store: PommeAgentCredentialStore = .init()) {
        self.store = store
    }

    /// Stores `credential` for the template. An existing item for the same
    /// identifier is kept and must hold the same secret.
    func retain(_ credential: String, credentialID: UUID) throws {
        let expected: String
        do { expected = try PommeAgentAuthentication.normalized(credential) }
        catch { throw PommeAgentCredentialStore.Error.malformedCredential }
        let stored = try store.readOrCreate(
            vmUUID: credentialID, account: Self.account, generate: { expected })
        guard stored == expected else { throw PommeAgentCredentialStore.Error.unexpectedCredentialData }
    }

    func read(credentialID: UUID) throws -> String {
        try store.read(vmUUID: credentialID, account: Self.account)
    }

    /// Removing an absent item succeeds.
    func remove(credentialID: UUID) throws {
        try store.remove(vmUUID: credentialID, account: Self.account)
    }
}

/// Host evidence that an agent installation handed this VM's own credential
/// to the guest, so the guest might already hold a working, pinned agent even
/// though the installation phase didn't record a receipt. Before Pomme spends
/// a Recovery installation on `create --resume` or `agent repair`, this
/// evidence lets it check normal macOS first.
///
/// The record is a hint, not an authority: only a normal agent that
/// authenticates with this VM's credential and reports the plan's pinned
/// digest proves anything. A missing record costs a Recovery installation, as
/// before; a stale one costs one bounded normal boot.
struct PommeAgentInstallDispatch: Codable, Equatable, Sendable {
    enum Method: String, Codable, Equatable, Sendable {
        /// The request-bound Recovery agent received the credential.
        case recovery
        /// The agent cloned from a provisioned template received it in
        /// normal macOS.
        case template
    }

    static let fileName = "agent-install-v1.dispatched"

    let vmUUID: UUID
    let planDigest: String
    let method: Method
    /// The journal attempt of the latest installation that sent the
    /// credential.
    let attempt: UInt64
    /// The latest attempt for which a normal-boot check already failed.
    let probedAttempt: UInt64?

    init(vmUUID: UUID, planDigest: String, method: Method, attempt: UInt64, probedAttempt: UInt64? = nil) {
        self.vmUUID = vmUUID
        self.planDigest = planDigest
        self.method = method
        self.attempt = attempt
        self.probedAttempt = probedAttempt
    }

    func matches(_ plan: PommeProvisioningPlan) -> Bool {
        vmUUID == plan.vm.uuid && planDigest == plan.digest && attempt > 0
    }

    /// True until a normal-boot check fails for the latest dispatch. Each
    /// dispatch is checked at most once, so repeated failures don't each pay
    /// for a normal boot before Recovery.
    var awaitsProbe: Bool { (probedAttempt ?? 0) < attempt }

    /// The record for a newer dispatch keeps the probe history.
    func dispatched(method: Method, attempt: UInt64) -> Self {
        .init(vmUUID: vmUUID, planDigest: planDigest, method: method,
              attempt: max(self.attempt, attempt), probedAttempt: probedAttempt)
    }

    func probed() -> Self {
        .init(vmUUID: vmUUID, planDigest: planDigest, method: method, attempt: attempt, probedAttempt: attempt)
    }
}

/// While this record exists, the VM helper also offers the template's
/// credential to the VM's persistent agent, because the agent cloned from the
/// template authenticates with it until the adoption gives it the VM's own.
/// The adoption writes it before it boots the clone and removes it as soon
/// as the guest holds the new credential; a Recovery installation or a
/// normal-boot check removes any record that an interrupted adoption left.
struct PommeTemplateAdoptionLease: Codable, Equatable, Sendable {
    static let fileName = "template-agent-adoption-v1.json"

    let vmUUID: UUID
    let planDigest: String
    let credentialID: UUID

    func matches(_ plan: PommeProvisioningPlan, template: PommeTemplateAgentReference) -> Bool {
        vmUUID == plan.vm.uuid && planDigest == plan.digest && credentialID == template.credentialID
    }
}

/// Offers each candidate credential in turn, one per authentication attempt.
/// The agent proves knowledge of one credential per connection and
/// reconnects after a rejected attempt, so alternating reaches the right one
/// within one retry without the host learning which one the guest holds.
final class PommeAgentCredentialRotation: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func next(_ candidates: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        return lock.withLock {
            defer { counter &+= 1 }
            return candidates[counter % candidates.count]
        }
    }
}

enum PommeTemplateAgentAdoptionError: Error, Equatable, PommeDescribedError {
    /// The agent cloned from the template didn't authenticate in time.
    case agentUnavailable(vmName: String)
    /// The authenticated agent isn't the template's or the plan's build.
    case unexpectedAgent(vmName: String)
    /// The authenticated agent can't receive files or run processes.
    case unsupportedAgent(vmName: String)
    /// The clone's startup disk isn't the volume group the template recorded.
    case startupVolumeMismatch(vmName: String)

    /// The adopted agent never authenticated, so nothing reached the guest
    /// and a Recovery installation can safely take over.
    var isAgentUnavailable: Bool {
        if case .agentUnavailable = self { return true }
        return false
    }

    var code: PommeErrorCode {
        switch self {
        case .agentUnavailable: .guestAgentUnavailable
        case .unexpectedAgent, .unsupportedAgent: .provisioningAgentInvalid
        case .startupVolumeMismatch: .guestRecoveryDataVolumeUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .agentUnavailable(let name):
            "The Pomme agent that \(name) carries from its template didn't connect in normal macOS."
        case .unexpectedAgent(let name):
            "The Pomme agent in \(name) isn't the one that its template captured."
        case .unsupportedAgent(let name):
            "The Pomme agent that \(name) carries from its template can't receive files or run processes."
        case .startupVolumeMismatch(let name):
            "The startup disk of \(name) isn't the one that its template captured."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .agentUnavailable(let name):
            "Run `pomme create \(name) --resume` to try again, or `pomme agent repair \(name)` to install the agent through Recovery."
        case .unexpectedAgent(let name), .unsupportedAgent(let name), .startupVolumeMismatch(let name):
            "Run `pomme agent repair \(name)` to install the agent through Recovery, or delete the VM and create it again."
        }
    }
}

/// The ordering of the template adoption, apart from its VM and Keychain
/// effects. Its invariant: once the lease is written, every exit either
/// leaves the lease removed and the VM helper stopped, or returns the receipt
/// with the lease removed and the guest shut down. A helper that accepted the
/// template's credential never outlives the attempt.
struct PommeTemplateAdoptionRun: Sendable {
    /// Whether the template's credential is still in the Keychain.
    var credentialExists: @Sendable () throws -> Bool
    /// Removes the lease; true when one was present.
    var withdrawLease: @Sendable () throws -> Bool
    /// Stops the VM helper, forcing it when a graceful stop fails, so no
    /// session that the lease admitted survives.
    var stopHelper: @Sendable () async throws -> Void
    /// Makes this VM's own credential durable and resolves the pinned agent.
    var prepare: @Sendable () throws -> Void
    var writeLease: @Sendable () throws -> Void
    /// Boots normal macOS, checks the agent, records the startup volume
    /// group, and installs the pinned agent with this VM's credential.
    var install: @Sendable () async throws -> Void
    /// Records the installed agent as the plan's pin.
    var recordInstalled: @Sendable () throws -> Void
    /// Shuts the guest down so verification boots the persisted install.
    var shutDown: @Sendable () async throws -> Void
    var receipt: @Sendable () throws -> String
    var warn: @Sendable (String) -> Void

    static let missingCredentialWarning =
        "Warning: The template's agent credential is no longer in your login Keychain, so Pomme installs the agent through Recovery."

    func run() async throws -> String? {
        guard try credentialExists() else {
            // A lease left by an interrupted attempt must not keep admitting
            // the template's credential through a running helper.
            if try withdrawLease() { try await stopHelper() }
            PommeUnifiedLog.notice("template agent adoption skipped: the template's credential is missing",
                                   logger: PommeUnifiedLog.template)
            warn(Self.missingCredentialWarning)
            return nil
        }
        PommeUnifiedLog.notice("template agent adoption started", logger: PommeUnifiedLog.template)
        try prepare()
        try writeLease()
        do {
            try await install()
            _ = try withdrawLease()
            try recordInstalled()
            PommeUnifiedLog.notice("template agent adoption installed the clone's credential",
                                   logger: PommeUnifiedLog.template)
        } catch {
            PommeUnifiedLog.error(error, context: "template agent adoption", logger: PommeUnifiedLog.template)
            // Best effort: the original error is what the caller reports.
            _ = try? withdrawLease()
            try? await stopHelper()
            throw error
        }
        do {
            try await shutDown()
        } catch {
            try? await stopHelper()
            throw error
        }
        return try receipt()
    }
}

/// The ordering of the check for an agent that an earlier installation
/// attempt left in the guest. It always starts from a stopped helper, so the
/// proof comes from a session that only this VM's credential could
/// authenticate, and it leaves the helper stopped whenever it returns nil.
struct PommeInstalledAgentProbe: Sendable {
    var withdrawLease: @Sendable () throws -> Bool
    var stopHelper: @Sendable () async throws -> Void
    /// Boots normal macOS and waits for the pinned agent.
    var prove: @Sendable () async throws -> Bool
    /// Records the startup volume group read through the proven agent.
    var recordVolumeGroup: @Sendable () async throws -> Void
    var markProbed: @Sendable () -> Void
    var receipt: @Sendable () throws -> String
    var log: @Sendable (String) -> Void

    func run() async throws -> String? {
        do {
            _ = try withdrawLease()
            try await stopHelper()
            if try await prove() {
                try await recordVolumeGroup()
                log("the pinned agent proved itself in normal macOS; Recovery isn't needed.")
                return try receipt()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            PommeUnifiedLog.error(error, context: "installed-agent probe in normal macOS",
                                  logger: PommeUnifiedLog.provisioning)
            log("the normal-boot check failed [code=\(PommeErrorReport(error).code.rawValue)].")
        }
        markProbed()
        try await stopHelper()
        return nil
    }
}

/// Pure checks for adopting a template's agent, kept apart from the VM and
/// Keychain effects so they can be tested directly.
enum PommeTemplateAgentAdoption {
    /// What the adoption asks of the agent it finds: an authenticated file
    /// upload and process start, exactly what `pomme agent update` needs.
    static let requiredCapabilities: Set<String> = ["file.open", "file.write", "file.commit", "process.start"]

    /// Whether an authenticated agent may be adopted: it reports the build the
    /// template captured, or the plan's pinned build after an earlier attempt
    /// already installed it, and it can receive the replacement.
    static func accepts(
        digest: String, capabilities: [String],
        template: PommeTemplateAgentReference, plan: PommeProvisioningPlan
    ) -> Bool {
        [template.executableDigest, plan.normalAgent.executableDigest].contains(digest)
            && requiredCapabilities.isSubset(of: capabilities)
    }

    /// The guest's startup volume group, from `diskutil apfs listVolumeGroups
    /// -plist` and `diskutil info -plist /` run in normal macOS. The root
    /// volume must belong to the expected group, such as the one a template
    /// recorded, and that group must be the single System and Data pair, as
    /// the Recovery installer requires. Without an expected group, the disk
    /// must have exactly one such pair. Returns nil when the output doesn't
    /// prove that.
    static func startupVolumeGroup(volumeGroups: Data, rootInfo: Data, expected: UUID?) -> UUID? {
        guard let selected = try? PommeRecoveryDataVolumeResolver.resolveDataVolume(
                from: volumeGroups, expectedVolumeGroupUUID: expected),
              let root = try? PropertyListSerialization.propertyList(from: rootInfo, format: nil) as? [String: Any],
              let rawGroup = (root["APFSVolumeGroupID"] as? String) ?? (root["APFSVolumeGroupUUID"] as? String),
              UUID(uuidString: rawGroup) == selected.volumeGroupUUID,
              (root["FilesystemType"] as? String)?.caseInsensitiveCompare("apfs") == .orderedSame,
              root["MountPoint"] as? String == "/"
        else { return nil }
        return selected.volumeGroupUUID
    }
}
