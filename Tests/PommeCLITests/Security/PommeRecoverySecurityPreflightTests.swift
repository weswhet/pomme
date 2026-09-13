import Foundation
import Testing

@Suite("Recovery security qualification before effects")
struct PommeRecoverySecurityPreflightTests {
    @Test("Every security action accepts a planner-qualified experimental profile and stops at the next gate", arguments: [
        PommeRecoveryOperation.sip(.status), .sip(.enable), .sip(.disable),
        .amfi(.status), .amfi(.enable), .amfi(.disable)
    ])
    func experimentalSecurityPassesProfileGate(_ operation: PommeRecoveryOperation) async throws {
        let fixture = try SecurityPreflightFixture()
        let integration = try await fixture.factory.make(reference: fixture.reference, operation: operation)
        do {
            switch operation {
            case .sip(let action): _ = try await integration.sip(action: action, finalState: .stopped)
            case .amfi(let action): _ = try await integration.amfi(action: action, finalState: .stopped)
            case .installAgent: Issue.record("Unexpected install operation")
            case .terminalSession: Issue.record("Unexpected terminal operation")
            }
            Issue.record("Security operation unexpectedly succeeded without a runtime")
        } catch {
            #expect(!(error is PommeRecoverySecurityQualification.Error))
        }
        // The profile gate is crossed; whatever gate follows is not a live effect.
        #expect(Array(fixture.trace.events.prefix(3)) == ["identity", "executable", "profile"])
        #expect(fixture.trace.events.count > 3)
        #expect(!fixture.trace.events.contains("runtime"))
    }

    @Test("Experimental agent installation still passes qualification")
    func experimentalInstallRemainsAvailable() async throws {
        let fixture = try SecurityPreflightFixture()
        let integration = try await fixture.factory.make(reference: fixture.reference, operation: .installAgent)
        await #expect(throws: PommeLiveRecoveryIntegration.Error.credentialRejected) {
            _ = try await integration.installAgent(finalState: .stopped)
        }
        #expect(fixture.trace.events == ["identity", "executable", "profile", "installMode", "credential"])
    }
}

private enum SecurityPreflightStop: Error { case unexpectedEffect }

private final class SecurityPreflightTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    func record(_ event: String) { lock.withLock { values.append(event) } }
}

private struct SecurityPreflightFixture {
    let reference: VMReference
    let factory: PommeRecoveryIntegrationFactory
    let trace: SecurityPreflightTrace

    init() throws {
        // Only in-memory identities are used: no VM bundle, credential or file is created.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-security-preflight-\(UUID().uuidString)")
        reference = VMReference(name: "preflight", bundle: BundleLayout(rootURL: root))
        let owner = try PommeVMOwnership(name: "preflight", uuid: UUID(), bundlePath: root.path)
        let identity = try PommeLiveRecoveryIntegration.VMIdentity(ownership: owner)
        let executable = try PommeLiveRecoveryIntegration.ExecutableIdentity(
            url: root.appendingPathComponent("pomme"), sha256: String(repeating: "a", count: 64))
        let descriptor = try PommeRecoveryProfileSelector.descriptor(version: "15.6.1", build: "24G90")
        let profile = PommeRecoveryProfileEvidence(
            build: .experimental(version: "15.6.1", build: "24G90"), locale: .english,
            geometry: .pixels1280x800, privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .experimentalProfile(descriptor.digest), ownership: .verified)
        let trace = SecurityPreflightTrace()
        self.trace = trace
        factory = PommeLiveRecoveryIntegration.factory(dependencies: .init(
            resolveVM: { _ in trace.record("identity"); return identity },
            resolveExecutable: { _, _ in trace.record("executable"); return executable },
            makeRuntime: { _, _, _, _ in
                trace.record("runtime"); throw SecurityPreflightStop.unexpectedEffect
            },
            stagingParent: { _ in
                trace.record("staging"); throw SecurityPreflightStop.unexpectedEffect
            },
            recoveryProfileEvidence: { _ in trace.record("profile"); return profile },
            persistentAgentSecret: { _ in
                trace.record("persistentSecret"); throw SecurityPreflightStop.unexpectedEffect
            },
            resolveInstallMode: { _, _ in trace.record("installMode"); return .initial },
            issueCredential: { _ in
                trace.record("credential"); throw PommeLiveRecoveryIntegration.Error.credentialRejected
            }
        ))
    }
}
