import CryptoKit
import Darwin
import Foundation

/// The four security mutations that have a durable, resumable transaction.
/// Status observations deliberately do not create a workflow journal.
enum PommeSecurityWorkflowOperation: String, Codable, CaseIterable, Sendable {
    case sipEnable
    case sipDisable
    case amfiEnable
    case amfiDisable

    var wireName: String {
        switch self {
        case .sipEnable: "sip.enable"
        case .sipDisable: "sip.disable"
        case .amfiEnable: "amfi.enable"
        case .amfiDisable: "amfi.disable"
        }
    }
}

/// Every externally visible effect in a security workflow has an intent and
/// a verified receipt. Keeping those pairs in one closed sequence lets a
/// crashed invocation resume from the last durable boundary.
enum PommeSecurityWorkflowPhase: String, Codable, CaseIterable, Sendable {
    /// A read-only AMFI prerequisite has started. No credential, owner, or
    /// requested-state receipt is implied by this phase.
    case preflightIntent
    /// The read-only AMFI prerequisite was rejected after the captured run
    /// state was restored and proved. This is a terminal no-effect tombstone.
    case preflightRejected
    case credentialPending
    case credentialStored
    case accountCreationIntent
    case accountCreationVerified
    case autologinIntent
    case autologinVerified
    case securityMutationIntent
    case securityMutationVerified
    case normalBootVerified
    case noMutationVerified
    case restorationPending
    case restorationComplete

    fileprivate var index: Int {
        Self.allCases.firstIndex(of: self)!
    }
}

enum PommeSecurityWorkflowOwnerPreparation: String, Codable, CaseIterable, Sendable {
    case new
    case existing
}

struct PommeSecurityWorkflowOwnerRecord: Codable, Equatable, Sendable {
    let accountUsername: String
    let generatedUID: UUID?
    let ownerPreparation: PommeSecurityWorkflowOwnerPreparation

    init(
        accountUsername: String,
        ownerPreparation: PommeSecurityWorkflowOwnerPreparation,
        generatedUID: UUID? = nil
    ) throws {
        guard Self.isSafeAccountName(accountUsername) else {
            throw PommeSecurityWorkflowJournalError.invalidIdentity
        }
        self.accountUsername = accountUsername
        self.generatedUID = generatedUID
        self.ownerPreparation = ownerPreparation
    }

    fileprivate var isVerified: Bool { generatedUID != nil }

    private static func isSafeAccountName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.range(of: "^[A-Za-z][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
}

/// The host identity used by a security transaction. `volumeVUID` is allowed
/// to be absent only before the VM has had a normal boot that can expose it;
/// it must be bound before the security mutation intent is recorded.
struct PommeSecurityWorkflowIdentity: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let vmName: String
    let vmUUID: UUID
    let machineIdentifierSHA256: String
    let diskImageFileResourceID: String
    let startupVolumeGroupUUID: UUID
    let volumeVUID: String?
    let immutableProvisioningPlanDigest: String

    init(
        vmName: String,
        vmUUID: UUID,
        machineIdentifierSHA256: String,
        diskImageFileResourceID: String,
        startupVolumeGroupUUID: UUID,
        volumeVUID: String? = nil,
        immutableProvisioningPlanDigest: String = String(repeating: "0", count: 64)
    ) throws {
        guard (try? validateVMName(vmName)) == vmName,
              Self.isSHA256(machineIdentifierSHA256),
              Self.isSafeResourceID(diskImageFileResourceID),
              Self.isCanonicalUUID(startupVolumeGroupUUID),
              volumeVUID.map(Self.isSafeVUID) ?? true,
              Self.isSHA256(immutableProvisioningPlanDigest)
        else {
            throw PommeSecurityWorkflowJournalError.invalidIdentity
        }
        self.vmName = vmName
        self.vmUUID = vmUUID
        self.machineIdentifierSHA256 = machineIdentifierSHA256.lowercased()
        self.diskImageFileResourceID = diskImageFileResourceID
        self.startupVolumeGroupUUID = startupVolumeGroupUUID
        self.volumeVUID = volumeVUID?.lowercased()
        self.immutableProvisioningPlanDigest = immutableProvisioningPlanDigest.lowercased()
    }

