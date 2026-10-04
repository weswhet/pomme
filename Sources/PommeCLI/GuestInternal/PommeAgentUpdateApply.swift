import Darwin
import Foundation

/// Replaces the persistent normal-boot agent in a running guest with the bytes
/// of the staged executable that runs this mode. The host uploads that
/// executable through the authenticated agent, then runs it as root through
/// the same agent. Errors are deliberately non-descriptive.
///
/// The executable and LaunchDaemon definition are replaced in one recoverable
/// install transaction; the existing token is rewritten unchanged. The running
/// daemon keeps serving the old bytes until the host restarts the job.
enum PommeAgentUpdateApply {
    static let flag = "--pomme-agent-update-apply"

    enum Outcome: String, Equatable {
        case applied, alreadyApplied
    }

    /// Exit statuses name the failed step without describing guest state.
    enum Phase {
        static let request: Int32 = 61
        static let stagedFile: Int32 = 62
        static let digest: Int32 = 63
        static let token: Int32 = 64
        static let install: Int32 = 65
        static let cleanup: Int32 = 66
    }

    static func apply(
        staged: URL,
        targetSHA256: String,
        selfExecutable: URL,
        paths: PommeAgentRecoveryInstaller.Paths = .init(),
        stagedPrefix: String = PommeAgentInstall.updatePrefix,
        expectedOwner: uid_t = 0,
        phase: (Int32) -> Void = { _ in },
        install: (Data, Data, Data, PommeAgentRecoveryInstaller.Paths) throws -> Void = {
            try PommeAgentRecoveryInstaller().installTransaction(executable: $0, token: $1, plist: $2, paths: $3)
        }
    ) throws -> Outcome {
        phase(Phase.request)
        let target = try PommeAgentAuthentication.normalized(targetSHA256)
        // Only a host-staged file in the agent's private directory may update
        // the agent, and only by running itself.
        // Lexical normalization only: Foundation's file-URL standardization
        // rewrites the real /private/var path to its /var alias.
        guard staged.path == staged.standardized.path,
              staged.path.hasPrefix(stagedPrefix),
              selfExecutable.resolvingSymlinksInPath().path == staged.resolvingSymlinksInPath().path
        else { throw PommeAgentOperationError.invalid }
        phase(Phase.stagedFile)
        var info = stat()
        guard lstat(staged.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == expectedOwner, info.st_nlink == 1, info.st_mode & 0o022 == 0
        else { throw PommeAgentOperationError.invalid }
        let executable = try PommeAgentFileTransaction.readRegular(
            staged, maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes)
        phase(Phase.digest)
        guard PommeBootstrapRequest.digest(executable) == target else { throw PommeAgentOperationError.invalid }
        let plist = Data(try PommeAgentInstall.definition(digest: target).utf8)

        let installed = (try? PommeAgentFileTransaction.readRegular(
            paths.executable, maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes)) ?? Data()
        let installedPlist = (try? PommeAgentFileTransaction.readRegular(paths.plist, maximumBytes: 64 * 1024)) ?? Data()
        let outcome: Outcome
        if installed == executable, installedPlist == plist {
            outcome = .alreadyApplied
        } else {
            // The token is never returned or logged; it is rewritten byte for
            // byte so the daemon keeps authenticating with the same secret.
            phase(Phase.token)
            let token = try PommeAgentFileTransaction.readRegular(paths.token, maximumBytes: 128)
            guard let text = String(data: token, encoding: .utf8),
                  try PommeAgentAuthentication.normalized(text) == text
            else { throw PommeAgentOperationError.invalid }
            phase(Phase.install)
            try install(executable, token, plist, paths)
            outcome = .applied
        }
        phase(Phase.cleanup)
        guard unlink(staged.path) == 0 else { throw PommeAgentOperationError.invalid }
        return outcome
    }

    /// launchd restarts a kickstarted job with the arguments it loaded at boot,
    /// which still pin the previous digest. An updated daemon is accepted when
    /// the root-owned LaunchDaemon definition on disk pins its exact digest:
    /// only root can write that file, as only root can replace the executable.
    static func installedDefinitionPins(
        _ digest: String,
        executablePath: String,
        plistPath: String = PommeAgentInstall.plist,
        expectedOwner: uid_t = 0
    ) -> Bool {
        guard executablePath == PommeAgentInstall.executable,
              let expected = try? PommeAgentInstall.definition(digest: digest)
        else { return false }
        var info = stat()
        guard lstat(plistPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == expectedOwner, info.st_mode & 0o022 == 0,
              let bytes = try? PommeAgentFileTransaction.readRegular(
                URL(fileURLWithPath: plistPath), maximumBytes: 64 * 1024)
        else { return false }
        return bytes == Data(expected.utf8)
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[0] == flag, geteuid() == 0 else { return 1 }
        var failureStatus = Phase.request
        do {
            let outcome = try apply(
                staged: URL(fileURLWithPath: arguments[1]),
                targetSHA256: arguments[2],
                selfExecutable: try PommeExecutableIdentity.currentExecutableURL(),
                phase: { failureStatus = $0 }
            )
            FileHandle.standardOutput.write(Data("\(outcome.rawValue) \(arguments[2])\n".utf8))
            return 0
        } catch {
            return failureStatus
        }
    }
}
