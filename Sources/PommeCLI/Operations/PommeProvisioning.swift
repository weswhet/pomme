import CryptoKit
import Foundation

/// Closed, durable provisioning data.  It deliberately contains neither user
/// credentials nor mutable transport configuration.
struct PommeProvisioningPlan: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let vm: PommeVMOwnership
    let restore: PommeRestoreIdentity
    let display: PommeDisplayContract
    let profile: PommeRecoveryProfileContract
    let normalAgent: PommeAgentIdentity
    let recoveryAgent: PommeAgentIdentity
    let finalState: PommeProvisioningFinalState

    init(
        vm: PommeVMOwnership,
        restore: PommeRestoreIdentity,
        display: PommeDisplayContract,
        profile: PommeRecoveryProfileContract,
        normalAgent: PommeAgentIdentity,
        recoveryAgent: PommeAgentIdentity,
        finalState: PommeProvisioningFinalState
    ) throws {
        self.schema = Self.schemaVersion
        self.vm = vm
        self.restore = restore
        self.display = display
        self.profile = profile
        self.normalAgent = normalAgent
        self.recoveryAgent = recoveryAgent
        self.finalState = finalState
        try validate()
    }

    func validate() throws {
        guard schema == Self.schemaVersion,
              restore.isExact,
              display == .required,
              profile.isUsable(for: restore, display: display),
              normalAgent.role == .normal,
              recoveryAgent.role == .recovery,
              normalAgent.identifier != recoveryAgent.identifier
        else { throw PommeProvisioningError.invalidPlan }
    }

    var digest: String { PommeProvisioningDigest.sha256(try! PommeProvisioningCoding.encode(self)) }
}

struct PommeVMOwnership: Codable, Equatable, Sendable {
    static let provenance = "pomme-v1"

    let name: String
    let uuid: UUID
    let bundlePath: String
    let marker: String

    init(name: String, uuid: UUID, bundlePath: String, marker: String = provenance) throws {
        guard !name.isEmpty,
              !bundlePath.isEmpty,
              bundlePath.hasPrefix("/"),
              URL(fileURLWithPath: bundlePath).standardizedFileURL.path == bundlePath,
              marker == Self.provenance
        else { throw PommeProvisioningError.invalidOwnership }
        self.name = name
        self.uuid = uuid
        self.bundlePath = bundlePath
        self.marker = marker
    }
}

struct PommeRestoreIdentity: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let restoreImageDigest: String

    var isExact: Bool {
        PommeProvisioningDigest.isSHA256(restoreImageDigest)
            && !version.isEmpty && !build.isEmpty
    }
}

struct PommeDisplayContract: Codable, Equatable, Sendable {
    let locale: String
    let width: Int
    let height: Int

    static let required = Self(locale: "en", width: 1280, height: 800)
}

enum PommeProvisioningFinalState: String, Codable, Equatable, Sendable {
    case stopped
    case normalRunning
    case recoveryRunning
}

enum PommeProvisioningAgentRole: String, Codable, Equatable, Sendable { case normal, recovery }

struct PommeAgentIdentity: Codable, Equatable, Sendable {
    let identifier: String
    let executableDigest: String
    let protocolVersion: Int
    let role: PommeProvisioningAgentRole

    init(identifier: String, executableDigest: String, protocolVersion: Int = 1, role: PommeProvisioningAgentRole) throws {
        guard !identifier.isEmpty,
              PommeProvisioningDigest.isSHA256(executableDigest),
              protocolVersion == 1
        else { throw PommeProvisioningError.invalidAgent }
        self.identifier = identifier
        self.executableDigest = executableDigest
        self.protocolVersion = protocolVersion
        self.role = role
    }
}

/// The profile is closed here so planning cannot make a VM mutable before its
/// UI profile is selected. Reviewed Tahoe remains accepted; every other
/// descriptor is explicitly experimental and carries no review record.
struct PommeRecoveryProfileContract: Codable, Equatable, Sendable {
    enum Qualification: String, Codable, Equatable, Sendable {
        case accepted
        case externallyPending
        case experimental
    }

    let identifier: String
    let version: String
    let build: String
    let qualification: Qualification
    let reviewDigest: String

    static let tahoe = Self(
        identifier: "tahoe-26.6.0-25G72-en-1280x800",
        version: "26.6.0",
        build: "25G72",
        qualification: .accepted,
        reviewDigest: "a8a65ce3e53d4ef44847d3e656a0d1529c60eea42ff13a3fe68fdfc6a1e6c7e4"
    )
    static let sequoia = Self(
        identifier: "sequoia-15.6.1-24G90-en-1280x800",
        version: "15.6.1",
        build: "24G90",
        qualification: .externallyPending,
        reviewDigest: "6b8a6d0bf6710e7c10ee85f9af8a48a8e9fc073552cc8094a494172b7420b1e6"
    )

