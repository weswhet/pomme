import Foundation

enum PommeMDMChildScope {
    @TaskLocal static var vmName: String?
}

enum PommeMDMWorkflowFailure: Error, LocalizedError, Equatable {
    case conflictingEnrollment
    case downgradeUnsupported
    case evidenceUnavailable
    case outcomeUnknown
    case securityBaselineUnsupported
    case restorationIncomplete
    case competingSecurityOperation

    var errorDescription: String? {
        switch self {
        case .conflictingEnrollment: "The installed MDM profile or server conflicts with the supplied profile."
        case .downgradeUnsupported: "Unapproved mode cannot downgrade an approved or supervised enrollment."
        case .evidenceUnavailable: "The requested enrollment, approval, and supervision could not all be verified."
        case .outcomeUnknown: "The enrollment outcome is unknown. Repeat the same MDM request to inspect retained work; installation will not be repeated without evidence."
        case .securityBaselineUnsupported: "The original SIP/AMFI configuration cannot be reproduced exactly; security was not changed."
        case .restorationIncomplete: "MDM security or VM state restoration is incomplete. Repeat the same command and profile to resume its journal."
        case .competingSecurityOperation: "An unfinished MDM or security operation owns this VM. Resume its original command first."
        }
    }
}

struct PommeMDMObservedEnrollment: Equatable, Sendable {
    enum Disposition { case install, upgrade, satisfied }
    let installed: MDMInstalledProfileIdentity?
    let status: MDMEnrollmentStatus
    let supervised: Bool

    func disposition(profile: MDMEnrollmentProfileIdentity, mode: MDMEnrollmentMode) throws -> Disposition {
        if let installed, !installed.matches(profile) { throw PommeMDMWorkflowFailure.conflictingEnrollment }
        if let server = status.serverURL, server != profile.serverURL { throw PommeMDMWorkflowFailure.conflictingEnrollment }
        guard status.enrolled == (installed != nil), status.enrolled || (!status.userApproved && !supervised) else {
            throw PommeMDMWorkflowFailure.evidenceUnavailable
        }
        if mode == .unapproved, status.userApproved || supervised { throw PommeMDMWorkflowFailure.downgradeUnsupported }
        guard status.enrolled else { return .install }
        return mode == .unapproved || (status.userApproved && supervised) ? .satisfied : .upgrade
    }

    func requireRequestedState(profile: MDMEnrollmentProfileIdentity, mode: MDMEnrollmentMode) throws {
        guard try disposition(profile: profile, mode: mode) == .satisfied else {
            throw PommeMDMWorkflowFailure.evidenceUnavailable
        }
    }
}

struct PommeMDMWorkflowSecurityBaseline: Sendable {
    let sipDisabled: Bool
    let amfiDisabled: Bool
    let activeBootArguments: Data
    var configuredBootArguments: Data = Data("\"\"".utf8)

    /// The SIP state a finished enrollment must prove. `disabled` keeps only
    /// what this workflow disabled switched off; untouched settings, including
    /// every setting of an already-satisfied enrollment, stay as found.
    static func expectedFinalSIPDisabled(_ journal: PommeMDMEnrollmentJournal) -> Bool? {
        guard let original = journal.sipWasDisabled else { return nil }
        return journal.finalSecurity == .disabled && journal.sipChangeRequested ? true : original
    }

    static func expectedFinalAMFIDisabled(_ journal: PommeMDMEnrollmentJournal) -> Bool? {
        guard let original = journal.amfiWasDisabled else { return nil }
        return journal.finalSecurity == .disabled && journal.amfiChangeRequested ? true : original
    }

    /// Normal-boot evidence for the requested final security. A restored or
    /// untouched AMFI setting must reproduce the captured boot arguments
    /// exactly; one this workflow left disabled needs only the override.
    static func finalSecurityMatches(
        _ journal: PommeMDMEnrollmentJournal,
        sipDisabled: Bool, activeBootArguments: Data, configuredBootArguments: Data
    ) -> Bool {
        guard let sip = expectedFinalSIPDisabled(journal), sipDisabled == sip,
              let amfi = expectedFinalAMFIDisabled(journal) else { return false }
        if amfi, journal.amfiWasDisabled == false {
            return PommeBootArguments.containsOverride(activeBootArguments)
        }
        return activeBootArguments == journal.normalBootArguments
            && configuredBootArguments == journal.configuredBootArguments
    }

