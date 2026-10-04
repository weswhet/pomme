import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Agent update apply")
struct PommeAgentUpdateApplyTests {
    private struct Fixture {
        let root: URL
        let paths: PommeAgentRecoveryInstaller.Paths
        let prefix: String
        let staged: URL
        let bytes: Data
        let digest: String
        let token = Data(String(repeating: "b", count: 64).utf8)

        init(bytes: Data = Data("new agent".utf8)) throws {
            // The guest stages under /private/var; keep that spelling so a
            // check that rewrites it to the /var alias fails here too.
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            root = URL(fileURLWithPath: (temporary.hasPrefix("/private/") ? "" : "/private") + temporary, isDirectory: true)
                .appendingPathComponent("pomme-agent-update-\(UUID().uuidString)", isDirectory: true)
            let directory = root.appendingPathComponent("db", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            paths = .init(
                executable: root.appendingPathComponent("pomme"),
                token: directory.appendingPathComponent("agent.token"),
                plist: root.appendingPathComponent("agent.plist"),
                privateDirectory: directory
            )
            prefix = directory.path + "/agent-update-"
            staged = URL(fileURLWithPath: prefix + UUID().uuidString.lowercased())
            self.bytes = bytes
            digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try bytes.write(to: staged)
            chmod(staged.path, 0o500)
            try Data("old agent".utf8).write(to: paths.executable)
            try token.write(to: paths.token)
            try Data(PommeAgentInstall.definition(digest: String(repeating: "a", count: 64)).utf8).write(to: paths.plist)
        }

        func apply(
            target: String? = nil, selfExecutable: URL? = nil,
            install: @escaping (Data, Data, Data, PommeAgentRecoveryInstaller.Paths) throws -> Void
        ) throws -> PommeAgentUpdateApply.Outcome {
            try PommeAgentUpdateApply.apply(
                staged: staged, targetSHA256: target ?? digest, selfExecutable: selfExecutable ?? staged,
                paths: paths, stagedPrefix: prefix, expectedOwner: getuid(), install: install)
        }
    }

    @Test func installsStagedBytesWithUnchangedTokenAndNewPin() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var installed: (Data, Data, Data)?
        let outcome = try fixture.apply { executable, token, plist, paths in
            #expect(paths == fixture.paths)
            installed = (executable, token, plist)
        }
        #expect(outcome == .applied)
        #expect(installed?.0 == fixture.bytes)
        #expect(installed?.1 == fixture.token)
        #expect(installed?.2 == Data(try PommeAgentInstall.definition(digest: fixture.digest).utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @Test func rerunAfterInstallMakesNoChange() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.bytes.write(to: fixture.paths.executable)
        try Data(PommeAgentInstall.definition(digest: fixture.digest).utf8).write(to: fixture.paths.plist)
        let outcome = try fixture.apply { _, _, _, _ in Issue.record("installed again") }
        #expect(outcome == .alreadyApplied)
    }

    @Test func rejectsDigestMismatchForeignRunnerAndUnstagedPath() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refuse: (Data, Data, Data, PommeAgentRecoveryInstaller.Paths) throws -> Void = { _, _, _, _ in
            Issue.record("installed after rejection")
        }
        #expect(throws: (any Error).self) {
            try fixture.apply(target: String(repeating: "c", count: 64), install: refuse)
        }
        #expect(throws: (any Error).self) {
            try fixture.apply(selfExecutable: fixture.paths.executable, install: refuse)
        }
        #expect(throws: (any Error).self) {
            try PommeAgentUpdateApply.apply(
                staged: fixture.paths.executable, targetSHA256: fixture.digest,
                selfExecutable: fixture.paths.executable, paths: fixture.paths,
                stagedPrefix: fixture.prefix, expectedOwner: getuid(), install: refuse)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @Test func daemonAcceptsOnlyTheDigestPinnedOnDisk() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(PommeAgentInstall.definition(digest: fixture.digest).utf8).write(to: fixture.paths.plist)
        chmod(fixture.paths.plist.path, 0o644)
        let pins = { (digest: String, executable: String) in
            PommeAgentUpdateApply.installedDefinitionPins(
                digest, executablePath: executable, plistPath: fixture.paths.plist.path, expectedOwner: getuid())
        }
        #expect(pins(fixture.digest, PommeAgentInstall.executable))
        #expect(!pins(String(repeating: "a", count: 64), PommeAgentInstall.executable))
        #expect(!pins(fixture.digest, fixture.staged.path))
        chmod(fixture.paths.plist.path, 0o666)
        #expect(!pins(fixture.digest, PommeAgentInstall.executable))
    }
}
