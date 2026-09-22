import Foundation
import Testing

@Suite("Bootstrap diagnostic redaction")
struct PommeBootstrapDiagnosticsTests {
    @Test func candidateCheckpointIsRenderedOncePerAttemptButAlwaysUpdatesFailureStage() {
        for _ in 0..<2 {
            var diagnostics = PommeBootstrapDiagnostics()
            #expect(diagnostics.discoveryCandidateCheckpoint() == "bootstrap checkpoint stage=discoveryCandidateSelected")
            #expect(diagnostics.checkpoint(.discoveryKeyscanSucceeded) == "bootstrap checkpoint stage=discoveryKeyscanSucceeded")
            #expect(diagnostics.discoveryCandidateCheckpoint() == nil)
            #expect(diagnostics.failure() == "bootstrap failed stage=discoveryCandidateSelected")
            #expect(diagnostics.checkpoint(.discoveryLeaseVerified) == "bootstrap checkpoint stage=discoveryLeaseVerified")
        }
    }

    @Test func firstAuthenticationHasExtendedBoundedDeadline() throws {
        #expect(PommeSSHBootstrap.firstAuthenticationTimeout == 180)
        var messages: [String] = []
        _ = try PommeCore.runBootstrapProcess("/usr/bin/true", arguments: [],
            timeout: PommeSSHBootstrap.firstAuthenticationTimeout,
            operation: .sshAuthenticationAndUIDVerification, diagnostic: { messages.append($0) })
        #expect(messages == [
            "bootstrap process operation=sshAuthenticationAndUIDVerification outcome=started timeoutSeconds=180.0",
            "bootstrap process operation=sshAuthenticationAndUIDVerification outcome=succeeded timeoutSeconds=180.0",
        ])
    }

    @Test func everyDiagnosticUsesOnlyClosedVocabulary() {
        let allowed = Set([
            "started", "journalValidated", "ownerReferenceVerified", "dispatchMarkerVerified",
            "agentCredentialAvailable", "runtimeRecordAbsent", "runtimeStartAttempted", "runtimeStartSucceeded",
            "workspaceVerified", "discoveryStarted", "keyPinned", "sshUIDVerified",
            "discoveryCandidateSelected", "discoveryKeyscanSucceeded", "discoveryLeaseVerified",
            "requestVerified", "stagingVerified", "installerInvoked", "agentConnected",
        ])
        #expect(Set(PommeBootstrapDiagnostics.Stage.allCases.map(\.rawValue)) == allowed)
        var diagnostics = PommeBootstrapDiagnostics()
        for stage in PommeBootstrapDiagnostics.Stage.allCases {
            #expect(diagnostics.checkpoint(stage) == "bootstrap checkpoint stage=" + stage.rawValue)
            #expect(diagnostics.failure() == "bootstrap failed stage=" + stage.rawValue)
        }
    }

    @Test func underlyingErrorCannotEnterFailureDiagnostic() throws {
        let secret = "private-password-token-request-host-key"
        let underlying = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        var diagnostics = PommeBootstrapDiagnostics()
        _ = diagnostics.checkpoint(.runtimeStartAttempted)
        var rendered = ""
        do {
            do { throw underlying }
            catch {
                rendered = diagnostics.failure()
                throw error
            }
        } catch {
            #expect((error as NSError) === underlying)
        }
        #expect(rendered == "bootstrap failed stage=runtimeStartAttempted")
        #expect(!rendered.contains(secret))
    }
}
