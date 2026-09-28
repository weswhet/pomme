import Foundation

/// Where a VM's creation transaction stands, read without writing anything.
enum PommeProvisioningReadiness: Equatable, Sendable {
    case complete(schema: Int)
    case resumable(schema: Int, phase: String)
    case blocked(schema: Int?, reason: Blocked)

    enum Blocked: Equatable, Sendable {
        /// A bundle without a Pomme creation journal.
        case unmanaged
        case invalidJournal
        /// Framework first boot was dispatched without a receipt; replaying
        /// it could provision the guest twice.
        case ambiguousFirstBoot
        /// An interrupted effect that `create --resume` never re-executes.
        case interruptedPhase(String)

        var code: String {
            switch self {
            case .unmanaged: "unmanaged"
            case .invalidJournal: "invalidJournal"
            case .ambiguousFirstBoot: "ambiguousFirstBoot"
            case .interruptedPhase: "interruptedPhase"
            }
        }
    }

    var schema: Int? {
        switch self {
        case .complete(let schema), .resumable(let schema, _): schema
        case .blocked(let schema, _): schema
        }
    }

    var publicValue: [String: Any] {
        var value: [String: Any] = ["schema": schema as Any? ?? NSNull()]
        switch self {
        case .complete:
            value["state"] = "complete"
        case .resumable(_, let phase):
            value["state"] = "resumable"
            value["phase"] = phase
        case .blocked(_, let reason):
            value["state"] = "blocked"
            value["reason"] = reason.code
            if case .interruptedPhase(let phase) = reason { value["phase"] = phase }
        }
        return value
    }
}

/// Mirrors exactly what each orchestrator's `resume` accepts, so a planned
/// resume is never one the orchestrator would refuse.
enum PommeProvisioningReadinessClassifier {
    static func classify(v1 journal: PommeProvisioningJournal) -> PommeProvisioningReadiness {
        guard let next = try? PommeProvisioningCoordinator.nextPhase(in: journal) else {
            return (try? PommeProvisioningCoordinator.validate(events: journal.events)) == nil
                ? .blocked(schema: 1, reason: .invalidJournal) : .complete(schema: 1)
        }
        if let last = journal.events.last, last.kind == .intent,
           last.phase != .installRecoveryAgent, last.phase != .restoreFinalState {
            return .blocked(schema: 1, reason: .interruptedPhase(last.phase.rawValue))
        }
        return .resumable(schema: 1, phase: next.phase.rawValue)
    }

    static func classify(
        v2 journal: PommeProvisioningV2Journal, provisionGuestWasDispatched: () throws -> Bool
    ) -> PommeProvisioningReadiness {
        let next: (phase: PommeProvisioningV2Phase, attempt: UInt64)?
        do { next = try PommeProvisioningV2Coordinator.nextPhase(in: journal) }
        catch { return .blocked(schema: 2, reason: .invalidJournal) }
        guard let next else { return .complete(schema: 2) }
        let intended = journal.events.contains { $0.phase == .provisionGuest && $0.kind == .intent }
        let received = journal.events.contains { $0.phase == .provisionGuest && $0.kind == .receipt }
        if intended, !received, (try? provisionGuestWasDispatched()) != false {
            return .blocked(schema: 2, reason: .ambiguousFirstBoot)
        }
        if journal.events.last?.kind == .intent, next.phase == .install {
            return .blocked(schema: 2, reason: .interruptedPhase(next.phase.rawValue))
        }
        return .resumable(schema: 2, phase: next.phase.rawValue)
    }
}

/// Pure planning for `pomme mdm`: which preparation steps to run, in order,
/// before the enrollment engine, and which retained states must stop it.
enum PommeMDMReadiness {
    struct Request: Equatable, Sendable {
        var enrollmentMode: MDMEnrollmentMode = .supervised
        var finalSecurity: MDMFinalSecurity = .restore
        var force = false
        var interactive = false
        var skipServerPreflight = false
        /// A template, version, or restore image was supplied.
        var creationSourceSupplied = false
        /// Any creation option was supplied, including resources and boot.
        var creationOptionsSupplied = false
    }

    enum RunState: Equatable, Sendable {
        case stopped
        case running(BootMode)
        case paused(BootMode)
        case unknown

        init(_ snapshot: VMRunStateSnapshot) {
            switch snapshot {
            case .stopped: self = .stopped
            case .running(let mode): self = .running(mode)
            case .paused(let mode): self = .paused(mode)
            }
        }

