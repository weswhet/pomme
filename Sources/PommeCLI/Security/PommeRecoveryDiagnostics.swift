import Foundation

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
    let cleanupComplete: Bool
    let finalStateVerified: Bool
    let sensitiveCaptureCleared: Bool

    init(
        stage: PommeRecoveryDiagnosticStage,
        code: PommeRecoveryDiagnosticCode,
        cleanupComplete: Bool = false,
        finalStateVerified: Bool = false,
        sensitiveCaptureCleared: Bool = true
    ) {
        schemaVersion = Self.schemaVersion
        self.stage = stage
        self.code = code
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
        default:
            // Authentication failures are intentionally closed over a stable,
            // redacted code. Do not surface an arbitrary error's description,
            // even when the underlying provider includes paths or secrets.
            code = stage == .authentication ? .authenticationRejected : .unknown
        }
        return .init(
            stage: stage,
            code: code,
            cleanupComplete: cleanupComplete,
            finalStateVerified: finalStateVerified,
            sensitiveCaptureCleared: sensitiveCaptureCleared
        )
    }

    /// Public diagnostics intentionally contain no error text, path, request
    /// identifier, credential, screenshot, command, or guest response.
    static func payload(_ diagnostic: PommeRecoveryDiagnostic) -> [String: Any] {
        [
            "schemaVersion": diagnostic.schemaVersion,
            "stage": diagnostic.stage.rawValue,
            "code": diagnostic.code.rawValue,
            "cleanupComplete": diagnostic.cleanupComplete,
            "finalStateVerified": diagnostic.finalStateVerified,
            "sensitiveCaptureCleared": diagnostic.sensitiveCaptureCleared
        ]
    }
}