    /// Returns whether this contract is usable for the exact immutable restore
    /// and display identity. Experimental contracts are usable for bounded
    /// attempts only when they are the deterministic descriptor for that
    /// identity and have no review digest.
    func isUsable(for restore: PommeRestoreIdentity, display: PommeDisplayContract) -> Bool {
        guard display == .required,
              version == restore.version,
              build == restore.build
        else { return false }

        switch qualification {
        case .accepted:
            // Equality keeps the reviewed record closed: a caller cannot
            // forge acceptance by copying the Tahoe shape with a new build or
            // by supplying a different review digest.
            return self == Self.tahoe
        case .experimental:
            guard reviewDigest.isEmpty,
                  let descriptor = try? PommeRecoveryProfileSelector.descriptor(
                      version: restore.version,
                      build: restore.build
                  ),
                  descriptor.qualification == .experimental,
                  descriptor.id == identifier,
                  descriptor.version == version,
                  descriptor.build == build
            else { return false }
            return true
        case .externallyPending:
            // Kept solely so old encoded values decode. Pending records are
            // never usable as a durable plan; callers may convert a pending
            // descriptor through init(descriptor:), which deliberately emits
            // an explicit experimental contract with an empty review digest.
            return false
        }
    }

    /// Backwards-compatible spelling for callers that only need the reviewed
    /// Tahoe qualification. Experimental contracts are usable but are not
    /// accepted/reviewed records.
    func isAccepted(for restore: PommeRestoreIdentity, display: PommeDisplayContract) -> Bool {
        qualification == .accepted && isUsable(for: restore, display: display)
    }
}

extension PommeRecoveryProfileContract {
    /// Converts a selector descriptor into the durable profile contract. The
    /// descriptor is re-derived from its version/build before conversion so a
    /// caller cannot construct a new-build descriptor that falsely claims the
    /// reviewed Tahoe qualification.
    init(descriptor: PommeCreateRecoveryProfileDescriptor) throws {
        let canonical: PommeCreateRecoveryProfileDescriptor
        do {
            canonical = try PommeRecoveryProfileSelector.descriptor(
                version: descriptor.version,
                build: descriptor.build
            )
        } catch {
            throw PommeProvisioningError.invalidPlan
        }

        guard descriptor.id == canonical.id,
              descriptor.version == canonical.version,
              descriptor.build == canonical.build,
              descriptor.locale == canonical.locale,
              descriptor.displayWidth == canonical.displayWidth,
              descriptor.displayHeight == canonical.displayHeight
        else { throw PommeProvisioningError.invalidPlan }

        switch (descriptor.qualification, canonical.qualification) {
        case (.accepted, .accepted):
            self = .tahoe
        case (.experimental, .experimental), (.externallyPending, .experimental):
            self.init(
                identifier: canonical.id,
                version: canonical.version,
                build: canonical.build,
                qualification: .experimental,
                reviewDigest: ""
            )
        default:
            throw PommeProvisioningError.invalidPlan
        }
    }
}

enum PommeProvisioningPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case install
    case installRecoveryAgent
    case verifyNormalAgent
    case restoreFinalState

    /// The phase as a sentence subject, such as "Installing macOS".
    var displayName: String {
        switch self {
        case .install: "Installing macOS"
        case .installRecoveryAgent: "Installing the Pomme agent"
        case .verifyNormalAgent: "Verifying the Pomme agent"
        case .restoreFinalState: "Restoring the VM's final state"
        }
    }
}

struct PommeProvisioningEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable { case intent, receipt, failure }

    let kind: Kind
    let phase: PommeProvisioningPhase
    let attempt: UInt64
    let digest: String?

    init(kind: Kind, phase: PommeProvisioningPhase, attempt: UInt64, digest: String? = nil) throws {
        guard attempt > 0, digest.map(PommeProvisioningDigest.isSHA256) ?? true else {
            throw PommeProvisioningError.invalidJournal
        }
        self.kind = kind
        self.phase = phase
        self.attempt = attempt
        self.digest = digest
    }
}

struct PommeProvisioningJournal: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let generation: UInt64
    let plan: PommeProvisioningPlan
    let planDigest: String
    let events: [PommeProvisioningEvent]
    let integrity: String

    init(generation: UInt64, plan: PommeProvisioningPlan, events: [PommeProvisioningEvent], integrity: String) throws {
        guard generation > 0, plan.digest == PommeProvisioningDigest.normalized(planDigest: plan.digest),
              !integrity.isEmpty
        else { throw PommeProvisioningError.invalidJournal }
        self.schema = Self.schemaVersion
        self.generation = generation
        self.plan = plan
        self.planDigest = plan.digest
        self.events = events
        self.integrity = integrity
    }

    fileprivate struct Unsigned: Codable, Equatable {
        let schema: Int
        let generation: UInt64
        let plan: PommeProvisioningPlan
        let planDigest: String
        let events: [PommeProvisioningEvent]
    }

    fileprivate var unsigned: Unsigned { .init(schema: schema, generation: generation, plan: plan, planDigest: planDigest, events: events) }
}

enum PommeProvisioningError: Error, Equatable, PommeDescribedError, Sendable {
    case invalidPlan
    case invalidOwnership
    case invalidAgent
    case invalidJournal
    case integrityFailure
    case generationFailure
    case unexpectedEvent
    case ownershipMismatch
    case nothingToRepair(vmName: String)
    case repairUnavailable(phase: PommeProvisioningPhase, vmName: String)
    case repairInterrupted(phase: PommeProvisioningPhase, vmName: String)
    /// A phase failed after its intent was journaled. `cause` keeps the
    /// redacted reason, such as a full disk.
    case phaseFailed(PommeProvisioningPhase, vmName: String? = nil, cause: PommeErrorReport? = nil)
    case unavailableIntegration(String)

