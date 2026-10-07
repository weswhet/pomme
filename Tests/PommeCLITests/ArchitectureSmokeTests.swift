import Foundation
import Testing

@Suite("Pomme architecture")
struct ArchitectureSmokeTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Independent protocols start at version one with fixed bounds")
    func protocolContracts() {
        #expect(PommeControlProtocol.version == 1)
        #expect(PommeControlProtocol.maximumFrameBytes == 256 * 1024)
        #expect(PommeControlProtocol.maximumStreamChunkBytes == 64 * 1024)
        #expect(PommeAgentProtocol.version == 1)
        #expect(PommeAgentProtocol.maximumFrameBytes == 256 * 1024)
        #expect(PommeAgentProtocol.maximumStreamChunkBytes == 64 * 1024)
        #expect(PommeAgentProtocol.maximumFileChunkBytes == 32 * 1024)
    }

    @Test("Only Pomme agent ports exist")
    func agentPorts() {
        #expect(Constants.pommeAgentPort == 505_051)
        #expect(Constants.pommeRecoverySessionPort == 505_052)
        #expect(Constants.pommeRecoveryRuntimePort == 505_053)
        let retired = UInt32(505_000 + 50)
        let active = [
            PommeAgentPort.persistentNormal,
            PommeAgentPort.recoveryBootstrap,
            PommeAgentPort.recoveryRuntime
        ]
        #expect(active.contains(retired) == false)
    }

    @Test("Fixed host and guest identities are Pomme-only")
    func productIdentity() throws {
        #expect(Constants.appSupportDirectoryName == "pomme")
        #expect(Constants.vmNameEnvironmentVariable == "POMME_VM_NAME")
        #expect(PommeAgentInstall.executable == "/usr/local/libexec/pomme")
        #expect(PommeAgentInstall.label == "com.github.weswhet.pomme.agent")
        #expect(PommeAgentInstall.token == "/private/var/db/pomme/agent.token")

        let config = try String(
            contentsOf: root.appendingPathComponent("Config/Shared.xcconfig"),
            encoding: .utf8
        )
        #expect(config.contains("PRODUCT_NAME = pomme"))
        #expect(config.contains("PRODUCT_BUNDLE_IDENTIFIER = com.github.weswhet.pomme"))
        // Scripts/plan-release.sh reads the next stable version from here.
        #expect(config.range(
            of: #"(?m)^MARKETING_VERSION = \d+\.\d+\.\d+$"#,
            options: .regularExpression
        ) != nil)
    }

    @Test("Source tree contains no retired guest protocol identifiers")
    func retiredIdentifiersAreAbsent() throws {
        let sources = root.appendingPathComponent("Sources/PommeCLI")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let retired = [
            "q" + "ga",
            "fall" + "backAgent",
            "Fall" + "backAgent",
            "fall" + "backOnly",
            "Fall" + "backOnly",
            "apple-" + "vsock",
            "Fresh" + "Lab",
            "Import" + "Command",
            "import" + "VM",
            String(505_000 + 50)
        ]
        for identifier in retired {
            #expect(!text.localizedCaseInsensitiveContains(identifier), "Retired identifier: \(identifier)")
        }
    }

    @Test("Release publishing is manually protected")
    func releaseGate() throws {
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        #expect(workflow.contains("workflow_dispatch"))
        #expect(workflow.contains("pomme-release"))
        #expect(workflow.contains("qualification"))
        #expect(!workflow.contains("push:\n    tags:"))
    }

    @Test("Production automation stays headless")
    func headlessAutomation() throws {
        let sources = root.appendingPathComponent("Sources/PommeCLI")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for symbol in [
            "VZVirtualMachineView", "NSWindow", "ScreenCaptureKit",
            "makeKeyAndOrderFront", "CGEvent.post", ".post(tap:"
        ] {
            #expect(!text.contains(symbol), "Host-visible automation symbol: \(symbol)")
        }
    }
}
