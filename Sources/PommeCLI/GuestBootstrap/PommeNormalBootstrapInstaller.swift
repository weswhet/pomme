import Darwin
import Foundation

/// A one-shot normal-OS installer. All errors are deliberately non-descriptive.
enum PommeNormalBootstrapInstaller {
    static let flag = "--pomme-normal-bootstrap-install"
    struct Expected {
        let vmUUID: UUID
        let planSHA256: String
        let executableSHA256: String
        let requestID: UUID
    }
    static func install(workspace: URL, sourceWorkspace: URL, expected: Expected, selfExecutable: URL, paths: PommeAgentRecoveryInstaller.Paths = .init(), now: Date = Date(), phase: (Int32) -> Void = { _ in }, run: (String, [String]) throws -> Int32) throws {
        phase(51)
        guard geteuid() == 0 else { throw PommeSSHBootstrapError.invalid }
        let staged = try validateStaging(workspace: workspace, selfExecutable: selfExecutable, now: now, expected: expected)
        // The host verifies the signed artifact; validateStaging binds these exact bytes by SHA256.
        phase(52)
        let request = staged.request, executable = staged.executable, token = staged.token
        let requestURL = workspace.appendingPathComponent("request.json")
        let executableURL = workspace.appendingPathComponent("pomme")
        let tokenURL = workspace.appendingPathComponent("agent.token")
        let plist = Data(try PommeAgentInstall.definition(digest: request.executableSHA256).utf8)
        let files: [(URL, Data, mode_t)] = [(paths.executable, executable, 0o555), (paths.token, token, 0o400), (paths.plist, plist, 0o644)]
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.0.path) }
        if !existing.isEmpty {
            // A complete committed install is replayable; partial or different state is not.
            guard existing.count == files.count else { throw PommeSSHBootstrapError.invalid }
            for (url, data, mode) in files {
                guard try PommeSSHBootstrap.privateRead(url, owner: 0, allowedModes: [mode], maximum: max(data.count, 1)) == data else { throw PommeSSHBootstrapError.invalid }
            }
        } else {
            for (root, directory) in [("/usr", paths.executable.deletingLastPathComponent()), ("/Library", paths.plist.deletingLastPathComponent()), ("/private/var/db", paths.privateDirectory.deletingLastPathComponent())] {
                try PommeAgentFileTransaction.ensureDirectoryTree(under: URL(fileURLWithPath: root), through: directory, createdMode: 0o755, owner: 0, group: 0)
            }
            try PommeAgentRecoveryInstaller().installTransaction(executable: executable, token: token, plist: plist, paths: paths)
        }
        phase(53)
        try cleanSourceWorkspace(sourceWorkspace, staged: staged)
        // Recheck each exact artifact before removal; unexpected changes retain the staging directory.
        let stagedFiles: [(URL, Data, Set<mode_t>)] = [(requestURL, try JSONEncoder().encode(request), [0o600]), (executableURL, executable, [0o700, 0o500]), (tokenURL, token, [0o600])]
        for (url, expected, modes) in stagedFiles {
            let bytes = try PommeSSHBootstrap.privateRead(url, owner: 0, allowedModes: modes, maximum: max(expected.count * 2, executable.count))
            if url == requestURL { guard try JSONDecoder().decode(PommeBootstrapRequest.self, from: bytes) == request else { throw PommeSSHBootstrapError.invalid } }
            else { guard bytes == expected else { throw PommeSSHBootstrapError.invalid } }
        }
        for url in [requestURL, executableURL, tokenURL] { guard unlink(url.path) == 0 else { throw PommeSSHBootstrapError.invalid } }
        guard rmdir(workspace.path) == 0 else { throw PommeSSHBootstrapError.invalid }
        // No bootstrap token or executable remains in either staging location
        // before the agent can connect and make a lost SSH reply replayable.
        phase(54)
        try activate(plist: paths.plist, run: run)
    }

    struct Staging: CustomStringConvertible {
        let request: PommeBootstrapRequest
        let executable: Data
        let token: Data
        var description: String { "PommeBootstrapStaging(redacted)" }
    }
    static func validateStaging(workspace: URL, selfExecutable: URL, now: Date, expected: Expected, expectedOwner: uid_t = 0, requiredParent: URL = URL(fileURLWithPath: "/private/var/tmp")) throws -> Staging {
        // Foundation may resolve the real /private/var path to its /var alias.
        // Check lexical normalization here; lstat below rejects a linked workspace.
        guard workspace.path == workspace.standardized.path,
              workspace.deletingLastPathComponent().path == requiredParent.path,
              workspace.lastPathComponent.hasPrefix("pomme-bootstrap-root-\(expected.requestID.uuidString.lowercased()).") else { throw PommeSSHBootstrapError.invalid }
        var directory = stat()
        guard lstat(workspace.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_mode & 0o7777 == 0o700, directory.st_uid == expectedOwner else { throw PommeSSHBootstrapError.invalid }
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        guard Set(names) == ["request.json", "pomme", "agent.token"] else { throw PommeSSHBootstrapError.invalid }
        let requestURL = workspace.appendingPathComponent("request.json")
        let executableURL = workspace.appendingPathComponent("pomme")
        let tokenURL = workspace.appendingPathComponent("agent.token")
        let request = try JSONDecoder().decode(PommeBootstrapRequest.self, from: PommeSSHBootstrap.privateRead(requestURL, owner: directory.st_uid, allowedModes: [0o600]))
        guard request.requestID == expected.requestID else { throw PommeSSHBootstrapError.invalid }
        let executable = try PommeSSHBootstrap.privateRead(executableURL, owner: directory.st_uid, allowedModes: [0o700, 0o500], maximum: PommeRecoveryStagingBuilder.maximumExecutableBytes)
        let token = try PommeSSHBootstrap.privateRead(tokenURL, owner: directory.st_uid, allowedModes: [0o600], maximum: 128)
        guard let tokenText = String(data: token, encoding: .utf8), try PommeAgentAuthentication.normalized(tokenText) == tokenText else { throw PommeSSHBootstrapError.invalid }
        let ownBytes = try PommeAgentFileTransaction.readRegular(selfExecutable, maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes)
        guard PommeBootstrapRequest.digest(ownBytes) == request.executableSHA256,
              PommeBootstrapRequest.digest(executable) == request.executableSHA256 else { throw PommeSSHBootstrapError.invalid }
        try request.verify(token: token, now: now, vmUUID: expected.vmUUID, planSHA256: expected.planSHA256, executableSHA256: expected.executableSHA256)
        return Staging(request: request, executable: executable, token: token)
    }

    static func cleanSourceWorkspace(_ workspace: URL, staged: Staging) throws {
        let expectedPath = "/private/var/tmp/pomme-bootstrap-\(staged.request.requestID.uuidString.lowercased())"
        guard workspace.path == expectedPath, workspace.path == workspace.standardized.path else { throw PommeSSHBootstrapError.invalid }
        var directory = stat()
        if lstat(workspace.path, &directory) != 0 { guard errno == ENOENT else { throw PommeSSHBootstrapError.invalid }; return }
        guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == staged.request.stagingOwner, directory.st_mode & 0o7777 == 0o700 else { throw PommeSSHBootstrapError.invalid }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: workspace.path))
        guard names.isSubset(of: ["pomme", "request.json"]) else { throw PommeSSHBootstrapError.invalid }
        for name in names {
            let url = workspace.appendingPathComponent(name)
            let bytes = try PommeSSHBootstrap.privateRead(url, owner: staged.request.stagingOwner, allowedModes: [name == "pomme" ? 0o700 : 0o600], maximum: PommeRecoveryStagingBuilder.maximumExecutableBytes)
            if name == "pomme" { guard bytes == staged.executable else { throw PommeSSHBootstrapError.invalid } }
            else {
                let source = try JSONDecoder().decode(PommeBootstrapRequest.self, from: bytes)
                try source.authenticate(token: staged.token, vmUUID: staged.request.vmUUID, planSHA256: staged.request.planSHA256, executableSHA256: staged.request.executableSHA256)
                guard source.requestID == staged.request.requestID, source.stagingOwner == staged.request.stagingOwner,
                      source.expiresAt <= staged.request.expiresAt else { throw PommeSSHBootstrapError.invalid }
            }
        }
        for name in names { guard unlink(workspace.appendingPathComponent(name).path) == 0 else { throw PommeSSHBootstrapError.invalid } }
        guard rmdir(workspace.path) == 0 else { throw PommeSSHBootstrapError.invalid }
    }

    static func activate(plist: URL, run: (String, [String]) throws -> Int32) throws {
        // launchctl bootstrap may report an already loaded service after a lost reply.
        if try run("/bin/launchctl", ["print", "system/\(PommeAgentInstall.label)"]) != 0 {
            guard try run("/bin/launchctl", ["bootstrap", "system", plist.path]) == 0 else { throw PommeSSHBootstrapError.invalid }
        }
        guard try run("/bin/launchctl", ["kickstart", "system/\(PommeAgentInstall.label)"]) == 0,
              try run("/bin/launchctl", ["print", "system/\(PommeAgentInstall.label)"]) == 0 else { throw PommeSSHBootstrapError.invalid }
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 7, arguments[0] == flag,
              let vmUUID = UUID(uuidString: arguments[3]), let requestID = UUID(uuidString: arguments[6]) else { return 1 }
        var failureStatus: Int32 = 51
        do {
            try install(workspace: URL(fileURLWithPath: arguments[1]), sourceWorkspace: URL(fileURLWithPath: arguments[2]),
                        expected: .init(vmUUID: vmUUID, planSHA256: arguments[4], executableSHA256: arguments[5], requestID: requestID),
                        selfExecutable: URL(fileURLWithPath: CommandLine.arguments[0]), phase: { failureStatus = $0 }) { executable, arguments in
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit(); return process.terminationStatus
            }
            return 0
        } catch { return failureStatus }
    }
}