    var code: PommeErrorCode {
        switch self {
        case .invalidPlan: .provisioningPlanInvalid
        case .invalidOwnership, .ownershipMismatch: .provisioningOwnershipMismatch
        case .invalidAgent: .provisioningAgentInvalid
        case .invalidJournal, .unexpectedEvent: .provisioningJournalInvalid
        case .integrityFailure: .provisioningJournalIntegrityFailed
        case .generationFailure: .provisioningJournalStale
        case .nothingToRepair: .provisioningNothingToRepair
        case .repairUnavailable: .provisioningRepairUnavailable
        case .repairInterrupted: .provisioningPhaseInterrupted
        case .phaseFailed: .provisioningPhaseFailed
        case .unavailableIntegration: .provisioningIntegrationUnavailable
        }
    }

    var underlying: (any Error)? {
        if case .phaseFailed(_, _, let cause?) = self { return cause }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidPlan: "The VM's provisioning plan isn't one that this version of Pomme accepts."
        case .invalidOwnership: "The VM's ownership record isn't valid."
        case .invalidAgent: "The Pomme agent identity in the VM's provisioning plan isn't valid."
        case .invalidJournal: "The VM's provisioning journal isn't valid."
        case .integrityFailure: "Pomme couldn't verify the integrity of the VM's provisioning records."
        case .generationFailure: "The VM's provisioning journal is older than the last one that Pomme recorded, or another process changed it."
        case .unexpectedEvent: "The VM's provisioning journal records its steps in an order that isn't valid."
        case .ownershipMismatch: "The VM isn't the exact Pomme-owned VM that its provisioning plan names. It might have been moved, copied, or replaced."
        case .nothingToRepair(let vmName):
            "Nothing to repair for \(vmName): agent provisioning is complete. Agent repair does not reconcile SIP or AMFI security transactions."
        case .repairUnavailable(let phase, let vmName):
            "Agent repair can't continue the creation of \(vmName) at its current step "
                + "(\(SystemErrorDescription.lowercasingFirstWord(phase.displayName))). "
                + "Resume creation with `pomme create \(vmName) --resume`."
        case .repairInterrupted(let phase, let vmName):
            "\(phase.displayName) was interrupted for \(vmName), and agent repair can't reconcile an interrupted step. "
                + "The VM and journal were retained; inspect `pomme agent status \(vmName)` and obtain recovery assistance before retrying."
        case .phaseFailed(let phase, let vmName, let cause):
            phase.displayName + " failed"
                + (vmName.map { " for \($0)" } ?? "")
                + (cause.map { ": \(PommeErrorDescriber.clause(for: $0))" } ?? "")
                + ". The VM and journal were retained."
        case .unavailableIntegration(let operation):
            "Pomme can't continue because a component that it needs isn't available: \(operation)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .phaseFailed(_, let vmName, let cause):
            if let hint = cause?.hint {
                "\(hint) To continue creating the VM, run `pomme create \(vmName ?? "NAME") --resume`."
            } else {
                "Correct the cause, then run `pomme create \(vmName ?? "NAME") --resume` to continue."
            }
        case .ownershipMismatch, .invalidOwnership, .invalidJournal, .unexpectedEvent, .integrityFailure:
            "Delete the VM with `pomme delete NAME --force`, then create it again. Pomme keeps the VM's Keychain items when it can't prove which VM the bundle is."
        case .generationFailure:
            "Make sure that no other Pomme command is using the VM, then retry."
        default:
            nil
        }
    }
}

extension PommeProvisioningError {
    /// The cause to keep for a failed phase. A bare `phaseFailed` that a
    /// phase threw itself adds nothing, so it keeps that one's cause instead.
    static func phaseCause(of error: any Error) -> PommeErrorReport? {
        if case .phaseFailed(_, _, let cause)? = error as? PommeProvisioningError { return cause }
        return PommeErrorReport(keepingSystemCause: error)
    }
}

extension PommeErrorReport {
    /// A report for a cause that a wrapping error stores. When `error` is
    /// itself an operating-system or framework error, its domain and number
    /// become the first cause, so the wrapping message reads, for example,
    /// "the disk is out of space (VZErrorDomain 8)". With `codesOnly`, the
    /// report keeps only codes, for an error whose text might contain
    /// credentials.
    init(keepingSystemCause error: any Error, codesOnly: Bool = false) {
        // `PommeErrorReport` already keeps a framework error's own domain and
        // number as its first cause.
        self = codesOnly ? PommeErrorReport(codesOnly: error) : PommeErrorReport(error)
    }
}

enum PommeProvisioningDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    static func normalized(planDigest: String) -> String { planDigest.lowercased() }
}