        var code: String {
            switch self {
            case .stopped: "stopped"
            case .running(let mode): "running-\(mode.rawValue)"
            case .paused(let mode): "paused-\(mode.rawValue)"
            case .unknown: "unknown"
            }
        }
    }

    struct RetainedEnrollment: Equatable, Sendable {
        var phase: PommeMDMEnrollmentPhase
        var failure: PommeMDMEnrollmentFailure?
        var enrollmentDispatched: Bool
        var enrollmentVerified: Bool
        var canRetryEnrollment: Bool
        var pendingChild: PommeSecurityWorkflowOperation?
        var matchesProfile: Bool
        var matchesMode: Bool
        var matchesFinalSecurity: Bool

        init(_ journal: PommeMDMEnrollmentJournal, profile: MDMEnrollmentProfileIdentity?, request: Request) {
            phase = journal.phase
            failure = journal.failure
            enrollmentDispatched = journal.enrollmentDispatched
            enrollmentVerified = journal.enrollmentVerified
            canRetryEnrollment = journal.canRetryEnrollment
            pendingChild = journal.pendingChild
            matchesProfile = profile == nil || journal.profile == profile
            matchesMode = journal.enrollmentMode == request.enrollmentMode
            matchesFinalSecurity = journal.finalSecurity == request.finalSecurity
        }

        init(phase: PommeMDMEnrollmentPhase, failure: PommeMDMEnrollmentFailure? = nil,
             enrollmentDispatched: Bool = false, enrollmentVerified: Bool = false, canRetryEnrollment: Bool = false,
             pendingChild: PommeSecurityWorkflowOperation? = nil, matchesProfile: Bool = true,
             matchesMode: Bool = true, matchesFinalSecurity: Bool = true) {
            self.phase = phase
            self.failure = failure
            self.enrollmentDispatched = enrollmentDispatched
            self.enrollmentVerified = enrollmentVerified
            self.canRetryEnrollment = canRetryEnrollment
            self.pendingChild = pendingChild
            self.matchesProfile = matchesProfile
            self.matchesMode = matchesMode
            self.matchesFinalSecurity = matchesFinalSecurity
        }

        /// The same test `store.begin` uses to resume instead of starting anew.
        var unfinished: Bool { phase != .restorationComplete || (enrollmentDispatched && !enrollmentVerified) }
        /// A new identity import may still happen when this is resumed.
        var mayInstall: Bool { !enrollmentDispatched || canRetryEnrollment }
        var outcomeUnknown: Bool { enrollmentDispatched && !enrollmentVerified && !canRetryEnrollment }
    }

    struct RetainedSecurityWorkflow: Equatable, Sendable {
        var operation: PommeSecurityWorkflowOperation
        var phase: PommeSecurityWorkflowPhase
        var requestedFinalState: VMFinalState

        var unfinished: Bool { phase != .restorationComplete && phase != .preflightRejected }
    }

    enum Enrollment: String, Equatable, Sendable {
        case install, upgrade, satisfied, conflicting, downgrade
    }

    struct Facts: Equatable, Sendable {
        var vmExists = true
        var mutationInProgress = false
        var provisioning: PommeProvisioningReadiness?
        var runState: RunState = .unknown
        var pendingSnapshotRestore = false
        var retainedEnrollment: RetainedEnrollment?
        var retainedSecurity: RetainedSecurityWorkflow?
        /// Observed only when the VM is already running normal macOS.
        var agent: MDMAgentReadiness?
        var sipDisabled: Bool?
        var amfiDisabled: Bool?
        var securityBaselineSupported: Bool?
        var enrollment: Enrollment?
        var serverTrust: MDMServerTrustDecision?
    }

    enum Step: Equatable, Sendable {
        case create
        case resumeProvisioning(schema: Int, phase: String)
        case finishSecurityWorkflow(PommeSecurityWorkflowOperation, VMFinalState)
        case enroll

        var name: String {
            switch self {
            case .create: "create"
            case .resumeProvisioning: "resumeProvisioning"
            case .finishSecurityWorkflow: "finishSecurityWorkflow"
            case .enroll: "enroll"
            }
        }

        var detail: String {
            switch self {
            case .create: "Create the missing VM."
            case .resumeProvisioning(let schema, let phase):
                "Resume schema-\(schema) creation at \(phase)."
            case .finishSecurityWorkflow(let operation, let finalState):
                "Finish the retained \(operation.wireName) operation (final state \(finalState.rawValue))."
            case .enroll:
                "Detect SIP/AMFI, prepare only what enrollment needs, and enroll."
            }
        }
    }