    static func childAllowsRestorationReconciliation(_ phase: PommeSecurityWorkflowPhase?) -> Bool {
        phase == nil || phase == .restorationComplete || phase == .preflightRejected
    }

    static func validateOriginalAMFI(sipDisabled: Bool, activeBootArguments: Data,
        state: PommeSecurityWorkflowState) throws {
        // An AMFI enable receipt was captured while SIP was disabled. A
        // later SIP enable legitimately changes that LocalPolicy projection.
        // It is not permission to discard the receipt: the live adapter must
        // re-prove it after SIP preparation, before starting any AMFI child.
        let deferredEnabledReceipt = !sipDisabled && !state.disabled
            && state.baselinePresent && state.baselinePhase == "enabledVerified"
        guard state.disabled == PommeBootArguments.containsOverride(activeBootArguments),
              !state.reconciliationRequired || deferredEnabledReceipt,
              state.disabled || !state.baselinePresent || deferredEnabledReceipt else {
            throw PommeMDMWorkflowFailure.securityBaselineUnsupported
        }
    }
}

actor PommeMDMLastObservation {
    private var value: (PommeMDMObservedEnrollment, PommeMDMEnrollmentPhase)?
    private var failures: [PommeSecurityWorkflowError] = []
    func record(_ observed: PommeMDMObservedEnrollment, phase: PommeMDMEnrollmentPhase) { value = (observed, phase) }
    func snapshot() -> (PommeMDMObservedEnrollment, PommeMDMEnrollmentPhase)? { value }
    func recordFailure(_ failure: PommeSecurityWorkflowError) {
        if !failures.contains(failure) { failures.append(failure) }
    }
    func securityFailures() -> [PommeSecurityWorkflowError] { failures }
}

/// The lease owner is the only writer. A lock also allows the helper's launch
/// callback to durably mark dispatch immediately before the transport effect.
final class PommeMDMWorkflowProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PommeMDMEnrollmentJournal
    let store: PommeMDMEnrollmentJournalStore
    let lease: VMBundleMutationLease

    init(_ value: PommeMDMEnrollmentJournal, store: PommeMDMEnrollmentJournalStore, lease: VMBundleMutationLease) {
        self.value = value
        self.store = store
        self.lease = lease
    }

    var journal: PommeMDMEnrollmentJournal { lock.withLock { value } }

    func record(
        phase: PommeMDMEnrollmentPhase? = nil,
        pendingChild: PommeSecurityWorkflowOperation?? = nil,
        sipChangeRequested: Bool? = nil,
        amfiChangeRequested: Bool? = nil,
        enrollmentDispatched: Bool? = nil,
        enrollmentVerified: Bool? = nil,
        stagedProfileOwned: Bool? = nil,
        normalBootArguments: Data? = nil,
        configuredBootArguments: Data? = nil,
        helperTerminationUnproven: Bool? = nil,
        sipWasDisabled: Bool? = nil,
        amfiWasDisabled: Bool? = nil,
        failure: PommeMDMEnrollmentFailure? = nil
    ) throws {
        try lock.withLock {
            value = try store.update(
                value, phase: phase, pendingChild: pendingChild,
                sipChangeRequested: sipChangeRequested, amfiChangeRequested: amfiChangeRequested,
                enrollmentDispatched: enrollmentDispatched, enrollmentVerified: enrollmentVerified,
                normalBootArguments: normalBootArguments, configuredBootArguments: configuredBootArguments,
                helperTerminationUnproven: helperTerminationUnproven,
                stagedProfileOwned: stagedProfileOwned, failure: failure,
                sipWasDisabled: sipWasDisabled, amfiWasDisabled: amfiWasDisabled, lease: lease
            )
        }
    }
}