enum PommeProvisioningCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Redacted, stable failure codes for the durable provisioning boundary.
/// The journal continues to retain only a digest; host diagnostics get a
/// useful category without paths, payloads, credentials, or framework text.
enum PommeProvisioningFailureDiagnostic {
    static func code(for error: Error) -> String {
        if let error = error as? PommeLiveRecoveryIntegration.Error {
            switch error {
            case .unsupportedOperation: return "live_recovery.unsupported_operation"
            case .invalidDependencies: return "live_recovery.invalid_dependencies"
            case .ownershipMismatch: return "live_recovery.ownership_mismatch"
            case .executableMismatch: return "live_recovery.executable_mismatch"
            case .requestBindingRejected: return "live_recovery.request_binding_rejected"
            case .credentialRejected: return "live_recovery.credential_rejected"
            case .launcherRejected: return "live_recovery.launcher_rejected"
            case .runtimeRejected: return "live_recovery.runtime_rejected"
            case .guestRejected: return "live_recovery.guest_rejected"
            case .cleanupFailed: return "live_recovery.cleanup_failed"
            }
        }
        if let error = error as? PommeRecoveryRuntimeError {
            switch error {
            case .requestBindingRejected: return "recovery_runtime.request_binding_rejected"
            case .recoveryBootRequired: return "recovery_runtime.recovery_boot_required"
            case .attachmentConflict: return "recovery_runtime.attachment_conflict"
            case .attachmentNotApplied: return "recovery_runtime.attachment_not_applied"
            case .attachmentUnverified: return "recovery_runtime.attachment_unverified"
            case .invalidListener: return "recovery_runtime.invalid_listener"
            case .listenerAuthenticationRejected: return "recovery_runtime.authentication_rejected"
            case .listenerAuthenticationTimedOut: return "recovery_runtime.authentication_timed_out"
            case .helperExited: return "recovery_runtime.helper_exited"
            case .invalidLifecycle: return "recovery_runtime.invalid_lifecycle"
            case .cleanupMismatch: return "recovery_runtime.cleanup_mismatch"
            }
        }
        if let error = error as? PommeRecoverySessionError {
            switch error {
            case .invalidRequest: return "recovery_session.invalid_request"
            case .expiredCredential: return "recovery_session.expired_credential"
            case .invalidCredential: return "recovery_session.invalid_credential"
            case .invalidProof: return "recovery_session.invalid_proof"
            case .replayedCredential: return "recovery_session.replayed_credential"
            case .requestMismatch: return "recovery_session.request_mismatch"
            case .notPrepared: return "recovery_session.not_prepared"
            case .unauthenticated: return "recovery_session.unauthenticated"
            case .invalidLifecycle: return "recovery_session.invalid_lifecycle"
            case .observationTimedOut: return "recovery_session.observation_timed_out"
            case .terminalProofFailed: return "recovery_session.terminal_proof_failed"
            case .rootEvidenceRejected: return "recovery_session.root_evidence_rejected"
            case .preparationFailed: return "recovery_session.preparation_failed"
            case .guestOperationFailed: return "recovery_session.guest_operation_failed"
            case .cleanupFailed: return "recovery_session.cleanup_failed"
            case .finalStateUnverified: return "recovery_session.final_state_unverified"
            }
        }
        if let error = error as? VirtualizationPrivateHeadlessError {
            return "headless.\(error.kind.rawValue)"
        }

        let bridged = error as NSError
        switch bridged.domain {
        case "VZErrorDomain": return "virtualization.\(bridged.code)"
        case NSPOSIXErrorDomain: return "posix.\(bridged.code)"
        case NSCocoaErrorDomain: return "cocoa.\(bridged.code)"
        case NSOSStatusErrorDomain: return "osstatus.\(bridged.code)"
        default: return "internal.unknown"
        }
    }
}

struct PommeProvisioningJournalSigner: Sendable {
    private let key: SymmetricKey

    init(key: Data) throws {
        guard key.count >= 32 else { throw PommeProvisioningError.integrityFailure }
        self.key = SymmetricKey(data: key)
    }

    fileprivate func sign(_ unsigned: PommeProvisioningJournal.Unsigned) throws -> String {
        let data = try PommeProvisioningCoding.encode(unsigned)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64EncodedString()
    }

    func verify(_ journal: PommeProvisioningJournal) throws {
        guard journal.schema == PommeProvisioningJournal.schemaVersion,
              journal.plan.digest == journal.planDigest,
              let integrity = Data(base64Encoded: journal.integrity),
              HMAC<SHA256>.isValidAuthenticationCode(integrity, authenticating: try PommeProvisioningCoding.encode(journal.unsigned), using: key)
        else { throw PommeProvisioningError.integrityFailure }
        try journal.plan.validate()
        try PommeProvisioningCoordinator.validate(events: journal.events)
    }

    func make(generation: UInt64, plan: PommeProvisioningPlan, events: [PommeProvisioningEvent]) throws -> PommeProvisioningJournal {
        let unsigned = PommeProvisioningJournal.Unsigned(
            schema: PommeProvisioningJournal.schemaVersion,
            generation: generation,
            plan: plan,
            planDigest: plan.digest,
            events: events
        )
        return try .init(generation: generation, plan: plan, events: events, integrity: sign(unsigned))
    }
}

protocol PommeProvisioningJournalRepository: AnyObject, Sendable {
    func create(_ journal: PommeProvisioningJournal) throws
    func load() throws -> PommeProvisioningJournal
    func commit(_ journal: PommeProvisioningJournal, replacing generation: UInt64) throws
}

