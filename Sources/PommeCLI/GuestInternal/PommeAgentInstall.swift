import CryptoKit
import Darwin
import Foundation

/// Fixed, secret-free paths for the normal-boot LaunchDaemon.  The token is
/// never placed in a plist, protocol response, error, or journal.
struct PommeAgentInstall: Sendable {
    static let label = "com.github.weswhet.pomme.agent"
    static let executable = "/usr/local/libexec/pomme"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let token = "/private/var/db/pomme/agent.token"
    static let directory = "/private/var/db/pomme"
    static let journal = directory + "/agent-update.journal"
    static let updatePrefix = directory + "/agent-update-"

    static func definition(
        digest: String,
        port: UInt32 = Constants.pommeAgentPort,
        executable: String = PommeAgentInstall.executable,
        token: String = PommeAgentInstall.token
    ) throws -> String {
        let digest = try PommeAgentAuthentication.normalized(digest)
        // Without a ProcessType, launchd throttles the job's CPU and I/O. At
        // boot the throttled page-ins delayed the agent's main by up to 22
        // seconds, and every `pomme start` waits for the agent. Adaptive only
        // boosts during XPC activity, and the agent talks to the host over
        // VSOCK, so it must be Interactive. Processes the agent starts inherit
        // its priority.
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(executable)</string><string>--pomme-agent</string><string>\(port)</string><string>--token-file</string><string>\(token)</string><string>--expected-sha256</string><string>\(digest)</string><string>--role</string><string>normal</string></array>
        <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>5</integer>
        <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
    }
}

/// Installs the persistent daemon from the fixed, host-prepared Recovery
/// share.  The Recovery connection has already authenticated and bound the
/// request/session; this type additionally binds the operation's correlation
/// ID and payload to the request manifest on the read-only VirtioFS mount.
/// It never reads a token from the share and never returns one.
struct PommeAgentRecoveryInstaller: Sendable {
    struct Paths: Equatable, Sendable {
        let executable: URL
        let token: URL
        let plist: URL
        let privateDirectory: URL

        init(
            executable: URL = URL(fileURLWithPath: PommeAgentInstall.executable),
            token: URL = URL(fileURLWithPath: PommeAgentInstall.token),
            plist: URL = URL(fileURLWithPath: PommeAgentInstall.plist),
            privateDirectory: URL = URL(fileURLWithPath: PommeAgentInstall.directory)
        ) {
            self.executable = executable
            self.token = token
            self.plist = plist
            self.privateDirectory = privateDirectory
        }
    }

    struct Configuration: Sendable {
        typealias TargetDataResolver = @Sendable (UUID?) throws -> (
            root: URL,
            volumeGroupUUID: UUID
        )

        let paths: Paths
        let expectedOwner: uid_t
        let expectedGroup: gid_t
        let requiresRoot: Bool
        let resolveTargetDataRoot: TargetDataResolver
        let validateTargetDataRoot: @Sendable (URL) -> Bool
        let validateGuestWorkspace: @Sendable (URL, UUID) -> Bool

        init(
            paths: Paths = .init(),
            expectedOwner: uid_t = 0,
            expectedGroup: gid_t = 0,
            requiresRoot: Bool = true,
            resolveTargetDataRoot: @escaping TargetDataResolver = { uuid in
                let selection = try PommeRecoveryDataVolumeResolver().resolveSelection(
                    expectedVolumeGroupUUID: uuid
                )
                return (selection.root, selection.volume.volumeGroupUUID)
            },
            validateTargetDataRoot: @escaping @Sendable (URL) -> Bool = Self.isSafeDataRoot,
            validateGuestWorkspace: @escaping @Sendable (URL, UUID) -> Bool = Self.isSafeGuestWorkspace
        ) {
            self.paths = paths
            self.expectedOwner = expectedOwner
            self.expectedGroup = expectedGroup
            self.requiresRoot = requiresRoot
            self.resolveTargetDataRoot = resolveTargetDataRoot
            self.validateTargetDataRoot = validateTargetDataRoot
            self.validateGuestWorkspace = validateGuestWorkspace
        }

        private static func isSafeDataRoot(_ root: URL) -> Bool {
            root.path.hasPrefix("/Volumes/") && root.path != "/Volumes"
                && root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
        }

        private static func isSafeGuestWorkspace(_ root: URL, _ requestID: UUID) -> Bool {
            let expected = "/private/var/tmp/pomme-recovery-\(requestID.uuidString.lowercased())"
            guard root.path == expected else { return false }
            do {
                try PommeAgentFileTransaction.verifyRecoveryWorkspaceDirectory(root, owner: 0, group: 0)
                return true
            } catch { return false }
        }

    }

    private let configuration: Configuration

    init(configuration: Configuration = .init()) { self.configuration = configuration }