struct PommeMDMWorkflowDependencies: Sendable {
    let ensureNormal: @Sendable () async throws -> Void
    let observe: @Sendable () async throws -> PommeMDMObservedEnrollment
    let captureSecurity: @Sendable () async throws -> PommeMDMWorkflowSecurityBaseline
    let runSecurity: @Sendable (PommeSecurityWorkflowOperation) async throws -> Void
    let enroll: @Sendable () async throws -> Void
    let cleanup: @Sendable () async throws -> Void
    let requireHelperStopped: @Sendable () async throws -> Void
    let verifySecurity: @Sendable (PommeMDMEnrollmentJournal) async throws -> Void
    let restoreRunState: @Sendable (VMRunStateSnapshot) async throws -> Void
    let awaitEnrollment: @Sendable () async throws -> PommeMDMObservedEnrollment
    var restorationAlreadyVerified: @Sendable (PommeMDMEnrollmentJournal) async throws -> Bool = { _ in false }
    var reportSecurityFailure: @Sendable (PommeSecurityWorkflowError) async -> Void = { _ in }
}

/// One parent transaction owns preparation, enrollment and successful restoration. Child
/// Recovery journals keep their native deadlines and exact AMFI restoration.
struct PommeMDMWorkflowExecution: Sendable {
    let progress: PommeMDMWorkflowProgress
    let dependencies: PommeMDMWorkflowDependencies

    func run(preflightError: (any Error)? = nil) async throws -> PommeMDMObservedEnrollment {
        do {
            // A failed preflight preserves retained work without guest effects.
            if let preflightError { throw preflightError }
            if progress.journal.phase == .restorationComplete,
               progress.journal.enrollmentDispatched, !progress.journal.enrollmentVerified {
                try progress.record(phase: .runStateRestorationIntent)
            }
            try await dependencies.requireHelperStopped()
            try progress.record(helperTerminationUnproven: false)
            try await reconcileCompletedRestoration()
            if let pending = progress.journal.pendingChild { try await child(pending) }
            try await dependencies.ensureNormal()
            let before = try await dependencies.observe()
            let initial = progress.journal
            let disposition = try before.disposition(profile: initial.profile, mode: initial.enrollmentMode)
            // A previous launch may still have committed after losing its
            // reply. Only an observed installed profile permits an upgrade;
            // absence never authorizes replaying that installation.
            if initial.enrollmentDispatched, !initial.enrollmentVerified, disposition == .install,
               !initial.canRetryEnrollment {
                throw PommeMDMWorkflowFailure.outcomeUnknown
            }

            if disposition == .satisfied {
                try progress.record(enrollmentVerified: true)
            } else {
                if [.restorationComplete, .runStateRestorationIntent].contains(initial.phase), initial.enrollmentDispatched,
                   !initial.enrollmentVerified, disposition == .upgrade {
                    // Exact installed identity makes approval-only replay
                    // safe after a lost install reply and completed restore.
                    try progress.record(phase: .securityPreparationIntent)
                } else if initial.phase == .securityRestorationIntent || initial.phase == .securityRestored
                    || initial.phase == .runStateRestorationIntent || initial.phase == .restorationComplete {
                    throw PommeMDMWorkflowFailure.outcomeUnknown
                }
                if initial.sipWasDisabled == nil {
                    let baseline = try await dependencies.captureSecurity()
                    try progress.record(normalBootArguments: baseline.activeBootArguments,
                        configuredBootArguments: baseline.configuredBootArguments,
                        sipWasDisabled: baseline.sipDisabled, amfiWasDisabled: baseline.amfiDisabled)
                }
                if progress.journal.phase == .captured { try progress.record(phase: .existingEnrollmentChecked) }
                if progress.journal.phase == .existingEnrollmentChecked { try progress.record(phase: .securityPreparationIntent) }
                if progress.journal.phase == .securityPreparationIntent {
                    if progress.journal.sipWasDisabled == false { try await child(.sipDisable) }
                    if progress.journal.amfiWasDisabled == false { try await child(.amfiDisable) }
                    try progress.record(phase: .securityPrepared)
                }
                try await dependencies.ensureNormal()
                // Recheck exact profile/server and mode after Recovery and
                // immediately before invoking the privileged helper.
                let ready = try await dependencies.observe()
                _ = try ready.disposition(profile: initial.profile, mode: initial.enrollmentMode)
                if progress.journal.phase == .securityPrepared { try progress.record(phase: .enrollmentIntent) }
                do { try await dependencies.enroll() }
                catch {
                    if (error as? PommeMDMEnrollmentError) == .helperProcessTerminationUnproven {
                        try progress.record(helperTerminationUnproven: true)
                        throw error
                    }
                    throw error
                }
                let observed = try await dependencies.awaitEnrollment()
                try observed.requireRequestedState(profile: initial.profile, mode: initial.enrollmentMode)
                try progress.record(enrollmentVerified: true)
            }
            try await restore()
            let restored = try await dependencies.awaitEnrollment()
            try restored.requireRequestedState(profile: progress.journal.profile, mode: progress.journal.enrollmentMode)
            try progress.record(phase: .runStateRestorationIntent)
            try await dependencies.restoreRunState(progress.journal.originalRunState)
            try progress.record(phase: .restorationComplete)
            return restored
        } catch {
            if let failure = error as? PommeSecurityWorkflowError { await dependencies.reportSecurityFailure(failure) }
            // Preserve the first failure and the exact guest state. No polling,
            // cleanup, security changes, or run-state changes occur after it.
            let failure: PommeMDMEnrollmentFailure
            if let helper = error as? PommeMDMHelperFailure,
               helper.beforeIdentityImport, !progress.journal.helperTerminationUnproven {
                failure = .beforeIdentityImport
            } else if progress.journal.canRetryEnrollment {
                failure = .beforeIdentityImport
            } else {
                failure = progress.journal.enrollmentVerified ? .restoration
                    : (progress.journal.enrollmentDispatched ? .outcomeUnknown : .beforeDispatch)
            }
            try progress.record(failure: failure)
            throw error
        }
    }