    /// Captures the host-side pieces that can be checked before a Recovery
    /// boot. The volume group UUID comes from the already verified
    /// provisioning record; the VUID may be supplied later.
    static func capture(
        vmName: String,
        bundle: BundleLayout,
        startupVolumeGroupUUID: UUID,
        volumeVUID: String? = nil,
        immutableProvisioningPlanDigest: String = String(repeating: "0", count: 64)
    ) throws -> Self {
        guard let metadata = try? metadataPayload(bundle: bundle),
              let rawVMUUID = metadata[Constants.vmUUIDMetadataKey] as? String,
              UUID(uuidString: rawVMUUID) != nil,
              let vmUUID = UUID(uuidString: rawVMUUID)
        else { throw PommeSecurityWorkflowJournalError.invalidIdentity }

        let machineIdentifier: Data
        do {
            machineIdentifier = try readBoundRegularFile(bundle.machineIdentifierURL)
        } catch {
            throw PommeSecurityWorkflowJournalError.invalidIdentity
        }
        guard !machineIdentifier.isEmpty else {
            throw PommeSecurityWorkflowJournalError.invalidIdentity
        }

        let diskDescriptor = open(
            bundle.diskImageURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard diskDescriptor >= 0 else {
            throw PommeSecurityWorkflowJournalError.invalidIdentity
        }
        defer { _ = close(diskDescriptor) }
        var diskStatus = stat()
        guard fstat(diskDescriptor, &diskStatus) == 0,
              diskStatus.st_mode & S_IFMT == S_IFREG,
              diskStatus.st_nlink == 1,
              diskStatus.st_uid == geteuid()
        else { throw PommeSecurityWorkflowJournalError.invalidIdentity }

        let resourceID = "\(diskStatus.st_dev):\(diskStatus.st_ino)"
        return try Self(
            vmName: vmName,
            vmUUID: vmUUID,
            machineIdentifierSHA256: Self.sha256(machineIdentifier),
            diskImageFileResourceID: resourceID,
            startupVolumeGroupUUID: startupVolumeGroupUUID,
            volumeVUID: volumeVUID,
            immutableProvisioningPlanDigest: immutableProvisioningPlanDigest
        )
    }

    func binding(volumeVUID: String) throws -> Self {
        try withVolumeVUID(volumeVUID)
    }

    func withVolumeVUID(_ value: String?) throws -> Self {
        try Self(
            vmName: vmName,
            vmUUID: vmUUID,
            machineIdentifierSHA256: machineIdentifierSHA256,
            diskImageFileResourceID: diskImageFileResourceID,
            startupVolumeGroupUUID: startupVolumeGroupUUID,
            volumeVUID: value,
            immutableProvisioningPlanDigest: immutableProvisioningPlanDigest
        )
    }

    /// A caller that has not booted normally yet may compare every captured
    /// field while leaving the expected VUID unspecified. Once both sides
    /// carry a VUID it must match exactly.
    func matches(_ expected: Self) -> Bool {
        vmName == expected.vmName
            && vmUUID == expected.vmUUID
            && machineIdentifierSHA256 == expected.machineIdentifierSHA256
            && diskImageFileResourceID == expected.diskImageFileResourceID
            && startupVolumeGroupUUID == expected.startupVolumeGroupUUID
            && immutableProvisioningPlanDigest == expected.immutableProvisioningPlanDigest
            && (expected.volumeVUID == nil || volumeVUID == expected.volumeVUID)
    }

    func isWellFormed(requireVolumeVUID: Bool = false) -> Bool {
        (try? Self(
            vmName: vmName,
            vmUUID: vmUUID,
            machineIdentifierSHA256: machineIdentifierSHA256,
            diskImageFileResourceID: diskImageFileResourceID,
            startupVolumeGroupUUID: startupVolumeGroupUUID,
            volumeVUID: volumeVUID,
            immutableProvisioningPlanDigest: immutableProvisioningPlanDigest
        )) != nil && (!requireVolumeVUID || volumeVUID != nil)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case vmName
        case vmUUID
        case machineIdentifierSHA256
        case diskImageFileResourceID
        case startupVolumeGroupUUID
        case volumeVUID
        case immutableProvisioningPlanDigest
    }

    init(from decoder: Decoder) throws {
        try Self.requireExactKeys(
            decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            vmName: values.decode(String.self, forKey: .vmName),
            vmUUID: values.decode(UUID.self, forKey: .vmUUID),
            machineIdentifierSHA256: values.decode(String.self, forKey: .machineIdentifierSHA256),
            diskImageFileResourceID: values.decode(String.self, forKey: .diskImageFileResourceID),
            startupVolumeGroupUUID: values.decode(UUID.self, forKey: .startupVolumeGroupUUID),
            volumeVUID: values.decodeIfPresent(String.self, forKey: .volumeVUID),
            immutableProvisioningPlanDigest: values.decode(String.self, forKey: .immutableProvisioningPlanDigest)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(vmName, forKey: .vmName)
        try values.encode(vmUUID, forKey: .vmUUID)
        try values.encode(machineIdentifierSHA256, forKey: .machineIdentifierSHA256)
        try values.encode(diskImageFileResourceID, forKey: .diskImageFileResourceID)
        try values.encode(startupVolumeGroupUUID, forKey: .startupVolumeGroupUUID)
        try values.encode(volumeVUID, forKey: .volumeVUID)
        try values.encode(immutableProvisioningPlanDigest, forKey: .immutableProvisioningPlanDigest)
    }

    private static func isCanonicalUUID(_ value: UUID) -> Bool {
        UUID(uuidString: value.uuidString) != nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSafeResourceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x21 && scalar.value <= 0x7e && scalar != "/" && scalar != "\\")
            }
    }

    private static func isSafeVUID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireExactKeys(
        _ decoder: Decoder,
        expected: Set<String>
    ) throws {
        let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys
        guard Set(keys.map(\.stringValue)) == expected else {
            throw PommeSecurityWorkflowJournalError.malformed
        }
    }
}