    func install(payload: JSONValue, requestID: UUID) throws -> JSONValue {
        guard !configuration.requiresRoot || geteuid() == 0 else {
            throw PommeAgentOperationError.invalid
        }
        let workspace = try workspaceRoot(from: payload, requestID: requestID)
        let manifestURL = workspace.appendingPathComponent(PommeRecoveryArtifactNames.request)
        let executableURL = workspace.appendingPathComponent(PommeRecoveryArtifactNames.executable)
        let requestData = try PommeAgentFileTransaction.readRegular(manifestURL, maximumBytes: 64 * 1024)
        let request = try JSONDecoder().decode(PommeRecoverySessionRequest.self, from: requestData)
        guard request.isWellFormed,
              request.operation == PommeRecoveryOperation.installAgent.wireName,
              request.requestID == requestID,
              workspace.lastPathComponent == "pomme-recovery-\(requestID.uuidString.lowercased())"
        else { throw PommeAgentOperationError.invalid }
        let executable = try PommeAgentFileTransaction.readRegular(
            executableURL,
            maximumBytes: PommeRecoveryStagingBuilder.maximumExecutableBytes
        )
        guard !executable.isEmpty,
              SHA256.hash(data: executable).map({ String(format: "%02x", $0) }).joined() == request.executableSHA256
        else { throw PommeAgentOperationError.invalid }

        let tokenText = try persistentToken(from: payload, requestID: requestID)
        let plist = try PommeAgentInstall.definition(
            digest: request.executableSHA256
        )
        let target = try targetDataRoot(from: payload)
        let paths = try effectivePaths(under: target.root)
        try prepareTargetDirectories(under: target.root, paths: paths)
        try installTransaction(
            executable: executable,
            token: Data(tokenText.utf8),
            plist: Data(plist.utf8),
            paths: paths
        )
        return .object([
            "executableSHA256": .string(request.executableSHA256),
            "volumeGroupUUID": .string(target.volumeGroupUUID.uuidString.lowercased()),
            "capabilities": .array(PommeAgent.persistentCapabilities.map(JSONValue.string))
        ])
    }

    private func workspaceRoot(from payload: JSONValue, requestID: UUID) throws -> URL {
        guard let values = payload.objectValue,
              Set(values.keys) == ["installMode", "persistentToken", "requestID", "workspacePath"]
                || Set(values.keys) == ["installMode", "persistentToken", "requestID", "targetVolumeGroupUUID", "workspacePath"],
              let suppliedID = values["requestID"]?.stringValue.flatMap(UUID.init(uuidString:)),
              suppliedID == requestID,
              let path = values["workspacePath"]?.stringValue,
              path.utf8.count <= 256,
              !path.contains("\0")
        else { throw PommeAgentOperationError.invalid }
        // The request binds a lexical spelling, not Foundation's preferred
        // filesystem alias. Existing /private/var paths may otherwise become
        // /var paths and incorrectly reject their own authenticated request.
        let root = URL(fileURLWithPath: path).standardized
        guard root.path == path,
              configuration.validateGuestWorkspace(root, requestID)
        else { throw PommeAgentOperationError.invalid }
        do {
            try PommeAgentFileTransaction.verifyRecoveryWorkspaceDirectory(
                root, owner: configuration.expectedOwner, group: configuration.expectedGroup
            )
        } catch { throw PommeAgentOperationError.invalid }
        return root
    }

    /// The persistent credential is supplied only in the authenticated
    /// request body. It is never persisted except in the 0400 destination,
    /// and is deliberately excluded from response, journal, and diagnostics.
    private func persistentToken(from payload: JSONValue, requestID: UUID) throws -> String {
        guard let values = payload.objectValue,
              let suppliedID = values["requestID"]?.stringValue.flatMap(UUID.init(uuidString:)),
              suppliedID == requestID,
              let token = values["persistentToken"]?.stringValue
        else { throw PommeAgentOperationError.invalid }
        do { return try PommeAgentAuthentication.normalized(token) }
        catch { throw PommeAgentOperationError.invalid }
    }