/// A file journal is deliberately paired with a host-provided secure monotonic
/// counter.  Core owns the Keychain/host integration; this type owns the
/// closed encoding, HMAC checks, atomic journal replacement, and ordering.
final class PommeProvisioningFileJournalRepository: PommeProvisioningJournalRepository, @unchecked Sendable {
    private let journalURL: URL
    private let signer: PommeProvisioningJournalSigner
    private let loadHighWater: @Sendable () throws -> UInt64
    private let advanceHighWater: @Sendable (UInt64, UInt64) throws -> Void

    init(
        bundleURL: URL,
        signer: PommeProvisioningJournalSigner,
        loadHighWater: @escaping @Sendable () throws -> UInt64,
        advanceHighWater: @escaping @Sendable (UInt64, UInt64) throws -> Void
    ) {
        journalURL = bundleURL.appendingPathComponent(".pomme/provisioning-v1.json")
        self.signer = signer
        self.loadHighWater = loadHighWater
        self.advanceHighWater = advanceHighWater
    }

    func create(_ journal: PommeProvisioningJournal) throws {
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw PommeProvisioningError.generationFailure }
        try validate(journal, minimumGeneration: 0)
        try write(journal, createOnly: true)
        try advanceHighWater(0, journal.generation)
    }

    func load() throws -> PommeProvisioningJournal {
        let journal = try decode()
        try validate(journal, minimumGeneration: try loadHighWater())
        return journal
    }

    func commit(_ journal: PommeProvisioningJournal, replacing generation: UInt64) throws {
        let current = try load()
        guard current.generation == generation, journal.generation == generation + 1 else {
            throw PommeProvisioningError.generationFailure
        }
        try validate(journal, minimumGeneration: current.generation)
        try write(journal, createOnly: false)
        try advanceHighWater(current.generation, journal.generation)
    }

    private func validate(_ journal: PommeProvisioningJournal, minimumGeneration: UInt64) throws {
        guard journal.generation >= minimumGeneration else { throw PommeProvisioningError.generationFailure }
        try signer.verify(journal)
    }

    private func decode() throws -> PommeProvisioningJournal {
        guard let data = try? Data(contentsOf: journalURL), data.count <= 4 * 1024 * 1024 else {
            throw PommeProvisioningError.invalidJournal
        }
        return try JSONDecoder().decode(PommeProvisioningJournal.self, from: data)
    }

    private func write(_ journal: PommeProvisioningJournal, createOnly: Bool) throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if createOnly, FileManager.default.fileExists(atPath: journalURL.path) { throw PommeProvisioningError.generationFailure }
        try PommeProvisioningCoding.encode(journal).write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
}

enum PommeProvisioningCoordinator {
    static func validate(events: [PommeProvisioningEvent]) throws {
        var lastPhase = -1
        var pending: (phase: PommeProvisioningPhase, attempt: UInt64)?
        for event in events {
            let index = PommeProvisioningPhase.allCases.firstIndex(of: event.phase)!
            switch event.kind {
            case .intent:
                guard pending == nil, index == lastPhase + 1 || index == lastPhase,
                      event.attempt > 0
                else { throw PommeProvisioningError.unexpectedEvent }
                pending = (event.phase, event.attempt)
            case .receipt, .failure:
                guard let activeIntent = pending,
                      activeIntent.phase == event.phase,
                      activeIntent.attempt == event.attempt
                else {
                    throw PommeProvisioningError.unexpectedEvent
                }
                if event.kind == .receipt { lastPhase = index }
                pending = nil
            }
        }
    }

    static func nextPhase(in journal: PommeProvisioningJournal) throws -> (phase: PommeProvisioningPhase, attempt: UInt64)? {
        try nextPhase(events: journal.events)
    }

    private static func nextPhase(events: [PommeProvisioningEvent]) throws -> (phase: PommeProvisioningPhase, attempt: UInt64)? {
        try validate(events: events)
        var completed = Set<PommeProvisioningPhase>()
        var attempts: [PommeProvisioningPhase: UInt64] = [:]
        for event in events {
            attempts[event.phase] = max(attempts[event.phase] ?? 0, event.attempt)
            if event.kind == .receipt { completed.insert(event.phase) }
        }
        guard let phase = PommeProvisioningPhase.allCases.first(where: { !completed.contains($0) }) else { return nil }
        return (phase, (attempts[phase] ?? 0) + 1)
    }

    /// Classify valid journals before capturing runtime state or starting Recovery.
    static func repairPhase(in journal: PommeProvisioningJournal) throws -> (phase: PommeProvisioningPhase, attempt: UInt64) {
        guard let next = try nextPhase(in: journal) else {
            throw PommeProvisioningError.nothingToRepair(vmName: journal.plan.vm.name)
        }
        guard journal.events.last?.kind != .intent else {
            throw PommeProvisioningError.repairInterrupted(phase: next.phase, vmName: journal.plan.vm.name)
        }
        guard next.phase == .installRecoveryAgent else {
            throw PommeProvisioningError.repairUnavailable(phase: next.phase, vmName: journal.plan.vm.name)
        }
        return next
    }

