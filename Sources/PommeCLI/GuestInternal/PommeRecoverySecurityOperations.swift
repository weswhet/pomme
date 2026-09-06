import CryptoKit
import Darwin
import Foundation

/// The guest-side Recovery security surface is deliberately smaller than the
/// normal agent command surface.  It is called only after PommeAgent has
/// authenticated a bounded Recovery session.
enum PommeGuestRecoverySecurityError: Error, LocalizedError, Equatable, Sendable {
    case recoveryRoleRequired
    case rootRequired
    case invalidOperation
    case invalidPayload
    case credentialRequired
    case commandFailed
    case nvramWriteDenied
    case verificationFailed
    case rollbackFailed
    case invalidSnapshot
    case invalidPolicy
    case invalidNVRAM
    case nvramMutationUnqualified
    case recoveryEnvironmentUnverified
    case startupVolumeMismatch
    case snapshotPending
    case promptRejected
    case timedOut
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .recoveryRoleRequired:
            "Recovery security operations require the Recovery agent role."
        case .rootRequired:
            "Recovery security operations require root."
        case .invalidOperation:
            "The Recovery security operation is not supported."
        case .invalidPayload:
            "The Recovery security request payload is invalid."
        case .credentialRequired:
            "The Recovery security operation requires an authorized account credential."
        case .commandFailed:
            "The Recovery security command failed."
        case .nvramWriteDenied:
            "The Recovery NVRAM write was denied by the native platform."
        case .verificationFailed:
            "The Recovery security change could not be verified."
        case .rollbackFailed:
            "The Recovery security rollback could not be verified."
        case .invalidSnapshot:
            "The Recovery security snapshot is invalid."
        case .invalidPolicy:
            "The Recovery boot policy is invalid or cannot be restored exactly."
        case .invalidNVRAM:
            "The Recovery NVRAM state is invalid or cannot be restored exactly."
        case .nvramMutationUnqualified:
            "AMFI boot-argument mutation is unavailable until Recovery NVRAM write and readback are qualified."
        case .recoveryEnvironmentUnverified:
            "AMFI mutation requires an authenticated Recovery environment."
        case .startupVolumeMismatch:
            "The selected startup volume group does not match the requested Recovery target."
        case .snapshotPending:
            "A previous Recovery security transition is unresolved."
        case .promptRejected:
            "The Recovery security command presented an unsupported prompt."
        case .timedOut:
            "The Recovery security command timed out."
        case .outputTooLarge:
            "The Recovery security command returned too much output."
        }
    }
}

/// Durable phases are written before and after every policy/NVRAM effect.  A
/// process that dies between those writes leaves enough evidence for the next
/// same-direction request to reconcile the exact baseline rather than guessing
/// which half of the operation completed.
enum PommeGuestAMFITransactionPhase: String, Codable, Equatable, Sendable {
    case baselineCaptured
    case policyApplying
    case policyApplied
    case disabledConfigured
    case normalNVRAMApplying
    case normalNVRAMApplied
    case nvramApplying
    case nvramApplied
    case verifying
    case disabledVerified
    case restoringPolicy
    case policyRestored
    case restoringNVRAM
    case nvramRestored
    case enabledConfigured
    case enabledVerified
    case rollbackApplying
    case rollbackVerified
    case rollbackFailed

    var reconciliationRequired: Bool {
        switch self {
        case .disabledVerified, .enabledVerified:
            return false
        default:
            return true
        }
    }
}

/// Versioned ownership of the boot-argument half of the transaction. Version
/// 2 records use the original Recovery-only writer; staged records use the
/// authenticated persistent normal agent and are never interpreted by the
/// legacy Recovery path.
enum PommeGuestAMFIExecutionMode: String, Codable, Equatable, Sendable {
    case recoveryNVRAM
    case splitNormalNVRAM
}

/// A native LocalPolicy write is an authenticated, irreversible transition
/// from the point of view of the anti-replay fields.  The intent is persisted
/// before bputil is invoked; the complete post-readback policy is persisted as
/// a receipt only after the transition has been checked against the selected
/// volume and the policy's stable identity.
enum PommeGuestAMFINativePolicyAction: String, Codable, Equatable, Sendable {
    case disable
    case restore
    case rollback
}

struct PommeGuestAMFINativePolicyTransition: Codable, Equatable, Sendable {
    let action: PommeGuestAMFINativePolicyAction
    let beforePolicy: Data
    let beforeGeneration: UInt64
    let afterPolicy: Data?
    let afterGeneration: UInt64?
    let receipt: Bool

    init(
        action: PommeGuestAMFINativePolicyAction,
        beforePolicy: Data,
        beforeGeneration: UInt64,
        afterPolicy: Data? = nil,
        afterGeneration: UInt64? = nil,
        receipt: Bool = false
    ) throws {
        let hasAfterPolicy = afterPolicy != nil
        let hasAfterGeneration = afterGeneration != nil
        guard !beforePolicy.isEmpty,
              hasAfterPolicy == hasAfterGeneration,
              receipt == hasAfterPolicy,
              afterPolicy.map({ !$0.isEmpty }) ?? true
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        self.action = action
        self.beforePolicy = beforePolicy
        self.beforeGeneration = beforeGeneration
        self.afterPolicy = afterPolicy
        self.afterGeneration = afterGeneration
        self.receipt = receipt
    }

    var isWellFormed: Bool {
        let hasAfterPolicy = afterPolicy != nil
        let hasAfterGeneration = afterGeneration != nil
        return !beforePolicy.isEmpty
            && hasAfterPolicy == hasAfterGeneration
            && receipt == hasAfterPolicy
            && (afterPolicy?.isEmpty == false || afterPolicy == nil)
    }
}

/// The complete policy bytes observed after a native transition.  Keeping
/// this separately from the transition makes a resumed transaction compare
/// against the exact policy produced by its own authenticated write instead
/// of adopting a changed policy found in the guest after a crash.
struct PommeGuestAMFIPolicyCheckpoint: Codable, Equatable, Sendable {
    let action: PommeGuestAMFINativePolicyAction
    let observedPolicy: Data
    let generation: UInt64

    init(
        action: PommeGuestAMFINativePolicyAction,
        observedPolicy: Data,
        generation: UInt64
    ) throws {
        guard !observedPolicy.isEmpty else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        self.action = action
        self.observedPolicy = observedPolicy
        self.generation = generation
    }

    var isWellFormed: Bool { !observedPolicy.isEmpty }
}

enum PommeGuestAMFINVRAMAction: String, Codable, Equatable, Sendable {
    case disable
    case restore
    case rollback
}

struct PommeGuestAMFINVRAMCheckpoint: Codable, Equatable, Sendable {
    let action: PommeGuestAMFINVRAMAction
    let before: PommeNVRAMDelta
    let target: PommeNVRAMDelta
    let receipt: Bool

    init(
        action: PommeGuestAMFINVRAMAction,
        before: PommeNVRAMDelta,
        target: PommeNVRAMDelta,
        receipt: Bool = false
    ) throws {
        guard Set(before.values.keys) == Set(target.values.keys) else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        self.action = action
        self.before = before
        self.target = target
        self.receipt = receipt
    }

    var isWellFormed: Bool {
        !before.values.isEmpty && !target.values.isEmpty
            && Set(before.values.keys) == Set(target.values.keys)
    }
}

enum PommeGuestAMFINVRAMFailureStage: String, Codable, Equatable, Sendable {
    /// The runner did not return a completed process status. This can cover
    /// launch failure, timeout, or output limits; it does not claim which
    /// point the native process reached.
    case completionUnavailable
    case completedExit
}

enum PommeGuestAMFINVRAMFailureCategory: String, Codable, Equatable, Sendable {
    case permissionDenied
    case notPermitted
    case invalidArgument
    case other

    static func classify(stderr: Data) -> Self {
        let text = String(decoding: stderr.prefix(4 * 1024), as: UTF8.self).lowercased()
        if text.contains("permission denied") {
            return .permissionDenied
        }
        if text.contains("not permitted") || text.contains("not allowed") {
            return .notPermitted
        }
        if text.contains("invalid argument") || text.contains("bad argument") {
            return .invalidArgument
        }
        return .other
    }
}

struct PommeGuestAMFINVRAMFailureDiagnostic: Codable, Equatable, Sendable {
    let action: PommeGuestAMFINVRAMAction
    let transactionPhase: PommeGuestAMFITransactionPhase
    let stage: PommeGuestAMFINVRAMFailureStage
    let exitCode: Int32?
    let stderrCategory: PommeGuestAMFINVRAMFailureCategory

    init(
        action: PommeGuestAMFINVRAMAction,
        transactionPhase: PommeGuestAMFITransactionPhase,
        stage: PommeGuestAMFINVRAMFailureStage,
        exitCode: Int32?,
        stderrCategory: PommeGuestAMFINVRAMFailureCategory
    ) throws {
        let expectedPhase: PommeGuestAMFITransactionPhase
        switch action {
        case .disable: expectedPhase = .nvramApplying
        case .restore: expectedPhase = .restoringNVRAM
        case .rollback: expectedPhase = .rollbackApplying
        }
        let validPhase: Bool
        switch action {
        case .disable:
            validPhase = transactionPhase == .nvramApplying
                || transactionPhase == .normalNVRAMApplying
        case .restore:
            validPhase = transactionPhase == .restoringNVRAM
                || transactionPhase == .normalNVRAMApplying
        case .rollback:
            validPhase = transactionPhase == expectedPhase
        }
        guard validPhase,
              (stage == .completionUnavailable && exitCode == nil)
                  || (stage == .completedExit && exitCode != nil)
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        self.action = action
        self.transactionPhase = transactionPhase
        self.stage = stage
        self.exitCode = exitCode
        self.stderrCategory = stderrCategory
    }

    var isWellFormed: Bool {
        let expectedPhase: PommeGuestAMFITransactionPhase
        switch action {
        case .disable: expectedPhase = .nvramApplying
        case .restore: expectedPhase = .restoringNVRAM
        case .rollback: expectedPhase = .rollbackApplying
        }
        let validPhase: Bool
        switch action {
        case .disable:
            validPhase = transactionPhase == .nvramApplying
                || transactionPhase == .normalNVRAMApplying
        case .restore:
            validPhase = transactionPhase == .restoringNVRAM
                || transactionPhase == .normalNVRAMApplying
        case .rollback:
            validPhase = transactionPhase == expectedPhase
        }
        return validPhase
            && ((stage == .completionUnavailable && exitCode == nil)
                || (stage == .completedExit && exitCode != nil))
    }

    var statusObject: JSONValue {
        var object: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "phase": .string(transactionPhase.rawValue),
            "stage": .string(stage.rawValue),
            "stderrCategory": .string(stderrCategory.rawValue)
        ]
        if let exitCode {
            object["exitCode"] = .integer(Int64(exitCode))
        }
        return .object(object)
    }
}

private struct PommeGuestAMFINVRAMApplyFailure: Error {
    let diagnostic: PommeGuestAMFINVRAMFailureDiagnostic
    let recoveryError: PommeGuestRecoverySecurityError
}

struct PommeGuestAMFISnapshotRecord: Codable, Equatable, Sendable {
    let version: Int
    let executionMode: PommeGuestAMFIExecutionMode
    let volumeGroupUUID: UUID
    let phase: PommeGuestAMFITransactionPhase
    let snapshot: PommeAMFISecuritySnapshot
    let policyCheckpoint: PommeGuestAMFIPolicyCheckpoint?
    let nativeTransition: PommeGuestAMFINativePolicyTransition?
    let nvramCheckpoint: PommeGuestAMFINVRAMCheckpoint?
    let nvramFailure: PommeGuestAMFINVRAMFailureDiagnostic?

    private enum CodingKeys: String, CodingKey {
        case version
        case executionMode
        case volumeGroupUUID
        case phase
        case snapshot
        case policyCheckpoint
        case nativeTransition
        case nvramCheckpoint
        case nvramFailure
    }

    var isWellFormed: Bool {
        guard (version == 1 || version == 2 || version == 3),
              (version < 3 ? executionMode == .recoveryNVRAM : true),
              (version < 3 || executionMode == .splitNormalNVRAM),
              snapshot.isWellFormed,
              nativeTransition.map(\.isWellFormed) ?? true,
              policyCheckpoint.map(\.isWellFormed) ?? true,
              nvramCheckpoint.map(\.isWellFormed) ?? true,
              nvramFailure.map(\.isWellFormed) ?? true
        else { return false }

        // Version 1 records predate durable transition receipts. Do not let
        // a mixed-format record take a legacy baseline shortcut.
        if version == 1,
           policyCheckpoint != nil || nativeTransition != nil || nvramFailure != nil {
            return false
        }
        if executionMode == .splitNormalNVRAM, version < 3 {
            return false
        }
        if version < 3,
           [.disabledConfigured, .normalNVRAMApplying, .normalNVRAMApplied,
            .enabledConfigured, .enabledVerified].contains(phase) {
            return false
        }
        if let checkpoint = policyCheckpoint {
            guard let transition = nativeTransition,
                  transition.receipt,
                  transition.action == checkpoint.action,
                  transition.afterPolicy == checkpoint.observedPolicy,
                  transition.afterGeneration == checkpoint.generation else {
                return false
            }
        }
        if let transition = nativeTransition,
           transition.receipt,
           policyCheckpoint == nil {
            return false
        }
        return true
    }

    init(
        volumeGroupUUID: UUID,
        phase: PommeGuestAMFITransactionPhase,
        snapshot: PommeAMFISecuritySnapshot,
        executionMode: PommeGuestAMFIExecutionMode = .recoveryNVRAM,
        policyCheckpoint: PommeGuestAMFIPolicyCheckpoint? = nil,
        nativeTransition: PommeGuestAMFINativePolicyTransition? = nil,
        nvramCheckpoint: PommeGuestAMFINVRAMCheckpoint? = nil,
        nvramFailure: PommeGuestAMFINVRAMFailureDiagnostic? = nil
    ) throws {
        version = executionMode == .splitNormalNVRAM ? 3 : 2
        self.executionMode = executionMode
        self.volumeGroupUUID = volumeGroupUUID
        self.phase = phase
        self.snapshot = snapshot
        self.policyCheckpoint = policyCheckpoint
        self.nativeTransition = nativeTransition
        self.nvramCheckpoint = nvramCheckpoint
        self.nvramFailure = nvramFailure
        guard isWellFormed else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    init(
        version: Int,
        volumeGroupUUID: UUID,
        phase: PommeGuestAMFITransactionPhase,
        snapshot: PommeAMFISecuritySnapshot,
        executionMode: PommeGuestAMFIExecutionMode = .recoveryNVRAM,
        policyCheckpoint: PommeGuestAMFIPolicyCheckpoint?,
        nativeTransition: PommeGuestAMFINativePolicyTransition?,
        nvramCheckpoint: PommeGuestAMFINVRAMCheckpoint?,
        nvramFailure: PommeGuestAMFINVRAMFailureDiagnostic? = nil
    ) throws {
        self.version = version
        self.executionMode = executionMode
        self.volumeGroupUUID = volumeGroupUUID
        self.phase = phase
        self.snapshot = snapshot
        self.policyCheckpoint = policyCheckpoint
        self.nativeTransition = nativeTransition
        self.nvramCheckpoint = nvramCheckpoint
        self.nvramFailure = nvramFailure
        guard isWellFormed else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        executionMode = try container.decodeIfPresent(
            PommeGuestAMFIExecutionMode.self,
            forKey: .executionMode
        ) ?? .recoveryNVRAM
        volumeGroupUUID = try container.decode(UUID.self, forKey: .volumeGroupUUID)
        phase = try container.decode(PommeGuestAMFITransactionPhase.self, forKey: .phase)
        snapshot = try container.decode(PommeAMFISecuritySnapshot.self, forKey: .snapshot)
        policyCheckpoint = try container.decodeIfPresent(
            PommeGuestAMFIPolicyCheckpoint.self,
            forKey: .policyCheckpoint
        )
        nativeTransition = try container.decodeIfPresent(
            PommeGuestAMFINativePolicyTransition.self,
            forKey: .nativeTransition
        )
        nvramCheckpoint = try container.decodeIfPresent(
            PommeGuestAMFINVRAMCheckpoint.self,
            forKey: .nvramCheckpoint
        )
        nvramFailure = try container.decodeIfPresent(
            PommeGuestAMFINVRAMFailureDiagnostic.self,
            forKey: .nvramFailure
        )
        guard isWellFormed else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(executionMode, forKey: .executionMode)
        try container.encode(volumeGroupUUID, forKey: .volumeGroupUUID)
        try container.encode(phase, forKey: .phase)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encodeIfPresent(policyCheckpoint, forKey: .policyCheckpoint)
        try container.encodeIfPresent(nativeTransition, forKey: .nativeTransition)
        try container.encodeIfPresent(nvramCheckpoint, forKey: .nvramCheckpoint)
        try container.encodeIfPresent(nvramFailure, forKey: .nvramFailure)
    }

    var isLegacy: Bool { version == 1 }
    var isSplitNormalNVRAM: Bool { executionMode == .splitNormalNVRAM }
}

struct PommeGuestSecurityCredentials: Sendable, Equatable {
    let username: String
    let password: String

    init(username: String, password: String) throws {
        guard !username.isEmpty,
              username.utf8.count <= 256,
              !username.contains("\0"),
              !password.isEmpty,
              password.utf8.count <= 64 * 1024,
              !password.contains("\0")
        else { throw PommeGuestRecoverySecurityError.credentialRequired }
        self.username = username
        self.password = password
    }
}

struct PommeGuestProcessCapture: Sendable, Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Exact, owner-only persistence for the pre-mutation AMFI state.  Production
/// instances are rooted at the resolved target Data volume and carry the
/// selected APFS volume-group UUID, so Recovery's ephemeral root cannot become
/// the journal location for a later enable operation. The file contains no
/// credential material and is left in place when rollback cannot be proved.
struct PommeGuestAMFISnapshotStore: Sendable {
    static let snapshotRelativePath = "private/var/db/pomme/amfi-recovery.snapshot"
    typealias PublicationFailureInjector = @Sendable (
        _ phase: PommeGuestAMFITransactionPhase,
        _ replacing: Bool
    ) throws -> Void

    let url: URL
    let dataRoot: URL?
    let volumeGroupUUID: UUID
    let expectedOwner: uid_t
    let expectedGroup: gid_t?
    private let publicationFailureInjector: PublicationFailureInjector?

    init(
        url: URL,
        volumeGroupUUID: UUID,
        expectedOwner: uid_t = 0,
        expectedGroup: gid_t? = 0,
        publicationFailureInjector: PublicationFailureInjector? = nil
    ) {
        self.url = url.standardizedFileURL
        self.dataRoot = nil
        self.volumeGroupUUID = volumeGroupUUID
        self.expectedOwner = expectedOwner
        self.expectedGroup = expectedGroup
        self.publicationFailureInjector = publicationFailureInjector
    }

    init(
        dataRoot: URL,
        volumeGroupUUID: UUID,
        expectedOwner: uid_t = 0,
        expectedGroup: gid_t? = 0,
        publicationFailureInjector: PublicationFailureInjector? = nil
    ) throws {
        let root = dataRoot.standardizedFileURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        self.url = root.appendingPathComponent(Self.snapshotRelativePath)
        self.dataRoot = root
        self.volumeGroupUUID = volumeGroupUUID
        self.expectedOwner = expectedOwner
        self.expectedGroup = expectedGroup
        self.publicationFailureInjector = publicationFailureInjector
    }

    func isPresent() throws -> Bool {
        try loadRecordIfPresent() != nil
    }

    func save(_ snapshot: PommeAMFISecuritySnapshot) throws {
        try save(
            snapshot,
            phase: .baselineCaptured,
            executionMode: .recoveryNVRAM
        )
    }

    func save(
        _ snapshot: PommeAMFISecuritySnapshot,
        phase: PommeGuestAMFITransactionPhase,
        executionMode: PommeGuestAMFIExecutionMode = .recoveryNVRAM
    ) throws {
        try validateDataRoot()
        let record = try PommeGuestAMFISnapshotRecord(
            volumeGroupUUID: volumeGroupUUID,
            phase: phase,
            snapshot: snapshot,
            executionMode: executionMode
        )
        let exists = try loadRecordIfPresent() != nil
        guard !exists else { throw PommeGuestRecoverySecurityError.snapshotPending }
        try publish(record, replacing: false)
    }

