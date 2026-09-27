import Foundation
import Testing

@Suite("Scoped autologin comparison")
struct PommeAutologinComparisonTests {
    @Test("Production harness selects the exact normal owner path without a lab override")
    func productionOwnerRoute() throws {
        #expect(PommeAutologinComparisonStrategy.production.vmName == "pomme-agent-ownerflow26-20260927a")
        #expect(PommeAutologinComparisonStrategy.production.ownerPreparationOverride == nil)
        for strategy in [PommeAutologinComparisonStrategy.native, .legacy, .markerfirst] {
            #expect(strategy.ownerPreparationOverride == strategy)
            #expect(throws: (any Error).self) {
                try PommeAutologinComparison.validateScope(
                    name: PommeAutologinComparisonStrategy.production.vmName, strategy: strategy)
            }
            #expect(throws: (any Error).self) {
                try PommeAutologinComparison.validateScope(name: strategy.vmName, strategy: .production)
            }
        }
    }

    @Test("Marker-first console proof requires exact owner and UID")
    func consoleProof() {
        func result(_ text: String, timedOut: Bool = false) -> GuestCommandResult {
            .init(exitCode: 0, signal: nil, stdout: Data(text.utf8), stderr: Data(),
                  stdoutTruncated: false, stderrTruncated: false, timedOut: timedOut)
        }
        #expect(PommeAutologinComparison.ownerConsoleMatches(result("pomme:501\n"), username: "pomme", uniqueID: 501))
        #expect(!PommeAutologinComparison.ownerConsoleMatches(result("pomme:502\n"), username: "pomme", uniqueID: 501))
        #expect(!PommeAutologinComparison.ownerConsoleMatches(result("_mbsetupuser:248\n"), username: "pomme", uniqueID: 501))
        #expect(!PommeAutologinComparison.ownerConsoleMatches(result("pomme:501\n", timedOut: true), username: "pomme", uniqueID: 501))
    }

    @Test("Clone preflight uses runtime volume identity when immutable input has none")
    func runtimeVolumeIdentity() throws {
        let template = "/private/test/template.bundle"
        let input = PommeProvisioningInput(
            restoreImagePath: "/private/test/image.ipsw",
            memorySizeBytes: 4 * 1024 * 1024 * 1024,
            diskSizeBytes: 40 * 1024 * 1024 * 1024,
            hardwareModelData: Data([1]), machineIdentifierData: Data([1]),
            startupVolumeGroupUUID: nil, templateBundlePath: template)
        let group = UUID()
        #expect(input.startupVolumeGroupUUID == nil)
        #expect(try PommeAutologinComparison.validateClone(
            version: "26.6.2", build: "25G83", input: input,
            runtime: .init(vmUUID: UUID(), startupVolumeGroupUUID: group),
            expectedTemplatePath: template, frameworkOwnerPresent: false) == group)
        do {
            _ = try PommeAutologinComparison.validateClone(
                version: "26.6.2", build: "25G83", input: input,
                runtime: .init(vmUUID: UUID(), startupVolumeGroupUUID: nil),
                expectedTemplatePath: template, frameworkOwnerPresent: false)
            Issue.record("Missing runtime identity was accepted")
        } catch {
            #expect(error.localizedDescription.contains("runtime startup-volume-group identity is missing"))
        }
    }

    @Test("Only the assigned name can select each arm")
    func scope() throws {
        for strategy in [PommeAutologinComparisonStrategy.native, .legacy, .markerfirst, .production] {
            try PommeAutologinComparison.validateScope(name: strategy.vmName, strategy: strategy)
            for name in ["arbitrary", PommeAutologinComparison.templateName,
                         strategy == .native ? PommeAutologinComparisonStrategy.legacy.vmName
                                             : PommeAutologinComparisonStrategy.native.vmName] {
                #expect(throws: (any Error).self) {
                    try PommeAutologinComparison.validateScope(name: name, strategy: strategy)
                }
            }
        }
    }

    @Test("Legacy credential is carried only in authenticated stdin")
    func secretTransport() throws {
        let password = "private-example-password"
        let request = PommeAutologinComparison.legacyRequest(password: password)
        try request.validate()
        #expect(request.inputData == kcpasswordData(for: password))
        #expect(request.environment.isEmpty)
        #expect(!request.arguments.joined().contains(password))
        #expect(!request.arguments.joined().contains(kcpasswordData(for: password).base64EncodedString()))
        #expect(request.guestStdoutPath == nil)
        #expect(request.guestStderrPath == nil)
        #expect(!request.pty)
    }
}