    private func targetDataRoot(
        from payload: JSONValue
    ) throws -> (root: URL, volumeGroupUUID: UUID) {
        guard let values = payload.objectValue,
              let mode = values["installMode"]?.stringValue,
              ["initial", "repair"].contains(mode) else { throw PommeAgentOperationError.invalid }
        let uuid = values["targetVolumeGroupUUID"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard mode == "initial" ? uuid == nil : uuid != nil else { throw PommeAgentOperationError.invalid }
        let selected = try configuration.resolveTargetDataRoot(uuid)
        let root = selected.root.standardized
        guard root.path == selected.root.path else { throw PommeAgentOperationError.invalid }
        guard uuid == nil || selected.volumeGroupUUID == uuid else {
            throw PommeAgentOperationError.invalid
        }
        guard configuration.validateTargetDataRoot(root) else {
            throw PommeAgentOperationError.invalid
        }
        return (root, selected.volumeGroupUUID)
    }

    private func effectivePaths(under root: URL) throws -> Paths {
        let defaults = Paths()
        guard configuration.paths.executable == defaults.executable,
              configuration.paths.token == defaults.token,
              configuration.paths.plist == defaults.plist,
              configuration.paths.privateDirectory == defaults.privateDirectory else {
            guard targetsAreWithinDataVolume(root, paths: configuration.paths) else { throw PommeAgentOperationError.invalid }
            return configuration.paths
        }
        return .init(
            executable: root.appendingPathComponent("usr/local/libexec/pomme"),
            token: root.appendingPathComponent("private/var/db/pomme/agent.token"),
            plist: root.appendingPathComponent("Library/LaunchDaemons/\(PommeAgentInstall.label).plist"),
            privateDirectory: root.appendingPathComponent("private/var/db/pomme")
        )
    }

    /// Fresh macOS Data volumes do not necessarily contain `/usr/local` or
    /// `/usr/local/libexec`. Build only the fixed parent chains beneath the
    /// already-validated Data root, one descriptor-relative component at a
    /// time. Existing directories must be owner-controlled and non-writable
    /// by group/other; symbolic links are never followed.
    private func prepareTargetDirectories(under root: URL, paths: Paths) throws {
        guard targetsAreWithinDataVolume(root, paths: paths) else {
            throw PommeAgentOperationError.invalid
        }
        for parent in [
            paths.executable.deletingLastPathComponent(),
            paths.plist.deletingLastPathComponent(),
            paths.privateDirectory.deletingLastPathComponent()
        ] {
            try PommeAgentFileTransaction.ensureDirectoryTree(
                under: root,
                through: parent,
                createdMode: 0o755,
                owner: configuration.expectedOwner,
                group: configuration.expectedGroup
            )
        }
    }

    func installTransaction(executable: Data, token: Data, plist: Data, paths: Paths) throws {
        try PommeAgentFileTransaction.ensureDirectory(
            paths.privateDirectory,
            mode: 0o700,
            owner: configuration.expectedOwner,
            group: configuration.expectedGroup
        )
        let files: [(URL, Data, mode_t)] = [
            (paths.executable, executable, 0o555),
            (paths.token, token, 0o400),
            (paths.plist, plist, 0o644)
        ]
        let journalURL = paths.privateDirectory.appendingPathComponent("agent-install.journal")
        var staged: [(target: URL, stage: URL)] = []
        do {
            try PommeAgentFileTransaction.recoverInstallJournal(at: journalURL)
            for (target, data, mode) in files {
                let prepared = try PommeAgentFileTransaction.createAdjacentStage(for: target)
                do {
                    try PommeAgentFileTransaction.writeAll(prepared.descriptor, data: data)
                    guard fchmod(prepared.descriptor, mode) == 0,
                          fchown(prepared.descriptor, configuration.expectedOwner, configuration.expectedGroup) == 0,
                          fsync(prepared.descriptor) == 0
                    else { throw PommeAgentOperationError.invalid }
                    _ = Darwin.close(prepared.descriptor)
                    staged.append((target, prepared.url))
                } catch {
                    _ = Darwin.close(prepared.descriptor)
                    try? PommeAgentFileTransaction.removeAdjacentStage(prepared.url, for: target)
                    throw error
                }
            }
            try PommeAgentFileTransaction.replaceTransaction(staged, owner: configuration.expectedOwner, journalURL: journalURL)
            try verifyInstalled(files: files)
            Darwin.sync()
            try verifyInstalled(files: files)
        } catch {
            for item in staged { try? PommeAgentFileTransaction.removeAdjacentStage(item.stage, for: item.target) }
            throw PommeAgentOperationError.invalid
        }
    }

    private func targetsAreWithinDataVolume(_ root: URL, paths: Paths) -> Bool {
        [paths.executable, paths.token, paths.plist, paths.privateDirectory]
            .allSatisfy { $0.standardized.path == $0.path && $0.path.hasPrefix(root.path + "/") }
    }

    private func verifyInstalled(files: [(URL, Data, mode_t)]) throws {
        for (url, expected, mode) in files {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == configuration.expectedOwner,
                  info.st_gid == configuration.expectedGroup,
                  info.st_mode & 0o777 == mode,
                  info.st_nlink == 1,
                  try PommeAgentFileTransaction.readRegular(url, maximumBytes: max(expected.count, 1)) == expected
            else { throw PommeAgentOperationError.invalid }
            try PommeAgentFileTransaction.fsyncParentDirectory(of: url)
        }
    }
}

struct PommeAgentUpdateJournal: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, staged, activationPending, hostValidated, rolledBack, repairRequired }
    let transactionID: UUID
    let phase: Phase
    let sourceSHA256: String
    let targetSHA256: String
    let targetBytes: UInt64
    let stagedExecutable: String

    init(transactionID: UUID = UUID(), phase: Phase, sourceSHA256: String, targetSHA256: String, targetBytes: UInt64, stagedExecutable: String = "") throws {
        self.transactionID = transactionID; self.phase = phase
        self.sourceSHA256 = try PommeAgentAuthentication.normalized(sourceSHA256)
        self.targetSHA256 = try PommeAgentAuthentication.normalized(targetSHA256)
        guard targetBytes > 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        self.targetBytes = targetBytes
        self.stagedExecutable = stagedExecutable
    }

    func changing(_ phase: Phase) throws -> Self { try .init(transactionID: transactionID, phase: phase, sourceSHA256: sourceSHA256, targetSHA256: targetSHA256, targetBytes: targetBytes, stagedExecutable: stagedExecutable) }
}

