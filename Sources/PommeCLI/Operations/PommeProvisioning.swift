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
    case displayOnlyFirstNormalBoot
    case installRecoveryAgent
    case verifyNormalAgent
    case restoreFinalState
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

enum PommeProvisioningError: Error, Equatable, LocalizedError, Sendable {
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
    case phaseFailed(PommeProvisioningPhase, vmName: String? = nil)
    case unavailableIntegration(String)

    var errorDescription: String? {
        switch self {
        case .invalidPlan: "Pomme provisioning plan is not an accepted immutable profile."
        case .invalidOwnership: "Pomme VM ownership evidence is invalid."
        case .invalidAgent: "Pomme agent identity is invalid."
        case .invalidJournal: "Pomme provisioning journal is not a closed valid schema."
        case .integrityFailure: "Pomme provisioning journal integrity verification failed."
        case .generationFailure: "Pomme provisioning journal generation is stale or non-monotonic."
        case .unexpectedEvent: "Pomme provisioning journal has an invalid phase transition."
        case .ownershipMismatch: "The VM is not the exact Pomme-owned VM bound to this plan."
        case .nothingToRepair(let vmName):
            "Nothing to repair for \(vmName): agent provisioning is complete. Agent repair does not reconcile SIP or AMFI security transactions."
        case .repairUnavailable(let phase, let vmName):
            "Agent repair is unavailable during provisioning phase \(phase.rawValue). Resume creation with `pomme create \(vmName) --resume`."
        case .repairInterrupted(let phase, let vmName):
            "Agent repair cannot reconcile an interrupted \(phase.rawValue) intent for \(vmName). The VM and journal were retained; inspect `pomme agent status \(vmName)` and obtain recovery assistance before retrying."
        case .phaseFailed(let phase, let vmName):
            "\(vmName.map { "\($0) " } ?? "")provisioning phase \(phase.rawValue) failed; the VM and journal were retained."
        case .unavailableIntegration(let operation): "Pomme integration is unavailable for \(operation)."
        }
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
        if let error = error as? PommeFirstBootProcessError {
            switch error {
            case .invalidRequest: return "first_boot_process.invalid_request"
            case .capabilityRejected: return "first_boot_process.capability_rejected"
            case .identityRejected: return "first_boot_process.identity_rejected"
            case .spawnFailed: return "first_boot_process.spawn_failed"
            case .processCancelled: return "first_boot_process.cancelled"
            case .processTimedOut: return "first_boot_process.timed_out"
            case .processFailed: return "first_boot_process.worker_failed"
            case .invalidReceipt: return "first_boot_process.invalid_receipt"
            case .containmentFailed: return "first_boot_process.containment_failed"
            }
        }
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
            return "headless.\(error.code.rawValue)"
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
        try validate(events: journal.events)
        var completed = Set<PommeProvisioningPhase>()
        var attempts: [PommeProvisioningPhase: UInt64] = [:]
        for event in journal.events {
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
}

struct PommeProvisioningEffects: Sendable {
    let verifyOwnership: @Sendable (PommeVMOwnership) async throws -> PommeVMOwnership
    let install: @Sendable (PommeProvisioningPlan) async throws -> String
    let displayOnlyFirstNormalBoot: @Sendable (PommeProvisioningPlan) async throws -> String
    let installRecoveryAgent: @Sendable (PommeProvisioningPlan) async throws -> String
    let verifyNormalAgent: @Sendable (PommeProvisioningPlan) async throws -> String
    let restoreFinalState: @Sendable (PommeProvisioningPlan) async throws -> String
    let recoveryRepair: @Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String
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
        _ = try await exactOwnership(journal.plan.vm)
        while let next = try PommeProvisioningCoordinator.nextPhase(in: journal) {
            let intent = try PommeProvisioningCoordinator.appendingIntent(to: journal, phase: next.phase, attempt: next.attempt, signer: signer)
            try repository.commit(intent, replacing: journal.generation)
            journal = intent
            do {
                let receipt = try await effect(next.phase, plan: journal.plan)
                guard PommeProvisioningDigest.isSHA256(receipt) else { throw PommeProvisioningError.phaseFailed(next.phase) }
                let completed = try PommeProvisioningCoordinator.appendingResult(to: journal, kind: .receipt, phase: next.phase, attempt: next.attempt, receiptDigest: receipt, signer: signer)
                try repository.commit(completed, replacing: journal.generation)
                journal = completed
            } catch {
                PommeCore.log(
                    "provisioning phase \(next.phase.rawValue) failed "
                        + "[code=\(PommeProvisioningFailureDiagnostic.code(for: error))].",
                    vmName: journal.plan.vm.name
                )
                let digest = PommeProvisioningDigest.sha256(Data(String(describing: error).utf8))
                let failed = try PommeProvisioningCoordinator.appendingResult(to: journal, kind: .failure, phase: next.phase, attempt: next.attempt, receiptDigest: digest, signer: signer)
                try repository.commit(failed, replacing: journal.generation)
                throw PommeProvisioningError.phaseFailed(next.phase, vmName: journal.plan.vm.name)
            }
        }
    }

    func repair(finalState: PommeProvisioningFinalState) async throws {
        let journal = try repository.load()
        try journal.plan.validate()
        _ = try await exactOwnership(journal.plan.vm)
        let receipt = try await effects.recoveryRepair(journal.plan, finalState)
        guard PommeProvisioningDigest.isSHA256(receipt) else {
            throw PommeProvisioningError.phaseFailed(.installRecoveryAgent, vmName: journal.plan.vm.name)
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
        case .displayOnlyFirstNormalBoot: try await effects.displayOnlyFirstNormalBoot(plan)
        case .installRecoveryAgent: try await effects.installRecoveryAgent(plan)
        case .verifyNormalAgent: try await effects.verifyNormalAgent(plan)
        case .restoreFinalState: try await effects.restoreFinalState(plan)
        }
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
