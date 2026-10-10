import Foundation

/// Closed Recovery security failure values carried by the guest-agent error
/// envelope. These values are deliberately independent of native command
/// output, arguments, request payloads, and credentials.
enum PommeRecoveryGuestFailureCode: String, Codable, CaseIterable, Equatable, Sendable {
    case recoveryRoleRequired = "recovery-role-required"
    case rootRequired = "root-required"
    case invalidOperation = "recovery-invalid-operation"
    case invalidPayload = "recovery-invalid-payload"
    case credentialRequired = "recovery-credential-required"
    case commandFailed = "recovery-command-failed"
    case verificationFailed = "recovery-verification-failed"
    case rollbackFailed = "recovery-rollback-failed"
    case invalidSnapshot = "recovery-invalid-snapshot"
    case invalidPolicy = "recovery-invalid-policy"
    case invalidNVRAM = "recovery-invalid-nvram"
    case nvramWriteDenied = "recovery-nvram-write-denied"
    case nvramMutationUnqualified = "recovery-nvram-unqualified"
    case recoveryEnvironmentUnverified = "recovery-environment-unverified"
    case startupVolumeMismatch = "recovery-startup-volume-mismatch"
    case snapshotPending = "recovery-snapshot-pending"
    case promptRejected = "recovery-prompt-rejected"
    case timedOut = "recovery-timed-out"
    case outputTooLarge = "recovery-output-too-large"

    var diagnosticCode: PommeRecoveryDiagnosticCode {
        switch self {
        case .commandFailed: .commandFailed
        case .verificationFailed: .verificationFailed
        case .rollbackFailed: .policyRollbackRejected
        case .invalidSnapshot: .invalidSnapshot
        case .invalidPolicy: .invalidPolicy
        case .invalidNVRAM: .invalidNVRAM
        case .nvramWriteDenied: .operationRejected
        case .snapshotPending: .snapshotPending
        case .promptRejected: .promptRejected
        case .timedOut: .timedOut
        default: .operationRejected
        }
    }

    /// A phase is reported only when the failure itself proves it. A lost
    /// transport has no phase and must remain a generic operation failure.
    var diagnosticPhase: PommeRecoveryDiagnosticPhase? {
        self == .rollbackFailed ? .rollbackFailed : nil
    }

    var pommeCode: PommeErrorCode {
        switch self {
        case .rollbackFailed: .securityRollbackUnverified
        case .verificationFailed: .securityChangeUnverified
        case .invalidSnapshot, .invalidPolicy, .invalidNVRAM: .recoverySecurityStateRejected
        case .snapshotPending: .securityOperationPending
        case .nvramWriteDenied, .commandFailed, .promptRejected: .securityRecoveryCommandFailed
        case .timedOut: .recoveryTimedOut
        case .recoveryRoleRequired, .rootRequired, .invalidOperation, .invalidPayload,
             .credentialRequired, .nvramMutationUnqualified, .recoveryEnvironmentUnverified,
             .startupVolumeMismatch, .outputTooLarge:
            .recoveryOperationFailed
        }
    }

    var userDescription: String {
        switch self {
        case .rollbackFailed:
            "Pomme couldn't verify that Recovery rolled back the security change. Pomme kept the operation's progress."
        case .verificationFailed:
            "Pomme couldn't verify the security change in Recovery. Pomme kept the operation's progress."
        case .invalidSnapshot:
            "The security baseline that Pomme recorded for this VM isn't valid. Pomme kept the operation's progress."
        case .snapshotPending:
            "An earlier security operation on this VM is still unfinished."
        case .invalidPolicy:
            "Recovery reported a boot policy that Pomme can't use. Pomme kept the operation's progress."
        case .invalidNVRAM:
            "Recovery reported NVRAM values that Pomme can't use. Pomme kept the operation's progress."
        case .nvramWriteDenied:
            "Recovery refused to write the AMFI boot arguments to NVRAM. Pomme kept the operation's progress."
        case .commandFailed:
            "A security command in Recovery failed. Pomme kept the operation's progress."
        case .promptRejected:
            "A security command in Recovery showed a prompt that Pomme doesn't answer. Pomme kept the operation's progress."
        case .timedOut:
            "A security command in Recovery didn't finish within its time limit. Pomme kept the operation's progress."
        case .recoveryRoleRequired:
            "The Recovery agent refused the operation because it isn't running in macOS Recovery."
        case .rootRequired:
            "The Recovery agent refused the operation because it isn't running as root."
        case .invalidOperation, .invalidPayload:
            "The Recovery agent refused the operation because the request wasn't valid."
        case .credentialRequired:
            "The Recovery agent refused the operation because the owner's credential was missing."
        case .nvramMutationUnqualified:
            "The Recovery agent refused to change NVRAM because this macOS build isn't qualified for it."
        case .recoveryEnvironmentUnverified:
            "The Recovery agent couldn't verify that it's running in the VM's own Recovery system."
        case .startupVolumeMismatch:
            "The Recovery agent refused the operation because the startup volume isn't the VM's macOS volume."
        case .outputTooLarge:
            "The Recovery agent refused the operation because a command's output exceeded its size limit."
        }
    }

