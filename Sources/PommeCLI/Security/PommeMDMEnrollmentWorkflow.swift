import CryptoKit
import Darwin
import Foundation

/// Durable, redacted cursor for one host-managed MDM enrollment.  It never
/// records profile bytes, host paths, account names, credentials, or helper
/// request bodies.  Security workflows retain their own Recovery receipts;
/// this cursor binds their use to the MDM request and owns only the MDM
/// artifacts and restoration ordering.
enum PommeMDMEnrollmentPhase: String, Codable, CaseIterable, Sendable {
    case captured
    case existingEnrollmentChecked
    case securityPreparationIntent
    case securityPrepared
    case enrollmentIntent
    case enrollmentVerified
    case approvalIntent
    case approvalVerified
    case postEnrollmentEvidenceVerified
    case securityRestorationIntent
    case securityRestored
    case runStateRestorationIntent
    case restorationComplete

    fileprivate var index: Int { Self.allCases.firstIndex(of: self)! }
}

enum PommeMDMEnrollmentFailure: String, Codable, Sendable {
    case beforeDispatch
    case beforeIdentityImport
    case outcomeUnknown
    case restoration
}

struct PommeMDMEnrollmentJournal: Codable, Equatable, Sendable {
    static let schemaVersion = 6

    let schema: Int
    let generation: UInt64
    let identity: PommeSecurityWorkflowIdentity
    /// Exact source identity (identifier, UUID, server, and digest) needed to
    /// distinguish a profile replacement from a safe resume.
    let profile: MDMEnrollmentProfileIdentity
    let agentSHA256: String
    let enrollmentMode: MDMEnrollmentMode
    /// Schema 5 and earlier journals decode as `.restore`, their only behavior.
    let finalSecurity: MDMFinalSecurity
    let originalRunState: VMRunStateSnapshot
    /// Captured only after the intent journal is durable. A stopped, paused,
    /// or Recovery VM must never be booted merely to populate these fields
    /// before the cursor exists.
    let sipWasDisabled: Bool?
    let amfiWasDisabled: Bool?
    let pendingChild: PommeSecurityWorkflowOperation?
    let sipChangeRequested: Bool
    let amfiChangeRequested: Bool
    let enrollmentDispatched: Bool
    let enrollmentVerified: Bool
    let normalBootArguments: Data?
    /// Canonical JSON `null` when `boot-args` was absent, or a canonical JSON
    /// Base64 string when it was present. `nil` means capture has not run.
    let configuredBootArguments: Data?
    let helperTerminationUnproven: Bool
    /// Redacted failure disposition; the phase remains at the failed operation.
    let failure: PommeMDMEnrollmentFailure?
    /// Set before transferring a profile into an operation-owned guest path.
    /// Once true, cleanup may remove that path; a caller-provided path is
    /// never inferred to be owned by this journal.
    let stagedProfileOwned: Bool
    /// Guest-only, operation-generated artifact paths. A retained artifact is
    /// deliberately not unlinked when helper termination cannot be proven.
    let ownedArtifacts: [String]
    let phase: PommeMDMEnrollmentPhase
    let profileIdentifier: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        generation: UInt64,
        identity: PommeSecurityWorkflowIdentity,
        profile: MDMEnrollmentProfileIdentity,
        agentSHA256: String,
        enrollmentMode: MDMEnrollmentMode,
        finalSecurity: MDMFinalSecurity = .restore,
        originalRunState: VMRunStateSnapshot,
        sipWasDisabled: Bool? = nil,
        amfiWasDisabled: Bool? = nil,
        pendingChild: PommeSecurityWorkflowOperation? = nil,
        sipChangeRequested: Bool = false,
        amfiChangeRequested: Bool = false,
        enrollmentDispatched: Bool = false,
        enrollmentVerified: Bool = false,
        normalBootArguments: Data? = nil,
        configuredBootArguments: Data? = nil,
        helperTerminationUnproven: Bool = false,
        stagedProfileOwned: Bool = false,
        failure: PommeMDMEnrollmentFailure? = nil,
        ownedArtifacts: [String],
        phase: PommeMDMEnrollmentPhase,
        profileIdentifier: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard generation > 0,
              identity.isWellFormed(),
              Self.isProfile(profile),
              Self.isDigest(agentSHA256),
              Self.areSafeArtifacts(ownedArtifacts),
              Self.isSafeProfileIdentifier(profileIdentifier),
              Self.phaseAllowsSecurityBaseline(
                phase, sipWasDisabled: sipWasDisabled, amfiWasDisabled: amfiWasDisabled
              ),
              Self.areCapturedBootArguments(
                normal: normalBootArguments, configured: configuredBootArguments
              ),
              updatedAt >= createdAt,
              Self.phaseAllowsIdentifier(phase, profileIdentifier: profileIdentifier) else {
            throw PommeMDMEnrollmentWorkflowError.malformedJournal
        }
        let createdAt = Self.canonicalDate(createdAt)
        let updatedAt = Self.canonicalDate(updatedAt)
        guard updatedAt >= createdAt else { throw PommeMDMEnrollmentWorkflowError.malformedJournal }
        schema = Self.schemaVersion
        self.generation = generation
        self.identity = identity
        self.profile = profile
        self.agentSHA256 = agentSHA256.lowercased()
        self.enrollmentMode = enrollmentMode
        self.finalSecurity = finalSecurity
        self.originalRunState = originalRunState
        self.sipWasDisabled = sipWasDisabled
        self.amfiWasDisabled = amfiWasDisabled
        self.pendingChild = pendingChild
        self.sipChangeRequested = sipChangeRequested
        self.amfiChangeRequested = amfiChangeRequested
        self.enrollmentDispatched = enrollmentDispatched
        self.enrollmentVerified = enrollmentVerified
        self.normalBootArguments = normalBootArguments
        self.configuredBootArguments = configuredBootArguments
        self.helperTerminationUnproven = helperTerminationUnproven
        self.stagedProfileOwned = stagedProfileOwned
        self.failure = failure
        self.ownedArtifacts = ownedArtifacts.sorted()
        self.phase = phase
        self.profileIdentifier = profileIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, generation, identity, profile, agentSHA256, enrollmentMode, finalSecurity
        case originalRunState, sipWasDisabled, amfiWasDisabled, pendingChild, sipChangeRequested, amfiChangeRequested
        case enrollmentDispatched, enrollmentVerified, normalBootArguments, configuredBootArguments
        case helperTerminationUnproven, stagedProfileOwned, ownedArtifacts, phase, failure
        case profileIdentifier, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: MDMJournalCodingKey.self)
        let keys = Set(raw.allKeys.map(\.stringValue))
        let version = try raw.decode(Int.self, forKey: MDMJournalCodingKey(stringValue: "schema")!)
        let currentKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let schema5Keys = currentKeys.subtracting([CodingKeys.finalSecurity.stringValue])
        let schema4Keys = schema5Keys.subtracting([CodingKeys.failure.stringValue])
        let schema3Keys = schema4Keys.subtracting([CodingKeys.stagedProfileOwned.stringValue])
        guard (version == Self.schemaVersion && keys == currentKeys)
                || (version == 5 && keys == schema5Keys)
                || (version == 4 && keys == schema4Keys)
                || (version == 3 && keys == schema3Keys) else {
            throw PommeMDMEnrollmentWorkflowError.malformedJournal
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let phase = try values.decode(PommeMDMEnrollmentPhase.self, forKey: .phase)
        let enrollmentDispatched = try values.decode(Bool.self, forKey: .enrollmentDispatched)
        // Schema 3 never recorded staging ownership. A completed record has
        // no retained cleanup work. Before enrollment intent, an undispatched
        // record has provably not transferred a staged profile, so it can
        // safely resume as unowned. Never infer ownership after intent.
        let schema3PreTransfer = phase.index < PommeMDMEnrollmentPhase.enrollmentIntent.index
            && !enrollmentDispatched
        guard version >= 4
                || phase == .restorationComplete
                || schema3PreTransfer else {
            throw PommeMDMEnrollmentWorkflowError.malformedJournal
        }
        self = try .init(
            generation: values.decode(UInt64.self, forKey: .generation),
            identity: values.decode(PommeSecurityWorkflowIdentity.self, forKey: .identity),
            profile: values.decode(MDMEnrollmentProfileIdentity.self, forKey: .profile),
            agentSHA256: values.decode(String.self, forKey: .agentSHA256),
            enrollmentMode: values.decode(MDMEnrollmentMode.self, forKey: .enrollmentMode),
            finalSecurity: version >= 6
                ? values.decode(MDMFinalSecurity.self, forKey: .finalSecurity) : .restore,
            originalRunState: values.decode(VMRunStateSnapshot.self, forKey: .originalRunState),
            sipWasDisabled: values.decodeIfPresent(Bool.self, forKey: .sipWasDisabled),
            amfiWasDisabled: values.decodeIfPresent(Bool.self, forKey: .amfiWasDisabled),
            pendingChild: values.decodeIfPresent(PommeSecurityWorkflowOperation.self, forKey: .pendingChild),
            sipChangeRequested: values.decode(Bool.self, forKey: .sipChangeRequested),
            amfiChangeRequested: values.decode(Bool.self, forKey: .amfiChangeRequested),
            enrollmentDispatched: enrollmentDispatched,
            enrollmentVerified: values.decode(Bool.self, forKey: .enrollmentVerified),
            normalBootArguments: values.decodeIfPresent(Data.self, forKey: .normalBootArguments),
            configuredBootArguments: values.decodeIfPresent(Data.self, forKey: .configuredBootArguments),
            helperTerminationUnproven: values.decode(Bool.self, forKey: .helperTerminationUnproven),
            stagedProfileOwned: version >= 4
                ? values.decode(Bool.self, forKey: .stagedProfileOwned) : false,
            failure: version >= 5 ? values.decodeIfPresent(PommeMDMEnrollmentFailure.self, forKey: .failure) : nil,
            ownedArtifacts: values.decode([String].self, forKey: .ownedArtifacts),
            phase: phase,
            profileIdentifier: values.decodeIfPresent(String.self, forKey: .profileIdentifier),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    var canRetryEnrollment: Bool {
        failure == .beforeIdentityImport && phase == .enrollmentIntent
            && enrollmentDispatched && pendingChild == nil && !helperTerminationUnproven && !enrollmentVerified
    }

    func replacing(
        phase: PommeMDMEnrollmentPhase,
        profileIdentifier: String? = nil,
        sipWasDisabled: Bool? = nil,
        amfiWasDisabled: Bool? = nil,
        pendingChild: PommeSecurityWorkflowOperation?? = nil,
        sipChangeRequested: Bool? = nil, amfiChangeRequested: Bool? = nil,
        enrollmentDispatched: Bool? = nil, enrollmentVerified: Bool? = nil,
        normalBootArguments: Data? = nil, configuredBootArguments: Data? = nil,
        helperTerminationUnproven: Bool? = nil,
        stagedProfileOwned: Bool? = nil,
        failure: PommeMDMEnrollmentFailure? = nil,
        at date: Date
    ) throws -> Self {
        let nextPending = pendingChild ?? self.pendingChild
        let nextSIPChange = sipChangeRequested ?? self.sipChangeRequested
        let nextAMFIChange = amfiChangeRequested ?? self.amfiChangeRequested
        let nextDispatched = enrollmentDispatched ?? self.enrollmentDispatched
        let nextVerified = enrollmentVerified ?? self.enrollmentVerified
        let nextArguments: Data?
        let nextConfiguredArguments: Data?
        switch (normalBootArguments, configuredBootArguments) {
        case (nil, nil):
            nextArguments = self.normalBootArguments
            nextConfiguredArguments = self.configuredBootArguments
        case let (.some(normal), .some(configured)):
            guard (self.normalBootArguments == nil && self.configuredBootArguments == nil)
                    || (self.normalBootArguments == normal && self.configuredBootArguments == configured) else {
                throw PommeMDMEnrollmentWorkflowError.malformedJournal
            }
            nextArguments = normal
            nextConfiguredArguments = configured
        default:
            // These baselines are a single immutable receipt. Capturing only
            // one could make NVRAM restoration non-reproducible.
            throw PommeMDMEnrollmentWorkflowError.malformedJournal
        }
        let nextTermination = helperTerminationUnproven ?? self.helperTerminationUnproven
        let nextStagedProfileOwned = stagedProfileOwned ?? self.stagedProfileOwned
        guard !self.stagedProfileOwned || nextStagedProfileOwned else {
            throw PommeMDMEnrollmentWorkflowError.malformedJournal
        }
        return try Self.init(
            generation: generation + 1, identity: identity, profile: profile,
            agentSHA256: agentSHA256, enrollmentMode: enrollmentMode, finalSecurity: finalSecurity,
            originalRunState: originalRunState, sipWasDisabled: sipWasDisabled ?? self.sipWasDisabled,
            amfiWasDisabled: amfiWasDisabled ?? self.amfiWasDisabled,
            pendingChild: nextPending, sipChangeRequested: nextSIPChange,
            amfiChangeRequested: nextAMFIChange, enrollmentDispatched: nextDispatched,
            enrollmentVerified: nextVerified, normalBootArguments: nextArguments,
            configuredBootArguments: nextConfiguredArguments,
            helperTerminationUnproven: nextTermination,
            stagedProfileOwned: nextStagedProfileOwned,
            failure: failure ?? (enrollmentVerified == true ? nil : self.failure),
            ownedArtifacts: ownedArtifacts, phase: phase,
            profileIdentifier: profileIdentifier ?? self.profileIdentifier,
            createdAt: createdAt, updatedAt: date
        )
    }

    func matchesRequest(
        identity: PommeSecurityWorkflowIdentity,
        profile: MDMEnrollmentProfileIdentity,
        agentSHA256: String,
        enrollmentMode: MDMEnrollmentMode,
        finalSecurity: MDMFinalSecurity
    ) -> Bool {
        self.identity.matches(identity)
            && self.profile == profile
            && self.agentSHA256 == agentSHA256.lowercased()
            && self.enrollmentMode == enrollmentMode
            && self.finalSecurity == finalSecurity
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
    }

    private static func isProfile(_ profile: MDMEnrollmentProfileIdentity) -> Bool {
        isDigest(profile.digest)
            && !profile.identifier.isEmpty && profile.identifier.utf8.count <= 255
            && !profile.identifier.contains("\0")
            && !profile.serverURL.isEmpty && profile.serverURL.utf8.count <= 4 * 1024
            && !profile.serverURL.contains("\0")
    }

    private static func areSafeArtifacts(_ values: [String]) -> Bool {
        Set(values).count == values.count && values.allSatisfy { value in
            value.hasPrefix("/private/var/db/pomme-mdm-")
                && value.utf8.count <= 512
                && !value.contains("\0")
                && !value.split(separator: "/").contains("..")
        }
    }

    private static func isSafeProfileIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 255 && !value.contains("\0")
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }

    private static func phaseAllowsIdentifier(
        _ phase: PommeMDMEnrollmentPhase, profileIdentifier: String?
    ) -> Bool {
        // A failure may move directly to restoration before an identifier is
        // known; a no-op may likewise have no profile identifier in this
        // redacted journal. Evidence, not phase position, establishes the
        // identifier when it is available.
        _ = phase
        return isSafeProfileIdentifier(profileIdentifier)
    }

    private static func phaseAllowsSecurityBaseline(
        _ phase: PommeMDMEnrollmentPhase, sipWasDisabled: Bool?, amfiWasDisabled: Bool?
    ) -> Bool {
        let bound = sipWasDisabled != nil && amfiWasDisabled != nil
        if !bound {
            return sipWasDisabled == nil && amfiWasDisabled == nil && [
                // A matching, independently verified enrollment needs no
                // security inspection or mutation. Its evidence-only path is
                // intentionally durable even though no baseline exists.
                .captured, .existingEnrollmentChecked, .postEnrollmentEvidenceVerified,
                .securityRestorationIntent, .securityRestored,
                .runStateRestorationIntent, .restorationComplete,
            ].contains(phase)
        }
        switch phase {
        case .captured: return true
        default: return bound
        }
    }

    private static func areCapturedBootArguments(normal: Data?, configured: Data?) -> Bool {
        switch (normal, configured) {
        case (nil, nil):
            return true
        case let (.some(normal), .some(configured)):
            return normal.count <= 64 * 1024
                && !normal.contains(0)
                && isCanonicalConfiguredBootArguments(configured)
        default:
            return false
        }
    }

    private static func isCanonicalConfiguredBootArguments(_ encoded: Data) -> Bool {
        guard encoded.count <= 96 * 1024,
              let value = try? JSONDecoder().decode(JSONValue.self, from: encoded),
              let canonical = try? PommeProvisioningCoding.encode(value),
              canonical == encoded else {
            return false
        }
        switch value {
        case .null:
            return true
        case .string(let base64):
            guard let bytes = Data(base64Encoded: base64) else { return false }
            return bytes.count <= 64 * 1024
                && !bytes.contains(0)
                && bytes.base64EncodedString() == base64
        default:
            return false
        }
    }

    private static func canonicalDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(generation, forKey: .generation)
        try values.encode(identity, forKey: .identity)
        try values.encode(profile, forKey: .profile)
        try values.encode(agentSHA256, forKey: .agentSHA256)
        try values.encode(enrollmentMode, forKey: .enrollmentMode)
        try values.encode(finalSecurity, forKey: .finalSecurity)
        try values.encode(originalRunState, forKey: .originalRunState)
        try values.encode(sipWasDisabled, forKey: .sipWasDisabled)
        try values.encode(amfiWasDisabled, forKey: .amfiWasDisabled)
        try values.encode(pendingChild, forKey: .pendingChild)
        try values.encode(sipChangeRequested, forKey: .sipChangeRequested)
        try values.encode(amfiChangeRequested, forKey: .amfiChangeRequested)
        try values.encode(enrollmentDispatched, forKey: .enrollmentDispatched)
        try values.encode(enrollmentVerified, forKey: .enrollmentVerified)
        try values.encode(normalBootArguments, forKey: .normalBootArguments)
        try values.encode(configuredBootArguments, forKey: .configuredBootArguments)
        try values.encode(helperTerminationUnproven, forKey: .helperTerminationUnproven)
        try values.encode(stagedProfileOwned, forKey: .stagedProfileOwned)
        try values.encode(failure, forKey: .failure)
        try values.encode(ownedArtifacts, forKey: .ownedArtifacts)
        try values.encode(phase, forKey: .phase)
        try values.encode(profileIdentifier, forKey: .profileIdentifier)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

private struct MDMJournalCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum PommeMDMEnrollmentWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case leaseRequired
    case journalIdentityMismatch
    case unfinishedModeConflict
    case unfinishedFinalSecurityConflict
    case incompleteEnrollmentOutcome
    case malformedJournal
    case unsafeJournal
    case staleJournal
    case invalidPhaseTransition
    case restorationFailed
    case durabilityFailure(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .leaseRequired: "MDM enrollment requires the VM mutation lease."
        case .journalIdentityMismatch: "The retained MDM enrollment belongs to another VM or request."
        case .unfinishedModeConflict: "An unfinished MDM enrollment uses a different enrollment mode."
        case .unfinishedFinalSecurityConflict: "An unfinished MDM enrollment uses a different --final-security value. Repeat it with its original value."
        case .incompleteEnrollmentOutcome: "A prior MDM enrollment was dispatched without verified outcome. Inspect evidence before retrying."
        case .malformedJournal: "The retained MDM enrollment journal is malformed."
        case .unsafeJournal: "The retained MDM enrollment journal is unsafe."
        case .staleJournal: "The retained MDM enrollment journal changed concurrently."
        case .invalidPhaseTransition: "The retained MDM enrollment phase cannot be resumed safely."
        case .restorationFailed: "MDM enrollment could not restore the original security or run state."
        case .durabilityFailure(let operation, let code): "MDM enrollment journal \(operation) could not be durably synchronized (errno \(code))."
        }
    }
}