/// Codable run-state preservation is intentionally local to this journal. The
/// VM state type remains a small runtime value for the rest of the program.
extension VMRunStateSnapshot: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, bootMode }

    init(from decoder: Decoder) throws {
        try Self.requireExactKeys(decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "stopped":
            guard !values.contains(.bootMode) else { throw PommeSecurityWorkflowJournalError.malformed }
            self = .stopped
        case "running":
            guard let mode = BootMode(rawValue: try values.decode(String.self, forKey: .bootMode)) else {
                throw PommeSecurityWorkflowJournalError.malformed
            }
            self = .running(mode)
        case "paused":
            guard let mode = BootMode(rawValue: try values.decode(String.self, forKey: .bootMode)) else {
                throw PommeSecurityWorkflowJournalError.malformed
            }
            self = .paused(previousBootMode: mode)
        default:
            throw PommeSecurityWorkflowJournalError.malformed
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopped:
            try values.encode("stopped", forKey: .kind)
        case .running(let mode):
            try values.encode("running", forKey: .kind)
            try values.encode(mode.rawValue, forKey: .bootMode)
        case .paused(let mode):
            try values.encode("paused", forKey: .kind)
            try values.encode(mode.rawValue, forKey: .bootMode)
        }
    }

    private static func requireExactKeys(_ decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys
        let names = Set(keys.map(\.stringValue))
        guard names == ["kind"] || names == ["kind", "bootMode"] else {
            throw PommeSecurityWorkflowJournalError.malformed
        }
    }
}

extension VMFinalState: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let state = Self(rawValue: value) else {
            throw PommeSecurityWorkflowJournalError.malformed
        }
        self = state
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(rawValue)
    }
}

enum PommeSecurityWorkflowJournalError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentity
    case leaseRequired
    case leaseMismatch
    case unsafeBundle
    case unsafeJournal
    case journalMissing
    case journalTooLarge
    case malformed
    case identityMismatch
    case conflictingOperation
    case immutableRequestMismatch
    case invalidPhaseTransition(current: PommeSecurityWorkflowPhase, next: PommeSecurityWorkflowPhase)
    case invalidPreflightOperation
    case credentialRequired
    case ownerRequired
    case volumeVUIDRequired
    case staleGeneration
    case durabilityFailure(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "Pomme security workflow identity is invalid."
        case .leaseRequired: "Pomme security workflow requires the VM mutation lease."
        case .leaseMismatch: "Pomme security workflow mutation lease does not own this VM."
        case .unsafeBundle: "Pomme security workflow bundle is unsafe."
        case .unsafeJournal: "Pomme security workflow journal is unsafe."
        case .journalMissing: "Pomme security workflow journal is missing."
        case .journalTooLarge: "Pomme security workflow journal is too large."
        case .malformed: "Pomme security workflow journal is malformed."
        case .identityMismatch: "Pomme security workflow belongs to a different VM identity."
        case .conflictingOperation: "Another unfinished Pomme security operation owns this VM."
        case .immutableRequestMismatch: "Pomme security workflow request does not match the retained transaction."
        case .invalidPhaseTransition: "Pomme security workflow phase transition is invalid."
        case .invalidPreflightOperation:
            "Only an AMFI operation may begin a security preflight journal."
        case .credentialRequired: "Pomme security workflow requires a stored owner credential."
        case .ownerRequired: "Pomme security workflow requires a verified owner account identity."
        case .volumeVUIDRequired: "Pomme security workflow requires a verified startup volume identity."
        case .staleGeneration: "Pomme security workflow journal generation is stale."
        case .durabilityFailure(let operation, let code):
            "Pomme security workflow journal \(operation) could not be durably synchronized (errno \(code))."
        }
    }
}