    static func appendingIntent(to journal: PommeProvisioningJournal, phase: PommeProvisioningPhase, attempt: UInt64, signer: PommeProvisioningJournalSigner) throws -> PommeProvisioningJournal {
        guard let expected = try nextPhase(in: journal), expected.phase == phase, expected.attempt == attempt else {
            throw PommeProvisioningError.unexpectedEvent
        }
        return try signer.make(generation: journal.generation + 1, plan: journal.plan, events: journal.events + [.init(kind: .intent, phase: phase, attempt: attempt)])
    }

    static func appendingResult(to journal: PommeProvisioningJournal, kind: PommeProvisioningEvent.Kind, phase: PommeProvisioningPhase, attempt: UInt64, receiptDigest: String, signer: PommeProvisioningJournalSigner) throws -> PommeProvisioningJournal {
        guard kind == .receipt || kind == .failure,
              journal.events.last?.kind == .intent,
              journal.events.last?.phase == phase,
              journal.events.last?.attempt == attempt
        else { throw PommeProvisioningError.unexpectedEvent }
        return try signer.make(generation: journal.generation + 1, plan: journal.plan, events: journal.events + [.init(kind: kind, phase: phase, attempt: attempt, digest: receiptDigest)])
    }

    /// Appends the receipt for the pending intent and, in the same
    /// generation, an intent and receipt for each phase in `completing`,
    /// which must be the phases that follow it in order. An effect that
    /// already proved a later phase records that proof this way: a single
    /// commit can't leave behind an intent that `create --resume` won't
    /// re-execute.
    static func appendingReceipt(
        to journal: PommeProvisioningJournal,
        phase: PommeProvisioningPhase,
        attempt: UInt64,
        receiptDigest: String,
        completing following: [PommeProvisioningPhase],
        signer: PommeProvisioningJournalSigner
    ) throws -> PommeProvisioningJournal {
        guard journal.events.last?.kind == .intent,
              journal.events.last?.phase == phase,
              journal.events.last?.attempt == attempt
        else { throw PommeProvisioningError.unexpectedEvent }
        var events = journal.events + [try .init(kind: .receipt, phase: phase, attempt: attempt, digest: receiptDigest)]
        for next in following {
            guard let expected = try nextPhase(events: events), expected.phase == next else {
                throw PommeProvisioningError.unexpectedEvent
            }
            events += [
                try .init(kind: .intent, phase: next, attempt: expected.attempt),
                try .init(kind: .receipt, phase: next, attempt: expected.attempt, digest: receiptDigest),
            ]
        }
        return try signer.make(generation: journal.generation + 1, plan: journal.plan, events: events)
    }
}

struct PommeProvisioningEffects: Sendable {
    let verifyOwnership: @Sendable (PommeVMOwnership) async throws -> PommeVMOwnership
    let install: @Sendable (PommeProvisioningPlan) async throws -> String
    let installRecoveryAgent: @Sendable (PommeProvisioningPlan) async throws -> String
    let verifyNormalAgent: @Sendable (PommeProvisioningPlan) async throws -> String
    let restoreFinalState: @Sendable (PommeProvisioningPlan) async throws -> String
    let recoveryRepair: @Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String
    /// The agent-installation phase in normal macOS for a VM cloned from a
    /// provisioned template whose agent credential the host kept. Returns
    /// nil when that doesn't apply, and the phase continues below.
    var adoptTemplateAgent: @Sendable (PommeProvisioningPlan) async throws -> String? = { _ in nil }
    /// Proves, in normal macOS, an agent that an earlier installation attempt
    /// left in the guest. Returns nil when there's no evidence of one or it
    /// doesn't prove itself, and the Recovery installation runs instead.
    var probeInstalledAgent: @Sendable (PommeProvisioningPlan) async throws -> String? = { _ in nil }
    /// `agent repair` in normal macOS: the adoption or the check above,
    /// followed by verification and the requested final state. Returns nil
    /// when neither applies, and `recoveryRepair` runs instead.
    var repairInNormalBoot: @Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String? = { _, _ in nil }
}

/// `repairInNormalBoot` installed and verified the agent, and only the
/// requested final state failed. The repair records the proven phases and
/// reports the final state's failure instead of reinstalling through
/// Recovery.
struct PommeAgentRepairFinalStateFailure: Error, PommeDescribedError {
    let receipt: String
    let cause: any Error

    var code: PommeErrorCode { .provisioningPhaseFailed }
    var underlying: (any Error)? { cause }
    var errorDescription: String? {
        "The Pomme agent was repaired, but restoring the VM's previous state failed: \(PommeErrorDescriber.clause(for: cause))."
    }
}

/// How `agent repair` reinstalled or proved the agent.
enum PommeAgentRepairRoute: String, Equatable, Sendable {
    case normal
    case recovery
}

struct PommeProvisioningOrchestrator: Sendable {
    let signer: PommeProvisioningJournalSigner
    let repository: any PommeProvisioningJournalRepository
    let effects: PommeProvisioningEffects

    func start(_ plan: PommeProvisioningPlan) async throws {
        try plan.validate() // Closed profile preflight before any effect.
        _ = try await exactOwnership(plan.vm)
        let initial = try signer.make(generation: 1, plan: plan, events: [])
        try repository.create(initial)
        try await resume(expectedPlan: plan)
    }

