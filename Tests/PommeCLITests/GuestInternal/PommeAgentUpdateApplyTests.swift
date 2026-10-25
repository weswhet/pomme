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
            target: String? = nil, selfExecutable: URL? = nil, replacement: Data? = nil,
            install: @escaping (Data, Data, Data, PommeAgentRecoveryInstaller.Paths) throws -> Void
        ) throws -> PommeAgentUpdateApply.Outcome {
            try PommeAgentUpdateApply.apply(
                staged: staged, targetSHA256: target ?? digest, selfExecutable: selfExecutable ?? staged,
                replacementCredential: replacement,
                paths: paths, stagedPrefix: prefix, expectedOwner: getuid(), install: install)
        }
    }

    @Test func replacementCredentialIsInstalledWithTheNewBytes() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacement = Data(String(repeating: "c", count: 64).utf8)
        var installed: (Data, Data, Data)?
        let outcome = try fixture.apply(replacement: replacement + Data("\n".utf8)) { executable, token, plist, _ in
            installed = (executable, token, plist)
        }
        #expect(outcome == .applied)
        #expect(installed?.0 == fixture.bytes)
        // The token file holds the bare credential, exactly as an install writes it.
        #expect(installed?.1 == replacement)
        #expect(installed?.2 == Data(try PommeAgentInstall.definition(digest: fixture.digest).utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    @Test func replacementCredentialAloneStillInstalls() throws {
        // A rerun after the bytes were installed but before the credential was
        // must not report the update as already applied.
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.bytes.write(to: fixture.paths.executable)
        try Data(PommeAgentInstall.definition(digest: fixture.digest).utf8).write(to: fixture.paths.plist)
        let replacement = Data(String(repeating: "c", count: 64).utf8)
        var installedToken: Data?
        #expect(try fixture.apply(replacement: replacement) { _, token, _, _ in installedToken = token } == .applied)
        #expect(installedToken == replacement)

        let rerun = try Fixture()
        defer { try? FileManager.default.removeItem(at: rerun.root) }
        try rerun.bytes.write(to: rerun.paths.executable)
        try Data(PommeAgentInstall.definition(digest: rerun.digest).utf8).write(to: rerun.paths.plist)
        try replacement.write(to: rerun.paths.token)
        #expect(try rerun.apply(replacement: replacement) { _, _, _, _ in Issue.record("installed again") } == .alreadyApplied)
    }

    @Test func interruptedTransactionIsRecoveredBeforeTheAlreadyAppliedCheck() throws {
        // The installed files look current, but an interrupted transaction
        // left a journal whose recovery changes them: the comparison must see
        // the recovered state, not skip recovery.
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacement = Data(String(repeating: "c", count: 64).utf8)
        try fixture.bytes.write(to: fixture.paths.executable)
        try Data(PommeAgentInstall.definition(digest: fixture.digest).utf8).write(to: fixture.paths.plist)
        try replacement.write(to: fixture.paths.token)
        var recovered: [URL] = []
        var installedToken: Data?
        let outcome = try PommeAgentUpdateApply.apply(
            staged: fixture.staged, targetSHA256: fixture.digest, selfExecutable: fixture.staged,
            replacementCredential: replacement, paths: fixture.paths, stagedPrefix: fixture.prefix,
            expectedOwner: getuid(),
            recoverInstallJournal: { journal in
                recovered.append(journal)
                // Rolling back restores the previous credential.
                try fixture.token.write(to: fixture.paths.token)
            },
            install: { _, token, _, _ in installedToken = token })
        #expect(recovered == [fixture.paths.privateDirectory.appendingPathComponent("agent-install.journal")])
        #expect(outcome == .applied)
        #expect(installedToken == replacement)
    }

    @Test func malformedReplacementCredentialIsRejectedBeforeInstall() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for bad in ["", "short", String(repeating: "C", count: 64), String(repeating: "c", count: 64) + "\n\n"] {
            #expect(throws: (any Error).self) {
                try fixture.apply(replacement: Data(bad.utf8)) { _, _, _, _ in Issue.record("installed a bad credential") }
            }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.staged.path))
        #expect(try PommeAgentUpdateApply.credential(fromStandardInput: Data((String(repeating: "a", count: 64) + "\n").utf8))
            == Data(String(repeating: "a", count: 64).utf8))
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