    enum Blocker: Equatable, Sendable {
        case mutationInProgress
        case vmMissing
        case provisioning(PommeProvisioningReadiness.Blocked)
        case pendingSnapshotRestore
        case runStateUnknown
        case retainedEnrollmentConflict
        case competingSecurityOperation(PommeSecurityWorkflowOperation)
        case agent(MDMAgentReadiness)
        case securityBaselineUnsupported
        case conflictingEnrollment
        case downgradeUnsupported
        case untrustedServer

        var code: String {
            switch self {
            case .mutationInProgress: "mutationInProgress"
            case .vmMissing: "vmMissing"
            case .provisioning(let reason): "provisioning.\(reason.code)"
            case .pendingSnapshotRestore: "pendingSnapshotRestore"
            case .runStateUnknown: "runStateUnknown"
            case .retainedEnrollmentConflict: "retainedEnrollmentConflict"
            case .competingSecurityOperation: "competingSecurityOperation"
            case .agent(let readiness): "agent.\(readiness.code)"
            case .securityBaselineUnsupported: "securityBaselineUnsupported"
            case .conflictingEnrollment: "conflictingEnrollment"
            case .downgradeUnsupported: "downgradeUnsupported"
            case .untrustedServer: "untrustedServer"
            }
        }

        var message: String {
            switch self {
            case .mutationInProgress:
                "Another Pomme operation is changing this VM. Wait for it to finish."
            case .vmMissing:
                "The VM does not exist. Add --from-template, --version, --latest, or --restore-image to create it."
            case .provisioning(.unmanaged):
                "The VM bundle has no Pomme creation journal."
            case .provisioning(.invalidJournal):
                "The VM's creation journal cannot be verified."
            case .provisioning(.ambiguousFirstBoot):
                "First-boot provisioning was dispatched without a receipt; it will not be replayed. Recreate the VM."
            case .provisioning(.interruptedPhase(let phase)):
                "Creation was interrupted during \(phase), which cannot be resumed safely. Recreate the VM."
            case .pendingSnapshotRestore:
                "A snapshot restore is pending. Run `pomme start NAME` to finish it first."
            case .runStateUnknown:
                "The VM is changing state. Wait for it to settle."
            case .retainedEnrollmentConflict:
                "An unfinished MDM enrollment uses a different profile, --enrollment-mode, or --final-security. Repeat it with its original values."
            case .competingSecurityOperation(let operation):
                "An unfinished \(operation.wireName) operation belongs to an unfinished MDM enrollment for a different request."
            case .agent(.missingCapabilities):
                "The VM's pinned guest agent lacks capabilities MDM requires. Recreate the VM with a current Pomme build."
            case .agent(.digestMismatch):
                "The guest agent is not the executable creation pinned."
            case .agent:
                "The guest agent is not an authenticated, attested persistent agent."
            case .securityBaselineUnsupported:
                "The guest has a pending boot-args change; its SIP/AMFI state cannot be reproduced exactly."
            case .conflictingEnrollment:
                "The guest is enrolled with a different profile or server."
            case .downgradeUnsupported:
                "Unapproved mode cannot downgrade an approved or supervised enrollment."
            case .untrustedServer:
                "Neither Apple's roots nor the profile's certificates validate the MDM server. Fix the profile, or pass --skip-server-preflight if the guest already trusts it."
            }
        }
    }

    enum Warning: String, Equatable, Sendable {
        case creationOptionsIgnored
        case pausedMemoryDiscarded
        case serverUnreachableFromHost
        case finalSecurityDisabled
        case enrollmentOutcomeUnknown
        case ownerConsentMayBeRequired

        var message: String {
            switch self {
            case .creationOptionsIgnored: "The VM exists; creation options were ignored."
            case .pausedMemoryDiscarded: "The paused VM will be cold-started for enrollment; its paused memory is discarded."
            case .serverUnreachableFromHost: "The host could not reach the MDM server; the guest checks again before enrolling."
            case .finalSecurityDisabled: "SIP/AMFI settings this enrollment disables will stay disabled."
            case .enrollmentOutcomeUnknown: "A retained enrollment has an unknown outcome; installation will not be repeated without evidence."
            case .ownerConsentMayBeRequired: "If this VM has no owner account, creating one needs --force or an interactive confirmation."
            }
        }
    }

    struct Plan: Equatable, Sendable {
        var steps: [Step]
        var blockers: [Blocker]
        var warnings: [Warning]

        var nextPreparation: Step? { blockers.isEmpty ? steps.first { $0 != .enroll } : nil }
    }