    func resume(expectedPlan: PommeProvisioningPlan? = nil) async throws {
        var journal = try repository.load()
        if let expectedPlan, journal.plan != expectedPlan { throw PommeProvisioningError.invalidPlan }
        try journal.plan.validate()
        try PommeProvisioningCoordinator.validate(events: journal.events)
        _ = try await exactOwnership(journal.plan.vm)
        if let pending = journal.events.last, pending.kind == .intent {
            guard pending.phase == .installRecoveryAgent || pending.phase == .restoreFinalState else {
                throw PommeProvisioningError.unexpectedEvent
            }
            journal = try await executeEffect(
                phase: pending.phase,
                attempt: pending.attempt,
                in: journal
            )
        }
        while let next = try PommeProvisioningCoordinator.nextPhase(in: journal) {
            let intent = try PommeProvisioningCoordinator.appendingIntent(to: journal, phase: next.phase, attempt: next.attempt, signer: signer)
            try repository.commit(intent, replacing: journal.generation)
            journal = intent
            journal = try await executeEffect(
                phase: next.phase,
                attempt: next.attempt,
                in: journal
            )
        }
    }

    private func executeEffect(
        phase: PommeProvisioningPhase,
        attempt: UInt64,
        in journal: PommeProvisioningJournal
    ) async throws -> PommeProvisioningJournal {
        let label: String
        switch phase {
        case .install: label = "Preparing macOS installation"
        case .installRecoveryAgent: label = "Bootstrapping Pomme agent for normal boot"
        case .verifyNormalAgent: label = "Verifying Pomme agent in normal macOS"
        case .restoreFinalState: label = "Restoring requested VM state"
        }
        PommeProgressContext.sink?.step(vm: journal.plan.vm.name, label)
        do {
            let receipt = try await effect(phase, plan: journal.plan)
            guard PommeProvisioningDigest.isSHA256(receipt) else {
                throw PommeProvisioningError.phaseFailed(phase)
            }
            let completed = try PommeProvisioningCoordinator.appendingResult(
                to: journal,
                kind: .receipt,
                phase: phase,
                attempt: attempt,
                receiptDigest: receipt,
                signer: signer
            )
            try repository.commit(completed, replacing: journal.generation)
            return completed
        } catch {
            PommeCore.log(
                "provisioning phase \(phase.rawValue) failed "
                    + "[code=\(PommeProvisioningFailureDiagnostic.code(for: error))].",
                vmName: journal.plan.vm.name
            )
            let digest = PommeProvisioningDigest.sha256(Data(String(describing: error).utf8))
            let failed = try PommeProvisioningCoordinator.appendingResult(
                to: journal,
                kind: .failure,
                phase: phase,
                attempt: attempt,
                receiptDigest: digest,
                signer: signer
            )
            try repository.commit(failed, replacing: journal.generation)
            throw PommeProvisioningError.phaseFailed(
                phase,
                vmName: journal.plan.vm.name,
                cause: PommeProvisioningError.phaseCause(of: error)
            )
        }
    }

    func repair(finalState: PommeProvisioningFinalState) async throws {
        let journal = try repository.load()
        try journal.plan.validate()
        _ = try await exactOwnership(journal.plan.vm)
        PommeProgressContext.sink?.step(vm: journal.plan.vm.name, "Repairing Pomme agent in Recovery")
        let receipt = try await effects.recoveryRepair(journal.plan, finalState)
        guard PommeProvisioningDigest.isSHA256(receipt) else {
            throw PommeProvisioningError.phaseFailed(.installRecoveryAgent, vmName: journal.plan.vm.name)
        }
    }