    var userRecoverySuggestion: String? {
        switch self {
        case .rollbackFailed, .verificationFailed, .invalidSnapshot, .invalidPolicy, .invalidNVRAM,
             .nvramWriteDenied, .commandFailed, .promptRejected, .timedOut:
            "Run `pomme sip status NAME` to check the VM, then repeat the same action with the same `--final-state` value to resume."
        case .snapshotPending:
            "Repeat the earlier operation's command with the same `--final-state` value to finish it."
        case .credentialRequired:
            "Provide the owner's credentials, then run the same command again."
        case .recoveryRoleRequired, .rootRequired, .invalidOperation, .invalidPayload,
             .nvramMutationUnqualified, .recoveryEnvironmentUnverified, .startupVolumeMismatch, .outputTooLarge:
            nil
        }
    }
}

/// Translate guest security errors to the closed wire vocabulary without
/// changing the guest operation implementation or exposing its description.
extension PommeGuestRecoverySecurityError {
    var recoveryFailureCode: PommeRecoveryGuestFailureCode {
        switch self {
        case .recoveryRoleRequired: .recoveryRoleRequired
        case .rootRequired: .rootRequired
        case .invalidOperation: .invalidOperation
        case .invalidPayload: .invalidPayload
        case .credentialRequired: .credentialRequired
        case .commandFailed: .commandFailed
        case .verificationFailed: .verificationFailed
        case .rollbackFailed: .rollbackFailed
        case .invalidSnapshot: .invalidSnapshot
        case .invalidPolicy: .invalidPolicy
        case .invalidNVRAM: .invalidNVRAM
        case .nvramWriteDenied: .nvramWriteDenied
        case .nvramMutationUnqualified: .nvramMutationUnqualified
        case .recoveryEnvironmentUnverified: .recoveryEnvironmentUnverified
        case .startupVolumeMismatch: .startupVolumeMismatch
        case .snapshotPending: .snapshotPending
        case .promptRejected: .promptRejected
        case .timedOut: .timedOut
        case .outputTooLarge: .outputTooLarge
        }
    }
}

enum PommeRecoveryDiagnosticPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case rollbackFailed
}

/// A typed guest failure that survived the authenticated session. It carries
/// only the closed failure code and the one phase proven by that code.
struct PommeRecoveryGuestOperationFailure: PommeDescribedError, Equatable, Sendable {
    let failureCode: PommeRecoveryGuestFailureCode
    let phase: PommeRecoveryDiagnosticPhase?

    init(code: PommeRecoveryGuestFailureCode) {
        failureCode = code
        phase = code.diagnosticPhase
    }

    var code: PommeErrorCode { failureCode.pommeCode }
    var errorDescription: String? { failureCode.userDescription }
    var recoverySuggestion: String? { failureCode.userRecoverySuggestion }

    /// The guest's wire code, kept so a report shows the exact failure.
    var underlying: (any Error)? {
        PommeExternalCause(domain: "PommeRecoveryGuest", code: failureCode.rawValue, description: "The Recovery agent reported \(failureCode.rawValue).")
    }
}

enum PommeRecoveryDiagnosticStage: String, Codable, CaseIterable, Equatable, Sendable {
    case request
    case staging
    case authentication
    case operation
    case containment
    case cleanup
    case finalState
}

