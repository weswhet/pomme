import Foundation
import Testing

@Suite("Experimental Recovery resident bootstrap")
struct PommeExperimentalRecoveryBootstrapTests {
    private let vm = "11111111-1111-4111-8111-111111111111"
    private let session = "abcdefab-2222-4222-8222-222222222222"
    private let digest = String(repeating: "a", count: 64)
    private var arguments: [String] {
        ["--pomme-agent", "505054", "--role", "recovery", "--token-file",
         PommeExperimentalRecoveryPayload.runtimeTokenFile, "--expected-sha256", digest,
         "--vm-id", vm, "--session-id", session, "--resident-recovery", session]
    }
    private func parse(_ args: [String]? = nil,
                       executable: String = PommeExperimentalRecoveryPayload.runtimeExecutable) throws -> PommeAgentDaemon.Options {
        try PommeAgentDaemon.parse(arguments: args ?? arguments, executablePath: executable)
    }

    @Test("Production resident is plan-bound, terminal-only, and separate from request ports")
    func guestAdmission() throws {
        let options = try parse()
        #expect(options.port == 505054)
        #expect(options.terminalAuthority && options.residentRecovery)
        #expect(options.allowedOperation == "terminal.session")
        #expect(!options.consumesToken)
        #expect(PommeAgentVSOCKRole.recoveryResident.port != PommeAgentVSOCKRole.recoveryRuntime.port)
        for (old, replacement) in [("505054", "505053"), ("505054", "505052"),
                                   ("recovery", "normal"), (vm, "invalid"),
                                   (PommeExperimentalRecoveryPayload.runtimeTokenFile, "/tmp/token")] {
            #expect(throws: Error.self) { try parse(arguments.map { $0 == old ? replacement : $0 }) }
        }
        var wrongSession = arguments
        wrongSession[wrongSession.count - 1] = vm
        #expect(throws: Error.self) { try parse(wrongSession) }
        #expect(throws: Error.self) { try parse(executable: "/pomme-recovery-payload/pomme") }
        #expect(throws: Error.self) { try parse(arguments + ["--resident-recovery-lab", "pomme-agent-test"]) }
        for extra in [["--operation", "agent.install"], ["--request-file", "/tmp/request"],
                      ["--one-shot-expiry", String(Date().timeIntervalSince1970 + 60)]] {
            #expect(throws: Error.self) { try parse(arguments + extra) }
        }
    }

    @Test("Production image wrapper has no lab environment dependency")
    func productionArtifacts() throws {
        let script = PommeExperimentalRecoveryPayload.wrapper(digest: digest,
            vmID: UUID(uuidString: vm)!, sessionID: UUID(uuidString: session)!)
        #expect(script.contains("--pomme-agent 505054"))
        #expect(script.contains("--resident-recovery '" + session + "'"))
        #expect(script.contains("stage=" + PommeExperimentalRecoveryPayload.runtimeDirectory))
        #expect(!script.contains("POMME_LAB_"))
        let bytes = try PommeExperimentalRecoveryPayload.plist()
        let decoded = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        let plist = try #require(decoded as? [String: Any])
        #expect(plist["EnvironmentVariables"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["Label"] as? String == PommeExperimentalRecoveryPayload.jobLabel)
    }

    @Test("Bootstrap rejects a different executable or privileged guest authority")
    func descriptionBinding() throws {
        var fields: [String: JSONValue] = ["role": .string("recovery"),
            "protocol": .string(PommeAgentProtocol.name), "version": .integer(Int64(PommeAgentProtocol.version)),
            "executableSHA256": .string(digest),
            "terminalSessionVersion": .integer(Int64(PommeAgent.terminalSessionVersion)),
            "capabilities": .array(PommeAgent.recoveryTerminalCapabilities.map(JSONValue.string))]
        try PommeExperimentalRecoveryBootstrap.validate(description: .object(fields), executableSHA256: digest)
        #expect(throws: Error.self) {
            try PommeExperimentalRecoveryBootstrap.validate(description: .object(fields), executableSHA256: String(repeating: "b", count: 64))
        }
        for (key, badValue) in [("role", JSONValue.string("persistent")),
                                ("protocol", .string("different-protocol")),
                                ("version", .integer(999)), ("terminalSessionVersion", .integer(999)),
                                ("capabilities", .array([.string("agent.describe")])),
                                ("capabilities", .array(PommeAgent.recoveryTerminalCapabilities.map(JSONValue.string) + [.integer(1)]))] {
            var changed = fields
            changed[key] = badValue
            #expect(throws: Error.self) {
                try PommeExperimentalRecoveryBootstrap.validate(description: .object(changed), executableSHA256: digest)
            }
        }
        fields["capabilities"] = .array((PommeAgent.recoveryTerminalCapabilities + ["agent.install"]).map(JSONValue.string))
        #expect(throws: Error.self) {
            try PommeExperimentalRecoveryBootstrap.validate(description: .object(fields), executableSHA256: digest)
        }
    }
    @Test("Production staging resumes partial writes and a committed temporary link")
    func interruptedStaging() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("pomme-production-stage-test-" + UUID().uuidString)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("source")
        let bytes = Data("complete signed artifact fixture".utf8)
        try bytes.write(to: source)
        let partial = staging.appendingPathComponent("pomme.next")
        #expect(FileManager.default.createFile(atPath: partial.path, contents: Data("partial".utf8), attributes: [.posixPermissions: 0o600]))
        func stage() throws {
            try PommeExperimentalRecoveryPayload.stage(directory: staging, target: "ordinary-vm",
                sessionID: UUID(uuidString: session)!, executable: source,
                expectedDigest: PommeProvisioningDigest.sha256(bytes), credential: String(repeating: "c", count: 64),
                vmID: UUID(uuidString: vm)!, diskPath: root.appendingPathComponent("Disk.img").path)
        }
        try stage()
        #expect(try Data(contentsOf: staging.appendingPathComponent("pomme")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try FileManager.default.linkItem(at: staging.appendingPathComponent("pomme"), to: partial)
        try stage()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: staging.appendingPathComponent("pomme")) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).allSatisfy { !$0.hasSuffix(".next") })
        // After preparation, Keychain keeps the only host copy of the credential.
        let token = staging.appendingPathComponent("agent.token")
        #expect(FileManager.default.fileExists(atPath: token.path))
        try PommeExperimentalRecoveryPayload.removeCredential(from: staging)
        #expect(!FileManager.default.fileExists(atPath: token.path))
        try PommeExperimentalRecoveryPayload.removeCredential(from: staging)
        #expect(try Data(contentsOf: staging.appendingPathComponent("pomme")) == bytes)
        // A later restage that precedes another preparation writes it again.
        try stage()
        #expect(FileManager.default.fileExists(atPath: token.path))
    }

    @Test("Virtualization creation discloses the selected Recovery installer")
    func creationDisclosure() {
        let fields = PommeCore.provisioningDisclosure(virtualization: true, experimentalRecovery: true)
        #expect(fields["guestProvisioning"] == "virtualization")
        #expect(fields["agentInstallMethod"] == "experimental-recovery")
        #expect(PommeApplication.provisioningSummary(fields).contains("agent=experimental-recovery"))
        #expect(PommeApplication.provisioningSummary(PommeCore.provisioningDisclosure(virtualization: true))
            .contains("agent=ssh-bootstrap"))
    }

}