    /// `pomme agent repair` for a creation stopped at the agent-installation
    /// phase that `PommeProvisioningCoordinator.repairPhase` returned. The
    /// intent is journaled before any effect. Normal macOS is tried first;
    /// when it doesn't apply or fails, the Recovery repair runs exactly as
    /// before. Both routes verify the pinned agent in normal macOS before
    /// they return, so the verification phase is journaled with the
    /// installation's receipt, in one commit, and a later `create --resume`
    /// continues with the final state.
    func repairAgentInstallation(
        from journal: PommeProvisioningJournal,
        phase next: (phase: PommeProvisioningPhase, attempt: UInt64),
        finalState: PommeProvisioningFinalState
    ) async throws -> PommeAgentRepairRoute {
        let intent = try PommeProvisioningCoordinator.appendingIntent(
            to: journal, phase: next.phase, attempt: next.attempt, signer: signer)
        try repository.commit(intent, replacing: journal.generation)
        let vmName = intent.plan.vm.name
        var provenWithoutFinalState: PommeAgentRepairFinalStateFailure?
        do {
            var route = PommeAgentRepairRoute.normal
            var receipt: String?
            do {
                receipt = try await effects.repairInNormalBoot(intent.plan, finalState)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as PommeAgentRepairFinalStateFailure {
                provenWithoutFinalState = failure
                throw failure
            } catch {
                PommeCore.warning(
                    "repairing the agent in normal macOS failed "
                        + "[code=\(PommeProvisioningFailureDiagnostic.code(for: error))]; repairing it through Recovery.",
                    vmName: vmName)
            }
            if receipt == nil {
                route = .recovery
                PommeProgressContext.sink?.step(vm: vmName, "Repairing Pomme agent in Recovery")
                receipt = try await effects.recoveryRepair(intent.plan, finalState)
            }
            guard let receipt, PommeProvisioningDigest.isSHA256(receipt) else {
                throw PommeProvisioningError.phaseFailed(next.phase)
            }
            let completed = try PommeProvisioningCoordinator.appendingReceipt(
                to: intent, phase: next.phase, attempt: next.attempt, receiptDigest: receipt,
                completing: [.verifyNormalAgent], signer: signer)
            try repository.commit(completed, replacing: intent.generation)
            return route
        } catch {
            if let failure = provenWithoutFinalState {
                // The agent is installed and verified in normal macOS; a
                // Recovery reinstall wouldn't fix the final state. Record the
                // proof and report the final state's failure, which
                // `create --resume` restores later.
                let completed = try PommeProvisioningCoordinator.appendingReceipt(
                    to: intent, phase: next.phase, attempt: next.attempt, receiptDigest: failure.receipt,
                    completing: [.verifyNormalAgent], signer: signer)
                try repository.commit(completed, replacing: intent.generation)
                throw PommeProvisioningError.phaseFailed(
                    .restoreFinalState, vmName: vmName, cause: PommeErrorReport(keepingSystemCause: failure.cause))
            }
            // Repair reports the same redacted failure code the orchestrator
            // logs, so the command that exists to diagnose a retained journal
            // does not say strictly less than `create --resume` about the same
            // failure.
            PommeCore.warning(
                "provisioning phase \(next.phase.rawValue) failed "
                    + "[code=\(PommeProvisioningFailureDiagnostic.code(for: error))].",
                vmName: vmName
            )
            let digest = PommeProvisioningDigest.sha256(Data(String(describing: error).utf8))
            let failed = try PommeProvisioningCoordinator.appendingResult(
                to: intent, kind: .failure, phase: next.phase, attempt: next.attempt,
                receiptDigest: digest, signer: signer)
            try repository.commit(failed, replacing: intent.generation)
            throw PommeProvisioningError.phaseFailed(
                next.phase, vmName: vmName, cause: PommeProvisioningError.phaseCause(of: error))
        }
    }

    private func exactOwnership(_ expected: PommeVMOwnership) async throws -> PommeVMOwnership {
        let actual = try await effects.verifyOwnership(expected)
        guard actual == expected, actual.marker == PommeVMOwnership.provenance else {
            throw PommeProvisioningError.ownershipMismatch
        }
        return actual
    }

    private func effect(_ phase: PommeProvisioningPhase, plan: PommeProvisioningPlan) async throws -> String {
        switch phase {
        case .install: try await effects.install(plan)
        case .installRecoveryAgent: try await installAgent(plan)
        case .verifyNormalAgent: try await effects.verifyNormalAgent(plan)
        case .restoreFinalState: try await effects.restoreFinalState(plan)
        }
    }

    /// The agent-installation phase boots Recovery only when it has to: a
    /// provisioned template's clone gets its template's agent in normal
    /// macOS, and an agent that an earlier attempt already installed is
    /// proven in normal macOS. The phase keeps its journal name, so
    /// journals and resume work the same on every route.
    private func installAgent(_ plan: PommeProvisioningPlan) async throws -> String {
        do {
            if let adopted = try await effects.adoptTemplateAgent(plan) { return adopted }
        } catch let error as PommeTemplateAgentAdoptionError where error.isAgentUnavailable {
            // The template's agent never authenticated, so nothing reached
            // the guest, and the adoption withdrew its lease and stopped the
            // VM. Converge through Recovery instead of failing creation.
            PommeCore.warning(
                "the agent from the template didn't connect in normal macOS; installing it through Recovery.",
                vmName: plan.vm.name)
        }
        if let proven = try await effects.probeInstalledAgent(plan) { return proven }
        return try await effects.installRecoveryAgent(plan)
    }
}

enum PommeAgentRepairFinalState: String, Codable, Equatable, Sendable { case previous }

struct PommeAgentClosedStatus: Codable, Equatable, Sendable {
    enum Connection: String, Codable, Equatable, Sendable { case disconnected, connected }
    let connection: Connection
    let role: PommeProvisioningAgentRole
    let protocolVersion: Int
    let executableDigest: String
    let capabilities: [String]
    let updateState: String
}

struct PommeProvisioningApplicationServices: Sendable {
    let resume: @Sendable (String) async throws -> PommeOperationResult
    let agentStatus: @Sendable (String) async throws -> PommeAgentClosedStatus
    let agentRepair: @Sendable (String, PommeAgentRepairFinalState) async throws -> PommeOperationResult

    static let unavailable = Self(
        resume: { _ in throw PommeProvisioningError.unavailableIntegration("create resume") },
        agentStatus: { _ in throw PommeProvisioningError.unavailableIntegration("agent status") },
        agentRepair: { _, _ in throw PommeProvisioningError.unavailableIntegration("agent repair") }
    )
}