enum PommeRecoveryDiagnosticCode: String, Codable, CaseIterable, Equatable, Sendable {
    case invalidRequest
    case expiredCredential
    case authenticationRejected
    case evidenceRejected
    case operationRejected
    case commandFailed
    case verificationFailed
    case invalidSnapshot
    case snapshotPending
    case invalidPolicy
    case invalidNVRAM
    case promptRejected
    case timedOut
    case cleanupRejected
    case finalStateUnverified
    case policyRollbackRejected
    case unknown
}

struct PommeRecoveryDiagnostic: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let stage: PommeRecoveryDiagnosticStage
    let code: PommeRecoveryDiagnosticCode
    let phase: PommeRecoveryDiagnosticPhase?
    let cleanupComplete: Bool
    let finalStateVerified: Bool
    let sensitiveCaptureCleared: Bool

    init(
        stage: PommeRecoveryDiagnosticStage,
        code: PommeRecoveryDiagnosticCode,
        phase: PommeRecoveryDiagnosticPhase? = nil,
        cleanupComplete: Bool = false,
        finalStateVerified: Bool = false,
        sensitiveCaptureCleared: Bool = true
    ) {
        schemaVersion = Self.schemaVersion
        self.stage = stage
        self.code = code
        self.phase = phase
        self.cleanupComplete = cleanupComplete
        self.finalStateVerified = finalStateVerified
        self.sensitiveCaptureCleared = sensitiveCaptureCleared
    }
}

enum PommeRecoveryDiagnosticRedactor {
    static func make(
        error: Error,
        stage: PommeRecoveryDiagnosticStage,
        cleanupComplete: Bool = false,
        finalStateVerified: Bool = false,
        sensitiveCaptureCleared: Bool = true
    ) -> PommeRecoveryDiagnostic {
        let code: PommeRecoveryDiagnosticCode
        var phase: PommeRecoveryDiagnosticPhase? = nil
        switch error {
        case PommeRecoverySessionError.expiredCredential:
            code = .expiredCredential
        case PommeRecoverySessionError.invalidProof,
             PommeRecoverySessionError.replayedCredential:
            code = .authenticationRejected
        case PommeRecoverySessionError.rootEvidenceRejected:
            code = .evidenceRejected
        case PommeRecoverySecurityError.rollbackFailed:
            code = .policyRollbackRejected
        case PommeRecoverySessionError.cleanupFailed:
            code = .cleanupRejected
        case PommeRecoverySessionError.finalStateUnverified:
            code = .finalStateUnverified
        case PommeRecoverySecurityError.verificationFailed,
             PommeRecoverySecurityError.operationRejected:
            code = .operationRejected
        case PommeRecoverySessionError.invalidRequest:
            code = .invalidRequest
        case let failure as PommeRecoveryGuestOperationFailure:
            code = failure.failureCode.diagnosticCode
            phase = failure.phase
        default:
            // Authentication failures are intentionally closed over a stable,
            // redacted code. Do not surface an arbitrary error's description,
            // even when the underlying provider includes paths or secrets.
            code = stage == .authentication ? .authenticationRejected : .unknown
        }
        return .init(
            stage: stage,
            code: code,
            phase: phase,
            cleanupComplete: cleanupComplete,
            finalStateVerified: finalStateVerified,
            sensitiveCaptureCleared: sensitiveCaptureCleared
        )
    }

    /// Public diagnostics intentionally contain no error text, path, request
    /// identifier, credential, screenshot, command, or guest response.
    static func payload(_ diagnostic: PommeRecoveryDiagnostic) -> [String: Any] {
        var result: [String: Any] = [
            "schemaVersion": diagnostic.schemaVersion,
            "stage": diagnostic.stage.rawValue,
            "code": diagnostic.code.rawValue,
            "cleanupComplete": diagnostic.cleanupComplete,
            "finalStateVerified": diagnostic.finalStateVerified,
            "sensitiveCaptureCleared": diagnostic.sensitiveCaptureCleared
        ]
        if let phase = diagnostic.phase {
            result["phase"] = phase.rawValue
        }
        return result
    }
}
