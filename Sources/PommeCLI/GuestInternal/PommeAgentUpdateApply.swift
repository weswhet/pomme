import Darwin
import Foundation
import os

/// Replaces the persistent normal-boot agent in a running guest with the bytes
/// of the staged executable that runs this mode. The host uploads that
/// executable through the authenticated agent, then runs it as root through
/// the same agent. Errors are deliberately non-descriptive.
///
/// The executable and LaunchDaemon definition are replaced in one recoverable
/// install transaction; the existing token is rewritten unchanged, unless the
/// host supplies a replacement on standard input, which the same transaction
/// installs instead. The running daemon keeps serving the old bytes, and its
/// in-memory token, until the job restarts.
enum PommeAgentUpdateApply {
    static let flag = "--pomme-agent-update-apply"
    /// The optional last argument. The new credential is read from standard
    /// input so it never appears in a process's arguments.
    static let replaceCredentialFlag = "--replace-credential-from-stdin"

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
        replacementCredential: Data? = nil,
        paths: PommeAgentRecoveryInstaller.Paths = .init(),
        stagedPrefix: String = PommeAgentInstall.updatePrefix,
        expectedOwner: uid_t = 0,
        phase: (Int32) -> Void = { _ in },
        recoverInstallJournal: (URL) throws -> Void = { try PommeAgentFileTransaction.recoverInstallJournal(at: $0) },
        install: (Data, Data, Data, PommeAgentRecoveryInstaller.Paths) throws -> Void = {
            try PommeAgentRecoveryInstaller().installTransaction(executable: $0, token: $1, plist: $2, paths: $3)
        }
    ) throws -> Outcome {
        phase(Phase.request)
        let target = try PommeAgentAuthentication.normalized(targetSHA256)
        let replacement = try replacementCredential.map(credential(fromStandardInput:))
        // Only a host-staged file in the agent's private directory may update
        // the agent, and only by running itself.
        // Lexical normalization only: Foundation's file-URL standardization
        // rewrites the real /private/var path to its /var alias.
        guard staged.path == staged.standardized.path,
              staged.path.hasPrefix(stagedPrefix),
              selfExecutable.resolvingSymlinksInPath().path == staged.resolvingSymlinksInPath().path
        else { throw PommeAgentOperationError.invalid("The update must run from the staged agent under \(stagedPrefix)") }
        phase(Phase.stagedFile)
        var info = stat()
        guard lstat(staged.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == expectedOwner, info.st_nlink == 1, info.st_mode & 0o022 == 0
        else { throw PommeAgentOperationError.invalid("The staged agent \(staged.path) must be a single-link regular file that only its owner can write") }
        let executable = try PommeAgentFileTransaction.readRegular(
            staged, maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes)
        phase(Phase.digest)
        guard PommeBootstrapRequest.digest(executable) == target else {
            throw PommeAgentOperationError.invalid("The staged agent's SHA-256 doesn't match the requested update")
        }
        let plist = Data(try PommeAgentInstall.definition(digest: target).utf8)

        // An interrupted earlier transaction must be rolled forward or back
        // before the installed files are compared; otherwise a finished-looking
        // install could keep its backups, including a replaced credential.
        phase(Phase.install)
        try recoverInstallJournal(paths.privateDirectory.appendingPathComponent("agent-install.journal"))
        let installed = (try? PommeAgentFileTransaction.readRegular(
            paths.executable, maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes)) ?? Data()
        let installedPlist = (try? PommeAgentFileTransaction.readRegular(paths.plist, maximumBytes: 64 * 1024)) ?? Data()
        let installedToken = try? PommeAgentFileTransaction.readRegular(paths.token, maximumBytes: 128)
        let outcome: Outcome
        if installed == executable, installedPlist == plist, replacement == nil || installedToken == replacement {
            outcome = .alreadyApplied
        } else {
            // The token is never returned or logged. Without a replacement it
            // is rewritten byte for byte so the daemon keeps authenticating
            // with the same secret.
            phase(Phase.token)
            let token: Data
            if let replacement {
                token = replacement
            } else {
                guard let existing = installedToken,
                      let text = String(data: existing, encoding: .utf8),
                      try PommeAgentAuthentication.normalized(text) == text
                else { throw PommeAgentOperationError.invalid("The installed agent credential file is malformed") }
                token = existing
            }
            phase(Phase.install)
            try install(executable, token, plist, paths)
            outcome = .applied
        }
        phase(Phase.cleanup)
        guard unlink(staged.path) == 0 else {
            let code = errno
            throw PommeAgentOperationError.described(
                .invalid,
                message: "Removing the staged agent \(staged.path) failed: \(String(cString: strerror(code))) (errno \(code))"
            )
        }
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

    /// The credential the host wrote to standard input: exactly one
    /// lowercase hexadecimal token, optionally followed by a newline, in the
    /// exact bytes the installed token file holds.
    static func credential(fromStandardInput data: Data) throws -> Data {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let text = String(data: bytes, encoding: .utf8),
              (try? PommeAgentAuthentication.normalized(text)) == text
        else { throw PommeAgentOperationError.invalid("The replacement agent credential is malformed") }
        return bytes
    }

    /// Reads at most `maximum` bytes, so an unexpected stream can't grow
    /// without bound.
    private static func readStandardInput(maximum: Int = 256) throws -> Data {
        var data = Data()
        while data.count <= maximum {
            guard let chunk = try FileHandle.standardInput.read(upToCount: maximum + 1 - data.count),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw PommeAgentOperationError.invalid("The replacement agent credential is too long")
    }

    static func run(arguments: [String]) -> Int32 {
        let replacesCredential = arguments.count == 4 && arguments[3] == replaceCredentialFlag
        let log = PommeUnifiedLog.bootstrap
        guard arguments.count == 3 || replacesCredential, arguments[0] == flag, geteuid() == 0 else {
            log.error("Agent update rejected its arguments or isn't running as root")
            return 1
        }
        var failureStatus = Phase.request
        // The replacement credential on standard input is never logged.
        log.notice("""
            Agent update starting: target=\(arguments[2], privacy: .public) \
            replacesCredential=\(replacesCredential, privacy: .public)
            """)
        do {
            let replacement = replacesCredential ? try readStandardInput() : nil
            let outcome = try apply(
                staged: URL(fileURLWithPath: arguments[1]),
                targetSHA256: arguments[2],
                selfExecutable: try PommeExecutableIdentity.currentExecutableURL(),
                replacementCredential: replacement,
                phase: { phase in
                    failureStatus = phase
                    log.info("Agent update phase \(phase, privacy: .public)")
                }
            )
            log.notice("Agent update finished: outcome=\(outcome.rawValue, privacy: .public)")
            FileHandle.standardOutput.write(Data("\(outcome.rawValue) \(arguments[2])\n".utf8))
            return 0
        } catch {
            log.error("Agent update failed in phase \(failureStatus, privacy: .public)")
            PommeUnifiedLog.error(error, context: "Agent update", logger: log)
            return failureStatus
        }
    }
}