    func loadRecordIfPresent() throws -> PommeGuestAMFISnapshotRecord? {
        try validateDataRoot()
        guard let data = try readExactFile() else { return nil }
        do {
            let record = try JSONDecoder().decode(PommeGuestAMFISnapshotRecord.self, from: data)
            guard record.volumeGroupUUID == volumeGroupUUID,
                  record.isWellFormed
            else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            return record
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            // Accept the pre-phase format only as a baseline captured record;
            // it remains bound to this store's selected volume group.
            do {
                let snapshot = try JSONDecoder().decode(PommeAMFISecuritySnapshot.self, from: data)
                return try .init(
                    version: 1,
                    volumeGroupUUID: volumeGroupUUID,
                    phase: .baselineCaptured,
                    snapshot: snapshot,
                    policyCheckpoint: nil,
                    nativeTransition: nil,
                    nvramCheckpoint: nil
                )
            } catch {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
        }
    }

    func loadRecord() throws -> PommeGuestAMFISnapshotRecord {
        guard let record = try loadRecordIfPresent() else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        return record
    }

    func load() throws -> PommeAMFISecuritySnapshot {
        try loadRecord().snapshot
    }

    func setPhase(_ phase: PommeGuestAMFITransactionPhase) throws {
        let current = try loadRecord()
        try update(
            phase: phase,
            policyCheckpoint: current.policyCheckpoint,
            nativeTransition: current.nativeTransition,
            nvramCheckpoint: current.nvramCheckpoint,
            nvramFailure: current.nvramFailure
        )
    }

    func update(
        phase: PommeGuestAMFITransactionPhase,
        policyCheckpoint: PommeGuestAMFIPolicyCheckpoint?,
        nativeTransition: PommeGuestAMFINativePolicyTransition?,
        nvramCheckpoint: PommeGuestAMFINVRAMCheckpoint?
    ) throws {
        let current = try loadRecord()
        try update(
            phase: phase,
            policyCheckpoint: policyCheckpoint,
            nativeTransition: nativeTransition,
            nvramCheckpoint: nvramCheckpoint,
            nvramFailure: current.nvramFailure
        )
    }

    func update(
        phase: PommeGuestAMFITransactionPhase,
        policyCheckpoint: PommeGuestAMFIPolicyCheckpoint?,
        nativeTransition: PommeGuestAMFINativePolicyTransition?,
        nvramCheckpoint: PommeGuestAMFINVRAMCheckpoint?,
        nvramFailure: PommeGuestAMFINVRAMFailureDiagnostic?
    ) throws {
        let current = try loadRecord()
        try publish(
            try .init(
                volumeGroupUUID: current.volumeGroupUUID,
                phase: phase,
                snapshot: current.snapshot,
                executionMode: current.executionMode,
                policyCheckpoint: policyCheckpoint,
                nativeTransition: nativeTransition,
                nvramCheckpoint: nvramCheckpoint,
                nvramFailure: nvramFailure
            ),
            replacing: true
        )
    }

    /// Replaces a completed staged tombstone with a newly captured baseline.
    /// The caller must first prove that the current policy and exact NVRAM
    /// still match the tombstone's verified terminal state.
    func replaceBaseline(
        _ snapshot: PommeAMFISecuritySnapshot,
        executionMode: PommeGuestAMFIExecutionMode = .splitNormalNVRAM
    ) throws {
        try validateDataRoot()
        let current = try loadRecord()
        guard current.phase == .enabledVerified else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        try publish(
            try .init(
                volumeGroupUUID: volumeGroupUUID,
                phase: .baselineCaptured,
                snapshot: snapshot,
                executionMode: executionMode
            ),
            replacing: true
        )
    }

    func clear() throws {
        try validateDataRoot()
        guard try loadRecordIfPresent() != nil else { return }
        // Re-check the opened inode through the same descriptor-relative
        // parent immediately before removal. A symlink or path-component swap
        // cannot redirect this operation to another directory.
        try withVerifiedParent { parent, name in
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1 else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            defer { _ = Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_dev == info.st_dev,
                  opened.st_ino == info.st_ino,
                  opened.st_nlink == info.st_nlink,
                  unlinkat(parent, name, 0) == 0,
                  fsync(parent) == 0 else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
        }
    }

    private func publish(
        _ record: PommeGuestAMFISnapshotRecord,
        replacing: Bool
    ) throws {
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        guard data.count <= 1024 * 1024 else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        do {
            try publicationFailureInjector?(record.phase, replacing)
            try withVerifiedParent { parentDescriptor, name in
                let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString.lowercased())"
                let descriptor = openat(
                    parentDescriptor,
                    temporaryName,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
                guard descriptor >= 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
                var descriptorOpen = true
                var published = false
                defer {
                    if descriptorOpen { _ = Darwin.close(descriptor) }
                    if !published { _ = unlinkat(parentDescriptor, temporaryName, 0) }
                }
                try writeAll(descriptor, data)
                guard fchmod(descriptor, mode_t(0o600)) == 0,
                      fchown(descriptor, expectedOwner, expectedGroup ?? getegid()) == 0,
                      fsync(descriptor) == 0 else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
                guard close(descriptor) == 0 else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
                descriptorOpen = false
                if replacing {
                    guard renameatx_np(
                        parentDescriptor, temporaryName,
                        parentDescriptor, name,
                        UInt32(RENAME_SWAP)
                    ) == 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
                    guard unlinkat(parentDescriptor, temporaryName, 0) == 0 else {
                        throw PommeGuestRecoverySecurityError.invalidSnapshot
                    }
                } else {
                    guard renameatx_np(
                        parentDescriptor, temporaryName,
                        parentDescriptor, name,
                        UInt32(RENAME_EXCL)
                    ) == 0 else {
                        if errno == EEXIST { throw PommeGuestRecoverySecurityError.snapshotPending }
                        throw PommeGuestRecoverySecurityError.invalidSnapshot
                    }
                }
                published = true
                guard fsync(parentDescriptor) == 0 else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
                var written = stat()
                guard fstatat(parentDescriptor, name, &written, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
                try validate(written, regular: true)
                guard written.st_nlink == 1 else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
            }
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    private func readExactFile() throws -> Data? {
        return try withVerifiedParent { parent, name in
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { return nil }
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            defer { _ = Darwin.close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            try validate(before, regular: true)
            guard before.st_nlink == 1,
                  before.st_size > 0,
                  before.st_size <= 1024 * 1024 else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            var data = Data(count: Int(before.st_size))
            try data.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw PommeGuestRecoverySecurityError.invalidSnapshot
                    }
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_nlink == after.st_nlink,
                  before.st_size == after.st_size else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            return data
        }
    }

    private func validateDataRoot() throws {
        guard let dataRoot else { return }
        var info = stat()
        guard lstat(dataRoot.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              dataRoot.path.hasPrefix("/"),
              dataRoot.path == dataRoot.resolvingSymlinksInPath().standardizedFileURL.path,
              url.path.hasPrefix(dataRoot.path.hasSuffix("/") ? dataRoot.path : dataRoot.path + "/")
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func withVerifiedParent<T>(_ body: (Int32, String) throws -> T) throws -> T {
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        defer { _ = Darwin.close(root) }
        do {
            return try PommeAgentFileTransaction.withVerifiedParent(
                of: url,
                rootDescriptor: root,
                body
            )
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    private func ensureDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            guard lstat(directory.path, &info) == 0 else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == expectedOwner,
              info.st_mode & 0o077 == 0,
              expectedGroup.map({ info.st_gid == $0 }) ?? true
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func validate(_ info: stat, regular: Bool) throws {
        guard (!regular || (info.st_mode & S_IFMT) == S_IFREG),
              info.st_uid == expectedOwner,
              info.st_mode & 0o077 == 0,
              expectedGroup.map({ info.st_gid == $0 }) ?? true
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
            }
        }
    }
}

/// Guest-side Recovery security dispatcher.  PommeAgent can call this value
/// directly from its Recovery branch; no normal-role caller is admitted.
struct PommeGuestRecoverySecurityOperations: Sendable {
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> PommeGuestProcessCapture
    typealias SecretProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ credentials: PommeGuestSecurityCredentials) throws -> PommeGuestProcessCapture
    typealias DataRootResolver = @Sendable (_ expectedVolumeGroupUUID: UUID) throws -> URL
    /// A production verifier must prove both that the process is executing in
    /// Recovery and that the requested UUID is the uniquely selected APFS
    /// System+Data volume group. Tests may inject a deterministic equivalent;
    /// the default is always a real command-backed proof.
    typealias RecoveryEnvironmentVerifier = @Sendable (_ expectedVolumeGroupUUID: UUID) throws -> Void
    /// The normal agent must independently prove that it is running from the
    /// installed startup System+Data pair before it can touch boot-args.  The
    /// injected form is used only by deterministic offline tests.
    typealias NormalEnvironmentVerifier = @Sendable (_ expectedVolumeGroupUUID: UUID) throws -> Void

    private let process: ProcessRunner
    private let secretProcess: SecretProcessRunner
    private let effectiveUserID: @Sendable () -> uid_t
    private let snapshotStore: PommeGuestAMFISnapshotStore?
    private let dataRootResolver: DataRootResolver?
    private let recoveryEnvironmentVerifier: RecoveryEnvironmentVerifier
    private let normalEnvironmentVerifier: NormalEnvironmentVerifier
    /// Kept as a narrow compatibility seam for offline qualification tests.
    /// Production construction leaves it nil and uses the concrete verifier.
    private let legacyNVRAMMutationVerified: (@Sendable () -> Bool)?

    init(
        process: @escaping ProcessRunner = Self.runProcess,
        secretProcess: @escaping SecretProcessRunner = Self.runSecretProcess,
        effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
        snapshotStore: PommeGuestAMFISnapshotStore? = nil,
        dataRootResolver: DataRootResolver? = nil,
        nvramMutationVerified: (@Sendable () -> Bool)? = nil,
        recoveryEnvironmentVerifier: RecoveryEnvironmentVerifier? = nil,
        normalEnvironmentVerifier: NormalEnvironmentVerifier? = nil
    ) {
        self.process = process
        self.secretProcess = secretProcess
        self.effectiveUserID = effectiveUserID
        self.snapshotStore = snapshotStore
        self.dataRootResolver = dataRootResolver
        self.legacyNVRAMMutationVerified = nvramMutationVerified
        self.recoveryEnvironmentVerifier = recoveryEnvironmentVerifier ?? { expected in
            try Self.verifyRecoveryEnvironment(
                expectedVolumeGroupUUID: expected,
                process: process
            )
        }
        self.normalEnvironmentVerifier = normalEnvironmentVerifier ?? { expected in
            try Self.verifyNormalEnvironment(
                expectedVolumeGroupUUID: expected,
                process: process
            )
        }
    }

    /// Execute exactly one of the six Recovery operations. Mutation payloads
    /// contain only an authorized username and password; neither is returned
    /// or interpolated into an error.
    func execute(role: PommeAgentRole, operation: String, payload: JSONValue) throws -> JSONValue {
        guard role == .recovery else { throw PommeGuestRecoverySecurityError.recoveryRoleRequired }
        guard effectiveUserID() == 0 else { throw PommeGuestRecoverySecurityError.rootRequired }
        guard let operation = Operation(rawValue: operation) else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }

        do {
            switch operation {
            case .sipStatus:
                try requireEmptyPayload(payload)
                return try sipStatusResult(operation: operation.rawValue)
            case .sipDisable:
                let request = try sipMutationRequest(from: payload)
                return try sipMutation(
                    operation: operation,
                    credentials: request.credentials,
                    expectedVolumeGroupUUID: request.volumeGroupUUID
                )
            case .sipEnable:
                let request = try sipMutationRequest(from: payload)
                return try sipMutation(
                    operation: operation,
                    credentials: request.credentials,
                    expectedVolumeGroupUUID: request.volumeGroupUUID
                )
            case .amfiStatus:
                return try amfiStatusResult(payload: payload)
            case .amfiDisable:
                let request = try amfiRequest(from: payload)
                if request.stage == .policy {
                    return try amfiDisablePolicyOnly(
                        expectedVolumeGroupUUID: request.volumeGroupUUID,
                        credentials: request.credentials
                    )
                }
                return try amfiDisable(expectedVolumeGroupUUID: request.volumeGroupUUID, credentials: request.credentials)
            case .amfiEnable:
                let request = try amfiRequest(from: payload)
                if request.stage == .policy {
                    return try amfiEnablePolicyOnly(
                        expectedVolumeGroupUUID: request.volumeGroupUUID,
                        credentials: request.credentials
                    )
                }
                return try amfiEnable(expectedVolumeGroupUUID: request.volumeGroupUUID, credentials: request.credentials)
            }
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    /// Execute the credential-free normal-boot half of the staged AMFI
    /// transaction.  Only the exact volume-group UUID is accepted; all
    /// ownership and target state comes from the durable split record written
    /// by the authenticated Recovery stage.
    func executeNormalAMFI(
        role: PommeAgentRole,
        operation: String,
        payload: JSONValue
    ) throws -> JSONValue {
        guard role == .persistent else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        guard effectiveUserID() == 0 else {
            throw PommeGuestRecoverySecurityError.rootRequired
        }
        guard let operation = NormalAMFIOperation(rawValue: operation) else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        let volumeGroupUUID = try normalAMFIRequest(from: payload)
        do {
            try normalEnvironmentVerifier(volumeGroupUUID)
            let store = try normalSnapshotStore(for: volumeGroupUUID)
            let record = try store.loadRecord()
            guard record.isSplitNormalNVRAM else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            switch operation {
            case .disable:
                return try normalAMFIDisable(store: store, record: record, volumeGroupUUID: volumeGroupUUID)
            case .enable:
                return try normalAMFIEnable(store: store, record: record, volumeGroupUUID: volumeGroupUUID)
            case .verifyDisabled:
                return try normalAMFIVerifyDisabled(store: store, record: record, volumeGroupUUID: volumeGroupUUID)
            case .verifyEnabled:
                return try normalAMFIVerifyEnabled(store: store, record: record, volumeGroupUUID: volumeGroupUUID)
            }
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    private enum Operation: String {
        case sipStatus = "sip.status"
        case sipDisable = "sip.disable"
        case sipEnable = "sip.enable"
        case amfiStatus = "amfi.status"
        case amfiDisable = "amfi.disable"
        case amfiEnable = "amfi.enable"

        var mutationAction: String {
            switch self {
            case .sipDisable, .amfiDisable: "disable"
            case .sipEnable, .amfiEnable: "enable"
            case .sipStatus, .amfiStatus: "status"
            }
        }
    }

    private enum NormalAMFIOperation: String {
        case disable = "amfi.normal.disable"
        case enable = "amfi.normal.enable"
        case verifyDisabled = "amfi.normal.verifyDisabled"
        case verifyEnabled = "amfi.normal.verifyEnabled"
    }

    private func requireEmptyPayload(_ payload: JSONValue) throws {
        guard let object = payload.objectValue, object.isEmpty else {
            throw PommeGuestRecoverySecurityError.invalidPayload
        }
    }

    private func credentials(from payload: JSONValue) throws -> PommeGuestSecurityCredentials {
        guard let object = payload.objectValue,
              Set(object.keys) == ["authorizedUser", "password"],
              let username = object["authorizedUser"]?.stringValue,
              let password = object["password"]?.stringValue
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        return try PommeGuestSecurityCredentials(username: username, password: password)
    }

    private struct SIPMutationRequest: Sendable {
        let credentials: PommeGuestSecurityCredentials
        let volumeGroupUUID: UUID?
    }

    private func sipMutationRequest(from payload: JSONValue) throws -> SIPMutationRequest {
        guard let object = payload.objectValue else {
            throw PommeGuestRecoverySecurityError.invalidPayload
        }
        if Set(object.keys) == ["authorizedUser", "password"] {
            // Keep the old closed credentials-only form for explicitly
            // injected offline callers. Production construction must carry
            // the target UUID so the guest can validate the selected startup
            // volume before accepting a SIP write.
            guard legacyNVRAMMutationVerified != nil else {
                throw PommeGuestRecoverySecurityError.invalidPayload
            }
            return try .init(credentials: credentials(from: payload), volumeGroupUUID: nil)
        }
        guard Set(object.keys) == ["authorizedUser", "password", "volumeGroupUUID"],
              let rawUUID = object["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawUUID),
              volumeGroupUUID.uuidString.lowercased() == rawUUID
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        return try .init(
            credentials: credentials(from: .object([
                "authorizedUser": object["authorizedUser"] ?? .null,
                "password": object["password"] ?? .null
            ])),
            volumeGroupUUID: volumeGroupUUID
        )
    }

    private enum AMFIRequestStage: String {
        case policy
    }

    private func amfiRequest(from payload: JSONValue) throws -> (
        credentials: PommeGuestSecurityCredentials,
        volumeGroupUUID: UUID,
        stage: AMFIRequestStage?
    ) {
        guard let object = payload.objectValue,
              Set(object.keys).isSubset(of: ["authorizedUser", "password", "volumeGroupUUID", "stage"]),
              Set(["authorizedUser", "password", "volumeGroupUUID"]).isSubset(of: Set(object.keys)),
              let rawUUID = object["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawUUID),
              volumeGroupUUID.uuidString.lowercased() == rawUUID
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        let stage: AMFIRequestStage?
        if let rawStage = object["stage"] {
            guard let value = rawStage.stringValue,
                  let parsed = AMFIRequestStage(rawValue: value) else {
                throw PommeGuestRecoverySecurityError.invalidPayload
            }
            stage = parsed
        } else {
            stage = nil
        }
        return try (credentials(from: .object([
            "authorizedUser": object["authorizedUser"] ?? .null,
            "password": object["password"] ?? .null
        ])), volumeGroupUUID, stage)
    }

    private func normalAMFIRequest(from payload: JSONValue) throws -> UUID {
        guard let object = payload.objectValue,
              Set(object.keys) == ["volumeGroupUUID"],
              let rawUUID = object["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawUUID),
              volumeGroupUUID.uuidString.lowercased() == rawUUID else {
            throw PommeGuestRecoverySecurityError.invalidPayload
        }
        return volumeGroupUUID
    }

    private func sipStatus() throws -> Bool {
        let result = try process("/usr/bin/csrutil", ["status"])
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        let text = String(decoding: result.stdout, as: UTF8.self)
        let matches = ["enabled", "disabled"].filter { state in
            text.range(of: #"(?i)\bstatus\s*:\s*\#(state)\b"#, options: .regularExpression) != nil
        }
        guard matches.count == 1 else { throw PommeGuestRecoverySecurityError.verificationFailed }
        return matches[0] == "enabled"
    }

    private func sipStatusResult(operation: String) throws -> JSONValue {
        let enabled = try sipStatus()
        return .object([
            "operation": .string(operation),
            "sipEnabled": .bool(enabled),
            "sipDisabled": .bool(!enabled),
            "verified": .bool(true)
        ])
    }

    private func sipMutation(
        operation: Operation,
        credentials: PommeGuestSecurityCredentials,
        expectedVolumeGroupUUID: UUID?
    ) throws -> JSONValue {
        if let expectedVolumeGroupUUID {
            try verifyMutationEnvironment(expectedVolumeGroupUUID)
        } else if let legacyNVRAMMutationVerified {
            guard legacyNVRAMMutationVerified() else {
                throw PommeGuestRecoverySecurityError.nvramMutationUnqualified
            }
        } else {
            throw PommeGuestRecoverySecurityError.invalidPayload
        }
        let expectedEnabled = operation == .sipEnable
        let result = try secretProcess(
            "/usr/bin/csrutil",
            [operation.mutationAction],
            credentials
        )
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        let observedEnabled = try sipStatus()
        guard observedEnabled == expectedEnabled else {
            throw PommeGuestRecoverySecurityError.verificationFailed
        }
        return .object([
            "operation": .string(operation.rawValue),
            "sipEnabled": .bool(observedEnabled),
            "sipDisabled": .bool(!observedEnabled),
            "verified": .bool(true)
        ])
    }

    private func amfiStatusResult(payload: JSONValue) throws -> JSONValue {
        let request = try amfiStatusRequest(from: payload)
        let state = try captureAMFIState(
            expectedVolumeGroupUUID: request.volumeGroupUUID,
            strictPolicy: false
        )
        let active = PommeBootArguments.containsOverride(state.snapshot.nvram.value(for: "boot-args"))
        var result: [String: JSONValue] = [
            "operation": .string(Operation.amfiStatus.rawValue),
            "amfiBootArgActive": .bool(active),
            "amfiDisabled": .bool(active && state.policy.allowsCustomBootArguments),
            "bootPolicyAllowsCustomBootArgs": .bool(state.policy.allowsCustomBootArguments),
            "securityMode": .string(state.policy.securityMode),
            "verified": .bool(true)
        ]
        if request.includeWorkflowState, let volumeGroupUUID = request.volumeGroupUUID {
            let store = try snapshotStore(for: volumeGroupUUID)
            let record = try store.loadRecordIfPresent()
            let tombstone: Bool
            if let record, record.phase == .enabledVerified {
                // A phase label alone is not proof that the final normal
                // boot was observed.  Keep a drifted tombstone visible as a
                // retained baseline so host reconciliation cannot mistake it
                // for a completed transaction.
                tombstone = (try? enabledTombstoneMatches(record, current: state)) == true
            } else {
                tombstone = false
            }
            result["baselinePresent"] = .bool(record != nil && !tombstone)
            let reportedPhase: String
            if tombstone {
                reportedPhase = "none"
            } else if let record {
                // Older split agents published `disabledConfigured` directly
                // after the Recovery policy write. Project that retained
                // policy-only progress to the phase the host can safely
                // resume, without rewriting or adopting the journal.
                reportedPhase = try workflowStatusPhase(record: record, current: state).rawValue
            } else {
                reportedPhase = "none"
            }
            result["baselinePhase"] = .string(reportedPhase)
            let requiresReconciliation: Bool
            if tombstone {
                requiresReconciliation = false
            } else {
                requiresReconciliation = try reconciliationRequired(record: record, current: state)
            }
            result["reconciliationRequired"] = .bool(requiresReconciliation)
            if let nvramFailure = record?.nvramFailure {
                result["nvramFailure"] = nvramFailure.statusObject
            }
        }
        return .object(result)
    }

    private struct AMFIStatusRequest: Sendable {
        let volumeGroupUUID: UUID?
        let includeWorkflowState: Bool
    }

    private func amfiStatusRequest(from payload: JSONValue) throws -> AMFIStatusRequest {
        guard let object = payload.objectValue else {
            throw PommeGuestRecoverySecurityError.invalidPayload
        }
        if object.isEmpty {
            // Preserve the historical no-argument status response exactly;
            // MDM consumes that closed shape.
            return .init(volumeGroupUUID: nil, includeWorkflowState: false)
        }
        guard Set(object.keys).isSubset(of: ["volumeGroupUUID", "includeWorkflowState"]),
              let rawUUID = object["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawUUID),
              volumeGroupUUID.uuidString.lowercased() == rawUUID,
              object["includeWorkflowState"] == .bool(true)
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        return .init(volumeGroupUUID: volumeGroupUUID, includeWorkflowState: true)
    }

    private func reconciliationRequired(
        record: PommeGuestAMFISnapshotRecord?,
        current: PommeGuestAMFIState
    ) throws -> Bool {
        guard let record else { return false }
        // The status caller invokes this only after an enabled tombstone has
        // failed its exact policy/NVRAM proof.  Do not reinterpret that
        // retained enabled record as a disabled target merely because its
        // phase label is one of the normally clean phases.
        if record.phase == .enabledVerified {
            return true
        }
        // An enable can fail after restoring the baseline policy and then
        // compensate with a native rollback to the disabled target.  That
        // leaves a rollback receipt and the durable baseline in place so the
        // same enable request can resume.  Treat this state as reconciled
        // only when the receipt proves the exact disabled projection and the
        // NVRAM target is present; every other rollbackVerified record still
        // requires reconciliation.
        if record.phase == .rollbackVerified,
           record.policyCheckpoint?.action == .rollback {
            let baselinePolicy = try parseSnapshotPolicy(
                record.snapshot.localPolicy,
                expectedVolumeGroupUUID: record.volumeGroupUUID,
                strict: true
            )
            let targetBoot = try PommeNVRAMDelta.bootArguments(
                present: true,
                bytes: PommeBootArguments.addingOverride(
                    to: record.snapshot.nvram.value(for: "boot-args")?.bytes ?? Data()
                )
            )
            let rollbackTarget = try policyCheckpointMatches(
                record: record,
                current: current,
                expected: { $0.matchesDisabledTargetProjection(of: baselinePolicy) }
            )
            if rollbackTarget && current.snapshot.nvram == targetBoot {
                return false
            }
        }

        if record.phase.reconciliationRequired { return true }
        let baselinePolicy = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: record.volumeGroupUUID,
            strict: true
        )
        let targetBoot = try PommeNVRAMDelta.bootArguments(
            present: true,
            bytes: PommeBootArguments.addingOverride(
                to: record.snapshot.nvram.value(for: "boot-args")?.bytes ?? Data()
            )
        )
        let policyTarget: Bool
        if record.isLegacy {
            policyTarget = current.policy.matchesDisabledTarget(of: baselinePolicy)
        } else {
            policyTarget = try policyCheckpointMatches(
                record: record,
                current: current,
                expected: { $0.matchesDisabledTargetProjection(of: baselinePolicy) }
            )
        }
        let nvramTarget: Bool
        if record.phase == .disabledVerified {
            // A clean verified phase requires the durable NVRAM receipt and
            // its exact source baseline as well as the currently observed
            // disabled target.  The phase label alone is never proof.
            nvramTarget = record.nvramCheckpoint?.action == .disable
                && record.nvramCheckpoint?.receipt == true
                && record.nvramCheckpoint?.before == record.snapshot.nvram
                && record.nvramCheckpoint?.target == targetBoot
                && current.snapshot.nvram == targetBoot
        } else {
            nvramTarget = current.snapshot.nvram == targetBoot
        }
        let target = policyTarget && nvramTarget
        return !target
    }

    private func workflowStatusPhase(
        record: PommeGuestAMFISnapshotRecord,
        current: PommeGuestAMFIState
    ) throws -> PommeGuestAMFITransactionPhase {
        guard record.phase == .disabledConfigured,
              record.isSplitNormalNVRAM else {
            return record.phase
        }

        let baselinePolicy = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: record.volumeGroupUUID,
            strict: true
        )
        guard try policyCheckpointMatches(
            record: record,
            current: current,
            expected: { $0.matchesDisabledTargetProjection(of: baselinePolicy) }
        ) else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        let disabledTarget = try disabledBootArguments(from: record.snapshot)
        if let checkpoint = record.nvramCheckpoint {
            guard checkpoint.action == .disable,
                  checkpoint.before == record.snapshot.nvram,
                  checkpoint.target == disabledTarget,
                  (current.snapshot.nvram == (checkpoint.receipt
                      ? checkpoint.target
                      : checkpoint.before)
                      || (!checkpoint.receipt
                          && current.snapshot.nvram == checkpoint.target)) else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            return checkpoint.receipt ? record.phase : .policyApplied
        }

        guard current.snapshot.nvram == record.snapshot.nvram else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        return .policyApplied
    }

    private func policyCheckpointMatches(
        record: PommeGuestAMFISnapshotRecord,
        current: PommeGuestAMFIState,
        expected: (PommeGuestAMFIPolicy) -> Bool
    ) throws -> Bool {
        guard let checkpoint = record.policyCheckpoint,
              let transition = record.nativeTransition,
              transition.action == checkpoint.action,
              transition.receipt,
              transition.afterPolicy == checkpoint.observedPolicy,
              transition.afterGeneration == checkpoint.generation,
              expected(current.policy) else {
            return false
        }
        let before = try parseSnapshotPolicy(
            transition.beforePolicy,
            expectedVolumeGroupUUID: record.volumeGroupUUID,
            strict: true
        )
        let observed = try parseSnapshotPolicy(
            checkpoint.observedPolicy,
            expectedVolumeGroupUUID: record.volumeGroupUUID,
            strict: true
        )
        guard transition.beforeGeneration == before.stng,
              observed.stng == checkpoint.generation,
              current.policy.matchesRetainedBaseline(of: observed) else {
            return false
        }
        if transition.beforePolicy == observed.snapshotCanonical,
           transition.beforeGeneration == observed.stng {
            guard before.isSupportedStandardSIPDisabledProfile,
                  checkpoint.action == .disable || checkpoint.action == .restore else {
                return false
            }
            let baseline = try parseSnapshotPolicy(
                record.snapshot.localPolicy,
                expectedVolumeGroupUUID: record.volumeGroupUUID,
                strict: true
            )
            return baseline.isSupportedStandardSIPDisabledProfile
                && baseline.snapshotCanonical == before.snapshotCanonical
                && before.snapshotCanonical == observed.snapshotCanonical
                && current.policy.snapshotCanonical == observed.snapshotCanonical
        }
        return observed.followsNativeTransition(from: before)
    }

    private func ownedPolicyReceiptMatches(
        record: PommeGuestAMFISnapshotRecord,
        current: PommeGuestAMFIState
    ) throws -> Bool {
        guard let action = record.policyCheckpoint?.action else { return false }
        let baseline = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: record.volumeGroupUUID,
            strict: true
        )
        switch action {
        case .disable:
            return try policyCheckpointMatches(
                record: record,
                current: current,
                expected: { $0.matchesDisabledTargetProjection(of: baseline) }
            )
        case .restore, .rollback:
            return try policyCheckpointMatches(
                record: record,
                current: current,
                expected: {
                    $0.restorableCanonical == baseline.restorableCanonical
                        && $0.nativeStableIdentityCanonical == baseline.nativeStableIdentityCanonical
                }
            )
        }
    }

    private func nativePolicyIntent(
        for state: PommeGuestAMFIState,
        action: PommeGuestAMFINativePolicyAction
    ) throws -> PommeGuestAMFINativePolicyTransition {
        try .init(
            action: action,
            beforePolicy: state.policy.snapshotCanonical,
            beforeGeneration: state.policy.stng
        )
    }

    /// A standard SIP-disabled profile already permits the AMFI boot-argument
    /// path. Preserve its exact native policy and publish an authenticated
    /// no-op receipt instead of asking bputil to reconstruct a nonzero SIP
    /// mask. The durable intent/receipt boundaries remain identical to a
    /// native transition so interruption is retryable without guessing.
    private func applyNoOpNativePolicy(
        store: PommeGuestAMFISnapshotStore,
        action: PommeGuestAMFINativePolicyAction,
        intentPhase: PommeGuestAMFITransactionPhase,
        receiptPhase: PommeGuestAMFITransactionPhase,
        before: PommeGuestAMFIState,
        expectedVolumeGroupUUID: UUID
    ) throws -> PommeGuestAMFIState {
        let currentRecord = try store.loadRecord()
        let baseline = try parseSnapshotPolicy(
            currentRecord.snapshot.localPolicy,
            expectedVolumeGroupUUID: expectedVolumeGroupUUID,
            strict: true
        )
        guard baseline.isSupportedStandardSIPDisabledProfile,
              before.policy.matchesRetainedBaseline(of: baseline) else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        let intent = try nativePolicyIntent(for: before, action: action)
        try store.update(
            phase: intentPhase,
            policyCheckpoint: nil,
            nativeTransition: intent,
            nvramCheckpoint: currentRecord.nvramCheckpoint
        )

        let observed: PommeGuestAMFIState
        do {
            observed = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        } catch {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        guard observed.policy.isSupportedStandardSIPDisabledProfile,
              observed.policy.snapshotCanonical == baseline.snapshotCanonical,
              observed.policy.snapshotCanonical == before.policy.snapshotCanonical,
              observed.policy.stng == before.policy.stng else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        let transition = try PommeGuestAMFINativePolicyTransition(
            action: action,
            beforePolicy: before.policy.snapshotCanonical,
            beforeGeneration: before.policy.stng,
            afterPolicy: observed.policy.snapshotCanonical,
            afterGeneration: observed.policy.stng,
            receipt: true
        )
        let checkpoint = try PommeGuestAMFIPolicyCheckpoint(
            action: action,
            observedPolicy: observed.policy.snapshotCanonical,
            generation: observed.policy.stng
        )
        let record = try store.loadRecord()
        try store.update(
            phase: receiptPhase,
            policyCheckpoint: checkpoint,
            nativeTransition: transition,
            nvramCheckpoint: record.nvramCheckpoint
        )
        return observed
    }

    private func applyNativePolicy(
        store: PommeGuestAMFISnapshotStore,
        action: PommeGuestAMFINativePolicyAction,
        intentPhase: PommeGuestAMFITransactionPhase,
        receiptPhase: PommeGuestAMFITransactionPhase,
        before: PommeGuestAMFIState,
        expectedVolumeGroupUUID: UUID,
        arguments: [String],
        credentials: PommeGuestSecurityCredentials,
        expected: (PommeGuestAMFIPolicy) -> Bool
    ) throws -> PommeGuestAMFIState {
        if before.policy.isSupportedStandardSIPDisabledProfile {
            return try applyNoOpNativePolicy(
                store: store,
                action: action,
                intentPhase: intentPhase,
                receiptPhase: receiptPhase,
                before: before,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
        }
        let currentRecord = try store.loadRecord()
        let intent = try nativePolicyIntent(for: before, action: action)
        try store.update(
            phase: intentPhase,
            policyCheckpoint: nil,
            nativeTransition: intent,
            nvramCheckpoint: currentRecord.nvramCheckpoint
        )

        let result: PommeGuestProcessCapture
        do {
            result = try secretProcess("/usr/bin/bputil", arguments, credentials)
        } catch let error as PommeGuestRecoverySecurityError {
            throw classifyUnreceiptedPolicyFailure(
                error,
                before: before,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
        } catch {
            throw classifyUnreceiptedPolicyFailure(
                .commandFailed,
                before: before,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
        }
        guard result.status == 0 else {
            throw classifyUnreceiptedPolicyFailure(
                .commandFailed,
                before: before,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
        }

        let observed: PommeGuestAMFIState
        do {
            observed = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        } catch {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        guard observed.policy.followsNativeTransition(from: before.policy),
              expected(observed.policy) else {
            // A changed policy without a durable receipt is ambiguous. Never
            // issue a compensating native write from this state.
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        let transition = try PommeGuestAMFINativePolicyTransition(
            action: action,
            beforePolicy: before.policy.snapshotCanonical,
            beforeGeneration: before.policy.stng,
            afterPolicy: observed.policy.snapshotCanonical,
            afterGeneration: observed.policy.stng,
            receipt: true
        )
        let checkpoint = try PommeGuestAMFIPolicyCheckpoint(
            action: action,
            observedPolicy: observed.policy.snapshotCanonical,
            generation: observed.policy.stng
        )
        let record = try store.loadRecord()
        try store.update(
            phase: receiptPhase,
            policyCheckpoint: checkpoint,
            nativeTransition: transition,
            nvramCheckpoint: record.nvramCheckpoint
        )
        return observed
    }

    private func classifyUnreceiptedPolicyFailure(
        _ error: PommeGuestRecoverySecurityError,
        before: PommeGuestAMFIState,
        expectedVolumeGroupUUID: UUID
    ) -> PommeGuestRecoverySecurityError {
        guard let observed = try? captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID) else {
            return .snapshotPending
        }
        guard observed.policy == before.policy else {
            return .snapshotPending
        }
        return error
    }

    private func applyNVRAMCheckpoint(
        store: PommeGuestAMFISnapshotStore,
        action: PommeGuestAMFINVRAMAction,
        intentPhase: PommeGuestAMFITransactionPhase,
        receiptPhase: PommeGuestAMFITransactionPhase,
        before: PommeGuestAMFIState,
        target: PommeNVRAMDelta,
        expectedVolumeGroupUUID: UUID
    ) throws -> PommeGuestAMFIState {
        let currentRecord = try store.loadRecord()
        let intent = try PommeGuestAMFINVRAMCheckpoint(
            action: action,
            before: before.snapshot.nvram,
            target: target,
            receipt: false
        )
        try store.update(
            phase: intentPhase,
            policyCheckpoint: currentRecord.policyCheckpoint,
            nativeTransition: currentRecord.nativeTransition,
            nvramCheckpoint: intent
        )

        if before.snapshot.nvram != target {
            do {
                try applyNVRAM(
                    target,
                    action: action,
                    transactionPhase: intentPhase
                )
            } catch let failure as PommeGuestAMFINVRAMApplyFailure {
                try persistNVRAMFailure(
                    store: store,
                    diagnostic: failure.diagnostic
                )
                guard let observed = try? captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID) else {
                    throw PommeGuestRecoverySecurityError.snapshotPending
                }
                if observed.snapshot.nvram == target {
                    return try acknowledgeNVRAMReceipt(
                        store: store,
                        current: observed,
                        action: action,
                        before: before.snapshot.nvram,
                        target: target,
                        phase: receiptPhase
                    )
                }
                if observed.snapshot.nvram == before.snapshot.nvram {
                    throw failure.recoveryError
                }
                throw PommeGuestRecoverySecurityError.snapshotPending
            } catch let error as PommeGuestRecoverySecurityError {
                guard let observed = try? captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID) else {
                    throw PommeGuestRecoverySecurityError.snapshotPending
                }
                if observed.snapshot.nvram == target {
                    return try acknowledgeNVRAMReceipt(
                        store: store,
                        current: observed,
                        action: action,
                        before: before.snapshot.nvram,
                        target: target,
                        phase: receiptPhase
                    )
                }
                if observed.snapshot.nvram == before.snapshot.nvram {
                    throw error
                }
                throw PommeGuestRecoverySecurityError.snapshotPending
            } catch {
                guard let observed = try? captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID) else {
                    throw PommeGuestRecoverySecurityError.snapshotPending
                }
                if observed.snapshot.nvram == target {
                    return try acknowledgeNVRAMReceipt(
                        store: store,
                        current: observed,
                        action: action,
                        before: before.snapshot.nvram,
                        target: target,
                        phase: receiptPhase
                    )
                }
                if observed.snapshot.nvram == before.snapshot.nvram {
                    throw PommeGuestRecoverySecurityError.commandFailed
                }
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
        }

        let observed: PommeGuestAMFIState
        do {
            observed = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        } catch {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        guard observed.snapshot.nvram == target else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        let receipt = try PommeGuestAMFINVRAMCheckpoint(
            action: action,
            before: before.snapshot.nvram,
            target: target,
            receipt: true
        )
        let record = try store.loadRecord()
        try store.update(
            phase: receiptPhase,
            policyCheckpoint: record.policyCheckpoint,
            nativeTransition: record.nativeTransition,
            nvramCheckpoint: receipt
        )
        return observed
    }

    private func persistNVRAMFailure(
        store: PommeGuestAMFISnapshotStore,
        diagnostic: PommeGuestAMFINVRAMFailureDiagnostic
    ) throws {
        let record = try store.loadRecord()
        // Preserve the first failure that explains the retained transaction.
        // A compensating rollback attempt must not erase the original native
        // write evidence with a second generic failure.
        try store.update(
            phase: record.phase,
            policyCheckpoint: record.policyCheckpoint,
            nativeTransition: record.nativeTransition,
            nvramCheckpoint: record.nvramCheckpoint,
            nvramFailure: record.nvramFailure ?? diagnostic
        )
    }

    private func acknowledgeNVRAMReceipt(
        store: PommeGuestAMFISnapshotStore,
        current: PommeGuestAMFIState,
        action: PommeGuestAMFINVRAMAction,
        before: PommeNVRAMDelta,
        target: PommeNVRAMDelta,
        phase: PommeGuestAMFITransactionPhase
    ) throws -> PommeGuestAMFIState {
        guard current.snapshot.nvram == target else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        let record = try store.loadRecord()
        let checkpoint = try PommeGuestAMFINVRAMCheckpoint(
            action: record.nvramCheckpoint?.action ?? action,
            before: record.nvramCheckpoint?.before ?? before,
            target: target,
            receipt: true
        )
        try store.update(
            phase: phase,
            policyCheckpoint: record.policyCheckpoint,
            nativeTransition: record.nativeTransition,
            nvramCheckpoint: checkpoint
        )
        return current
    }

    // MARK: Split Recovery / normal AMFI transaction

    /// Recovery owns LocalPolicy only in the staged contract.  The normal
    /// agent later owns the exact boot-args write, so this path deliberately
    /// never calls `applyNVRAMCheckpoint` or `applyNVRAM`.
    private func amfiDisablePolicyOnly(
        expectedVolumeGroupUUID: UUID,
        credentials: PommeGuestSecurityCredentials
    ) throws -> JSONValue {
        try verifyMutationEnvironment(expectedVolumeGroupUUID)
        let current = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let store = try snapshotStore(for: expectedVolumeGroupUUID)
        var record = try store.loadRecordIfPresent()

        if let existing = record {
            guard existing.isSplitNormalNVRAM else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            if existing.phase == .enabledVerified {
                guard try enabledTombstoneMatches(existing, current: current) else {
                    throw PommeGuestRecoverySecurityError.snapshotPending
                }
                try store.replaceBaseline(current.snapshot, executionMode: .splitNormalNVRAM)
                record = try store.loadRecord()
            }
        } else {
            // Validate the exact raw boot-args representation before any
            // authenticated policy effect, even though this stage defers its
            // NVRAM write to normal boot.
            _ = try disabledBootArguments(from: current.snapshot)
            try store.save(
                current.snapshot,
                phase: .baselineCaptured,
                executionMode: .splitNormalNVRAM
            )
            record = try store.loadRecord()
        }

        guard let durableRecord = record,
              durableRecord.isSplitNormalNVRAM else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        let baselinePolicy = try parseSnapshotPolicy(
            durableRecord.snapshot.localPolicy,
            expectedVolumeGroupUUID: expectedVolumeGroupUUID,
            strict: true
        )
        let baseline = PommeGuestAMFIState(policy: baselinePolicy, snapshot: durableRecord.snapshot)
        _ = try disabledBootArguments(from: baseline.snapshot)

        var retryPolicyIntent = false
        if let transition = durableRecord.nativeTransition, !transition.receipt {
            let before = try parseSnapshotPolicy(
                transition.beforePolicy,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                strict: true
            )
            guard current.policy.matchesRetainedBaseline(of: before),
                  current.snapshot.nvram == baseline.snapshot.nvram else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            retryPolicyIntent = transition.action == .disable
                && before.matchesRetainedBaseline(of: baselinePolicy)
        }

        let ownedTarget: Bool
        if let action = durableRecord.policyCheckpoint?.action,
           action == .disable || action == .rollback {
            ownedTarget = try policyCheckpointMatches(
                record: durableRecord,
                current: current,
                expected: { $0.matchesDisabledTargetProjection(of: baselinePolicy) }
            )
        } else {
            ownedTarget = false
        }

        if ownedTarget {
            let disabledTarget = try disabledBootArguments(from: baseline.snapshot)
            let ownsNVRAMCheckpoint = durableRecord.nvramCheckpoint?.action == .disable
                && durableRecord.nvramCheckpoint?.before == baseline.snapshot.nvram
                && durableRecord.nvramCheckpoint?.target == disabledTarget
            let nvramReceipt = ownsNVRAMCheckpoint
                && durableRecord.nvramCheckpoint?.receipt == true
            let currentNVRAMIsOwned: Bool
            if let checkpoint = durableRecord.nvramCheckpoint {
                // A normal-agent write can be durable in the system before
                // its receipt publication.  Admit that exact owned target
                // so the normal stage can acknowledge it; reject every
                // unrelated checkpoint or value without guessing.
                currentNVRAMIsOwned = ownsNVRAMCheckpoint && (
                    checkpoint.receipt
                        ? current.snapshot.nvram == checkpoint.target
                        : (current.snapshot.nvram == checkpoint.before
                            || current.snapshot.nvram == checkpoint.target)
                )
            } else {
                currentNVRAMIsOwned = current.snapshot.nvram == baseline.snapshot.nvram
            }
            guard currentNVRAMIsOwned else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            let refreshed = try store.loadRecord()
            return stagedAMFIResponse(
                operation: Operation.amfiDisable.rawValue,
                state: current,
                baselinePresent: true,
                phase: refreshed.phase,
                stage: "policy",
                policyReceipt: true,
                nvramReceipt: nvramReceipt,
                normalBootProofPending: refreshed.phase != .disabledVerified,
                rebootRequired: true
            )
        }

        guard current.policy.matchesRetainedBaseline(of: baselinePolicy),
              current.snapshot.nvram == baseline.snapshot.nvram,
              durableRecord.policyCheckpoint == nil,
              durableRecord.nativeTransition == nil || retryPolicyIntent else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        let observed = try applyNativePolicy(
            store: store,
            action: .disable,
            intentPhase: .policyApplying,
            receiptPhase: .policyApplied,
            before: current,
            expectedVolumeGroupUUID: expectedVolumeGroupUUID,
            arguments: baselinePolicy.disableArguments,
            credentials: credentials,
            expected: {
                $0.matchesDisabledTargetAfterNativeTransition(
                    of: baselinePolicy,
                    from: current.policy
                )
            }
        )
        let refreshed = try store.loadRecord()
        return stagedAMFIResponse(
            operation: Operation.amfiDisable.rawValue,
            state: observed,
            baselinePresent: true,
            phase: refreshed.phase,
            stage: "policy",
            policyReceipt: true,
            nvramReceipt: false,
            normalBootProofPending: true,
            rebootRequired: true
        )
    }

    /// Recovery-side enable is admitted only after normal boot has durably
    /// restored the exact baseline NVRAM value.  This method never writes
    /// NVRAM and retains the baseline until normal verifyEnabled creates the
    /// completed tombstone.
    private func amfiEnablePolicyOnly(
        expectedVolumeGroupUUID: UUID,
        credentials: PommeGuestSecurityCredentials
    ) throws -> JSONValue {
        try verifyMutationEnvironment(expectedVolumeGroupUUID)
        let current = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let store = try snapshotStore(for: expectedVolumeGroupUUID)
        let record = try store.loadRecord()
        guard record.isSplitNormalNVRAM else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        if record.phase == .enabledVerified {
            guard try enabledTombstoneMatches(record, current: current) else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            return stagedAMFIResponse(
                operation: Operation.amfiEnable.rawValue,
                state: current,
                baselinePresent: false,
                phase: .enabledVerified,
                stage: "policy",
                policyReceipt: true,
                nvramReceipt: true,
                normalBootProofPending: false,
                rebootRequired: false
            )
        }

        let baselinePolicy = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: expectedVolumeGroupUUID,
            strict: true
        )
        let baseline = PommeGuestAMFIState(policy: baselinePolicy, snapshot: record.snapshot)
        let targetBoot = try disabledBootArguments(from: baseline.snapshot)
        guard let nvramCheckpoint = record.nvramCheckpoint,
              nvramCheckpoint.action == .restore,
              nvramCheckpoint.receipt,
              nvramCheckpoint.target == baseline.snapshot.nvram,
              nvramCheckpoint.before == targetBoot,
              current.snapshot.nvram == baseline.snapshot.nvram else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        var retryRestoreIntent = false
        if let transition = record.nativeTransition, !transition.receipt {
            let before = try parseSnapshotPolicy(
                transition.beforePolicy,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                strict: true
            )
            guard current.policy.matchesRetainedBaseline(of: before) else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            retryRestoreIntent = transition.action == .restore
                && before.matchesDisabledTargetProjection(of: baselinePolicy)
        }

        let policyRestored: Bool
        if record.policyCheckpoint?.action == .restore {
            policyRestored = try policyCheckpointMatches(
                record: record,
                current: current,
                expected: {
                    $0.restorableCanonical == baselinePolicy.restorableCanonical
                        && $0.nativeStableIdentityCanonical == baselinePolicy.nativeStableIdentityCanonical
                }
            )
        } else {
            policyRestored = false
        }

        if policyRestored {
            guard record.phase == .policyRestored || record.phase == .enabledConfigured else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            if record.phase == .policyRestored {
                try store.setPhase(.enabledConfigured)
            }
            let refreshed = try store.loadRecord()
            return stagedAMFIResponse(
                operation: Operation.amfiEnable.rawValue,
                state: current,
                baselinePresent: true,
                phase: refreshed.phase,
                stage: "policy",
                policyReceipt: true,
                nvramReceipt: true,
                normalBootProofPending: true,
                rebootRequired: true
            )
        }

        let ownedDisabledTarget: Bool
        if retryRestoreIntent {
            ownedDisabledTarget = true
        } else if let action = record.policyCheckpoint?.action,
                  action == .disable || action == .rollback {
            ownedDisabledTarget = try policyCheckpointMatches(
                record: record,
                current: current,
                expected: { $0.matchesDisabledTargetProjection(of: baselinePolicy) }
            )
        } else {
            ownedDisabledTarget = false
        }
        guard ownedDisabledTarget else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        let observed = try applyNativePolicy(
            store: store,
            action: .restore,
            intentPhase: .restoringPolicy,
            receiptPhase: .policyRestored,
            before: current,
            expectedVolumeGroupUUID: expectedVolumeGroupUUID,
            arguments: baselinePolicy.restoreArguments,
            credentials: credentials,
            expected: {
                $0.matchesRestoredConfiguration(
                    of: baselinePolicy,
                    from: current.policy
                )
            }
        )
        try store.setPhase(.enabledConfigured)
        let refreshed = try store.loadRecord()
        return stagedAMFIResponse(
            operation: Operation.amfiEnable.rawValue,
            state: observed,
            baselinePresent: true,
            phase: refreshed.phase,
            stage: "policy",
            policyReceipt: true,
            nvramReceipt: true,
            normalBootProofPending: true,
            rebootRequired: true
        )
    }

    private func normalAMFIDisable(
        store: PommeGuestAMFISnapshotStore,
        record: PommeGuestAMFISnapshotRecord,
        volumeGroupUUID: UUID
    ) throws -> JSONValue {
        let current = try captureAMFIState(expectedVolumeGroupUUID: volumeGroupUUID)
        let baseline = try splitBaselineState(record, volumeGroupUUID: volumeGroupUUID)
        let target = try disabledBootArguments(from: baseline.snapshot)
        guard try ownedDisabledPolicyReceiptMatches(record: record, current: current, baseline: baseline.policy) else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        if record.phase == .disabledVerified,
           record.nvramCheckpoint?.action == .disable,
           record.nvramCheckpoint?.receipt == true,
           current.snapshot.nvram == target {
            return stagedAMFIResponse(
                operation: NormalAMFIOperation.disable.rawValue,
                state: current,
                baselinePresent: true,
                phase: .disabledVerified,
                stage: "normalNVRAM",
                policyReceipt: true,
                nvramReceipt: true,
                normalBootProofPending: false,
                rebootRequired: false
            )
        }

        if let checkpoint = record.nvramCheckpoint {
            guard checkpoint.action == .disable,
                  checkpoint.before == baseline.snapshot.nvram,
                  checkpoint.target == target,
                  current.snapshot.nvram == checkpoint.before || current.snapshot.nvram == checkpoint.target else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            if checkpoint.receipt, current.snapshot.nvram == target {
                try store.setPhase(.disabledConfigured)
                let refreshed = try store.loadRecord()
                return stagedAMFIResponse(
                    operation: NormalAMFIOperation.disable.rawValue,
                    state: current,
                    baselinePresent: true,
                    phase: refreshed.phase,
                    stage: "normalNVRAM",
                    policyReceipt: true,
                    nvramReceipt: true,
                    normalBootProofPending: true,
                    rebootRequired: true
                )
            }
            if !checkpoint.receipt, current.snapshot.nvram == checkpoint.target {
                let acknowledged = try acknowledgeNVRAMReceipt(
                    store: store,
                    current: current,
                    action: .disable,
                    before: checkpoint.before,
                    target: checkpoint.target,
                    phase: .normalNVRAMApplied
                )
                try store.setPhase(.disabledConfigured)
                let refreshed = try store.loadRecord()
                return stagedAMFIResponse(
                    operation: NormalAMFIOperation.disable.rawValue,
                    state: acknowledged,
                    baselinePresent: true,
                    phase: refreshed.phase,
                    stage: "normalNVRAM",
                    policyReceipt: true,
                    nvramReceipt: true,
                    normalBootProofPending: true,
                    rebootRequired: true
                )
            }
        } else {
            guard current.snapshot.nvram == baseline.snapshot.nvram else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
        }

        let before = current
        let observed = try applyNVRAMCheckpoint(
            store: store,
            action: .disable,
            intentPhase: .normalNVRAMApplying,
            receiptPhase: .normalNVRAMApplied,
            before: before,
            target: target,
            expectedVolumeGroupUUID: volumeGroupUUID
        )
        try store.setPhase(.disabledConfigured)
        let refreshed = try store.loadRecord()
        return stagedAMFIResponse(
            operation: NormalAMFIOperation.disable.rawValue,
            state: observed,
            baselinePresent: true,
            phase: refreshed.phase,
            stage: "normalNVRAM",
            policyReceipt: true,
            nvramReceipt: true,
            normalBootProofPending: true,
            rebootRequired: true
        )
    }

    private func normalAMFIEnable(
        store: PommeGuestAMFISnapshotStore,
        record: PommeGuestAMFISnapshotRecord,
        volumeGroupUUID: UUID
    ) throws -> JSONValue {
        let current = try captureAMFIState(expectedVolumeGroupUUID: volumeGroupUUID)
        let baseline = try splitBaselineState(record, volumeGroupUUID: volumeGroupUUID)
        let target = baseline.snapshot.nvram
        let disabledTarget = try disabledBootArguments(from: baseline.snapshot)
        let restoredPolicyReceipt: Bool
        if record.policyCheckpoint?.action == .restore {
            restoredPolicyReceipt = try policyCheckpointMatches(
                record: record,
                current: current,
                expected: {
                    $0.restorableCanonical == baseline.policy.restorableCanonical
                        && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
                }
            )
        } else {
            restoredPolicyReceipt = false
        }
        if restoredPolicyReceipt,
           record.nvramCheckpoint?.action == .restore,
           record.nvramCheckpoint?.receipt == true,
           record.nvramCheckpoint?.before == disabledTarget,
           record.nvramCheckpoint?.target == target,
           current.snapshot.nvram == target {
            return stagedAMFIResponse(
                operation: NormalAMFIOperation.enable.rawValue,
                state: current,
                baselinePresent: record.phase != .enabledVerified,
                phase: record.phase,
                stage: "normalNVRAM",
                policyReceipt: true,
                nvramReceipt: true,
                normalBootProofPending: record.phase != .enabledVerified,
                rebootRequired: record.phase != .enabledVerified
            )
        }
        let ownedDisabled = try ownedDisabledPolicyReceiptMatches(
            record: record,
            current: current,
            baseline: baseline.policy
        )
        if !ownedDisabled {
            let tombstoneMatches = try enabledTombstoneMatches(record, current: current)
            if record.phase == .enabledVerified,
               current.snapshot.nvram == target,
               tombstoneMatches {
                return stagedAMFIResponse(
                    operation: NormalAMFIOperation.enable.rawValue,
                    state: current,
                    baselinePresent: false,
                    phase: .enabledVerified,
                    stage: "normalNVRAM",
                    policyReceipt: true,
                    nvramReceipt: true,
                    normalBootProofPending: false,
                    rebootRequired: false
                )
            }
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        if let checkpoint = record.nvramCheckpoint,
           checkpoint.action == .restore {
            guard checkpoint.before == disabledTarget,
                  checkpoint.target == target,
                  current.snapshot.nvram == checkpoint.before || current.snapshot.nvram == checkpoint.target else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            if checkpoint.receipt, current.snapshot.nvram == checkpoint.target {
                let refreshed = try store.loadRecord()
                return stagedAMFIResponse(
                    operation: NormalAMFIOperation.enable.rawValue,
                    state: current,
                    baselinePresent: true,
                    phase: refreshed.phase,
                    stage: "normalNVRAM",
                    policyReceipt: true,
                    nvramReceipt: true,
                    normalBootProofPending: true,
                    rebootRequired: true
                )
            }
            if !checkpoint.receipt, current.snapshot.nvram == checkpoint.target {
                let acknowledged = try acknowledgeNVRAMReceipt(
                    store: store,
                    current: current,
                    action: .restore,
                    before: checkpoint.before,
                    target: checkpoint.target,
                    phase: .normalNVRAMApplied
                )
                let refreshed = try store.loadRecord()
                return stagedAMFIResponse(
                    operation: NormalAMFIOperation.enable.rawValue,
                    state: acknowledged,
                    baselinePresent: true,
                    phase: refreshed.phase,
                    stage: "normalNVRAM",
                    policyReceipt: true,
                    nvramReceipt: true,
                    normalBootProofPending: true,
                    rebootRequired: true
                )
            }
            guard current.snapshot.nvram == checkpoint.before else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
        } else {
            guard let disableCheckpoint = record.nvramCheckpoint,
                  disableCheckpoint.action == .disable,
                  disableCheckpoint.receipt,
                  disableCheckpoint.target == disabledTarget,
                  current.snapshot.nvram == disableCheckpoint.target else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
        }

        let observed = try applyNVRAMCheckpoint(
            store: store,
            action: .restore,
            intentPhase: .normalNVRAMApplying,
            receiptPhase: .normalNVRAMApplied,
            before: current,
            target: target,
            expectedVolumeGroupUUID: volumeGroupUUID
        )
        let refreshed = try store.loadRecord()
        return stagedAMFIResponse(
            operation: NormalAMFIOperation.enable.rawValue,
            state: observed,
            baselinePresent: true,
            phase: refreshed.phase,
            stage: "normalNVRAM",
            policyReceipt: true,
            nvramReceipt: true,
            normalBootProofPending: true,
            rebootRequired: true
        )
    }

    private func normalAMFIVerifyDisabled(
        store: PommeGuestAMFISnapshotStore,
        record: PommeGuestAMFISnapshotRecord,
        volumeGroupUUID: UUID
    ) throws -> JSONValue {
        let current = try captureAMFIState(expectedVolumeGroupUUID: volumeGroupUUID)
        let baseline = try splitBaselineState(record, volumeGroupUUID: volumeGroupUUID)
        let target = try disabledBootArguments(from: baseline.snapshot)
        let policyReceipt = try ownedDisabledPolicyReceiptMatches(
            record: record,
            current: current,
            baseline: baseline.policy
        )
        guard policyReceipt,
              record.nvramCheckpoint?.action == .disable,
              record.nvramCheckpoint?.receipt == true,
              record.nvramCheckpoint?.before == baseline.snapshot.nvram,
              record.nvramCheckpoint?.target == target,
              current.snapshot.nvram == target else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        try verifyNormalBootArguments(target)
        if record.phase != .disabledVerified {
            try store.setPhase(.disabledVerified)
        }
        return stagedAMFIResponse(
            operation: NormalAMFIOperation.verifyDisabled.rawValue,
            state: current,
            baselinePresent: true,
            phase: .disabledVerified,
            stage: "normalVerify",
            policyReceipt: true,
            nvramReceipt: true,
            normalBootProofPending: false,
            rebootRequired: false
        )
    }

    private func normalAMFIVerifyEnabled(
        store: PommeGuestAMFISnapshotStore,
        record: PommeGuestAMFISnapshotRecord,
        volumeGroupUUID: UUID
    ) throws -> JSONValue {
        let current = try captureAMFIState(expectedVolumeGroupUUID: volumeGroupUUID)
        let baseline = try splitBaselineState(record, volumeGroupUUID: volumeGroupUUID)
        let disabledTarget = try disabledBootArguments(from: baseline.snapshot)
        let restoredPolicy = try policyCheckpointMatches(
            record: record,
            current: current,
            expected: {
                $0.restorableCanonical == baseline.policy.restorableCanonical
                    && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
            }
        )
        guard record.nvramCheckpoint?.action == .restore,
              record.nvramCheckpoint?.receipt == true,
              record.nvramCheckpoint?.before == disabledTarget,
              record.nvramCheckpoint?.target == baseline.snapshot.nvram,
              current.snapshot.nvram == baseline.snapshot.nvram,
              record.policyCheckpoint?.action == .restore,
              restoredPolicy else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        try verifyNormalBootArguments(baseline.snapshot.nvram)
        if record.phase != .enabledVerified {
            try store.setPhase(.enabledVerified)
        }
        return stagedAMFIResponse(
            operation: NormalAMFIOperation.verifyEnabled.rawValue,
            state: current,
            baselinePresent: false,
            phase: .enabledVerified,
            stage: "normalVerify",
            policyReceipt: true,
            nvramReceipt: true,
            normalBootProofPending: false,
            rebootRequired: false
        )
    }

    /// Verify the boot arguments actually consumed by the current normal
    /// kernel. `sysctl` appends one line-feed delimiter; remove only that
    /// delimiter so every other byte remains part of the comparison.
    private func verifyNormalBootArguments(_ expected: PommeNVRAMDelta) throws {
        guard let value = expected.value(for: "boot-args") else {
            throw PommeGuestRecoverySecurityError.invalidNVRAM
        }
        let result: PommeGuestProcessCapture
        do {
            result = try process("/usr/sbin/sysctl", ["-n", "kern.bootargs"])
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard result.status == 0 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        var observed = result.stdout
        if observed.last == 0x0a {
            observed.removeLast()
        }
        let expectedBytes = value.present ? value.bytes : Data()
        guard observed == expectedBytes else {
            throw PommeGuestRecoverySecurityError.verificationFailed
        }
    }

    private func splitBaselineState(
        _ record: PommeGuestAMFISnapshotRecord,
        volumeGroupUUID: UUID
    ) throws -> PommeGuestAMFIState {
        guard record.volumeGroupUUID == volumeGroupUUID,
              record.isSplitNormalNVRAM else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        let policy = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: volumeGroupUUID,
            strict: true
        )
        guard policy.volumeGroupUUID == volumeGroupUUID.uuidString.lowercased() else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        return PommeGuestAMFIState(policy: policy, snapshot: record.snapshot)
    }

    private func ownedDisabledPolicyReceiptMatches(
        record: PommeGuestAMFISnapshotRecord,
        current: PommeGuestAMFIState,
        baseline: PommeGuestAMFIPolicy
    ) throws -> Bool {
        guard let action = record.policyCheckpoint?.action,
              action == .disable || action == .rollback else {
            return false
        }
        return try policyCheckpointMatches(
            record: record,
            current: current,
            expected: { $0.matchesDisabledTargetProjection(of: baseline) }
        )
    }

    private func enabledTombstoneMatches(
        _ record: PommeGuestAMFISnapshotRecord,
        current: PommeGuestAMFIState
    ) throws -> Bool {
        guard record.phase == .enabledVerified,
              current.snapshot.nvram == record.snapshot.nvram,
              let nvramCheckpoint = record.nvramCheckpoint,
              nvramCheckpoint.action == .restore,
              nvramCheckpoint.receipt,
              nvramCheckpoint.target == record.snapshot.nvram,
              record.policyCheckpoint?.action == .restore else {
            return false
        }
        let baseline = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: record.volumeGroupUUID,
            strict: true
        )
        let disabledTarget = try disabledBootArguments(from: record.snapshot)
        guard nvramCheckpoint.before == disabledTarget else {
            return false
        }
        return try policyCheckpointMatches(
            record: record,
            current: current,
            expected: {
                $0.restorableCanonical == baseline.restorableCanonical
                    && $0.nativeStableIdentityCanonical == baseline.nativeStableIdentityCanonical
            }
        )
    }

    private func stagedAMFIResponse(
        operation: String,
        state: PommeGuestAMFIState,
        baselinePresent: Bool,
        phase: PommeGuestAMFITransactionPhase,
        stage: String,
        policyReceipt: Bool,
        nvramReceipt: Bool,
        normalBootProofPending: Bool,
        rebootRequired: Bool
    ) -> JSONValue {
        var object = amfiResponse(
            operation: operation,
            state: state,
            baselinePresent: baselinePresent
        ).objectValue ?? [:]
        object["stage"] = .string(stage)
        object["phase"] = .string(phase.rawValue)
        object["policyReceipt"] = .bool(policyReceipt)
        object["nvramReceipt"] = .bool(nvramReceipt)
        object["normalBootProofPending"] = .bool(normalBootProofPending)
        object["rebootRequired"] = .bool(rebootRequired)
        return .object(object)
    }

    private func amfiDisable(
        expectedVolumeGroupUUID: UUID,
        credentials: PommeGuestSecurityCredentials
    ) throws -> JSONValue {
        try verifyMutationEnvironment(expectedVolumeGroupUUID)
        let current = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let snapshotStore = try snapshotStore(for: expectedVolumeGroupUUID)
        let record = try snapshotStore.loadRecordIfPresent()
        let baseline: PommeGuestAMFIState
        if let record {
            guard record.volumeGroupUUID == expectedVolumeGroupUUID else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            guard !record.isSplitNormalNVRAM else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            let policy = try parseSnapshotPolicy(
                record.snapshot.localPolicy,
                expectedVolumeGroupUUID: record.volumeGroupUUID,
                strict: true
            )
            guard policy.volumeGroupUUID == expectedVolumeGroupUUID.uuidString.lowercased() else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            baseline = .init(policy: policy, snapshot: record.snapshot)
        } else {
            baseline = current
        }

        // Validate the exact baseline before publishing it or allowing any
        // authenticated policy write. The NVRAM writer accepts only the
        // UTF-8 string form that the strict XML reader captures.
        let targetBoot = try disabledBootArguments(from: baseline.snapshot)
        if record == nil {
            // The baseline is the first durable effect. No authenticated
            // policy or NVRAM write may occur before this succeeds.
            try snapshotStore.save(current.snapshot, phase: .baselineCaptured)
        }
        let durableRecord = try snapshotStore.loadRecord()
        if let transition = durableRecord.nativeTransition, !transition.receipt {
            let before = try parseSnapshotPolicy(
                transition.beforePolicy,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                strict: true
            )
            // An intent with a changed policy but no post-write receipt is an
            // unclassifiable crash window. Do not adopt it or issue rollback.
            guard current.policy.matchesRetainedBaseline(of: before) else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
        }
        let checkpointTarget: Bool
        if durableRecord.policyCheckpoint?.action == .disable {
            checkpointTarget = try policyCheckpointMatches(
                record: durableRecord,
                current: current,
                expected: { $0.matchesDisabledTargetProjection(of: baseline.policy) }
            )
        } else {
            checkpointTarget = false
        }
        let checkpointBaseline: Bool
        if durableRecord.policyCheckpoint?.action == .rollback {
            checkpointBaseline = try policyCheckpointMatches(
                record: durableRecord,
                current: current,
                expected: {
                    $0.restorableCanonical == baseline.policy.restorableCanonical
                        && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
                }
            )
        } else {
            checkpointBaseline = false
        }
        let currentPolicyIsBaseline =
            current.policy.matchesRetainedBaseline(of: baseline.policy) || checkpointBaseline
        let currentPolicyIsTarget: Bool
        if checkpointTarget {
            currentPolicyIsTarget = true
        } else if current.policy.matchesDisabledTarget(of: baseline.policy) {
            // A v1 record can be resumed only when the old policy is still
            // byte-for-byte equivalent in every compared field. A v2 record
            // without a receipt cannot safely adopt a target after a crash.
            guard durableRecord.isLegacy
                || baseline.policy.isSupportedStandardSIPDisabledProfile else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            currentPolicyIsTarget = true
        } else {
            currentPolicyIsTarget = false
        }
        let currentBootIsBaseline = current.snapshot.nvram == baseline.snapshot.nvram
        let currentBootIsTarget = current.snapshot.nvram == targetBoot

        // A pending same-direction request may resume a crash after either
        // resource write. Any unrelated drift is a conflict and is rejected
        // without inventing a policy or overwriting foreign NVRAM bytes.
        guard (currentPolicyIsBaseline || currentPolicyIsTarget),
              (currentBootIsBaseline || currentBootIsTarget) else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        var noOpPolicyReceipt = false
        if currentPolicyIsTarget,
           currentBootIsTarget,
           !checkpointTarget,
           baseline.policy.isSupportedStandardSIPDisabledProfile {
            _ = try applyNoOpNativePolicy(
                store: snapshotStore,
                action: .disable,
                intentPhase: .policyApplying,
                receiptPhase: .policyApplied,
                before: current,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
            noOpPolicyReceipt = true
        }
        if currentPolicyIsTarget && currentBootIsTarget {
            guard durableRecord.isLegacy || checkpointTarget || noOpPolicyReceipt else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            if !durableRecord.isLegacy {
                _ = try acknowledgeNVRAMReceipt(
                    store: snapshotStore,
                    current: current,
                    action: .disable,
                    before: durableRecord.nvramCheckpoint?.before ?? baseline.snapshot.nvram,
                    target: targetBoot,
                    phase: .disabledVerified
                )
            }
            return amfiResponse(
                operation: Operation.amfiDisable,
                state: current,
                baselinePresent: true
            )
        }

        do {
            var observed = current
            var policyReceipt = checkpointTarget
            if currentPolicyIsTarget,
               !policyReceipt,
               baseline.policy.isSupportedStandardSIPDisabledProfile {
                observed = try applyNoOpNativePolicy(
                    store: snapshotStore,
                    action: .disable,
                    intentPhase: .policyApplying,
                    receiptPhase: .policyApplied,
                    before: observed,
                    expectedVolumeGroupUUID: expectedVolumeGroupUUID
                )
                policyReceipt = true
            }
            if !currentPolicyIsTarget {
                let beforePolicy = observed.policy
                observed = try applyNativePolicy(
                    store: snapshotStore,
                    action: .disable,
                    intentPhase: .policyApplying,
                    receiptPhase: .policyApplied,
                    before: observed,
                    expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                    arguments: baseline.policy.disableArguments,
                    credentials: credentials,
                    expected: {
                        $0.matchesDisabledTargetAfterNativeTransition(
                            of: baseline.policy,
                            from: beforePolicy
                        )
                    }
                )
                policyReceipt = true
            }

            let currentRecord = try snapshotStore.loadRecord()
            if observed.snapshot.nvram != targetBoot
                || currentRecord.nvramCheckpoint?.receipt != true {
                observed = try applyNVRAMCheckpoint(
                    store: snapshotStore,
                    action: .disable,
                    intentPhase: .nvramApplying,
                    receiptPhase: .nvramApplied,
                    before: observed,
                    target: targetBoot,
                    expectedVolumeGroupUUID: expectedVolumeGroupUUID
                )
            } else if !policyReceipt {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }

            let recordAfterResources = try snapshotStore.loadRecord()
            guard policyReceipt,
                  try policyCheckpointMatches(
                      record: recordAfterResources,
                      current: observed,
                      expected: { $0.matchesDisabledTargetProjection(of: baseline.policy) }
                  ),
                  observed.snapshot.nvram == targetBoot,
                  recordAfterResources.nvramCheckpoint?.receipt == true
            else { throw PommeGuestRecoverySecurityError.snapshotPending }

            try snapshotStore.setPhase(.verifying)
            observed = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
            let verifyingRecord = try snapshotStore.loadRecord()
            guard observed.snapshot.nvram == targetBoot,
                  try policyCheckpointMatches(
                      record: verifyingRecord,
                      current: observed,
                      expected: { $0.matchesDisabledTargetProjection(of: baseline.policy) }
                  ) else { throw PommeGuestRecoverySecurityError.snapshotPending }
            try snapshotStore.setPhase(.disabledVerified)
            return amfiResponse(
                operation: Operation.amfiDisable,
                state: observed,
                baselinePresent: true
            )
        } catch let error as PommeGuestRecoverySecurityError {
            if error != .snapshotPending {
                if let record = try snapshotStore.loadRecordIfPresent(),
                   record.policyCheckpoint?.action == .disable,
                   record.nativeTransition?.receipt == true {
                    guard let rollbackCurrent = try? captureAMFIState(
                        expectedVolumeGroupUUID: expectedVolumeGroupUUID
                    ) else {
                        try? snapshotStore.setPhase(.rollbackFailed)
                        throw PommeGuestRecoverySecurityError.rollbackFailed
                    }
                    guard try ownedPolicyReceiptMatches(record: record, current: rollbackCurrent),
                          try rollbackNVRAMStateIsKnown(
                              record: record,
                              preFailure: current,
                              current: rollbackCurrent
                          ) else {
                        try? snapshotStore.setPhase(.rollbackFailed)
                        throw PommeGuestRecoverySecurityError.rollbackFailed
                    }
                    try rollbackAfterFailure(
                        error: error,
                        snapshotStore: snapshotStore,
                        baseline: baseline,
                        current: rollbackCurrent,
                        credentials: credentials
                    )
                }
            }
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    private func amfiEnable(
        expectedVolumeGroupUUID: UUID,
        credentials: PommeGuestSecurityCredentials
    ) throws -> JSONValue {
        try verifyMutationEnvironment(expectedVolumeGroupUUID)
        let before = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let snapshotStore = try snapshotStore(for: expectedVolumeGroupUUID)
        let record = try snapshotStore.loadRecord()
        guard record.volumeGroupUUID == expectedVolumeGroupUUID else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        guard !record.isSplitNormalNVRAM else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        let policy = try parseSnapshotPolicy(
            record.snapshot.localPolicy,
            expectedVolumeGroupUUID: expectedVolumeGroupUUID,
            strict: true
        )
        let baseline = PommeGuestAMFIState(policy: policy, snapshot: record.snapshot)
        guard policy.volumeGroupUUID == expectedVolumeGroupUUID.uuidString.lowercased(),
              before.policy.vuid == policy.vuid else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        let targetBoot = try disabledBootArguments(from: baseline.snapshot)
        let currentRecord = try snapshotStore.loadRecord()
        let pendingRestoreIntent = currentRecord.nativeTransition?.action == .restore
            && currentRecord.nativeTransition?.receipt == false
        if let transition = currentRecord.nativeTransition, !transition.receipt {
            let transitionBefore = try parseSnapshotPolicy(
                transition.beforePolicy,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                strict: true
            )
            guard before.policy.matchesRetainedBaseline(of: transitionBefore) else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
        }
        let checkpointTarget: Bool
        if currentRecord.policyCheckpoint?.action == .disable
            || currentRecord.policyCheckpoint?.action == .rollback {
            checkpointTarget = try policyCheckpointMatches(
                record: currentRecord,
                current: before,
                expected: { $0.matchesDisabledTargetProjection(of: baseline.policy) }
            )
        } else {
            checkpointTarget = false
        }
        let policyIsOwnedTarget = checkpointTarget
            || (currentRecord.isLegacy && before.policy.matchesDisabledTarget(of: baseline.policy))
        let pendingRestoreBefore: Bool
        if let transition = currentRecord.nativeTransition,
           transition.action == .restore,
           !transition.receipt {
            let transitionBefore = try parseSnapshotPolicy(
                transition.beforePolicy,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                strict: true
            )
            pendingRestoreBefore = before.policy.matchesRetainedBaseline(of: transitionBefore)
                && before.policy.matchesDisabledTargetProjection(of: baseline.policy)
        } else {
            pendingRestoreBefore = false
        }
        let policyIsOwnedRestored: Bool
        if currentRecord.policyCheckpoint?.action == .restore
            || currentRecord.policyCheckpoint?.action == .rollback {
            policyIsOwnedRestored = try policyCheckpointMatches(
                record: currentRecord,
                current: before,
                expected: {
                    $0.restorableCanonical == baseline.policy.restorableCanonical
                        && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
                }
            )
        } else {
            policyIsOwnedRestored = false
        }
        let policyIsBaseline = before.policy.matchesRetainedBaseline(of: baseline.policy)
        guard policyIsBaseline || policyIsOwnedTarget || pendingRestoreBefore || policyIsOwnedRestored,
              before.snapshot.nvram == baseline.snapshot.nvram
                || before.snapshot.nvram == targetBoot
        else { throw PommeGuestRecoverySecurityError.snapshotPending }

        do {
            var after = before
            var policyReceipt = !policyIsOwnedTarget
            if after.policy.matchesRetainedBaseline(of: baseline.policy),
               !policyIsOwnedRestored,
               baseline.policy.isSupportedStandardSIPDisabledProfile,
               pendingRestoreIntent || !policyReceipt {
                after = try applyNoOpNativePolicy(
                    store: snapshotStore,
                    action: .restore,
                    intentPhase: .restoringPolicy,
                    receiptPhase: .policyRestored,
                    before: after,
                    expectedVolumeGroupUUID: expectedVolumeGroupUUID
                )
                policyReceipt = true
            }
            if !after.policy.matchesRetainedBaseline(of: baseline.policy)
                && !policyIsOwnedRestored {
                let beforePolicy = after.policy
                after = try applyNativePolicy(
                    store: snapshotStore,
                    action: .restore,
                    intentPhase: .restoringPolicy,
                    receiptPhase: .policyRestored,
                    before: after,
                    expectedVolumeGroupUUID: expectedVolumeGroupUUID,
                    arguments: policy.restoreArguments,
                    credentials: credentials,
                    expected: {
                        $0.matchesRestoredConfiguration(
                            of: baseline.policy,
                            from: beforePolicy
                        )
                    }
                )
                policyReceipt = true
            }
            let recordAfterPolicy = try snapshotStore.loadRecord()
            if pendingRestoreIntent {
                guard recordAfterPolicy.nativeTransition?.action == .restore,
                      recordAfterPolicy.nativeTransition?.receipt == true,
                      recordAfterPolicy.policyCheckpoint?.action == .restore else {
                    throw PommeGuestRecoverySecurityError.snapshotPending
                }
            }
            if after.snapshot.nvram != baseline.snapshot.nvram
                || recordAfterPolicy.nvramCheckpoint?.receipt != true {
                after = try applyNVRAMCheckpoint(
                    store: snapshotStore,
                    action: .restore,
                    intentPhase: .restoringNVRAM,
                    receiptPhase: .nvramRestored,
                    before: after,
                    target: baseline.snapshot.nvram,
                    expectedVolumeGroupUUID: expectedVolumeGroupUUID
                )
            }
            guard policyReceipt else { throw PommeGuestRecoverySecurityError.snapshotPending }
            try snapshotStore.setPhase(.verifying)
            after = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
            let verifyingRecord = try snapshotStore.loadRecord()
            let restoredCheckpointMatches: Bool
            if after.policy.matchesRetainedBaseline(of: baseline.policy) {
                if pendingRestoreIntent {
                    restoredCheckpointMatches = try policyCheckpointMatches(
                        record: verifyingRecord,
                        current: after,
                        expected: {
                            $0.restorableCanonical == baseline.policy.restorableCanonical
                                && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
                        }
                    )
                } else {
                    restoredCheckpointMatches = true
                }
            } else {
                restoredCheckpointMatches = try policyCheckpointMatches(
                    record: verifyingRecord,
                    current: after,
                    expected: {
                        $0.restorableCanonical == baseline.policy.restorableCanonical
                            && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
                    }
                )
            }
            guard after.snapshot.nvram == baseline.snapshot.nvram,
                  restoredCheckpointMatches else {
                throw PommeGuestRecoverySecurityError.snapshotPending
            }
            try snapshotStore.clear()
            return amfiResponse(
                operation: Operation.amfiEnable,
                state: after,
                baselinePresent: false
            )
        } catch let error as PommeGuestRecoverySecurityError {
            if error != .snapshotPending {
                if let record = try snapshotStore.loadRecordIfPresent(),
                   record.policyCheckpoint?.action == .restore,
                   record.nativeTransition?.receipt == true {
                    guard let rollbackCurrent = try? captureAMFIState(
                        expectedVolumeGroupUUID: expectedVolumeGroupUUID
                    ) else {
                        try? snapshotStore.setPhase(.rollbackFailed)
                        throw PommeGuestRecoverySecurityError.rollbackFailed
                    }
                    guard try ownedPolicyReceiptMatches(record: record, current: rollbackCurrent),
                          try rollbackNVRAMStateIsKnown(
                              record: record,
                              preFailure: before,
                              current: rollbackCurrent
                          ) else {
                        try? snapshotStore.setPhase(.rollbackFailed)
                        throw PommeGuestRecoverySecurityError.rollbackFailed
                    }
                    try rollbackAfterFailure(
                        error: error,
                        snapshotStore: snapshotStore,
                        baseline: before,
                        current: rollbackCurrent,
                        credentials: credentials
                    )
                }
            }
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    private func verifyMutationEnvironment(_ expectedVolumeGroupUUID: UUID) throws {
        if let legacyNVRAMMutationVerified {
            guard legacyNVRAMMutationVerified() else {
                throw PommeGuestRecoverySecurityError.nvramMutationUnqualified
            }
            return
        }
        do {
            try recoveryEnvironmentVerifier(expectedVolumeGroupUUID)
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
    }

    private static func verifyRecoveryEnvironment(
        expectedVolumeGroupUUID: UUID,
        process: @escaping ProcessRunner
    ) throws {
        // Read SIP state as a consistency check, but do not treat `csrutil`
        // as the Recovery proof: both status forms can succeed in a normal
        // macOS boot.
        let sip: PommeGuestProcessCapture
        do {
            sip = try process("/usr/bin/csrutil", ["status"])
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard sip.status == 0 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        let sipText = String(decoding: sip.stdout, as: UTF8.self)
        let statuses = ["enabled", "disabled"].filter { state in
            sipText.range(
                of: #"(?i)\bstatus\s*:\s*\#(state)\b"#,
                options: .regularExpression
            ) != nil
        }
        guard statuses.count == 1 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }

        // `csrutil authenticated-root status` is also available from a normal
        // macOS boot. Treat it as a consistency check only; the read-only
        // BaseSystem/CDIS/SystemVersion checks below establish Recovery.
        let authenticatedRoot: PommeGuestProcessCapture
        do {
            authenticatedRoot = try process(
                "/usr/bin/csrutil",
                ["authenticated-root", "status"]
            )
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard authenticatedRoot.status == 0,
              String(decoding: authenticatedRoot.stdout, as: UTF8.self).range(
                of: #"(?i)authenticated\s+root\s+status\s*:\s*(?:enabled|disabled)\b"#,
                options: .regularExpression
              ) != nil else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }

        let rootInfo: PommeGuestProcessCapture
        do {
            rootInfo = try process(
                "/usr/sbin/diskutil",
                ["info", "-plist", "/"]
            )
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard rootInfo.status == 0 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }

        let groups: PommeGuestProcessCapture
        do {
            groups = try process(
                "/usr/sbin/diskutil",
                ["apfs", "listVolumeGroups", "-plist"]
            )
        } catch {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
        guard groups.status == 0 else {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
        do {
            let selected = try PommeRecoveryDataVolumeResolver.resolveDataVolume(
                from: groups.stdout,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
            guard selected.volumeGroupUUID == expectedVolumeGroupUUID else {
                throw PommeGuestRecoverySecurityError.startupVolumeMismatch
            }
            try Self.verifyRecoveryRoot(
                rootInfo: rootInfo.stdout,
                selected: selected,
                process: process
            )
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
    }

    /// `csrutil` is available in a normal boot too. The booted root therefore
    /// supplies the independent Recovery proof: Recovery runs from Apple's
    /// read-only BaseSystem disk image, includes the CDIS utilities tree, and
    /// exposes a Recovery OS SystemVersion plist. The root device must also be
    /// distinct from the request-bound installed System+Data pair.
    private static func verifyRecoveryRoot(
        rootInfo data: Data,
        selected: PommeRecoveryDataVolumeResolver.Volume,
        process: @escaping ProcessRunner
    ) throws {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              root["MountPoint"] as? String == "/",
              let device = root["DeviceIdentifier"] as? String,
              safeDeviceIdentifier(device),
              device != selected.systemDevice,
              device != selected.dataDevice,
              (root["WritableVolume"] as? Bool) == false,
              (root["Writable"] as? Bool) == false,
              let filesystem = root["FilesystemType"] as? String,
              ["hfs", "apfs"].contains(filesystem.lowercased()),
              let volumeName = root["VolumeName"] as? String,
              isBaseSystemVolumeName(volumeName)
        else { throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified }

        // A BaseSystem volume is normally a read-only disk image. Keep the
        // check tolerant of older diskutil dictionaries that omit DiskImage,
        // while still requiring HFS/APFS BaseSystem identity and read-only
        // media above.
        if let diskImage = root["DiskImage"] as? Bool, !diskImage,
           filesystemIsHFS(root["FilesystemType"]) == false {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }

        let cdis = try process("/bin/test", ["-d", "/System/Installation/CDIS"])
        guard cdis.status == 0 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }

        let systemVersion = try process(
            "/usr/bin/plutil",
            ["-convert", "xml1", "-o", "-", "/System/Library/CoreServices/SystemVersion.plist"]
        )
        guard systemVersion.status == 0,
              let version = try? PropertyListSerialization.propertyList(
                from: systemVersion.stdout,
                options: [],
                format: nil
              ) as? [String: Any],
              (version["ProductName"] as? String)?.caseInsensitiveCompare("macOS") == .orderedSame,
              let productVersion = version["ProductVersion"] as? String,
              productVersion.range(of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let build = version["ProductBuildVersion"] as? String,
              build.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,63}$"#, options: .regularExpression) != nil
        else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
    }

    /// Normal-boot proof for the credential-free NVRAM stage.  A successful
    /// `csrutil status` is insufficient because the utility also runs in
    /// Recovery; the root disk must instead be the requested installed
    /// System volume (or its APFS snapshot) and must not be a BaseSystem or
    /// disk image.  SIP must already be disabled for this stage.  This guard
    /// intentionally does not infer or alter LocalPolicy sip0/custom bits.
    private static func verifyNormalEnvironment(
        expectedVolumeGroupUUID: UUID,
        process: @escaping ProcessRunner
    ) throws {
        let sip: PommeGuestProcessCapture
        do {
            sip = try process("/usr/bin/csrutil", ["status"])
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard sip.status == 0 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        let sipText = String(decoding: sip.stdout, as: UTF8.self)
        guard sipText.range(
            of: #"(?i)\bstatus\s*:\s*disabled\b"#,
            options: .regularExpression
        ) != nil,
        sipText.range(
            of: #"(?i)\bstatus\s*:\s*enabled\b"#,
            options: .regularExpression
        ) == nil else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }

        let groups: PommeGuestProcessCapture
        do {
            groups = try process(
                "/usr/sbin/diskutil",
                ["apfs", "listVolumeGroups", "-plist"]
            )
        } catch {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
        guard groups.status == 0 else {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
        let selected: PommeRecoveryDataVolumeResolver.Volume
        do {
            selected = try PommeRecoveryDataVolumeResolver.resolveDataVolume(
                from: groups.stdout,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
        } catch {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
        guard selected.volumeGroupUUID == expectedVolumeGroupUUID else {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }

        let rootInfo: PommeGuestProcessCapture
        do {
            rootInfo = try process("/usr/sbin/diskutil", ["info", "-plist", "/"])
        } catch {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard rootInfo.status == 0 else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
        guard let root = try? PropertyListSerialization.propertyList(
            from: rootInfo.stdout,
            options: [],
            format: nil
        ) as? [String: Any],
        root["MountPoint"] as? String == "/",
        let device = root["DeviceIdentifier"] as? String,
        safeDeviceIdentifier(device),
        device == selected.systemDevice || device.hasPrefix("\(selected.systemDevice)s"),
        (root["FilesystemType"] as? String)?.caseInsensitiveCompare("apfs") == .orderedSame,
        let group = (root["APFSVolumeGroupID"] as? String)
            ?? (root["APFSVolumeGroupUUID"] as? String),
        UUID(uuidString: group) == expectedVolumeGroupUUID,
        let volumeName = root["VolumeName"] as? String,
        !isBaseSystemVolumeName(volumeName),
        (root["DiskImage"] as? Bool) != true,
        (root["RecoveryVolume"] as? Bool) != true else {
            throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
        }
    }

    private static func isBaseSystemVolumeName(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return normalized == "macos base system" || normalized == "os x base system"
    }

    private static func filesystemIsHFS(_ value: Any?) -> Bool {
        (value as? String)?.caseInsensitiveCompare("hfs") == .orderedSame
    }

    private static func safeDeviceIdentifier(_ value: String) -> Bool {
        value.range(of: #"^disk[0-9]+s[0-9]+(?:s[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private func disabledBootArguments(
        from snapshot: PommeAMFISecuritySnapshot
    ) throws -> PommeNVRAMDelta {
        let current = snapshot.nvram.value(for: "boot-args") ?? .absent
        // Do this before the first bputil write. A binary or otherwise
        // unrepresentable value cannot be restored through the string form
        // accepted by the Recovery nvram command, so it must fail closed
        // while the baseline is still untouched.
        _ = try restorableBootArgumentText(current)
        return try PommeNVRAMDelta.bootArguments(
            present: true,
            bytes: PommeBootArguments.addingOverride(to: current.bytes)
        )
    }

    private func restorableBootArgumentText(_ value: PommeNVRAMValue) throws -> String? {
        guard value.present else {
            guard value.bytes.isEmpty else { throw PommeGuestRecoverySecurityError.invalidNVRAM }
            return nil
        }
        guard let text = String(data: value.bytes, encoding: .utf8),
              !text.contains("\0") else {
            throw PommeGuestRecoverySecurityError.invalidNVRAM
        }
        return text
    }

    private func rollbackAfterFailure(
        error: PommeGuestRecoverySecurityError,
        snapshotStore: PommeGuestAMFISnapshotStore,
        baseline: PommeGuestAMFIState,
        current: PommeGuestAMFIState,
        credentials: PommeGuestSecurityCredentials
    ) throws {
        _ = error
        do {
            let record = try snapshotStore.loadRecord()
            // A compensating native write is authorized only by the exact
            // receipt produced by this transaction. A stale caller snapshot
            // or a foreign NVRAM value must never be used to justify a
            // rollback after a read failure or an interrupted write.
            guard try ownedPolicyReceiptMatches(record: record, current: current),
                  try rollbackNVRAMStateIsKnown(
                      record: record,
                      preFailure: baseline,
                      current: current
                  ) else {
                throw PommeGuestRecoverySecurityError.rollbackFailed
            }
            var observed = current
            if observed.policy != baseline.policy {
                let beforePolicy = observed.policy
                observed = try applyNativePolicy(
                    store: snapshotStore,
                    action: .rollback,
                    intentPhase: .rollbackApplying,
                    receiptPhase: .rollbackApplying,
                    before: observed,
                    expectedVolumeGroupUUID: try baselinePolicyVolumeGroupUUID(baseline),
                    arguments: baseline.policy.restoreArguments,
                    credentials: credentials,
                    expected: {
                        $0.matchesRestoredConfiguration(
                            of: baseline.policy,
                            from: beforePolicy
                        )
                    }
                )
            } else {
                try snapshotStore.update(
                    phase: .rollbackApplying,
                    policyCheckpoint: record.policyCheckpoint,
                    nativeTransition: record.nativeTransition,
                    nvramCheckpoint: nil
                )
            }
            observed = try applyNVRAMCheckpoint(
                store: snapshotStore,
                action: .rollback,
                intentPhase: .rollbackApplying,
                receiptPhase: .rollbackApplying,
                before: observed,
                target: baseline.snapshot.nvram,
                expectedVolumeGroupUUID: try baselinePolicyVolumeGroupUUID(baseline)
            )
            let finalRecord = try snapshotStore.loadRecord()
            let policyRestored: Bool
            if observed.policy.matchesRetainedBaseline(of: baseline.policy) {
                policyRestored = true
            } else {
                policyRestored = try policyCheckpointMatches(
                    record: finalRecord,
                    current: observed,
                    expected: {
                        $0.restorableCanonical == baseline.policy.restorableCanonical
                            && $0.nativeStableIdentityCanonical == baseline.policy.nativeStableIdentityCanonical
                    }
                )
            }
            guard policyRestored,
                  observed.snapshot.nvram == baseline.snapshot.nvram else {
                throw PommeGuestRecoverySecurityError.rollbackFailed
            }
            // Keep the baseline after a failed transaction. The next same
            // operation can reconcile it, and an explicit enable can restore
            // it exactly even after the host lost the prior response.
            try snapshotStore.setPhase(.rollbackVerified)
        } catch {
            try? snapshotStore.setPhase(.rollbackFailed)
            throw PommeGuestRecoverySecurityError.rollbackFailed
        }
    }

    private func rollbackNVRAMStateIsKnown(
        record: PommeGuestAMFISnapshotRecord,
        preFailure: PommeGuestAMFIState,
        current: PommeGuestAMFIState
    ) throws -> Bool {
        guard record.snapshot.isWellFormed else { return false }

        // The record baseline and the state captured immediately before the
        // failed operation are independently known values. A checkpoint adds
        // the exact native writer's before/target pair; either value may be
        // observed when the failure happened between its durable boundaries.
        var allowed = [record.snapshot.nvram, preFailure.snapshot.nvram]
        if let checkpoint = record.nvramCheckpoint {
            guard checkpoint.isWellFormed else { return false }
            allowed.append(checkpoint.before)
            allowed.append(checkpoint.target)
        }

        // If the NVRAM intent was not published before the failure, derive
        // the only target this transaction could have requested from the raw
        // baseline. This does not authorize a write by itself; the policy
        // receipt check above still has to pass.
        if record.policyCheckpoint?.action == .disable {
            allowed.append(try disabledBootArguments(from: record.snapshot))
        }
        return allowed.contains(current.snapshot.nvram)
    }

    private func baselinePolicyVolumeGroupUUID(_ state: PommeGuestAMFIState) throws -> UUID {
        guard let uuid = UUID(uuidString: state.policy.volumeGroupUUID) else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        return uuid
    }

    private func amfiResponse(
        operation: Operation,
        state: PommeGuestAMFIState,
        baselinePresent: Bool
    ) -> JSONValue {
        amfiResponse(
            operation: operation.rawValue,
            state: state,
            baselinePresent: baselinePresent
        )
    }

    private func amfiResponse(
        operation: String,
        state: PommeGuestAMFIState,
        baselinePresent: Bool
    ) -> JSONValue {
        let bootConfigured = PommeBootArguments.containsOverride(
            state.snapshot.nvram.value(for: "boot-args")
        )
        let configuredDisabled = bootConfigured && state.policy.allowsCustomBootArguments
        return .object([
            "operation": .string(operation),
            "amfiBootArgActive": .bool(bootConfigured),
            "amfiDisabled": .bool(configuredDisabled),
            "bootPolicyAllowsCustomBootArgs": .bool(state.policy.allowsCustomBootArguments),
            "securityMode": .string(state.policy.securityMode),
            "configuredState": .string(configuredDisabled ? "disabled" : "enabled"),
            // Boot arguments and LocalPolicy describe configuration only;
            // this guest transaction cannot claim live enforcement state.
            "enforcementState": .string("unknown"),
            "baselinePresent": .bool(baselinePresent),
            "verified": .bool(true)
        ])
    }

    private func applyNVRAM(
        _ delta: PommeNVRAMDelta,
        action: PommeGuestAMFINVRAMAction,
        transactionPhase: PommeGuestAMFITransactionPhase
    ) throws {
        guard Set(delta.values.keys) == ["boot-args"],
              let value = delta.value(for: "boot-args")
        else { throw PommeGuestRecoverySecurityError.invalidNVRAM }
        let result: PommeGuestProcessCapture
        do {
            if value.present {
                guard let text = try restorableBootArgumentText(value) else {
                    throw PommeGuestRecoverySecurityError.invalidNVRAM
                }
                result = try process("/usr/sbin/nvram", ["boot-args=\(text)"])
            } else {
                result = try process("/usr/sbin/nvram", ["-d", "boot-args"])
            }
        } catch let error as PommeGuestRecoverySecurityError {
            if error == .invalidNVRAM {
                throw error
            }
            throw PommeGuestAMFINVRAMApplyFailure(
                diagnostic: try .init(
                    action: action,
                    transactionPhase: transactionPhase,
                    stage: .completionUnavailable,
                    exitCode: nil,
                    stderrCategory: .other
                ),
                recoveryError: error
            )
        } catch {
            throw PommeGuestAMFINVRAMApplyFailure(
                diagnostic: try .init(
                    action: action,
                    transactionPhase: transactionPhase,
                    stage: .completionUnavailable,
                    exitCode: nil,
                    stderrCategory: .other
                ),
                recoveryError: .commandFailed
            )
        }
        guard result.status == 0 else {
            let stderrCategory = PommeGuestAMFINVRAMFailureCategory.classify(stderr: result.stderr)
            let recoveryError: PommeGuestRecoverySecurityError
            switch stderrCategory {
            case .permissionDenied, .notPermitted:
                recoveryError = .nvramWriteDenied
            case .invalidArgument, .other:
                recoveryError = .commandFailed
            }
            throw PommeGuestAMFINVRAMApplyFailure(
                diagnostic: try .init(
                    action: action,
                    transactionPhase: transactionPhase,
                    stage: .completedExit,
                    exitCode: result.status,
                    stderrCategory: stderrCategory
                ),
                recoveryError: recoveryError
            )
        }
    }

    private struct PommeGuestAMFIState: Sendable {
        let policy: PommeGuestAMFIPolicy
        let snapshot: PommeAMFISecuritySnapshot
    }

    private func captureAMFIState(
        expectedVolumeGroupUUID: UUID? = nil,
        strictPolicy: Bool = true
    ) throws -> PommeGuestAMFIState {
        let groupUUID = try currentVolumeGroupUUID(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        if let expectedVolumeGroupUUID,
           groupUUID != expectedVolumeGroupUUID.uuidString.lowercased() {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
        let policy = try capturePolicy(groupUUID: groupUUID, strict: strictPolicy)
        let boot = try readBootArguments()
        let delta = try PommeNVRAMDelta.bootArguments(present: boot.present, bytes: boot.bytes)
        let snapshot = try PommeAMFISecuritySnapshot(
            localPolicy: policy.snapshotCanonical,
            nvram: delta
        )
        return .init(policy: policy, snapshot: snapshot)
    }

    private func snapshotStore(for volumeGroupUUID: UUID) throws -> PommeGuestAMFISnapshotStore {
        if let snapshotStore {
            guard snapshotStore.volumeGroupUUID == volumeGroupUUID else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            return snapshotStore
        }

        let root: URL
        do {
            if let dataRootResolver {
                root = try dataRootResolver(volumeGroupUUID)
            } else {
                let resolver = PommeRecoveryDataVolumeResolver { executable, arguments in
                    let result = try process(executable, arguments)
                    return (status: result.status, stdout: result.stdout)
                }
                root = try resolver.resolve(expectedVolumeGroupUUID: volumeGroupUUID)
            }
            return try PommeGuestAMFISnapshotStore(
                dataRoot: root,
                volumeGroupUUID: volumeGroupUUID
            )
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    /// Resolve the already-mounted normal-boot Data volume without using the
    /// Recovery resolver's `/Volumes/...` mount contract. Normal macOS keeps
    /// the selected Data volume at `/System/Volumes/Data`; mounting another
    /// volume here would make the credential-free stage target ambiguous.
    private func normalSnapshotStore(
        for volumeGroupUUID: UUID
    ) throws -> PommeGuestAMFISnapshotStore {
        if let snapshotStore {
            guard snapshotStore.volumeGroupUUID == volumeGroupUUID else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            return snapshotStore
        }
        if let dataRootResolver {
            do {
                return try PommeGuestAMFISnapshotStore(
                    dataRoot: dataRootResolver(volumeGroupUUID),
                    volumeGroupUUID: volumeGroupUUID
                )
            } catch let error as PommeGuestRecoverySecurityError {
                throw error
            } catch {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
        }

        do {
            let groups = try process(
                "/usr/sbin/diskutil",
                ["apfs", "listVolumeGroups", "-plist"]
            )
            guard groups.status == 0 else {
                throw PommeGuestRecoverySecurityError.startupVolumeMismatch
            }
            let selected = try PommeRecoveryDataVolumeResolver.resolveDataVolume(
                from: groups.stdout,
                expectedVolumeGroupUUID: volumeGroupUUID
            )
            let dataInfo = try process(
                "/usr/sbin/diskutil",
                ["info", "-plist", selected.dataDevice]
            )
            guard dataInfo.status == 0,
                  let root = try? PropertyListSerialization.propertyList(
                      from: dataInfo.stdout,
                      options: [],
                      format: nil
                  ) as? [String: Any],
                  root["DeviceIdentifier"] as? String == selected.dataDevice,
                  (root["FilesystemType"] as? String)?.caseInsensitiveCompare("apfs") == .orderedSame,
                  let group = (root["APFSVolumeGroupID"] as? String)
                      ?? (root["APFSVolumeGroupUUID"] as? String),
                  UUID(uuidString: group) == volumeGroupUUID,
                  let mountPoint = root["MountPoint"] as? String,
                  mountPoint == "/System/Volumes/Data"
                      || (mountPoint.hasPrefix("/Volumes/") && mountPoint != "/Volumes/") else {
                throw PommeGuestRecoverySecurityError.startupVolumeMismatch
            }
            let rootURL = URL(fileURLWithPath: mountPoint, isDirectory: true).standardizedFileURL
            var info = stat()
            guard lstat(rootURL.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  rootURL.path == rootURL.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            return try PommeGuestAMFISnapshotStore(
                dataRoot: rootURL,
                volumeGroupUUID: volumeGroupUUID
            )
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    private func currentVolumeGroupUUID(expectedVolumeGroupUUID: UUID? = nil) throws -> String {
        let result = try process("/usr/sbin/diskutil", ["apfs", "listVolumeGroups", "-plist"])
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        do {
            let volume = try PommeRecoveryDataVolumeResolver.resolveDataVolume(
                from: result.stdout,
                expectedVolumeGroupUUID: expectedVolumeGroupUUID
            )
            return volume.volumeGroupUUID.uuidString.lowercased()
        } catch {
            throw PommeGuestRecoverySecurityError.startupVolumeMismatch
        }
    }

    private func readBootArguments() throws -> PommeNVRAMValue {
        let result = try process("/usr/sbin/nvram", ["-x", "boot-args"])
        guard result.status == 0 else {
            let diagnostic = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.stdout.isEmpty,
                  diagnostic == "nvram: Error getting variable - 'boot-args': (iokit/common) data was not found" else {
                throw PommeGuestRecoverySecurityError.invalidNVRAM
            }
            return .absent
        }
        guard String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: result.stdout,
                  options: [],
                  format: nil
              ) as? [String: Any],
              Set(plist.keys) == ["boot-args"],
              let text = plist["boot-args"] as? String else {
            throw PommeGuestRecoverySecurityError.invalidNVRAM
        }
        // XML `<data>` values are deliberately rejected above. Re-encoding a
        // binary plist value as an nvram string would guess its native type
        // and could not prove exact restoration.
        return try .init(present: true, bytes: Data(text.utf8))
    }

    private func capturePolicy(groupUUID: String, strict: Bool) throws -> PommeGuestAMFIPolicy {
        let targeted = try process(
            "/usr/bin/bputil",
            ["--json", "--display-policy", "-v", groupUUID]
        )
        if targeted.status == 0 {
            do {
                return try parsePolicy(
                    targeted.stdout,
                    expectedVolumeGroupUUID: groupUUID,
                    strict: strict
                )
            } catch {
                // Some Recovery builds do not support a UUID-bound display
                // query even though the all-policy query is available. Fall
                // back only after a successful command produced an
                // unparseable response; a failed command's stdout is never a
                // trusted policy readback.
            }
        }
        let all = try process(
            "/usr/bin/bputil",
            ["--json", "--display-all-policies"]
        )
        guard all.status == 0 else {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        return try parsePolicy(
            all.stdout,
            expectedVolumeGroupUUID: groupUUID,
            strict: strict
        )
    }

    private func parseSnapshotPolicy(
        _ data: Data,
        expectedVolumeGroupUUID: UUID,
        strict: Bool
    ) throws -> PommeGuestAMFIPolicy {
        let expected = expectedVolumeGroupUUID.uuidString.lowercased()
        do {
            return try parsePolicy(
                data,
                expectedVolumeGroupUUID: expected,
                strict: strict
            )
        } catch {
            // Records written by the earlier development build wrapped the
            // policy with its volume UUID. Keep those records readable only
            // when their explicit wrapper still matches this store.
            let policy = try parsePolicy(data, expectedVolumeGroupUUID: nil, strict: strict)
            guard policy.volumeGroupUUID == expected else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            return policy
        }
    }

    private struct PommeGuestAMFIPolicy: Sendable, Equatable {
        let volumeGroupUUID: String
        let vuid: String
        let securityMode: String
        let allowsMDM: Bool
        let allowsKexts: Bool
        let kernelCTRRDisabled: Bool
        let allowsCustomBootArguments: Bool
        let ssvDisabled: Bool
        let unmanagedMDM: Bool
        let unknownSecurityModeExtension: Bool
        let customSIPBits: UInt64
        let sip0Exists: Bool
        let spih: String
        let spihExists: Bool
        let nsih: String
        let stng: UInt64
        let stngExists: Bool
        let identityCanonical: Data
        let nativeStableIdentityCanonical: Data
        let restorableCanonical: Data
        let canonical: Data

        /// This is the complete Tahoe 26 bputil JSON vocabulary captured from
        /// Recovery. Unknown fields remain status-readable but are rejected
        /// before a mutation because bputil's restore flags cannot preserve
        /// them safely.
        static let knownKeys: Set<String> = [
            "CSEC", "CEPO", "SDOM", "CHIP", "BORD", "ECID", "CRPO", "lobo",
            "kuid", "love", "bputil_version",
            "spih", "spih_exists", "nsih", "stng", "stng_exists",
            "lpnh", "rpnh", "os_lpnh", "os_ronh",
            "auxp", "auxp_exists", "auxi", "auxi_exists", "auxr", "auxr_exists",
            "coih", "coih_exists",
            "vuid", "security_mode",
            "smb0", "smb1", "smb2", "smb3", "smb4", "smb5",
            "sip0", "sip0_exists", "sip1", "sip2", "sip3",
            "properly_paired", "os_paired_to_current", "baa_certified",
            "os_type", "os_type_overriden"
        ]

        /// `lpnh` is intentionally excluded from equality. Apple documents it
        /// as an anti-replay value that changes whenever any LocalPolicy on
        /// the system is changed; `os_lpnh` is bputil's corresponding value
        /// for the selected OS. The full JSON containing both values remains
        /// in `canonical` and therefore in the durable snapshot.
        static let antiReplayKeys: Set<String> = ["lpnh", "os_lpnh"]

        /// These fields describe the selected boot objects and the Cryptex1
        /// anti-replay generation. They are not user-controlled policy flags.
        /// A native bputil write may regenerate them, but only the transition
        /// validator below may permit that regeneration.
        static let regeneratedKeys: Set<String> = [
            "spih", "spih_exists", "nsih", "stng", "stng_exists"
        ]

        static let restorableKeys: Set<String> = [
            "vuid", "security_mode", "smb0", "smb1", "smb2", "smb3", "smb4", "smb5",
            "sip0", "sip0_exists", "sip1", "sip2", "sip3"
        ]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identityCanonical == rhs.identityCanonical
                && lhs.restorableCanonical == rhs.restorableCanonical
        }

        var isSupportedStandardSIPDisabledProfile: Bool {
            securityMode == "permissive"
                && customSIPBits == 127
                && sip0Exists
                && !ssvDisabled
                && kernelCTRRDisabled
                && allowsCustomBootArguments
                && !unmanagedMDM
                && !unknownSecurityModeExtension
        }

        /// A retained baseline comparison is stricter for the standard SIP
        /// disabled profile. Its no-op receipt proves that no native policy
        /// operation occurred, so even Apple's rotating nonce fields must
        /// remain byte-for-byte identical to the saved baseline.
        func matchesRetainedBaseline(of original: Self) -> Bool {
            if original.isSupportedStandardSIPDisabledProfile {
                return snapshotCanonical == original.snapshotCanonical
            }
            return self == original
        }

        /// PommeAMFISecuritySnapshot stores the exact validated bputil policy
        /// bytes. The surrounding snapshot record carries the selected
        /// volume-group identity, so enable never has to guess its target.
        var snapshotCanonical: Data {
            canonical
        }

        var restoreArguments: [String] {
            var arguments = [securityMode == "full" ? "-f" : securityMode == "reduced" ? "-g" : "-n", "-v", volumeGroupUUID]
            if allowsMDM { arguments.append("-m") }
            if allowsKexts { arguments.append("-k") }
            if kernelCTRRDisabled { arguments.append("-c") }
            if allowsCustomBootArguments { arguments.append("-a") }
            if ssvDisabled { arguments.append("-s") }
            return arguments
        }

        /// bputil documents `-m` and `-k` as the native switches for
        /// retaining user-authorized MDM and third-party-kext policy while
        /// rebuilding a downgraded policy. Include them in the AMFI target so
        /// the disable operation does not silently discard an enabled field.
        var disableArguments: [String] {
            var arguments = ["-a"]
            if allowsMDM { arguments.append("-m") }
            if allowsKexts { arguments.append("-k") }
            if kernelCTRRDisabled { arguments.append("-c") }
            if ssvDisabled { arguments.append("-s") }
            arguments.append(contentsOf: ["-v", volumeGroupUUID])
            return arguments
        }

        func matchesDisabledTarget(of original: Self) -> Bool {
            if original.isSupportedStandardSIPDisabledProfile {
                return snapshotCanonical == original.snapshotCanonical
            }
            guard volumeGroupUUID == original.volumeGroupUUID,
                  vuid == original.vuid,
                  identityCanonical == original.identityCanonical,
                  securityMode == "permissive",
                  allowsMDM == original.allowsMDM,
                  allowsKexts == original.allowsKexts,
                  kernelCTRRDisabled == original.kernelCTRRDisabled,
                  ssvDisabled == original.ssvDisabled,
                  allowsCustomBootArguments,
                  !unmanagedMDM,
                  !unknownSecurityModeExtension,
                  customSIPBits == 0
            else { return false }
            return true
        }

        /// Compare only the effective disabled configuration and stable
        /// identity. The native transition validator separately proves that
        /// regenerated manifest fields came from the authenticated write.
        func matchesDisabledTargetProjection(of original: Self) -> Bool {
            if original.isSupportedStandardSIPDisabledProfile {
                return snapshotCanonical == original.snapshotCanonical
            }
            guard volumeGroupUUID == original.volumeGroupUUID,
                  vuid == original.vuid,
                  nativeStableIdentityCanonical == original.nativeStableIdentityCanonical,
                  securityMode == "permissive",
                  allowsMDM == original.allowsMDM,
                  allowsKexts == original.allowsKexts,
                  kernelCTRRDisabled == original.kernelCTRRDisabled,
                  ssvDisabled == original.ssvDisabled,
                  allowsCustomBootArguments,
                  !unmanagedMDM,
                  !unknownSecurityModeExtension,
                  customSIPBits == 0
            else { return false }
            return true
        }

        /// Verify a policy produced by an authenticated native write. This is
        /// intentionally separate from `==` and `matchesDisabledTarget`: an
        /// observed manifest change is accepted only when the caller has a
        /// durable before-policy intent and a successful bputil readback.
        func followsNativeTransition(from before: Self) -> Bool {
            guard volumeGroupUUID == before.volumeGroupUUID,
                  vuid == before.vuid,
                  nativeStableIdentityCanonical == before.nativeStableIdentityCanonical,
                  spihExists == before.spihExists,
                  stngExists == before.stngExists,
                  before.stng < UInt64.max,
                  stng == before.stng + 1,
                  Self.validSHA384(spih),
                  Self.validSHA384(nsih)
            else { return false }
            return true
        }

        func matchesDisabledTargetAfterNativeTransition(
            of original: Self,
            from before: Self
        ) -> Bool {
            guard followsNativeTransition(from: before),
                  nativeStableIdentityCanonical == original.nativeStableIdentityCanonical,
                  volumeGroupUUID == original.volumeGroupUUID,
                  vuid == original.vuid,
                  securityMode == "permissive",
                  allowsMDM == original.allowsMDM,
                  allowsKexts == original.allowsKexts,
                  kernelCTRRDisabled == original.kernelCTRRDisabled,
                  ssvDisabled == original.ssvDisabled,
                  allowsCustomBootArguments,
                  !unmanagedMDM,
                  !unknownSecurityModeExtension,
                  customSIPBits == 0
            else { return false }
            return true
        }

        func matchesRestoredConfiguration(
            of original: Self,
            from before: Self
        ) -> Bool {
            guard followsNativeTransition(from: before),
                  nativeStableIdentityCanonical == original.nativeStableIdentityCanonical,
                  restorableCanonical == original.restorableCanonical,
                  volumeGroupUUID == original.volumeGroupUUID,
                  vuid == original.vuid
            else { return false }
            return true
        }

        private static func validSHA384(_ value: String) -> Bool {
            value.count == 96
                && value.unicodeScalars.allSatisfy {
                    (0x30...0x39).contains($0.value)
                        || (0x41...0x46).contains($0.value)
                        || (0x61...0x66).contains($0.value)
                }
        }
    }

    private func parsePolicy(
        _ data: Data,
        expectedVolumeGroupUUID: String?,
        strict: Bool = true
    ) throws -> PommeGuestAMFIPolicy {
        guard data.count <= 512 * 1024 else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        // Tahoe bputil prefixes JSON display output with one exact,
        // target-bound human-readable line. Keep the exact JSON object for
        // the durable baseline while ignoring only that known framing text;
        // arbitrary diagnostics around JSON are rejected.
        let jsonData: Data
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
            jsonData = data
        } else {
            guard let expectedVolumeGroupUUID,
                  let expectedUUID = UUID(uuidString: expectedVolumeGroupUUID) else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
            let bytes = [UInt8](data)
            guard let newline = bytes.firstIndex(of: 0x0a),
                  String(decoding: bytes[0..<newline], as: UTF8.self)
                      == "Operating on Volume Group UUID \(expectedUUID.uuidString.uppercased())" else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
            var start = newline + 1
            while start < bytes.count, Self.isJSONWhitespace(bytes[start]) {
                start += 1
            }
            guard start < bytes.count, bytes[start] == 0x7b,
                  let end = bytes.lastIndex(of: 0x7d), end >= start,
                  bytes[(end + 1)...].allSatisfy(Self.isJSONWhitespace) else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
            jsonData = Data(bytes[start...end])
        }
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }

        if expectedVolumeGroupUUID == nil,
           Set(root.keys) == ["volumeGroupUUID", "policy"],
           let rawGroup = root["volumeGroupUUID"] as? String,
           let group = UUID(uuidString: rawGroup)?.uuidString.lowercased(),
           let wrappedPolicy = root["policy"] as? [String: Any],
           let (rootVUID, rawPolicy) = wrappedPolicy.first,
           wrappedPolicy.count == 1,
           let policy = rawPolicy as? [String: Any] {
            return try parsePolicyObject(
                root: wrappedPolicy,
                rootVUID: rootVUID,
                policy: policy,
                volumeGroupUUID: group,
                canonical: jsonData,
                strict: strict
            )
        }

        guard root.count == 1,
              let (rootVUID, rawPolicy) = root.first,
              let policy = rawPolicy as? [String: Any],
              let expectedVolumeGroupUUID,
              let group = UUID(uuidString: expectedVolumeGroupUUID)?.uuidString.lowercased()
        else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        return try parsePolicyObject(
            root: root,
            rootVUID: rootVUID,
            policy: policy,
            volumeGroupUUID: group,
            canonical: jsonData,
            strict: strict
        )
    }

    private func parsePolicyObject(
        root: [String: Any],
        rootVUID: String,
        policy: [String: Any],
        volumeGroupUUID: String,
        canonical: Data,
        strict: Bool
    ) throws -> PommeGuestAMFIPolicy {
        if strict {
            guard Set(policy.keys).isSubset(of: PommeGuestAMFIPolicy.knownKeys) else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }
        guard let embedded = policy["vuid"] as? String,
              let vuid = UUID(uuidString: embedded)?.uuidString.lowercased(),
              UUID(uuidString: rootVUID)?.uuidString.lowercased() == vuid,
              vuid == volumeGroupUUID,
              let mode = policy["security_mode"] as? String,
              ["full", "reduced", "permissive"].contains(mode.lowercased()),
              let smb0 = Self.exactBool(policy["smb0"]),
              let smb1 = Self.exactBool(policy["smb1"]),
              let allowsKexts = Self.exactBool(policy["smb2"]),
              let allowsMDM = Self.exactBool(policy["smb3"]),
              let unmanagedMDM = Self.exactBool(policy["smb4"]),
              let ssvDisabled = Self.exactBool(policy["sip1"]),
              let kernelCTRRDisabled = Self.exactBool(policy["sip2"]),
              let allowsCustomBootArguments = Self.exactBool(policy["sip3"]),
              let sip0 = Self.requiredUnsignedInteger(policy["sip0"])
        else { throw PommeGuestRecoverySecurityError.invalidPolicy }

        let expectedMode: String
        switch (smb0, smb1) {
        case (false, false): expectedMode = "full"
        case (true, false): expectedMode = "reduced"
        case (true, true): expectedMode = "permissive"
        case (false, true): throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        guard mode.lowercased() == expectedMode else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        let smb5: Bool
        if let rawSmb5 = policy["smb5"] {
            guard let parsedSmb5 = Self.exactBool(rawSmb5) else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
            smb5 = parsedSmb5
        } else {
            smb5 = false
        }
        let sip0Exists = Self.exactBool(policy["sip0_exists"]) ?? false
        let supportedStandardSIPDisabledProfile = expectedMode == "permissive"
            && sip0 == 127
            && sip0Exists
            && !ssvDisabled
            && kernelCTRRDisabled
            && allowsCustomBootArguments
        let auxiliaryPolicyActive = ["auxp", "auxi", "auxr", "coih"].contains {
            Self.exactBool(policy["\($0)_exists"]) == true
        }
        try validateNativeIdentityFields(policy)
        if strict {
            guard !unmanagedMDM,
                  !smb5,
                  ((sip0 == 0 && !sip0Exists) || supportedStandardSIPDisabledProfile),
                  !auxiliaryPolicyActive else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }
        if let paired = policy["properly_paired"] {
            guard Self.exactBool(paired) == true else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        }
        if let paired = policy["os_paired_to_current"] {
            guard Self.exactBool(paired) == true else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        }
        if let osType = policy["os_type"] {
            guard (osType as? String)?.caseInsensitiveCompare("macOS") == .orderedSame else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }

        switch expectedMode {
        case "full":
            guard !allowsMDM, !allowsKexts, !kernelCTRRDisabled,
                  !allowsCustomBootArguments, !ssvDisabled else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        case "reduced":
            guard !kernelCTRRDisabled, !allowsCustomBootArguments, !ssvDisabled else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        default:
            break
        }
        var identity = [String: Any]()
        for key in policy.keys
            where !PommeGuestAMFIPolicy.restorableKeys.contains(key)
                && !PommeGuestAMFIPolicy.antiReplayKeys.contains(key) {
            identity[key] = policy[key]
        }
        var nativeStableIdentity = [String: Any]()
        for key in policy.keys
            where !PommeGuestAMFIPolicy.restorableKeys.contains(key)
                && !PommeGuestAMFIPolicy.antiReplayKeys.contains(key)
                && !PommeGuestAMFIPolicy.regeneratedKeys.contains(key) {
            nativeStableIdentity[key] = policy[key]
        }
        let restorable: [String: Any] = [
            "vuid": vuid,
            "security_mode": expectedMode,
            "smb0": smb0,
            "smb1": smb1,
            "smb2": allowsKexts,
            "smb3": allowsMDM,
            "smb4": unmanagedMDM,
            "smb5": smb5,
            "sip0": sip0,
            "sip0_exists": sip0Exists,
            "sip1": ssvDisabled,
            "sip2": kernelCTRRDisabled,
            "sip3": allowsCustomBootArguments
        ]
        guard let identityCanonical = try? JSONSerialization.data(
                  withJSONObject: identity,
                  options: [.sortedKeys]
              ),
              let restorableCanonical = try? JSONSerialization.data(
                  withJSONObject: restorable,
                  options: [.sortedKeys]
              ),
              let nativeStableIdentityCanonical = try? JSONSerialization.data(
                  withJSONObject: nativeStableIdentity,
                  options: [.sortedKeys]
              ),
              let spih = policy["spih"] as? String,
              let spihExists = Self.exactBool(policy["spih_exists"]),
              let nsih = policy["nsih"] as? String,
              let stng = Self.requiredUnsignedInteger(policy["stng"]),
              let stngExists = Self.exactBool(policy["stng_exists"]) else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        return .init(
            volumeGroupUUID: volumeGroupUUID,
            vuid: vuid,
            securityMode: expectedMode,
            allowsMDM: allowsMDM,
            allowsKexts: allowsKexts,
            kernelCTRRDisabled: kernelCTRRDisabled,
            allowsCustomBootArguments: allowsCustomBootArguments,
            ssvDisabled: ssvDisabled,
            unmanagedMDM: unmanagedMDM,
            unknownSecurityModeExtension: smb5,
            customSIPBits: sip0,
            sip0Exists: sip0Exists,
            spih: spih,
            spihExists: spihExists,
            nsih: nsih,
            stng: stng,
            stngExists: stngExists,
            identityCanonical: identityCanonical,
            nativeStableIdentityCanonical: nativeStableIdentityCanonical,
            restorableCanonical: restorableCanonical,
            canonical: canonical
        )
    }

    private func validateNativeIdentityFields(_ policy: [String: Any]) throws {
        let booleanKeys = [
            "CSEC", "CRPO", "lobo", "properly_paired", "os_paired_to_current",
            "baa_certified", "os_type_overriden", "spih_exists", "stng_exists",
            "auxp_exists", "auxi_exists", "auxr_exists", "coih_exists", "sip0_exists"
        ]
        for key in booleanKeys {
            guard Self.exactBool(policy[key]) != nil else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }
        guard Self.exactBool(policy["properly_paired"]) == true,
              Self.exactBool(policy["os_paired_to_current"]) == true,
              let osType = policy["os_type"] as? String,
              osType.caseInsensitiveCompare("macOS") == .orderedSame,
              let bputilVersion = policy["bputil_version"] as? String,
              bputilVersion.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              let love = policy["love"] as? String,
              love.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+,[0-9]+$"#, options: .regularExpression) != nil,
              let kuid = policy["kuid"] as? String,
              UUID(uuidString: kuid) != nil else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        for key in ["CEPO", "SDOM", "CHIP", "BORD", "ECID", "stng", "sip0"] {
            guard Self.requiredUnsignedInteger(policy[key]) != nil else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }
        for key in ["spih", "nsih", "lpnh", "rpnh", "os_lpnh", "os_ronh"] {
            guard let value = policy[key] as? String,
                  value.count == 96,
                  value.unicodeScalars.allSatisfy({
                      (0x30...0x39).contains($0.value)
                          || (0x41...0x46).contains($0.value)
                          || (0x61...0x66).contains($0.value)
                  }) else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }
        for key in ["spih", "stng", "auxp", "auxi", "auxr", "coih"] {
            let exists = Self.exactBool(policy["\(key)_exists"]) == true
            if exists {
                if key == "stng" {
                    guard Self.requiredUnsignedInteger(policy[key]) != nil else {
                        throw PommeGuestRecoverySecurityError.invalidPolicy
                    }
                } else if key != "spih" {
                    guard let value = policy[key] as? String,
                          value.count == 96,
                          value.unicodeScalars.allSatisfy({
                              (0x30...0x39).contains($0.value)
                                  || (0x41...0x46).contains($0.value)
                                  || (0x61...0x66).contains($0.value)
                          }) else {
                        throw PommeGuestRecoverySecurityError.invalidPolicy
                    }
                }
            }
        }
        for key in ["spih", "stng", "auxp", "auxi", "auxr", "coih"] {
            let exists = Self.exactBool(policy["\(key)_exists"]) == true
            if !exists, policy[key] != nil && key != "spih" {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }
    }

    private static func exactBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x20
    }

    private static func requiredUnsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let text = number.stringValue
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) })
        else { return nil }
        return UInt64(text)
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> PommeGuestProcessCapture {
        guard executable.hasPrefix("/"),
              !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") })
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [:]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        let stdoutDescriptor = output.fileHandleForReading.fileDescriptor
        let stderrDescriptor = error.fileHandleForReading.fileDescriptor
        for descriptor in [stdoutDescriptor, stderrDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                process.terminate()
                process.waitUntilExit()
                throw PommeGuestRecoverySecurityError.commandFailed
            }
        }

        var stdout = Data()
        var stderr = Data()
        var stdoutEOF = false
        var stderrEOF = false
        let deadline = Date().addingTimeInterval(120)
        func drain(_ descriptor: Int32, into data: inout Data, eof: inout Bool) {
            guard !eof else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    eof = true
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    eof = true
                    return
                }
            }
        }

        while !stdoutEOF || !stderrEOF || process.isRunning {
            drain(stdoutDescriptor, into: &stdout, eof: &stdoutEOF)
            drain(stderrDescriptor, into: &stderr, eof: &stderrEOF)
            guard stdout.count <= 512 * 1024, stderr.count <= 512 * 1024 else {
                process.terminate()
                process.waitUntilExit()
                throw PommeGuestRecoverySecurityError.outputTooLarge
            }
            if Date() >= deadline {
                process.terminate()
                usleep(100_000)
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                throw PommeGuestRecoverySecurityError.timedOut
            }
            if !process.isRunning && stdoutEOF && stderrEOF { break }
            usleep(10_000)
        }
        process.waitUntilExit()
        return .init(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func runSecretProcess(
        _ executable: String,
        _ arguments: [String],
        _ credentials: PommeGuestSecurityCredentials
    ) throws -> PommeGuestProcessCapture {
        if executable == "/usr/bin/csrutil" {
            return try PommeGuestSecurityPTY.runSIP(
                action: arguments == ["enable"] ? "enable" : "disable",
                credentials: credentials,
                timeout: 120
            )
        }
        guard executable == "/usr/bin/bputil" else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        return try PommeGuestSecurityPTY.runBputil(
            arguments: arguments,
            credentials: credentials,
            timeout: 120
        )
    }
}

private enum PommeGuestSecurityPTY {
    private static let maximumTranscriptBytes = 512 * 1024

    static func runSIP(
        action: String,
        credentials: PommeGuestSecurityCredentials,
        timeout: TimeInterval
    ) throws -> PommeGuestProcessCapture {
        var responder = PommeGuestSIPPromptResponder(
            action: action,
            expectedUsername: credentials.username
        )
        let result = try run(
            executable: "/usr/bin/csrutil",
            arguments: [action],
            timeout: timeout
        ) { text, descriptor in
            if let input = try responder.nextInput(for: text, credentials: credentials) {
                try write(input + "\r", to: descriptor)
            }
        }
        guard responder.completed else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        return result
    }

    static func runBputil(
        arguments: [String],
        credentials: PommeGuestSecurityCredentials,
        timeout: TimeInterval
    ) throws -> PommeGuestProcessCapture {
        var responder = PommeGuestAMFIPromptResponder(
            expectedUsername: credentials.username
        )
        let result = try run(
            executable: "/usr/bin/bputil",
            arguments: arguments,
            timeout: timeout
        ) { text, descriptor in
            if let input = try responder.nextInput(for: text, credentials: credentials) {
                try write(input + "\r", to: descriptor)
            }
        }
        guard responder.completed else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        return result
    }

    private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        handle: (String, Int32) throws -> Void
    ) throws -> PommeGuestProcessCapture {
        guard timeout.isFinite, timeout > 0,
              executable.hasPrefix("/"),
              arguments.allSatisfy({ !$0.contains("\0") })
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        defer {
            if master >= 0 { _ = Darwin.close(master) }
            if slave >= 0 { _ = Darwin.close(slave) }
        }
        let child = pommeGuestFork()
        guard child >= 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        if child == 0 {
            _ = Darwin.close(master)
            _ = setsid()
            _ = ioctl(slave, TIOCSCTTY, 0)
            _ = dup2(slave, STDIN_FILENO)
            _ = dup2(slave, STDOUT_FILENO)
            _ = dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { _ = Darwin.close(slave) }
            let command = strdup(executable)
            var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
            argv.append(nil)
            // The PTY child must not inherit the launcher's environment. In
            // particular, Recovery authorization values are never copied into
            // a child environment where a command or diagnostic could expose
            // them. bputil/csrutil do not need a caller-provided environment;
            // retain only a fixed system PATH for their own helper lookup.
            var environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
            _ = execve(command, &argv, &environment)
            _exit(127)
        }
        _ = Darwin.close(slave)
        slave = -1
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            terminate(child, status: nil)
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        var transcript = Data()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child { finished = true }
            drain(master, into: &transcript)
            guard transcript.count <= maximumTranscriptBytes else {
                terminate(child, status: &status)
                throw PommeGuestRecoverySecurityError.outputTooLarge
            }
            do {
                let text = String(decoding: transcript, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "\n")
                try handle(text, master)
            } catch {
                terminate(child, status: &status)
                throw error
            }
            if finished { break }
            usleep(50_000)
        }
        guard finished else {
            terminate(child, status: &status)
            throw PommeGuestRecoverySecurityError.timedOut
        }
        drain(master, into: &transcript)
        guard transcript.count <= maximumTranscriptBytes else {
            throw PommeGuestRecoverySecurityError.outputTooLarge
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        transcript.resetBytes(in: 0..<transcript.count)
        return .init(status: exitCode)
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private static func write(_ text: String, to descriptor: Int32) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PommeGuestRecoverySecurityError.commandFailed
                }
            }
        }
    }

    private static func terminate(_ child: pid_t, status: inout Int32?) {
        _ = kill(-child, SIGTERM)
        _ = kill(child, SIGTERM)
        for _ in 0..<20 {
            var observed: Int32 = 0
            if waitpid(child, &observed, WNOHANG) == child {
                status = observed
                return
            }
            usleep(100_000)
        }
        _ = kill(-child, SIGKILL)
        _ = kill(child, SIGKILL)
        var observed: Int32 = 0
        _ = waitpid(child, &observed, 0)
        status = observed
    }

    private static func terminate(_ child: pid_t, status: inout Int32) {
        var optional: Int32? = status
        terminate(child, status: &optional)
        if let optional { status = optional }
    }

    private static func terminate(_ child: pid_t, status: Int32?) {
        var optional = status
        terminate(child, status: &optional)
    }
}

enum PommeGuestPromptParsing {
    enum PasswordPrompt: Equatable {
        case named(String)
        case unbound
    }

    static func firstLine(
        in text: String,
        matching predicate: (String) -> Bool
    ) -> Range<String.Index>? {
        for line in text.split(whereSeparator: \.isNewline) {
            if predicate(String(line)) {
                return line.startIndex..<line.endIndex
            }
        }
        return nil
    }

    static func withoutTrailingWhitespace(_ line: String) -> String {
        var result = line
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    static func usernamePrompt(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(
            of: #"(?i)^(?:authorized\s+user|administrator\s+username|local\s+owner\s+username|owner\s+username|user\s*name|username)\s*:\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func passwordPrompt(_ line: String) -> PasswordPrompt? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        for prefix in [
            "please enter password for user ",
            "enter password for user "
        ] {
            guard lowercased.hasPrefix(prefix), value.hasSuffix(":"), value.count > prefix.count + 1 else {
                continue
            }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            let end = value.index(before: value.endIndex)
            let username = String(value[start..<end]).trimmingCharacters(in: .whitespaces)
            guard !username.isEmpty,
                  username.utf8.count <= 256,
                  !username.contains("\0"),
                  !username.contains("\n"),
                  !username.contains("\r") else {
                return nil
            }
            return .named(username)
        }
        guard value.range(
            of: #"(?i)^password\s*:\s*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return .unbound
    }

    static func hasCredentialPrompt(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        guard value.contains(":") else { return false }
        return lowercased.contains("password")
            || lowercased.contains("authorized user")
            || lowercased.contains("administrator username")
            || lowercased.contains("username")
            || lowercased.contains("user name")
    }

    static func bareConfirmationPrompt(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "[y/n]:" || value == "[y/n]"
    }

    static func hasConfirmationPrompt(_ line: String) -> Bool {
        let value = withoutTrailingWhitespace(line)
        return value.hasSuffix("[y/n]:") || value.hasSuffix("[y/n]")
    }

    static func hasRejectedOutput(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("pick a macos installation")
            || value.contains("this computer has several macos installations")
            || value.contains("unknown user")
            || value.contains("no admin users authorized for recovery")
            || value.contains("enter recovery key")
            || value.contains("authentication token")
            || value.contains("failed to authenticate")
            || value.contains("aborted")
            || value.contains("cancelled")
            || value.contains("canceled")
    }
}

struct PommeGuestSIPPromptResponder {
    private enum State { case confirmation, username, password, complete }

    let action: String
    let expectedUsername: String
    private var state: State = .confirmation
    private var consumedCharacterCount = 0

    init(action: String, expectedUsername: String) {
        self.action = action
        self.expectedUsername = expectedUsername
    }

    mutating func nextInput(
        for transcript: String,
        credentials: PommeGuestSecurityCredentials
    ) throws -> String? {
        guard action == "enable" || action == "disable",
              credentials.username == expectedUsername,
              transcript.count >= consumedCharacterCount else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        let delta = String(transcript.dropFirst(consumedCharacterCount))
        guard !PommeGuestPromptParsing.hasRejectedOutput(delta) else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }

        switch state {
        case .confirmation:
            if let range = PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                Self.nativeConfirmationPrompt(line, action: action)
            }) {
                consume(transcript, delta: delta, through: range)
                state = .username
                return "Y"
            }
            if let range = PommeGuestPromptParsing.firstLine(
                in: delta,
                matching: PommeGuestPromptParsing.bareConfirmationPrompt
            ) {
                consume(transcript, delta: delta, through: range)
                state = .username
                return "Y"
            }
            if PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                PommeGuestPromptParsing.hasConfirmationPrompt(line)
            }) != nil || hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        case .username:
            if hasConfirmationPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
            if let range = PommeGuestPromptParsing.firstLine(in: delta, matching: PommeGuestPromptParsing.usernamePrompt) {
                consume(transcript, delta: delta, through: range)
                state = .password
                return credentials.username
            }
            if let range = PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                PommeGuestPromptParsing.passwordPrompt(line) != nil
            }) {
                guard let prompt = passwordPrompt(in: delta, at: range),
                      case .named(let username) = prompt,
                      username == expectedUsername else {
                    throw PommeGuestRecoverySecurityError.promptRejected
                }
                consume(transcript, delta: delta, through: range)
                state = .complete
                return credentials.password
            }
            if hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        case .password:
            if hasConfirmationPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
            if PommeGuestPromptParsing.firstLine(
                in: delta,
                matching: PommeGuestPromptParsing.usernamePrompt
            ) != nil {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
            if let range = PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                PommeGuestPromptParsing.passwordPrompt(line) != nil
            }) {
                guard let prompt = passwordPrompt(in: delta, at: range) else {
                    throw PommeGuestRecoverySecurityError.promptRejected
                }
                switch prompt {
                case .named(let username):
                    guard username == expectedUsername else {
                        throw PommeGuestRecoverySecurityError.promptRejected
                    }
                case .unbound:
                    break
                }
                consume(transcript, delta: delta, through: range)
                state = .complete
                return credentials.password
            }
            if hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        case .complete:
            if hasConfirmationPrompt(in: delta)
                || PommeGuestPromptParsing.firstLine(in: delta, matching: PommeGuestPromptParsing.usernamePrompt) != nil
                || PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                    PommeGuestPromptParsing.passwordPrompt(line) != nil
                }) != nil
                || hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        }
        return nil
    }

    var completed: Bool {
        if case .complete = state { return true }
        return false
    }

    private static func nativeConfirmationPrompt(_ line: String, action: String) -> Bool {
        let value = PommeGuestPromptParsing.withoutTrailingWhitespace(line)
        let prefix: String
        switch action {
        case "disable":
            prefix = "Allow booting unsigned operating systems and any kernel extensions for OS \""
        case "enable":
            prefix = "Raise security level to full boot security for OS \""
        default:
            return false
        }
        let suffix = "\"? [y/n]:"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        guard start < end else { return false }
        let label = value[start..<end]
        guard !label.isEmpty, label.utf8.count <= 256 else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x22
        }
    }

    private func hasConfirmationPrompt(in text: String) -> Bool {
        PommeGuestPromptParsing.firstLine(
            in: text,
            matching: { line in
                PommeGuestPromptParsing.bareConfirmationPrompt(line)
                    || PommeGuestPromptParsing.hasConfirmationPrompt(line)
            }
        ) != nil
    }

    private func hasCredentialPrompt(in text: String) -> Bool {
        PommeGuestPromptParsing.firstLine(
            in: text,
            matching: PommeGuestPromptParsing.hasCredentialPrompt
        ) != nil
    }

    private func passwordPrompt(
        in text: String,
        at range: Range<String.Index>
    ) -> PommeGuestPromptParsing.PasswordPrompt? {
        PommeGuestPromptParsing.passwordPrompt(String(text[range]))
    }

    private mutating func consume(
        _ transcript: String,
        delta: String,
        through range: Range<String.Index>
    ) {
        let consumed = delta.distance(from: delta.startIndex, to: range.upperBound)
        consumedCharacterCount += consumed
        // Keep this assertion local to the state machine: a malformed range
        // must never make the next call move backwards through transcript.
        consumedCharacterCount = min(consumedCharacterCount, transcript.count)
    }
}

struct PommeGuestAMFIPromptResponder {
    private enum State { case username, password, complete }

    let expectedUsername: String
    private var state: State = .username
    private var consumedCharacterCount = 0

    init(expectedUsername: String) {
        self.expectedUsername = expectedUsername
    }

    mutating func nextInput(
        for transcript: String,
        credentials: PommeGuestSecurityCredentials
    ) throws -> String? {
        guard credentials.username == expectedUsername,
              transcript.count >= consumedCharacterCount else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        let delta = String(transcript.dropFirst(consumedCharacterCount))
        guard !PommeGuestPromptParsing.hasRejectedOutput(delta) else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        switch state {
        case .username:
            if let range = PommeGuestPromptParsing.firstLine(
                in: delta,
                matching: PommeGuestPromptParsing.usernamePrompt
            ) {
                consume(transcript, delta: delta, through: range)
                state = .password
                return credentials.username
            }
            if let range = PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                PommeGuestPromptParsing.passwordPrompt(line) != nil
            }) {
                guard let prompt = PommeGuestPromptParsing.passwordPrompt(String(delta[range])),
                      case .named(let username) = prompt,
                      username == expectedUsername else {
                    throw PommeGuestRecoverySecurityError.promptRejected
                }
                consume(transcript, delta: delta, through: range)
                state = .complete
                return credentials.password
            }
            if hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        case .password:
            if PommeGuestPromptParsing.firstLine(
                in: delta,
                matching: PommeGuestPromptParsing.usernamePrompt
            ) != nil {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
            if let range = PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                PommeGuestPromptParsing.passwordPrompt(line) != nil
            }) {
                guard let prompt = PommeGuestPromptParsing.passwordPrompt(String(delta[range])) else {
                    throw PommeGuestRecoverySecurityError.promptRejected
                }
                switch prompt {
                case .named(let username):
                    guard username == expectedUsername else {
                        throw PommeGuestRecoverySecurityError.promptRejected
                    }
                case .unbound:
                    break
                }
                consume(transcript, delta: delta, through: range)
                state = .complete
                return credentials.password
            }
            if hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        case .complete:
            if PommeGuestPromptParsing.firstLine(
                in: delta,
                matching: PommeGuestPromptParsing.usernamePrompt
            ) != nil || PommeGuestPromptParsing.firstLine(in: delta, matching: { line in
                PommeGuestPromptParsing.passwordPrompt(line) != nil
            }) != nil || hasCredentialPrompt(in: delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        }
        return nil
    }

    var completed: Bool {
        if case .complete = state { return true }
        return false
    }

    private func hasCredentialPrompt(in text: String) -> Bool {
        PommeGuestPromptParsing.firstLine(
            in: text,
            matching: PommeGuestPromptParsing.hasCredentialPrompt
        ) != nil
    }

    private mutating func consume(
        _ transcript: String,
        delta: String,
        through range: Range<String.Index>
    ) {
        let consumed = delta.distance(from: delta.startIndex, to: range.upperBound)
        consumedCharacterCount += consumed
        consumedCharacterCount = min(consumedCharacterCount, transcript.count)
    }
}

@_silgen_name("fork")
private func pommeGuestFork() -> pid_t