/// Recovery installation state contains only fixed file paths and transaction
/// names—never the persistent token or any request credential.  `committed`
/// is the durable point after which recovery only finalizes retired backups.
private struct PommeAgentInstallJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, staged, committed }
    struct Entry: Codable, Sendable {
        let target: String
        let stage: String
        let backup: String
        let hadPrevious: Bool
    }
    let transactionID: UUID
    let phase: Phase
    let entries: [Entry]
}

private enum PommeAgentInstallJournalStore {
    static func write(_ journal: PommeAgentInstallJournal, at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".agent-install-journal-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(journal)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PommeAgentProtocol.Error.invalidRequest }
        let descriptor = Darwin.open(temporary.path, O_RDONLY | O_CLOEXEC)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        guard descriptor >= 0, fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary); throw PommeAgentProtocol.Error.invalidRequest
        }
        try PommeAgentFileTransaction.fsyncDirectory(parent)
    }

    static func read(at url: URL) throws -> PommeAgentInstallJournal? {
        var info = stat()
        if lstat(url.path, &info) != 0 { guard errno == ENOENT else { throw PommeAgentProtocol.Error.invalidRequest }; return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_mode & 0o077 == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        return try JSONDecoder().decode(PommeAgentInstallJournal.self, from: Data(contentsOf: url))
    }

    static func remove(at url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw PommeAgentProtocol.Error.invalidRequest }
        try PommeAgentFileTransaction.fsyncDirectory(url.deletingLastPathComponent())
    }
}

