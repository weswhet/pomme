import Foundation
import Testing

@Suite("Pomme provisioning failure diagnostics")
struct PommeProvisioningFailureDiagnosticTests {
    @Test("Typed Recovery failures use stable redacted codes")
    func typedRecoveryFailure() {
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeLiveRecoveryIntegration.Error.runtimeRejected
            ) == "live_recovery.runtime_rejected"
        )
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeRecoveryRuntimeError.attachmentUnverified
            ) == "recovery_runtime.attachment_unverified"
        )
    }

    @Test("Recovery navigation and preparation failures use closed redacted codes")
    func recoverySessionFailureCodes() {
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeRecoverySessionError.observationTimedOut
            ) == "recovery_session.observation_timed_out"
        )
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeRecoverySessionError.terminalProofFailed
            ) == "recovery_session.terminal_proof_failed"
        )
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeRecoverySessionError.rootEvidenceRejected
            ) == "recovery_session.root_evidence_rejected"
        )
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeRecoverySessionError.preparationFailed
            ) == "recovery_session.preparation_failed"
        )
    }

    @Test("Framework diagnostics omit descriptions, paths, and secrets")
    func frameworkFailureIsRedacted() {
        let error = NSError(
            domain: "VZErrorDomain",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "sensitive-token at /private/var/tmp/pomme-recovery-secret"
            ]
        )
        let code = PommeProvisioningFailureDiagnostic.code(for: error)

        #expect(code == "virtualization.2")
        #expect(!code.contains("sensitive-token"))
        #expect(!code.contains("/private"))
    }

    @Test("Headless errors retain only the closed failure code")
    func headlessFailureIsRedacted() {
        let error = VirtualizationPrivateHeadlessError(
            .frameTimeout,
            detail: "sensitive path and OCR text"
        )
        #expect(
            PommeProvisioningFailureDiagnostic.code(for: error)
                == "headless.frame_timeout"
        )
    }
}