    static func plan(_ facts: Facts, request: Request) -> Plan {
        var steps: [Step] = []
        var blockers: [Blocker] = []
        var warnings: [Warning] = []
        if facts.mutationInProgress { blockers.append(.mutationInProgress) }
        if request.finalSecurity == .disabled { warnings.append(.finalSecurityDisabled) }

        if !facts.vmExists {
            if request.creationSourceSupplied { steps.append(.create) } else { blockers.append(.vmMissing) }
        } else {
            if request.creationOptionsSupplied { warnings.append(.creationOptionsIgnored) }
            switch facts.provisioning {
            case .complete, nil: break
            case .resumable(let schema, let phase): steps.append(.resumeProvisioning(schema: schema, phase: phase))
            case .blocked(_, let reason): blockers.append(.provisioning(reason))
            }
            if facts.pendingSnapshotRestore { blockers.append(.pendingSnapshotRestore) }
            switch facts.runState {
            case .unknown: blockers.append(.runStateUnknown)
            case .paused: warnings.append(.pausedMemoryDiscarded)
            case .stopped, .running: break
            }
            let enrollment = facts.retainedEnrollment.flatMap { $0.unfinished ? $0 : nil }
            if let enrollment {
                if !enrollment.matchesProfile || !enrollment.matchesMode || !enrollment.matchesFinalSecurity {
                    blockers.append(.retainedEnrollmentConflict)
                }
                if enrollment.outcomeUnknown { warnings.append(.enrollmentOutcomeUnknown) }
            }
            if let security = facts.retainedSecurity, security.unfinished {
                if let enrollment {
                    if enrollment.pendingChild != security.operation {
                        blockers.append(.competingSecurityOperation(security.operation))
                    }
                } else {
                    steps.append(.finishSecurityWorkflow(security.operation, security.requestedFinalState))
                }
            }
            // A resumable creation installs and verifies the agent itself.
            if let agent = facts.agent, agent != .ready, !steps.contains(where: { $0.name == "resumeProvisioning" }) {
                blockers.append(.agent(agent))
            }
            if facts.securityBaselineSupported == false { blockers.append(.securityBaselineUnsupported) }
            switch facts.enrollment {
            case .conflicting: blockers.append(.conflictingEnrollment)
            case .downgrade: blockers.append(.downgradeUnsupported)
            default: break
            }
            if case .complete(1) = facts.provisioning, !request.force, !request.interactive,
               facts.enrollment != .satisfied, facts.sipDisabled != true || facts.amfiDisabled != true {
                warnings.append(.ownerConsentMayBeRequired)
            }
        }

        let mayInstall = facts.enrollment != .satisfied
            && (facts.retainedEnrollment.map { !$0.unfinished || $0.mayInstall } ?? true)
        switch facts.serverTrust {
        case .untrusted where mayInstall && !request.skipServerPreflight:
            blockers.append(.untrustedServer)
        case .unreachable:
            warnings.append(.serverUnreachableFromHost)
        default:
            break
        }
        steps.append(.enroll)
        return .init(steps: steps, blockers: blockers, warnings: warnings)
    }

    static func publicValue(_ facts: Facts, plan: Plan) -> [String: Any] {
        func optional(_ value: Bool?) -> Any { value.map { $0 as Any } ?? "notObserved" }
        var retained: [String: Any] = [:]
        if let enrollment = facts.retainedEnrollment, enrollment.unfinished {
            retained["enrollment"] = ["phase": enrollment.phase.rawValue,
                                      "failure": enrollment.failure?.rawValue as Any? ?? NSNull(),
                                      "outcomeUnknown": enrollment.outcomeUnknown]
        }
        if let security = facts.retainedSecurity, security.unfinished {
            retained["security"] = ["operation": security.operation.wireName, "phase": security.phase.rawValue,
                                    "finalState": security.requestedFinalState.rawValue]
        }
        return [
            "vmExists": facts.vmExists,
            "provisioning": facts.provisioning?.publicValue as Any? ?? NSNull(),
            "runState": facts.vmExists ? facts.runState.code : "absent",
            "agent": facts.agent?.code ?? "notObserved",
            "sipDisabled": optional(facts.sipDisabled),
            "amfiDisabled": optional(facts.amfiDisabled),
            "enrollment": facts.enrollment?.rawValue ?? "notObserved",
            "serverTrust": facts.serverTrust?.rawValue ?? "notChecked",
            "retained": retained,
            "steps": plan.steps.map { ["name": $0.name, "detail": $0.detail] },
            "blockers": plan.blockers.map { ["code": $0.code, "message": $0.message] },
            "warnings": plan.warnings.map { ["code": $0.rawValue, "message": $0.message] },
        ]
    }
}
