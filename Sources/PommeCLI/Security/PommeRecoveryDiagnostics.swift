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

    var userDescription: String {
        switch self {
        case .rollbackFailed:
            "Recovery security rollback was not verified; the retained transaction requires inspection before retry."
        case .verificationFailed:
            "Recovery security change was not verified; the retained transaction requires inspection before retry."
        case .invalidSnapshot:
            "The retained Recovery security baseline is invalid; inspect the transaction before retry."
        case .snapshotPending:
            "A previous Recovery security transaction remains pending; inspect it before retrying."
        case .invalidPolicy:
            "The Recovery boot policy was rejected; the retained transaction requires inspection before retry."
        case .invalidNVRAM:
            "The Recovery NVRAM state was rejected; the retained transaction requires inspection before retry."
        case .nvramWriteDenied:
            "Recovery denied the AMFI boot-argument write; the retained transaction requires inspection before retry."
        case .commandFailed:
            "The Recovery security command failed; the retained transaction requires inspection before retry."
        case .promptRejected:
            "The Recovery security command presented an unsupported prompt; the retained transaction requires inspection before retry."
        case .timedOut:
            "The Recovery security command timed out; the retained transaction requires inspection before retry."
        case .recoveryRoleRequired, .rootRequired, .invalidOperation, .invalidPayload,
             .credentialRequired, .nvramMutationUnqualified, .recoveryEnvironmentUnverified,
             .startupVolumeMismatch, .outputTooLarge:
            "The authenticated Recovery security operation was rejected."
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
struct PommeRecoveryGuestOperationFailure: Error, LocalizedError, Equatable, Sendable {
    let code: PommeRecoveryGuestFailureCode
    let phase: PommeRecoveryDiagnosticPhase?

    init(code: PommeRecoveryGuestFailureCode) {
        self.code = code
        phase = code.diagnosticPhase
    }

    var errorDescription: String? { code.userDescription }
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
            code = failure.code.diagnosticCode
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