enum PommeAgentJournalStore {
    static func write(_ journal: PommeAgentUpdateJournal, at path: String = PommeAgentInstall.journal) throws {
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        let data = try JSONEncoder().encode(journal)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PommeAgentProtocol.Error.malformedFrame }
        let fd = Darwin.open(temporary.path, O_RDONLY | O_CLOEXEC); defer { if fd >= 0 { _ = Darwin.close(fd) } }
        guard fd >= 0, fsync(fd) == 0, rename(temporary.path, destination.path) == 0 else { try? FileManager.default.removeItem(at: temporary); throw PommeAgentProtocol.Error.malformedFrame }
    }

    static func read(at path: String = PommeAgentInstall.journal) throws -> PommeAgentUpdateJournal {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0, info.st_mode & 0o077 == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        return try JSONDecoder().decode(PommeAgentUpdateJournal.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func remove(at path: String = PommeAgentInstall.journal) throws {
        guard unlink(path) == 0 || errno == ENOENT else { throw PommeAgentProtocol.Error.invalidRequest }
    }
}

enum PommeAgentFileTransaction {
    /// Verify the actual directory through the no-follow component walker.
    /// String-based symlink resolution is not an identity proof on macOS:
    /// Foundation can rewrite a real /private/var path to its /var alias.
    static func verifyRecoveryWorkspaceDirectory(_ url: URL, owner: uid_t, group: gid_t) throws {
        guard url.standardized.path == url.path else { throw PommeAgentProtocol.Error.invalidRequest }
        try withVerifiedParent(of: url) { parent, name in
            var entry = stat()
            guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  entry.st_mode & S_IFMT == S_IFDIR
            else { throw PommeAgentProtocol.Error.invalidRequest }
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            defer { _ = Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino,
                  opened.st_mode & S_IFMT == S_IFDIR,
                  opened.st_uid == owner, opened.st_gid == group,
                  opened.st_mode & 0o777 == 0o700
            else { throw PommeAgentProtocol.Error.invalidRequest }
        }
    }

    /// Reads a fixed artifact through an O_NOFOLLOW descriptor so a staging
    /// mount cannot substitute a symlink between validation and consumption.
    static func readRegular(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        let descriptor = try openRegular(url, flags: O_RDONLY)
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size > 0,
              info.st_size <= off_t(maximumBytes),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0
        else { throw PommeAgentProtocol.Error.invalidRequest }
        var data = Data(count: Int(info.st_size))
        let byteCount = data.count
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), byteCount - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            offset += count
        }
        return data
    }

    static func writeAll(_ descriptor: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            offset += count
        }
    }

    static func ensureDirectory(_ url: URL, mode: mode_t, owner: uid_t, group: gid_t) throws {
        guard url.path.hasPrefix("/"), !url.path.contains("\0") else { throw PommeAgentProtocol.Error.invalidRequest }
        try withVerifiedParent(of: url) { descriptor, name in
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT, mkdirat(descriptor, name, mode) == 0 else {
                    throw PommeAgentProtocol.Error.invalidRequest
                }
            }
            let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard child >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            defer { _ = Darwin.close(child) }
            guard fchmod(child, mode) == 0,
                  fchown(child, owner, group) == 0,
                  fstat(child, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == owner,
                  info.st_mode & 0o777 == mode,
                  fsync(child) == 0
            else { throw PommeAgentProtocol.Error.invalidRequest }
        }
    }

    /// Creates a bounded directory chain below an already-owned root without
    /// following a link at any component. This exists for fresh Recovery
    /// installs, where fixed system-owned parents may legitimately be absent.
    static func ensureDirectoryTree(
        under root: URL,
        through directoryURL: URL,
        createdMode: mode_t,
        owner: uid_t,
        group: gid_t
    ) throws {
        let normalizedRoot = root.standardized
        let normalizedDirectory = directoryURL.standardized
        guard normalizedRoot.path == root.path,
              normalizedDirectory.path == directoryURL.path,
              normalizedRoot.path.hasPrefix("/"),
              normalizedDirectory.path == normalizedRoot.path
                || normalizedDirectory.path.hasPrefix(normalizedRoot.path + "/"),
              createdMode & ~mode_t(0o777) == 0,
              createdMode & 0o022 == 0
        else { throw PommeAgentProtocol.Error.invalidRequest }

        let relative: [String]
        if normalizedDirectory.path == normalizedRoot.path {
            relative = []
        } else {
            relative = normalizedDirectory.path
                .dropFirst(normalizedRoot.path.count + 1)
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
        }
        guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PommeAgentProtocol.Error.invalidRequest
        }

        // Asking for the parent of a fixed, nonexistent anchor gives this
        // closure a descriptor for the exact root using the same no-follow
        // walker as every file transaction.
        let anchor = normalizedRoot.appendingPathComponent(".pomme-directory-anchor")
        try withVerifiedParent(of: anchor) { rootDescriptor, _ in
            var rootInfo = stat()
            guard fstat(rootDescriptor, &rootInfo) == 0,
                  rootInfo.st_mode & S_IFMT == S_IFDIR,
                  rootInfo.st_uid == owner,
                  rootInfo.st_mode & 0o022 == 0
            else { throw PommeAgentProtocol.Error.invalidRequest }

            var current = dup(rootDescriptor)
            guard current >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            defer { _ = Darwin.close(current) }

            for component in relative {
                var info = stat()
                var created = false
                if fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT,
                          mkdirat(current, component, createdMode) == 0
                    else { throw PommeAgentProtocol.Error.invalidRequest }
                    created = true
                } else {
                    guard info.st_mode & S_IFMT == S_IFDIR,
                          info.st_uid == owner,
                          info.st_mode & 0o022 == 0
                    else { throw PommeAgentProtocol.Error.invalidRequest }
                }

                let next = openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
                if created {
                    guard fchmod(next, createdMode) == 0,
                          fchown(next, owner, group) == 0,
                          fstat(next, &info) == 0,
                          info.st_mode & S_IFMT == S_IFDIR,
                          info.st_uid == owner,
                          info.st_gid == group,
                          info.st_mode & 0o777 == createdMode,
                          fsync(next) == 0,
                          fsync(current) == 0
                    else {
                        _ = Darwin.close(next)
                        throw PommeAgentProtocol.Error.invalidRequest
                    }
                }
                _ = Darwin.close(current)
                current = next
            }
        }
    }

    /// Removes only the fixed artifacts in an exact request workspace. The
    /// whole directory is enumerated and validated before the first unlink so
    /// an unexpected entry cannot be hidden by a partial cleanup.
    static func removeRecoveryWorkspace(
        _ workspace: URL,
        requestID: UUID,
        owner: uid_t,
        group: gid_t
    ) throws {
        let expectedName = "pomme-recovery-\(requestID.uuidString.lowercased())"
        let normalized = workspace.standardized
        guard normalized.path == workspace.path,
              normalized.lastPathComponent == expectedName
        else { throw PommeAgentProtocol.Error.invalidRequest }

        let expectedModes: [String: Set<mode_t>] = [
            PommeRecoveryArtifactNames.executable: [0o555],
            PommeRecoveryArtifactNames.request: [0o400],
            PommeRecoveryArtifactNames.credential: [0o400],
            PommeRecoveryArtifactNames.launcher: [0o500, 0o555]
        ]
        try withVerifiedParent(of: normalized) { parent, name in
            var workspaceInfo = stat()
            if fstatat(parent, name, &workspaceInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw PommeAgentProtocol.Error.invalidRequest }
                return
            }
            guard workspaceInfo.st_mode & S_IFMT == S_IFDIR,
                  workspaceInfo.st_uid == owner,
                  workspaceInfo.st_gid == group,
                  workspaceInfo.st_mode & 0o777 == 0o700
            else { throw PommeAgentProtocol.Error.invalidRequest }

            let descriptor = openat(
                parent,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            defer { _ = Darwin.close(descriptor) }

            let duplicate = dup(descriptor)
            guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                if duplicate >= 0 { _ = Darwin.close(duplicate) }
                throw PommeAgentProtocol.Error.invalidRequest
            }
            var entries: [String] = []
            errno = 0
            while let entry = readdir(stream) {
                let entryName = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
                }
                if entryName != "." && entryName != ".." { entries.append(entryName) }
            }
            let enumerationError = errno
            _ = closedir(stream)
            guard enumerationError == 0,
                  entries.allSatisfy({ expectedModes[$0] != nil })
            else { throw PommeAgentProtocol.Error.invalidRequest }

            for entryName in entries {
                var info = stat()
                guard let modes = expectedModes[entryName],
                      fstatat(descriptor, entryName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == owner,
                      info.st_gid == group,
                      modes.contains(info.st_mode & 0o777),
                      info.st_nlink == 1,
                      unlinkat(descriptor, entryName, 0) == 0
                else { throw PommeAgentProtocol.Error.invalidRequest }
            }
            guard fsync(descriptor) == 0,
                  unlinkat(parent, name, AT_REMOVEDIR) == 0,
                  fsync(parent) == 0,
                  fstatat(parent, name, &workspaceInfo, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT
            else { throw PommeAgentProtocol.Error.invalidRequest }
        }
    }

    /// The journal is written before any destination move. Pre-commit errors
    /// recover the exact old set; after `committed` is durable, backup
    /// retirement is a finalize-only action and is never rolled back.
    static func replaceTransaction(
        _ items: [(target: URL, stage: URL)], owner: uid_t, journalURL: URL
    ) throws {
        let transactionID = UUID()
        let entries = try items.map { item -> PommeAgentInstallJournal.Entry in
            guard item.stage.deletingLastPathComponent().path == item.target.deletingLastPathComponent().path else {
                throw PommeAgentProtocol.Error.invalidRequest
            }
            var info = stat()
            let exists = lstat(item.target.path, &info) == 0
            if exists {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
                      info.st_nlink == 1, info.st_mode & 0o022 == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            } else if errno != ENOENT { throw PommeAgentProtocol.Error.invalidRequest }
            let backup = item.target.deletingLastPathComponent()
                .appendingPathComponent(".pomme-install-\(transactionID.uuidString)-backup-\(item.target.lastPathComponent)")
            return .init(target: item.target.path, stage: item.stage.path, backup: backup.path, hadPrevious: exists)
        }
        var journal = PommeAgentInstallJournal(transactionID: transactionID, phase: .prepared, entries: entries)
        try PommeAgentInstallJournalStore.write(journal, at: journalURL)
        journal = .init(transactionID: transactionID, phase: .staged, entries: entries)
        try PommeAgentInstallJournalStore.write(journal, at: journalURL)
        do {
            for entry in entries {
                if entry.hadPrevious {
                    guard rename(entry.target, entry.backup) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
                }
                guard rename(entry.stage, entry.target) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
                try fsyncParent(of: URL(fileURLWithPath: entry.target))
            }
            journal = .init(transactionID: transactionID, phase: .committed, entries: entries)
            try PommeAgentInstallJournalStore.write(journal, at: journalURL)
        } catch {
            try recoverInstallJournal(at: journalURL)
            throw error
        }
        // This is intentionally outside the rollback region.  A failed
        // retirement leaves a committed journal that the next invocation
        // finalizes without ever restoring stale artifacts.
        try finalizeCommittedInstallJournal(journal, at: journalURL)
    }

    static func recoverInstallJournal(at journalURL: URL) throws {
        guard let journal = try PommeAgentInstallJournalStore.read(at: journalURL) else { return }
        if journal.phase == .committed { return try finalizeCommittedInstallJournal(journal, at: journalURL) }
        for entry in journal.entries.reversed() {
            if entry.hadPrevious, FileManager.default.fileExists(atPath: entry.backup) {
                _ = unlink(entry.target)
                guard rename(entry.backup, entry.target) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            } else if !entry.hadPrevious {
                _ = unlink(entry.target)
            }
            _ = unlink(entry.stage)
            try fsyncParent(of: URL(fileURLWithPath: entry.target))
        }
        try PommeAgentInstallJournalStore.remove(at: journalURL)
    }

    private static func finalizeCommittedInstallJournal(_ journal: PommeAgentInstallJournal, at journalURL: URL) throws {
        guard journal.phase == .committed else { throw PommeAgentProtocol.Error.invalidRequest }
        for entry in journal.entries {
            if entry.hadPrevious { guard unlink(entry.backup) == 0 || errno == ENOENT else { throw PommeAgentProtocol.Error.invalidRequest } }
            _ = unlink(entry.stage)
            try fsyncParent(of: URL(fileURLWithPath: entry.target))
        }
        try PommeAgentInstallJournalStore.remove(at: journalURL)
    }

    enum CommitError: Error, Equatable, LocalizedError {
        case destinationPublishedCleanupFailed

        var errorDescription: String? {
            "The destination was replaced, but retirement of its prior entry could not be verified; a prior entry may remain at the staging path."
        }
    }

    /// Commit only an adjacent, known staging file. RENAME_EXCL prevents a
    /// creation race; RENAME_SWAP replaces a symlink rather than following it.
    static func commit(stage: URL, destination: URL, beforePublish: () throws -> Void = {}) throws {
        guard stage.deletingLastPathComponent().path == destination.deletingLastPathComponent().path else { throw PommeAgentProtocol.Error.invalidRequest }
        try withVerifiedParent(of: destination) { parent, destinationName in
            let stageName = try leafName(stage)
            var info = stat(); let exists = fstatat(parent, destinationName, &info, AT_SYMLINK_NOFOLLOW) == 0
            if exists, (info.st_mode & S_IFMT) != S_IFREG { throw PommeAgentProtocol.Error.invalidRequest }
            if !exists, errno != ENOENT { throw PommeAgentProtocol.Error.invalidRequest }
            var staged = stat()
            guard fstatat(parent, stageName, &staged, AT_SYMLINK_NOFOLLOW) == 0,
                  staged.st_mode & S_IFMT == S_IFREG, staged.st_nlink == 1 else {
                throw PommeAgentProtocol.Error.invalidRequest
            }
            try beforePublish()
            let flag: UInt32 = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
            guard renameatx_np(parent, stageName, parent, destinationName, flag) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            // Publication has happened. Never treat a retirement failure as a
            // pre-publication error, nor unlink an entry substituted by a race.
            if exists {
                var retired = stat()
                guard fstatat(parent, stageName, &retired, AT_SYMLINK_NOFOLLOW) == 0,
                      retired.st_dev == info.st_dev, retired.st_ino == info.st_ino,
                      retired.st_mode & S_IFMT == S_IFREG,
                      unlinkat(parent, stageName, 0) == 0 else {
                    throw CommitError.destinationPublishedCleanupFailed
                }
            }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let descriptor = try openRegular(url, flags: O_RDONLY)
        defer { _ = Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: PommeAgentProtocol.maximumFileChunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validatedRegularFile(_ url: URL) throws -> UInt64 {
        let descriptor = try openRegular(url, flags: O_RDONLY)
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw PommeAgentProtocol.Error.invalidRequest }
        return UInt64(info.st_size)
    }

    static func fsyncFile(_ url: URL) throws {
        let descriptor = try openRegular(url, flags: O_RDONLY)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        guard descriptor >= 0, fsync(descriptor) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
    }

    /// Why an open beneath the verified-parent walk failed, found by walking
    /// the same components again with lstat. Only diagnostic: the walk
    /// itself stays the authoritative check.
    enum OpenFailure: Equatable, Sendable {
        case missing(String)
        case notRegular(String, isDirectory: Bool)
        case permission(String)
        case unsafe(String)
    }

    static func diagnoseOpenFailure(_ url: URL, forWrite: Bool) -> OpenFailure? {
        let path = url.path
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = pieces.first else { return nil }
        // The same fixed root aliases the walk resolves lexically.
        var walked = ["var", "tmp", "etc"].contains(first) ? "/private" : ""
        var spelled = ""
        for (index, component) in pieces.enumerated() {
            walked += "/" + component
            spelled += "/" + component
            let isLeaf = index == pieces.count - 1
            var info = stat()
            guard lstat(walked, &info) == 0 else {
                switch errno {
                case ENOENT, ENOTDIR:
                    guard isLeaf else { return .missing(spelled) }
                    guard forWrite else { return .missing(path) }
                    // A new file is staged in its parent, which must be writable.
                    let parent = (walked as NSString).deletingLastPathComponent
                    return access(parent, W_OK) == 0 ? nil : .permission(path)
                case EACCES:
                    return .permission(path)
                default:
                    return nil
                }
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK, walked != "/private" { return .unsafe(path) }
            if !isLeaf {
                guard type == S_IFDIR || walked == "/private" else { return .missing(path) }
                continue
            }
            if forWrite {
                return type == S_IFDIR ? .notRegular(path, isDirectory: true) : nil
            }
            guard type == S_IFREG else { return .notRegular(path, isDirectory: type == S_IFDIR) }
            return access(walked, R_OK) == 0 ? nil : .permission(path)
        }
        return nil
    }

    static func createAdjacentStage(for destination: URL) throws -> (url: URL, descriptor: Int32) {
        let name = ".pomme-stage-\(UUID().uuidString)"
        let stage = destination.deletingLastPathComponent().appendingPathComponent(name)
        let descriptor = try withVerifiedParent(of: destination) { parent, _ in
            let created = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard created >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            return created
        }
        return (stage, descriptor)
    }

    static func removeAdjacentStage(_ stage: URL, for destination: URL) throws {
        guard stage.deletingLastPathComponent().path == destination.deletingLastPathComponent().path else { throw PommeAgentProtocol.Error.invalidRequest }
        try withVerifiedParent(of: destination) { parent, _ in
            guard unlinkat(parent, try leafName(stage), 0) == 0 || errno == ENOENT else { throw PommeAgentProtocol.Error.invalidRequest }
        }
    }

    static func openRegular(_ url: URL, flags: Int32) throws -> Int32 {
        try withVerifiedParent(of: url) { parent, name in
            // A substituted FIFO must not block before fstat can reject it.
            let descriptor = openat(parent, name, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { _ = Darwin.close(descriptor); throw PommeAgentProtocol.Error.invalidRequest }
            return descriptor
        }
    }

    static func fsyncParentDirectory(of url: URL) throws {
        try withVerifiedParent(of: url) { descriptor, _ in
            guard fsync(descriptor) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        }
    }

    static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PommeAgentProtocol.Error.invalidRequest }
    }

    private static func fsyncParent(of url: URL) throws { try fsyncParentDirectory(of: url) }

    private static func withVerifiedParent<T>(of url: URL, _ body: (Int32, String) throws -> T) throws -> T {
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        defer { _ = Darwin.close(root) }
        return try withVerifiedParent(of: url, rootDescriptor: root, body)
    }

    /// Walks beneath an already-open filesystem root. Production always uses
    /// the real root and root-owned platform aliases; a separate descriptor
    /// allows tests to reproduce Recovery's filesystem without changing it.
    static func withVerifiedParent<T>(
        of url: URL,
        rootDescriptor: Int32,
        trustedAliasOwner: uid_t = 0,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("\0") else { throw PommeAgentProtocol.Error.invalidRequest }
        var pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = pieces.last, !leaf.isEmpty, leaf != ".", leaf != ".." else { throw PommeAgentProtocol.Error.invalidRequest }

        // macOS keeps these compatibility aliases at the filesystem root.
        // Resolve only the fixed aliases lexically, then continue walking every
        // component through an fd with O_NOFOLLOW.  Arbitrary user-controlled
        // ancestor symlinks remain rejected by the descriptor-relative walk.
        if let first = pieces.first, first == "var" || first == "tmp" || first == "etc" {
            pieces.insert("private", at: 0)
        }

        // Tahoe Recovery makes /private an actual symlink rather than the
        // directory seen in normal macOS. Recognize only the observed,
        // system-owned alias (relative to / or absolute) and walk its fixed
        // destination from the root descriptor; never follow an arbitrary
        // link or canonicalize a path.
        if pieces.first == "private", pieces.count > 1 {
            var entry = stat()
            guard fstatat(rootDescriptor, "private", &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw PommeAgentProtocol.Error.invalidRequest
            }
            if entry.st_mode & S_IFMT == S_IFLNK {
                let expectedTargets = [
                    Array("System/Volumes/Data/private".utf8),
                    Array("/System/Volumes/Data/private".utf8)
                ]
                // One extra byte distinguishes an exact target from a longer
                // link whose prefix would otherwise look valid after truncation.
                var target = [UInt8](repeating: 0, count: "/System/Volumes/Data/private".utf8.count + 1)
                let count = target.withUnsafeMutableBytes { buffer in
                    readlinkat(
                        rootDescriptor,
                        "private",
                        buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                        buffer.count
                    )
                }
                let matchesTarget = expectedTargets.contains { expected in
                    count == expected.count
                        && target.prefix(expected.count).elementsEqual(expected)
                }
                guard entry.st_uid == trustedAliasOwner,
                      entry.st_nlink == 1,
                      matchesTarget
                else { throw PommeAgentProtocol.Error.invalidRequest }

                // A changed directory entry is not the link whose target was
                // just checked. Reject replacement before opening any target.
                var current = stat()
                guard fstatat(rootDescriptor, "private", &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == entry.st_dev,
                      current.st_ino == entry.st_ino,
                      current.st_mode == entry.st_mode,
                      current.st_uid == entry.st_uid,
                      current.st_gid == entry.st_gid,
                      current.st_nlink == entry.st_nlink
                else { throw PommeAgentProtocol.Error.invalidRequest }
                pieces = ["System", "Volumes", "Data", "private"] + pieces.dropFirst()
            }
        }

        var directory = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
        defer { _ = Darwin.close(directory) }
        for component in pieces.dropLast() {
            guard component != ".", component != ".." else { throw PommeAgentProtocol.Error.invalidRequest }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw PommeAgentProtocol.Error.invalidRequest }
            _ = Darwin.close(directory); directory = next
        }
        return try body(directory, leaf)
    }

    private static func leafName(_ url: URL) throws -> String {
        let value = url.lastPathComponent
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/") else { throw PommeAgentProtocol.Error.invalidRequest }
        return value
    }
}