/// Durable redacted journal record. The credential field contains only the
/// immutable Keychain reference; the password is intentionally not Codable
/// and never enters this value.
struct PommeSecurityWorkflowJournal: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let generation: UInt64
    let identity: PommeSecurityWorkflowIdentity
    let operation: PommeSecurityWorkflowOperation
    let originalRunState: VMRunStateSnapshot
    let requestedFinalState: VMFinalState
    let credential: PommeOwnerCredentialReference?
    let owner: PommeSecurityWorkflowOwnerRecord?
    let phase: PommeSecurityWorkflowPhase
    let normalBootVerified: Bool
    let noMutationNeeded: Bool
    let createdAt: Date
    let updatedAt: Date

    var accountUsername: String? { owner?.accountUsername }
    var generatedUID: UUID? { owner?.generatedUID }
    var ownerPreparation: PommeSecurityWorkflowOwnerPreparation? {
        owner?.ownerPreparation
    }

    init(
        generation: UInt64,
        identity: PommeSecurityWorkflowIdentity,
        operation: PommeSecurityWorkflowOperation,
        originalRunState: VMRunStateSnapshot,
        requestedFinalState: VMFinalState,
        credential: PommeOwnerCredentialReference?,
        phase: PommeSecurityWorkflowPhase,
        createdAt: Date,
        updatedAt: Date,
        owner: PommeSecurityWorkflowOwnerRecord? = nil,
        normalBootVerified: Bool = false,
        noMutationNeeded: Bool = false
    ) throws {
        guard generation > 0,
              identity.isWellFormed(),
              updatedAt >= createdAt,
              Self.credentialAllowed(credential, identity: identity),
              Self.ownerAllowed(owner),
              Self.ownerCredentialAllowed(credential: credential, owner: owner),
              Self.receiptStateAllowed(
                  phase: phase,
                  normalBootVerified: normalBootVerified,
                  noMutationNeeded: noMutationNeeded
              ),
              Self.phaseAllowed(
                  phase,
                  credential: credential,
                  owner: owner,
                  identity: identity,
                  normalBootVerified: normalBootVerified
              )
        else { throw PommeSecurityWorkflowJournalError.malformed }
        self.schema = Self.schemaVersion
        self.generation = generation
        self.identity = identity
        self.operation = operation
        self.originalRunState = originalRunState
        self.requestedFinalState = requestedFinalState
        self.credential = credential
        self.owner = owner
        self.phase = phase
        self.normalBootVerified = normalBootVerified
        self.noMutationNeeded = noMutationNeeded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case generation
        case identity
        case operation
        case originalRunState
        case requestedFinalState
        case credential
        case owner
        case phase
        case normalBootVerified
        case noMutationNeeded
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys
        let expected = Set(CodingKeys.allCases.map(\.stringValue))
        guard Set(keys.map(\.stringValue)) == expected else {
            throw PommeSecurityWorkflowJournalError.malformed
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            generation: values.decode(UInt64.self, forKey: .generation),
            identity: values.decode(PommeSecurityWorkflowIdentity.self, forKey: .identity),
            operation: values.decode(PommeSecurityWorkflowOperation.self, forKey: .operation),
            originalRunState: values.decode(VMRunStateSnapshot.self, forKey: .originalRunState),
            requestedFinalState: values.decode(VMFinalState.self, forKey: .requestedFinalState),
            credential: values.decodeIfPresent(PommeOwnerCredentialReference.self, forKey: .credential),
            phase: values.decode(PommeSecurityWorkflowPhase.self, forKey: .phase),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            owner: values.decodeIfPresent(PommeSecurityWorkflowOwnerRecord.self, forKey: .owner),
            normalBootVerified: values.decode(Bool.self, forKey: .normalBootVerified),
            noMutationNeeded: values.decode(Bool.self, forKey: .noMutationNeeded)
        )
        guard try values.decode(Int.self, forKey: .schema) == Self.schemaVersion else {
            throw PommeSecurityWorkflowJournalError.malformed
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(generation, forKey: .generation)
        try values.encode(identity, forKey: .identity)
        try values.encode(operation, forKey: .operation)
        try values.encode(originalRunState, forKey: .originalRunState)
        try values.encode(requestedFinalState, forKey: .requestedFinalState)
        try values.encode(credential, forKey: .credential)
        try values.encode(owner, forKey: .owner)
        try values.encode(phase, forKey: .phase)
        try values.encode(normalBootVerified, forKey: .normalBootVerified)
        try values.encode(noMutationNeeded, forKey: .noMutationNeeded)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    fileprivate func replacing(
        generation: UInt64,
        identity: PommeSecurityWorkflowIdentity? = nil,
            credential: PommeOwnerCredentialReference? = nil,
            phase: PommeSecurityWorkflowPhase? = nil,
            at date: Date
    ) throws -> Self {
        try Self(
            generation: generation,
            identity: identity ?? self.identity,
            operation: operation,
            originalRunState: originalRunState,
            requestedFinalState: requestedFinalState,
            credential: credential ?? self.credential,
            phase: phase ?? self.phase,
            createdAt: createdAt,
            updatedAt: date,
            owner: self.owner,
            normalBootVerified: self.normalBootVerified || phase == .normalBootVerified,
            noMutationNeeded: self.noMutationNeeded || phase == .noMutationVerified
        )
    }

    fileprivate func replacing(
        owner: PommeSecurityWorkflowOwnerRecord?,
        generation: UInt64,
        at date: Date
    ) throws -> Self {
        try Self(
            generation: generation,
            identity: identity,
            operation: operation,
            originalRunState: originalRunState,
            requestedFinalState: requestedFinalState,
            credential: credential,
            phase: phase,
            createdAt: createdAt,
            updatedAt: date,
            owner: owner,
            normalBootVerified: normalBootVerified,
            noMutationNeeded: noMutationNeeded
        )
    }

    private static func credentialAllowed(
        _ credential: PommeOwnerCredentialReference?,
        identity: PommeSecurityWorkflowIdentity
    ) -> Bool {
        guard let credential else { return true }
        return credential.vmUUID == identity.vmUUID
            && credential.machineIdentifierSHA256 == identity.machineIdentifierSHA256
            && credential.diskImageFileResourceID == identity.diskImageFileResourceID
    }

    fileprivate static func ownerCredentialAllowed(
        credential: PommeOwnerCredentialReference?,
        owner: PommeSecurityWorkflowOwnerRecord?
    ) -> Bool {
        guard let credential, let owner else { return true }
        guard credential.account == owner.accountUsername else { return false }
        guard let credentialUID = credential.generatedUID,
              let ownerUID = owner.generatedUID
        else { return true }
        return credentialUID == ownerUID
    }

    private static func receiptStateAllowed(
        phase: PommeSecurityWorkflowPhase,
        normalBootVerified: Bool,
        noMutationNeeded: Bool
    ) -> Bool {
        guard !(normalBootVerified && noMutationNeeded) else { return false }
        switch phase {
        case .normalBootVerified:
            return normalBootVerified && !noMutationNeeded
        case .noMutationVerified:
            return noMutationNeeded && !normalBootVerified
        case .restorationPending, .restorationComplete:
            return normalBootVerified != noMutationNeeded
        default:
            return !normalBootVerified && !noMutationNeeded
        }
    }

    private static func phaseAllowed(
        _ phase: PommeSecurityWorkflowPhase,
        credential: PommeOwnerCredentialReference?,
        owner: PommeSecurityWorkflowOwnerRecord?,
        identity: PommeSecurityWorkflowIdentity,
        normalBootVerified: Bool
    ) -> Bool {
        let ownerRequired: Set<PommeSecurityWorkflowPhase> = [
            .accountCreationIntent,
            .accountCreationVerified,
            .autologinIntent,
            .autologinVerified,
            .securityMutationIntent,
            .securityMutationVerified,
            .normalBootVerified
        ]
        if ownerRequired.contains(phase), owner == nil { return false }
        if [.accountCreationVerified, .autologinIntent, .autologinVerified].contains(phase),
           owner?.generatedUID == nil { return false }
        if [.securityMutationIntent, .securityMutationVerified, .normalBootVerified].contains(phase),
           owner?.generatedUID == nil { return false }
        if [.credentialStored, .accountCreationIntent, .autologinIntent, .autologinVerified].contains(phase),
           credential == nil { return false }
        if phase == .accountCreationVerified,
           owner?.ownerPreparation == .new,
           credential == nil { return false }
        if [.securityMutationIntent, .securityMutationVerified, .normalBootVerified].contains(phase),
           owner?.ownerPreparation == .new,
           credential == nil { return false }
        if [.securityMutationIntent, .securityMutationVerified, .normalBootVerified].contains(phase),
           !identity.isWellFormed(requireVolumeVUID: true) { return false }
        if [.preflightIntent, .preflightRejected].contains(phase) {
            // A preflight record can retain references from a completed
            // transaction, but it can never claim a fresh owner effect.
            guard owner == nil
                || (owner?.ownerPreparation == .existing && owner?.generatedUID != nil)
            else { return false }
        }
        if normalBootVerified {
            if owner == nil || owner?.generatedUID == nil { return false }
            if owner?.ownerPreparation == .new, credential == nil { return false }
            if !identity.isWellFormed(requireVolumeVUID: true) { return false }
        }
        return true
    }

    private static func ownerAllowed(_ owner: PommeSecurityWorkflowOwnerRecord?) -> Bool {
        guard let owner else { return true }
        if owner.ownerPreparation == .new, owner.generatedUID != nil {
            return true
        }
        return owner.ownerPreparation == .existing || owner.generatedUID == nil
    }
}

/// Owns all on-disk journal I/O. Callers must already hold the exact
/// per-VM mutation lease; the journal never attempts to acquire or release it.
struct PommeSecurityWorkflowJournalStore: Sendable {
    static let journalName = "SecurityWorkflowJournal.json"
    static let maximumJournalBytes = 1 * 1024 * 1024

    typealias AtomicWriter = @Sendable (_ data: Data, _ destination: URL) throws -> Void

    let bundleURL: URL
    private let atomicWriter: AtomicWriter

    init(bundleURL: URL, atomicWriter: AtomicWriter? = nil) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.atomicWriter = atomicWriter ?? Self.writeAtomically
    }

    var journalURL: URL {
        bundleURL.appendingPathComponent(Self.journalName)
    }

    func begin(
        operation: PommeSecurityWorkflowOperation,
        identity: PommeSecurityWorkflowIdentity,
        originalRunState: VMRunStateSnapshot,
        requestedFinalState: VMFinalState,
        credential: PommeOwnerCredentialReference? = nil,
        now: Date = Date(),
        lease: VMBundleMutationLease,
        owner: PommeSecurityWorkflowOwnerRecord? = nil,
        preflight: Bool = false
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: identity)
        try requireBundleDirectory()
        guard !preflight || !operation.isSIP else {
            throw PommeSecurityWorkflowJournalError.invalidPreflightOperation
        }
        guard PommeSecurityWorkflowJournal.ownerCredentialAllowed(
            credential: credential,
            owner: owner
        ) else {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }

        if let existing = try loadIfPresent(lease: lease) {
            guard existing.identity.matches(identity) else {
                throw PommeSecurityWorkflowJournalError.identityMismatch
            }
            guard PommeSecurityWorkflowJournal.ownerCredentialAllowed(
                credential: credential ?? existing.credential,
                owner: owner ?? existing.owner
            ) else {
                throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
            }
            if existing.phase != .restorationComplete,
               existing.phase != .preflightRejected {
                guard existing.operation == operation else {
                    throw PommeSecurityWorkflowJournalError.conflictingOperation
                }
                guard existing.requestedFinalState == requestedFinalState,
                      existing.credential == nil
                        || credential == nil
                        || existing.credential == credential
                else { throw PommeSecurityWorkflowJournalError.immutableRequestMismatch }
                if let owner, existing.owner != owner {
                    throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
                }
                return existing
            }

            if let existingCredential = existing.credential,
               let credential,
               existingCredential != credential {
                throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
            }
            if let existingOwner = existing.owner, let owner, existingOwner != owner {
                throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
            }
            let retainedIdentity: PommeSecurityWorkflowIdentity
            if identity.volumeVUID == nil, existing.identity.volumeVUID != nil {
                retainedIdentity = try identity.withVolumeVUID(existing.identity.volumeVUID)
            } else {
                retainedIdentity = identity
            }
            let retainedCredential = credential ?? existing.credential
            let retainedOwner: PommeSecurityWorkflowOwnerRecord?
            if let existingOwner = existing.owner,
               existingOwner.ownerPreparation == .new,
               let generatedUID = existingOwner.generatedUID {
                retainedOwner = try PommeSecurityWorkflowOwnerRecord(
                    accountUsername: existingOwner.accountUsername,
                    ownerPreparation: .existing,
                    generatedUID: generatedUID
                )
            } else {
                retainedOwner = owner ?? existing.owner
            }
            let date = Self.canonicalDate(now)
            let journal = try PommeSecurityWorkflowJournal(
                generation: existing.generation + 1,
                identity: retainedIdentity,
                operation: operation,
                originalRunState: originalRunState,
                requestedFinalState: requestedFinalState,
                credential: retainedCredential,
                phase: preflight ? .preflightIntent : .credentialPending,
                createdAt: date,
                updatedAt: date,
                owner: retainedOwner
            )
            try write(journal)
            return journal
        }

        // A fresh preflight cursor is deliberately metadata-free. References
        // from a completed journal are retained only in the terminal-record
        // replacement path above.
        if preflight, credential != nil || owner != nil {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }
        let date = Self.canonicalDate(now)
        let journal = try PommeSecurityWorkflowJournal(
            generation: 1,
            identity: identity,
            operation: operation,
            originalRunState: originalRunState,
            requestedFinalState: requestedFinalState,
            credential: credential,
            phase: preflight ? .preflightIntent : .credentialPending,
            createdAt: date,
            updatedAt: date,
            owner: owner
        )
        try write(journal)
        return journal
    }

    func loadIfPresent(
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal? {
        guard let journal = try readJournalIfPresent() else { return nil }
        try requireLease(lease, for: journal.identity)
        return journal
    }

    func load(
        matching identity: PommeSecurityWorkflowIdentity,
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: identity)
        let journal = try readJournal()
        guard journal.identity.matches(identity) else {
            throw PommeSecurityWorkflowJournalError.identityMismatch
        }
        return journal
    }

    func load(lease: VMBundleMutationLease) throws -> PommeSecurityWorkflowJournal {
        guard let journal = try readJournalIfPresent() else {
            throw PommeSecurityWorkflowJournalError.journalMissing
        }
        try requireLease(lease, for: journal.identity)
        return journal
    }

    func advance(
        _ current: PommeSecurityWorkflowJournal,
        to nextPhase: PommeSecurityWorkflowPhase,
        credential: PommeOwnerCredentialReference? = nil,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: current.identity)
        let onDisk = try load(matching: current.identity, lease: lease)
        guard onDisk == current else { throw PommeSecurityWorkflowJournalError.staleGeneration }
        if let credential, let existing = current.credential, credential != existing {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }
        let selectedCredential = credential ?? current.credential
        guard PommeSecurityWorkflowJournal.ownerCredentialAllowed(
            credential: selectedCredential,
            owner: current.owner
        ) else {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }
        if nextPhase == current.phase { return current }
        guard Self.allowsTransition(from: current, to: nextPhase) else {
            throw PommeSecurityWorkflowJournalError.invalidPhaseTransition(
                current: current.phase,
                next: nextPhase
            )
        }
        if [.credentialStored, .accountCreationIntent, .autologinIntent, .autologinVerified].contains(nextPhase),
           selectedCredential == nil {
            throw PommeSecurityWorkflowJournalError.credentialRequired
        }
        if [.securityMutationIntent, .securityMutationVerified, .normalBootVerified].contains(nextPhase),
           current.owner?.ownerPreparation == .new,
           selectedCredential == nil {
            throw PommeSecurityWorkflowJournalError.credentialRequired
        }
        if [.securityMutationIntent, .securityMutationVerified, .normalBootVerified].contains(nextPhase),
           !current.identity.isWellFormed(requireVolumeVUID: true) {
            throw PommeSecurityWorkflowJournalError.volumeVUIDRequired
        }
        let updated = try current.replacing(
            generation: current.generation + 1,
            credential: selectedCredential,
            phase: nextPhase,
            at: Self.canonicalDate(now)
        )
        try write(updated)
        return updated
    }

    func recordOwnerIntent(
        _ current: PommeSecurityWorkflowJournal,
        accountUsername: String,
        ownerPreparation: PommeSecurityWorkflowOwnerPreparation,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: current.identity)
        let onDisk = try load(matching: current.identity, lease: lease)
        guard onDisk == current else { throw PommeSecurityWorkflowJournalError.staleGeneration }
        let owner = try PommeSecurityWorkflowOwnerRecord(
            accountUsername: accountUsername,
            ownerPreparation: ownerPreparation
        )
        guard PommeSecurityWorkflowJournal.ownerCredentialAllowed(
            credential: current.credential,
            owner: owner
        ) else {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }
        if let existing = current.owner {
            guard existing.accountUsername == owner.accountUsername,
                  existing.ownerPreparation == owner.ownerPreparation
            else { throw PommeSecurityWorkflowJournalError.immutableRequestMismatch }
            return current
        }
        guard current.phase == .credentialPending else {
            throw PommeSecurityWorkflowJournalError.invalidPhaseTransition(
                current: current.phase,
                next: current.phase
            )
        }
        let updated = try current.replacing(
            owner: owner,
            generation: current.generation + 1,
            at: Self.canonicalDate(now)
        )
        try write(updated)
        return updated
    }

    func recordOwnerVerified(
        _ current: PommeSecurityWorkflowJournal,
        generatedUID: UUID,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: current.identity)
        let onDisk = try load(matching: current.identity, lease: lease)
        guard onDisk == current else { throw PommeSecurityWorkflowJournalError.staleGeneration }
        guard let owner = current.owner else {
            throw PommeSecurityWorkflowJournalError.ownerRequired
        }
        if let existingUID = owner.generatedUID {
            guard existingUID == generatedUID else {
                throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
            }
            return current
        }
        if owner.ownerPreparation == .new,
           current.phase != .accountCreationIntent {
            throw PommeSecurityWorkflowJournalError.invalidPhaseTransition(
                current: current.phase,
                next: .accountCreationVerified
            )
        }
        let verified = try PommeSecurityWorkflowOwnerRecord(
            accountUsername: owner.accountUsername,
            ownerPreparation: owner.ownerPreparation,
            generatedUID: generatedUID
        )
        guard PommeSecurityWorkflowJournal.ownerCredentialAllowed(
            credential: current.credential,
            owner: verified
        ) else {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }
        let updated = try current.replacing(
            owner: verified,
            generation: current.generation + 1,
            at: Self.canonicalDate(now)
        )
        try write(updated)
        return updated
    }

    func bind(
        _ current: PommeSecurityWorkflowJournal,
        volumeVUID: String,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: current.identity)
        let onDisk = try load(matching: current.identity, lease: lease)
        guard onDisk == current else { throw PommeSecurityWorkflowJournalError.staleGeneration }
        guard current.phase.index < PommeSecurityWorkflowPhase.securityMutationIntent.index else {
            guard current.identity.volumeVUID == volumeVUID.lowercased() else {
                throw PommeSecurityWorkflowJournalError.volumeVUIDRequired
            }
            return current
        }
        guard current.identity.volumeVUID == nil
            || current.identity.volumeVUID == volumeVUID.lowercased()
        else { throw PommeSecurityWorkflowJournalError.identityMismatch }
        let updatedIdentity = try current.identity.withVolumeVUID(volumeVUID)
        let updated = try current.replacing(
            generation: current.generation + 1,
            identity: updatedIdentity,
            at: Self.canonicalDate(now)
        )
        try write(updated)
        return updated
    }

    func setCredential(
        _ current: PommeSecurityWorkflowJournal,
        credential: PommeOwnerCredentialReference,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: current.identity)
        let onDisk = try load(matching: current.identity, lease: lease)
        guard onDisk == current else { throw PommeSecurityWorkflowJournalError.staleGeneration }
        if let existing = current.credential {
            guard existing == credential else {
                throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
            }
            return current
        }
        guard PommeSecurityWorkflowJournal.ownerCredentialAllowed(
            credential: credential,
            owner: current.owner
        ) else {
            throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
        }
        let updated = try current.replacing(
            generation: current.generation + 1,
            credential: credential,
            at: Self.canonicalDate(now)
        )
        try write(updated)
        return updated
    }

    private static func allowsTransition(
        from current: PommeSecurityWorkflowJournal,
        to next: PommeSecurityWorkflowPhase
    ) -> Bool {
        switch (current.phase, next) {
        case (.preflightIntent, .preflightRejected),
             (.preflightIntent, .credentialPending):
            return true
        case (.credentialPending, .credentialStored):
            return current.credential != nil
        case (.credentialPending, .accountCreationVerified):
            return current.owner?.ownerPreparation == .existing
                && current.owner?.generatedUID != nil
        case (.credentialPending, .noMutationVerified):
            return true
        case (.credentialStored, .noMutationVerified):
            return true
        case (.credentialStored, .accountCreationIntent):
            return current.owner?.ownerPreparation == .new
        case (.credentialStored, .accountCreationVerified):
            return current.owner?.ownerPreparation == .existing
                && current.owner?.generatedUID != nil
        case (.accountCreationIntent, .accountCreationVerified):
            return current.owner?.ownerPreparation == .new
                && current.owner?.generatedUID != nil
        case (.accountCreationVerified, .autologinIntent):
            return current.owner?.ownerPreparation == .new
        case (.accountCreationVerified, .securityMutationIntent):
            return current.owner?.ownerPreparation == .existing
        case (.autologinIntent, .autologinVerified):
            return current.owner?.ownerPreparation == .new
        case (.autologinVerified, .securityMutationIntent):
            return current.owner?.ownerPreparation == .new
        case (.securityMutationIntent, .securityMutationVerified):
            return true
        case (.securityMutationVerified, .normalBootVerified):
            return true
        case (.normalBootVerified, .restorationPending):
            return true
        case (.noMutationVerified, .restorationPending):
            return true
        case (.restorationPending, .restorationComplete):
            return true
        default:
            return false
        }
    }

    private static func canonicalDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    func completeWithoutMutation(
        _ current: PommeSecurityWorkflowJournal,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try requireLease(lease, for: current.identity)
        var result = current
        guard [
            .credentialPending,
            .credentialStored,
            .noMutationVerified,
            .restorationPending,
            .restorationComplete
        ].contains(result.phase) else {
            if result.phase == .restorationComplete { return result }
            throw PommeSecurityWorkflowJournalError.invalidPhaseTransition(
                current: result.phase,
                next: .noMutationVerified
            )
        }
        if result.phase == .credentialPending || result.phase == .credentialStored {
            result = try advance(result, to: .noMutationVerified, now: now, lease: lease)
        }
        if result.phase == .noMutationVerified {
            result = try advance(result, to: .restorationPending, now: now, lease: lease)
        }
        if result.phase == .restorationPending {
            return try advance(result, to: .restorationComplete, now: now, lease: lease)
        }
        return result
    }

    func finishNoop(
        _ current: PommeSecurityWorkflowJournal,
        now: Date = Date(),
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowJournal {
        try completeWithoutMutation(current, now: now, lease: lease)
    }

    private func requireLease(
        _ lease: VMBundleMutationLease,
        for identity: PommeSecurityWorkflowIdentity
    ) throws {
        guard lease.validates(name: identity.vmName) else {
            throw PommeSecurityWorkflowJournalError.leaseMismatch
        }
    }

    private func requireBundleDirectory() throws {
        var status = stat()
        guard lstat(bundleURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0
        else { throw PommeSecurityWorkflowJournalError.unsafeBundle }
    }

    private func readJournalIfPresent() throws -> PommeSecurityWorkflowJournal? {
        let descriptor = open(
            journalURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw PommeSecurityWorkflowJournalError.unsafeJournal
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw PommeSecurityWorkflowJournalError.unsafeJournal
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1
        else { throw PommeSecurityWorkflowJournalError.unsafeJournal }
        guard status.st_size >= 0,
              status.st_size <= off_t(Self.maximumJournalBytes)
        else { throw PommeSecurityWorkflowJournalError.journalTooLarge }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PommeSecurityWorkflowJournalError.unsafeJournal
            }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= Self.maximumJournalBytes else {
                throw PommeSecurityWorkflowJournalError.journalTooLarge
            }
        }
        guard data.count <= Self.maximumJournalBytes else {
            throw PommeSecurityWorkflowJournalError.journalTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(PommeSecurityWorkflowJournal.self, from: data)
        } catch let error as PommeSecurityWorkflowJournalError {
            throw error
        } catch {
            throw PommeSecurityWorkflowJournalError.malformed
        }
    }

    private func readJournal() throws -> PommeSecurityWorkflowJournal {
        guard let journal = try readJournalIfPresent() else {
            throw PommeSecurityWorkflowJournalError.journalMissing
        }
        return journal
    }

    private func write(_ journal: PommeSecurityWorkflowJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try atomicWriter(encoder.encode(journal), journalURL)
            try verifyPublishedJournalFile()
        } catch let error as PommeSecurityWorkflowJournalError {
            throw error
        } catch {
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "write",
                code: (error as NSError).code > 0 ? Int32((error as NSError).code) : EIO
            )
        }
    }

    private func verifyPublishedJournalFile() throws {
        var status = stat()
        guard lstat(journalURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1
        else { throw PommeSecurityWorkflowJournalError.unsafeJournal }
    }

    /// Stages owner-only bytes, synchronizes the staged inode, publishes it
    /// with one rename, then synchronizes the containing directory.
    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let parentDescriptor = open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw PommeSecurityWorkflowJournalError.unsafeBundle
        }
        defer { _ = close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid()
        else { throw PommeSecurityWorkflowJournalError.unsafeBundle }

        let destinationName = destination.lastPathComponent
        guard destinationName == Self.journalName else {
            throw PommeSecurityWorkflowJournalError.unsafeJournal
        }
        var existing = stat()
        let existingStatus = destinationName.withCString {
            fstatat(parentDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if existingStatus == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_uid == geteuid(),
                  existing.st_mode & 0o777 == 0o600,
                  existing.st_nlink == 1
            else { throw PommeSecurityWorkflowJournalError.unsafeJournal }
        } else if errno != ENOENT {
            throw PommeSecurityWorkflowJournalError.unsafeJournal
        }

        let temporaryName = ".\(destinationName).\(UUID().uuidString)"
        var descriptor = temporaryName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "stage", code: errno
            )
        }

        var published = false
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if !published {
                _ = temporaryName.withCString {
                    unlinkat(parentDescriptor, $0, 0)
                }
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "permissions", code: errno
            )
        }
        var staged = stat()
        guard fstat(descriptor, &staged) == 0,
              staged.st_mode & S_IFMT == S_IFREG,
              staged.st_uid == geteuid(),
              staged.st_mode & 0o777 == 0o600,
              staged.st_nlink == 1
        else { throw PommeSecurityWorkflowJournalError.unsafeJournal }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw PommeSecurityWorkflowJournalError.durabilityFailure(
                        operation: "write", code: errno
                    )
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "file", code: errno
            )
        }
        guard close(descriptor) == 0 else {
            descriptor = -1
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "close", code: errno
            )
        }
        descriptor = -1

        let renameStatus = temporaryName.withCString { temporary in
            destinationName.withCString { destination in
                renameat(parentDescriptor, temporary, parentDescriptor, destination)
            }
        }
        guard renameStatus == 0 else {
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "publish", code: errno
            )
        }
        published = true

        guard fsync(parentDescriptor) == 0 else {
            throw PommeSecurityWorkflowJournalError.durabilityFailure(
                operation: "directory", code: errno
            )
        }
    }
}

/// Short aliases keep call sites readable while the longer names remain the
/// explicit public vocabulary for new orchestration code.
typealias PommeSecurityOperation = PommeSecurityWorkflowOperation
typealias PommeSecurityJournalPhase = PommeSecurityWorkflowPhase
typealias PommeSecurityJournalIdentity = PommeSecurityWorkflowIdentity
typealias PommeSecurityJournalStore = PommeSecurityWorkflowJournalStore

private func readBoundRegularFile(_ url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PommeSecurityWorkflowJournalError.invalidIdentity }
    defer { _ = close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(),
          status.st_nlink == 1,
          status.st_size >= 0,
          status.st_size <= off_t(PommeSecurityWorkflowJournalStore.maximumJournalBytes)
    else { throw PommeSecurityWorkflowJournalError.invalidIdentity }

    var result = Data()
    result.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw PommeSecurityWorkflowJournalError.invalidIdentity
        }
        result.append(contentsOf: buffer[0..<count])
        guard result.count <= PommeSecurityWorkflowJournalStore.maximumJournalBytes else {
            throw PommeSecurityWorkflowJournalError.journalTooLarge
        }
    }
    return result
}