    private func child(_ operation: PommeSecurityWorkflowOperation) async throws {
        try progress.record(pendingChild: .some(operation),
            sipChangeRequested: operation == .sipDisable ? true : nil,
            amfiChangeRequested: operation == .amfiDisable ? true : nil)
        try await dependencies.runSecurity(operation)
        try progress.record(pendingChild: .some(nil))
    }

    private func reconcileCompletedRestoration() async throws {
        guard progress.journal.phase == .securityRestorationIntent,
              try await dependencies.restorationAlreadyVerified(progress.journal) else { return }
        try progress.record(phase: .securityRestored, pendingChild: .some(nil))
    }

    private func restore() async throws {
        try await dependencies.requireHelperStopped()
        try progress.record(helperTerminationUnproven: false)
        // A retained Recovery child must finish its cleanup barriers before
        // any normal-guest artifact operation can boot the VM.
        try await reconcileCompletedRestoration()
        if let pending = progress.journal.pendingChild { try await child(pending) }
        do { try await dependencies.cleanup() }
        catch let failure as PommeMDMCleanupFailure { throw failure }
        catch { throw PommeMDMEnrollmentError.cleanupFailed }
        if ![.securityRestored, .runStateRestorationIntent, .restorationComplete].contains(progress.journal.phase) {
            try progress.record(phase: .securityRestorationIntent)
            if progress.journal.finalSecurity == .restore {
                if progress.journal.amfiChangeRequested { try await child(.amfiEnable) }
                // An AMFI failure throws above and is a barrier to re-enabling SIP.
                if progress.journal.sipChangeRequested { try await child(.sipEnable) }
            }
        }
        try await dependencies.ensureNormal()
        if progress.journal.sipWasDisabled != nil { try await dependencies.verifySecurity(progress.journal) }
        if progress.journal.phase == .securityRestorationIntent { try progress.record(phase: .securityRestored) }
    }
}