/// Owns the journal file only. The caller owns the VM mutation lease for every
/// read and write. This keeps an unfinished MDM cursor mutually exclusive with
/// the SecurityWorkflow cursor through the same VM lease, without combining
/// unrelated record schemas.
struct PommeMDMEnrollmentJournalStore: Sendable {
    static let journalName = "MDMEnrollmentJournal.json"
    static let maximumBytes = 128 * 1024

    let bundleURL: URL

    init(bundleURL: URL) { self.bundleURL = bundleURL.standardizedFileURL }
    var journalURL: URL { bundleURL.appendingPathComponent(Self.journalName) }

    func loadIfPresent(lease: VMBundleMutationLease) throws -> PommeMDMEnrollmentJournal? {
        let data = try readJournalIfPresent()
        guard let data else { return nil }
        let value: PommeMDMEnrollmentJournal
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            value = try decoder.decode(PommeMDMEnrollmentJournal.self, from: data)
        }
        catch { throw PommeMDMEnrollmentWorkflowError.malformedJournal }
        guard lease.validates(name: value.identity.vmName) else {
            throw PommeMDMEnrollmentWorkflowError.leaseRequired
        }
        return value
    }

    func begin(
        identity: PommeSecurityWorkflowIdentity,
        profile: MDMEnrollmentProfileIdentity,
        agentSHA256: String,
        enrollmentMode: MDMEnrollmentMode,
        finalSecurity: MDMFinalSecurity = .restore,
        originalRunState: VMRunStateSnapshot,
        sipWasDisabled: Bool? = nil,
        amfiWasDisabled: Bool? = nil,
        ownedArtifacts: [String],
        lease: VMBundleMutationLease,
        now: Date = Date()
    ) throws -> PommeMDMEnrollmentJournal {
        guard lease.validates(name: identity.vmName) else {
            throw PommeMDMEnrollmentWorkflowError.leaseRequired
        }
        if let retained = try loadIfPresent(lease: lease) {
            guard retained.identity.matches(identity) else {
                throw PommeMDMEnrollmentWorkflowError.journalIdentityMismatch
            }
            if retained.phase != .restorationComplete
                || (retained.enrollmentDispatched && !retained.enrollmentVerified) {
                guard retained.profile == profile,
                      retained.agentSHA256 == agentSHA256.lowercased() else {
                    throw PommeMDMEnrollmentWorkflowError.journalIdentityMismatch
                }
                guard retained.enrollmentMode == enrollmentMode else {
                    throw PommeMDMEnrollmentWorkflowError.unfinishedModeConflict
                }
                guard retained.finalSecurity == finalSecurity else {
                    throw PommeMDMEnrollmentWorkflowError.unfinishedFinalSecurityConflict
                }
                return retained
            }
        }
        let journal = try PommeMDMEnrollmentJournal(
            generation: ((try loadIfPresent(lease: lease))?.generation ?? 0) + 1,
            identity: identity, profile: profile, agentSHA256: agentSHA256,
            enrollmentMode: enrollmentMode, finalSecurity: finalSecurity, originalRunState: originalRunState,
            sipWasDisabled: sipWasDisabled, amfiWasDisabled: amfiWasDisabled,
            ownedArtifacts: ownedArtifacts, phase: .captured, createdAt: now, updatedAt: now
        )
        try write(journal)
        return journal
    }

    func advance(
        _ current: PommeMDMEnrollmentJournal,
        to phase: PommeMDMEnrollmentPhase,
        profileIdentifier: String? = nil,
        lease: VMBundleMutationLease,
        now: Date = Date()
    ) throws -> PommeMDMEnrollmentJournal {
        guard lease.validates(name: current.identity.vmName) else {
            throw PommeMDMEnrollmentWorkflowError.leaseRequired
        }
        guard try loadIfPresent(lease: lease) == current else {
            throw PommeMDMEnrollmentWorkflowError.staleJournal
        }
        guard Self.allowsTransition(from: current.phase, to: phase) else {
            throw PommeMDMEnrollmentWorkflowError.invalidPhaseTransition
        }
        if phase == current.phase { return current }
        let updated = try current.replacing(phase: phase, profileIdentifier: profileIdentifier, at: now)
        try write(updated)
        return updated
    }

    /// Atomically records intent/receipt fields without changing immutable VM,
    /// profile, mode, baseline, or owned-artifact bindings. `pendingChild` is
    /// double-optional: omit it to retain, pass `.some(nil)` to clear it.
    func update(
        _ current: PommeMDMEnrollmentJournal,
        phase: PommeMDMEnrollmentPhase? = nil,
        pendingChild: PommeSecurityWorkflowOperation?? = nil,
        sipChangeRequested: Bool? = nil,
        amfiChangeRequested: Bool? = nil,
        enrollmentDispatched: Bool? = nil,
        enrollmentVerified: Bool? = nil,
        normalBootArguments: Data? = nil,
        configuredBootArguments: Data? = nil,
        helperTerminationUnproven: Bool? = nil,
        stagedProfileOwned: Bool? = nil,
        failure: PommeMDMEnrollmentFailure? = nil,
        sipWasDisabled: Bool? = nil,
        amfiWasDisabled: Bool? = nil,
        lease: VMBundleMutationLease,
        now: Date = Date()
    ) throws -> PommeMDMEnrollmentJournal {
        guard lease.validates(name: current.identity.vmName),
              try loadIfPresent(lease: lease) == current else {
            throw PommeMDMEnrollmentWorkflowError.staleJournal
        }
        let selectedPhase = phase ?? current.phase
        // A lost helper reply can leave an installed, unapproved profile after
        // restoration. Record a fresh run-state intent before the engine does
        // any work; only its independently observed exact-profile upgrade
        // guard may then advance that intent into security preparation.
        let reopenLostDispatch = [
            (PommeMDMEnrollmentPhase.restorationComplete, PommeMDMEnrollmentPhase.runStateRestorationIntent),
            (.runStateRestorationIntent, .securityPreparationIntent),
        ].contains { current.phase == $0.0 && selectedPhase == $0.1 }
            && current.enrollmentDispatched
            && !current.enrollmentVerified
        guard Self.allowsTransition(from: current.phase, to: selectedPhase)
                || reopenLostDispatch else {
            throw PommeMDMEnrollmentWorkflowError.invalidPhaseTransition
        }
        let updated = try current.replacing(
            phase: selectedPhase,
            sipWasDisabled: sipWasDisabled,
            amfiWasDisabled: amfiWasDisabled,
            pendingChild: pendingChild ?? current.pendingChild,
            sipChangeRequested: sipChangeRequested,
            amfiChangeRequested: amfiChangeRequested,
            enrollmentDispatched: enrollmentDispatched,
            enrollmentVerified: enrollmentVerified,
            normalBootArguments: normalBootArguments,
            configuredBootArguments: configuredBootArguments,
            helperTerminationUnproven: helperTerminationUnproven,
            stagedProfileOwned: stagedProfileOwned,
            failure: failure,
            at: now
        )
        try write(updated)
        return updated
    }

    /// Records the pre-existing security state after the intent cursor is
    /// durable and before the first SIP/AMFI mutation. This is deliberately a
    /// separate write so a stopped/paused VM is never booted before recovery
    /// can restore its original run state from the retained journal.
    func bindSecurityBaseline(
        _ current: PommeMDMEnrollmentJournal,
        sipWasDisabled: Bool,
        amfiWasDisabled: Bool,
        lease: VMBundleMutationLease,
        now: Date = Date()
    ) throws -> PommeMDMEnrollmentJournal {
        guard lease.validates(name: current.identity.vmName),
              current.phase == .captured,
              current.sipWasDisabled == nil, current.amfiWasDisabled == nil,
              try loadIfPresent(lease: lease) == current else {
            throw PommeMDMEnrollmentWorkflowError.staleJournal
        }
        let updated = try current.replacing(
            phase: .captured, sipWasDisabled: sipWasDisabled,
            amfiWasDisabled: amfiWasDisabled, at: now
        )
        try write(updated)
        return updated
    }

    private func write(_ journal: PommeMDMEnrollmentJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(journal) }
        catch { throw PommeMDMEnrollmentWorkflowError.malformedJournal }
        guard data.count <= Self.maximumBytes else { throw PommeMDMEnrollmentWorkflowError.malformedJournal }
        try Self.writeAtomically(data, destination: journalURL, bundleURL: bundleURL)
    }

    private func readJournalIfPresent() throws -> Data? {
        let parent = Darwin.open(bundleURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PommeMDMEnrollmentWorkflowError.unsafeJournal }
        defer { _ = Darwin.close(parent) }
        var parentStatus = stat()
        guard fstat(parent, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid(), parentStatus.st_mode & 0o022 == 0 else {
            throw PommeMDMEnrollmentWorkflowError.unsafeJournal
        }
        let descriptor = Self.journalName.withCString {
            openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw PommeMDMEnrollmentWorkflowError.unsafeJournal
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= off_t(Self.maximumBytes) else {
            throw PommeMDMEnrollmentWorkflowError.unsafeJournal
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PommeMDMEnrollmentWorkflowError.unsafeJournal
            }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= Self.maximumBytes else {
                throw PommeMDMEnrollmentWorkflowError.unsafeJournal
            }
        }
        return data
    }

    private static func allowsTransition(
        from current: PommeMDMEnrollmentPhase, to next: PommeMDMEnrollmentPhase
    ) -> Bool {
        if current == next { return true }
        // Any incomplete phase may fail closed into the two restoration
        // intents. This is how cancellation and interrupted helper cleanup
        // restore security/run state without inventing a completion receipt.
        if next == .securityRestorationIntent {
            return current != .restorationComplete
        }
        switch (current, next) {
        case (.captured, .existingEnrollmentChecked),
             (.captured, .securityRestorationIntent),
             (.existingEnrollmentChecked, .securityPreparationIntent),
             (.existingEnrollmentChecked, .postEnrollmentEvidenceVerified),
             (.securityPreparationIntent, .securityPrepared),
             (.securityPrepared, .enrollmentIntent),
             (.enrollmentIntent, .enrollmentVerified),
             (.enrollmentIntent, .postEnrollmentEvidenceVerified),
             (.enrollmentVerified, .approvalIntent),
             (.approvalIntent, .approvalVerified),
             (.approvalVerified, .postEnrollmentEvidenceVerified),
             (.enrollmentVerified, .postEnrollmentEvidenceVerified),
             (.postEnrollmentEvidenceVerified, .securityRestorationIntent),
             (.securityRestorationIntent, .securityRestored),
             (.securityRestored, .runStateRestorationIntent),
             (.runStateRestorationIntent, .restorationComplete):
            return true
        default:
            return false
        }
    }

    private static func writeAtomically(_ data: Data, destination: URL, bundleURL: URL) throws {
        let parent = bundleURL.standardizedFileURL
        guard destination.deletingLastPathComponent() == parent,
              destination.lastPathComponent == Self.journalName else {
            throw PommeMDMEnrollmentWorkflowError.unsafeJournal
        }
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw PommeMDMEnrollmentWorkflowError.unsafeJournal }
        defer { _ = Darwin.close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid(), parentStatus.st_mode & 0o022 == 0 else {
            throw PommeMDMEnrollmentWorkflowError.unsafeJournal
        }
        var existing = stat()
        let existingResult = Self.journalName.withCString {
            fstatat(parentDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        guard existingResult == 0 || errno == ENOENT else {
            throw PommeMDMEnrollmentWorkflowError.unsafeJournal
        }
        if existingResult == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == geteuid(),
                  existing.st_mode & 0o777 == 0o600, existing.st_nlink == 1 else {
                throw PommeMDMEnrollmentWorkflowError.unsafeJournal
            }
        }
        let temporaryName = ".\(Self.journalName).\(UUID().uuidString)"
        var descriptor = temporaryName.withCString {
            openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "stage", code: errno)
        }
        var published = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !published { _ = temporaryName.withCString { unlinkat(parentDescriptor, $0, 0) } }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "permissions", code: errno)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "write", code: errno)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "file", code: errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "close", code: errno)
        }
        descriptor = -1
        let renameResult = temporaryName.withCString { temporary in
            Self.journalName.withCString { name in renameat(parentDescriptor, temporary, parentDescriptor, name) }
        }
        guard renameResult == 0 else {
            throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "publish", code: errno)
        }
        published = true
        guard fsync(parentDescriptor) == 0 else {
            throw PommeMDMEnrollmentWorkflowError.durabilityFailure(operation: "directory", code: errno)
        }
    }
}
