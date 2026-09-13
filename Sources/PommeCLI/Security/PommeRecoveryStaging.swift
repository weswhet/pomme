import CryptoKit
import Darwin
import Foundation
import Security
@preconcurrency import Virtualization

enum PommeRecoveryStagingError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput
    case sourceRejected
    case signatureRejected
    case identityChanged
    case unsafeParent
    case unsafeArtifact
    case unknownCleanupState
    case cleanupFailed
    case shareNotCleared

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "Recovery staging input was rejected."
        case .sourceRejected:
            "Recovery staging executable was rejected."
        case .signatureRejected:
            "Recovery staging executable signature was rejected."
        case .identityChanged:
            "Recovery staging executable identity changed while it was read."
        case .unsafeParent:
            "Recovery staging parent is not private and stable."
        case .unsafeArtifact:
            "Recovery staging artifact is not owner-private."
        case .unknownCleanupState:
            "Recovery staging cleanup encountered an unknown artifact."
        case .cleanupFailed:
            "Recovery staging cleanup could not be proven complete."
        case .shareNotCleared:
            "Recovery staging share could not be detached and verified."
        }
    }
}

/// Fixed names are the complete host-side artifact set. Cleanup rejects every
/// name outside this set before unlinking any entry.
enum PommeRecoveryArtifactNames {
    static let executable = "pomme-agent"
    static let launcher = "pomme-recovery-launcher"
    static let request = "request.json"
    static let credential = "session.credential"
    static let all: Set<String> = [executable, launcher, request, credential]

    static let modes: [String: mode_t] = [
        executable: 0o555,
        launcher: 0o555,
        request: 0o400,
        credential: 0o400
    ]
}

struct PommeRecoveryStagingProof: Equatable, Sendable {
    let requestID: UUID
    let vmUUID: UUID
    let readOnly: Bool
    let signatureVerified: Bool
    let digestVerified: Bool
    let inodeVerified: Bool
    let modeVerified: Bool
    let launcherInstalled: Bool

    var isComplete: Bool {
        readOnly
            && signatureVerified
            && digestVerified
            && inodeVerified
            && modeVerified
            && launcherInstalled
    }
}

/// A prepared, read-only VirtioFS directory share. It is bound to one VM and
/// one request; callers cannot reuse the artifact with a different request.
final class PommeRecoveryStaging: @unchecked Sendable {
    let request: PommeRecoverySessionRequest
    let rootURL: URL
    let deviceConfiguration: VZVirtioFileSystemDeviceConfiguration
    let proof: PommeRecoveryStagingProof

    private let binding: (requestID: UUID, vmUUID: UUID)
    private let lock = NSLock()
    private var artifactsRemoved = false

    init(
        request: PommeRecoverySessionRequest,
        rootURL: URL,
        deviceConfiguration: VZVirtioFileSystemDeviceConfiguration,
        proof: PommeRecoveryStagingProof
    ) {
        self.request = request
        self.rootURL = rootURL
        self.deviceConfiguration = deviceConfiguration
        self.proof = proof
        binding = (request.requestID, request.vmUUID)
    }

    var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] {
        [deviceConfiguration]
    }

    /// Converts staging proof into session evidence only when the immutable
    /// request binding still matches. A live root adapter supplies the
    /// listener bit after it has bound the request's port.
    func rootEvidence(listenerReady: Bool) throws -> PommeRecoveryRootEvidence {
        guard proof.requestID == request.requestID,
              proof.vmUUID == request.vmUUID,
              proof.isComplete
        else { throw PommeRecoveryStagingError.unsafeArtifact }
        return .init(
            requestID: request.requestID,
            vmUUID: request.vmUUID,
            listenerPort: request.listenerPort,
            shareReadOnly: proof.readOnly,
            executableSignatureVerified: proof.signatureVerified,
            executableDigestVerified: proof.digestVerified,
            inodeVerified: proof.inodeVerified,
            modeVerified: proof.modeVerified,
            launcherInstalled: proof.launcherInstalled,
            listenerReady: listenerReady
        )
    }

    func clearShare(from vm: VZVirtualMachine, on queue: DispatchQueue) throws {
        let cleared = queue.sync { () -> Bool in
            let matches = vm.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDevice }
                .filter { $0.tag == PommeRecoveryStagingBuilder.tag(for: request) }
            guard matches.count == 1 else { return false }
            matches[0].share = nil
            return matches[0].share == nil
        }
        guard cleared else { throw PommeRecoveryStagingError.shareNotCleared }
    }

    /// Replaces the empty ordinary-Recovery bootstrap share with this exact
    /// request-bound read-only staging share. The device tag is fixed by the
    /// request operation, so a pre-attached empty device can be populated
    /// only for terminal admission.
    func attachShare(to vm: VZVirtualMachine, on queue: DispatchQueue) throws {
        let attached = queue.sync { () -> Bool in
            let matches = vm.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDevice }
                .filter { $0.tag == PommeRecoveryStagingBuilder.tag(for: request) }
            guard matches.count == 1,
                  let share = deviceConfiguration.share
            else { return false }
            matches[0].share = share
            return matches[0].share != nil
        }
        guard attached else { throw PommeRecoveryStagingError.shareNotCleared }
    }

    /// Removes only the request's exact root and fixed children. An unknown
    /// entry, symlink, owner, mode, inode, or directory state is terminal.
    func removeHostArtifacts() throws {
        try lock.withLock {
            if artifactsRemoved { return }
            try Self.cleanupRoot(rootURL)
            artifactsRemoved = true
        }
    }

    static func cleanupRoot(_ root: URL) throws {
        let parent = root.deletingLastPathComponent()
        let name = root.lastPathComponent
        guard !name.isEmpty, name.hasPrefix(PommeRecoveryStagingBuilder.rootPrefix), !name.contains("/") else {
            throw PommeRecoveryStagingError.unknownCleanupState
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw PommeRecoveryStagingError.cleanupFailed }
        defer { close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_mode & 0o022 == 0
        else { throw PommeRecoveryStagingError.unsafeParent }

        let rootFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if rootFD < 0, errno == ENOENT { return }
        guard rootFD >= 0 else { throw PommeRecoveryStagingError.cleanupFailed }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              rootInfo.st_uid == geteuid(),
              rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_mode & 0o777 == 0o700,
              rootInfo.st_nlink >= 2
        else { throw PommeRecoveryStagingError.unsafeArtifact }

        let names = try names(in: rootFD)
        guard Set(names).isSubset(of: PommeRecoveryArtifactNames.all) else {
            throw PommeRecoveryStagingError.unknownCleanupState
        }
        for item in names {
            guard let expectedMode = PommeRecoveryArtifactNames.modes[item] else {
                throw PommeRecoveryStagingError.unknownCleanupState
            }
            var info = stat()
            guard fstatat(rootFD, item, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o777 == expectedMode,
                  info.st_nlink == 1,
                  unlinkat(rootFD, item, 0) == 0
            else { throw PommeRecoveryStagingError.unsafeArtifact }
        }

        guard fsync(rootFD) == 0 else { throw PommeRecoveryStagingError.cleanupFailed }

        var namedInfo = stat()
        guard fstatat(parentFD, name, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              namedInfo.st_uid == geteuid(),
              namedInfo.st_mode & S_IFMT == S_IFDIR,
              namedInfo.st_dev == rootInfo.st_dev,
              namedInfo.st_ino == rootInfo.st_ino,
              unlinkat(parentFD, name, AT_REMOVEDIR) == 0
        else { throw PommeRecoveryStagingError.cleanupFailed }
        guard fsync(parentFD) == 0 else { throw PommeRecoveryStagingError.cleanupFailed }
    }

    private static func names(in descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw PommeRecoveryStagingError.cleanupFailed
        }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let value = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if value != "." && value != ".." { result.append(value) }
        }
        return result
    }
}

struct PommeRecoveryStagingBuilder: Sendable {
    static let maximumExecutableBytes = 128 * 1_024 * 1_024
    static let rootPrefix = "pomme-recovery-"
    static let terminalBootstrapTag = "pomme-terminal-bootstrap"

    struct Input: Sendable {
        let request: PommeRecoverySessionRequest
        let signedExecutableURL: URL
        let launcherScript: String
        let credential: PommeRecoveryCredential
        let temporaryParentURL: URL
    }

    struct Dependencies: Sendable {
        var verifyCodeSignature: @Sendable (URL) throws -> Void
        var rootName: @Sendable () -> String

        init(
            verifyCodeSignature: @escaping @Sendable (URL) throws -> Void = Self.verifyCodeSignature,
            rootName: @escaping @Sendable () -> String = {
                "\(PommeRecoveryStagingBuilder.rootPrefix)\(UUID().uuidString.lowercased())"
            }
        ) {
            self.verifyCodeSignature = verifyCodeSignature
            self.rootName = rootName
        }

        private static func verifyCodeSignature(_ url: URL) throws {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecStaticCodeCheckValidity(
                      code,
                      SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                      nil
                  ) == errSecSuccess
            else { throw PommeRecoveryStagingError.signatureRejected }
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .init()) {
        self.dependencies = dependencies
    }

    func build(_ input: Input) throws -> PommeRecoveryStaging {
        guard input.request.isWellFormed,
              input.request.executableSHA256 == input.request.executableSHA256.lowercased(),
              input.credential.matches(request: input.request),
              !input.launcherScript.isEmpty,
              input.launcherScript.utf8.count <= 64 * 1024
        else { throw PommeRecoveryStagingError.invalidInput }

        let executable = try readVerifiedExecutable(
            at: input.signedExecutableURL,
            expectedSHA256: input.request.executableSHA256
        )
        let parent = input.temporaryParentURL.standardizedFileURL
        guard parent.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw PommeRecoveryStagingError.unsafeParent
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw PommeRecoveryStagingError.unsafeParent }
        defer { close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_mode & 0o022 == 0
        else { throw PommeRecoveryStagingError.unsafeParent }

        let rootName = dependencies.rootName()
        guard rootName.hasPrefix(Self.rootPrefix),
              rootName.count <= 96,
              !rootName.contains("/"),
              rootName.unicodeScalars.allSatisfy({
                  (0x30...0x39).contains($0.value)
                      || (0x61...0x7a).contains($0.value)
                      || $0.value == 0x2d
              }),
              mkdirat(parentFD, rootName, 0o700) == 0
        else { throw PommeRecoveryStagingError.invalidInput }

        let rootURL = parent.appendingPathComponent(rootName, isDirectory: true)
        do {
            let rootFD = openat(parentFD, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw PommeRecoveryStagingError.cleanupFailed }
            var rootInfo = stat()
            let safeRoot = fchmod(rootFD, 0o700) == 0
                && fstat(rootFD, &rootInfo) == 0
                && rootInfo.st_uid == geteuid()
                && rootInfo.st_mode & S_IFMT == S_IFDIR
                && rootInfo.st_mode & 0o777 == 0o700
            close(rootFD)
            guard safeRoot else { throw PommeRecoveryStagingError.unsafeParent }

            try Self.write(Data(executable), name: PommeRecoveryArtifactNames.executable, mode: 0o555, root: rootURL)
            try Self.write(Data(input.launcherScript.utf8), name: PommeRecoveryArtifactNames.launcher, mode: 0o555, root: rootURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let requestData = try encoder.encode(input.request)
            try Self.write(requestData, name: PommeRecoveryArtifactNames.request, mode: 0o400, root: rootURL)
            try Self.write(
                input.credential.hexadecimalDataForStaging(),
                name: PommeRecoveryArtifactNames.credential,
                mode: 0o400,
                root: rootURL
            )

            let tag = Self.tag(for: input.request)
            try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)
            let shared = VZSharedDirectory(url: rootURL, readOnly: true)
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            device.share = VZSingleDirectoryShare(directory: shared)
            let proof = PommeRecoveryStagingProof(
                requestID: input.request.requestID,
                vmUUID: input.request.vmUUID,
                readOnly: shared.isReadOnly,
                signatureVerified: true,
                digestVerified: Self.sha256(Data(executable)) == input.request.executableSHA256,
                inodeVerified: true,
                modeVerified: true,
                launcherInstalled: true
            )
            guard proof.isComplete else { throw PommeRecoveryStagingError.unsafeArtifact }
            return PommeRecoveryStaging(
                request: input.request,
                rootURL: rootURL,
                deviceConfiguration: device,
                proof: proof
            )
        } catch {
            // The root is request-specific and was just created. Remove only
            // known entries; if an unexpected entry appeared, preserve it and
            // report the cleanup failure rather than broadening the target.
            do { try PommeRecoveryStaging.cleanupRoot(rootURL) }
            catch { throw PommeRecoveryStagingError.cleanupFailed }
            throw error
        }
    }

    static func tag(for requestID: UUID) -> String {
        let compact = requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "pomme-\(compact.prefix(24))"
    }

    static func tag(for request: PommeRecoverySessionRequest) -> String {
        request.operation == PommeRecoveryOperation.terminalSession.wireName
            ? terminalBootstrapTag
            : tag(for: request.requestID)
    }

    private func readVerifiedExecutable(at url: URL, expectedSHA256: String) throws -> Data {
        var before = stat()
        let standardized = url.standardizedFileURL
        guard standardized.path == url.path,
              standardized.path == standardized.resolvingSymlinksInPath().standardizedFileURL.path,
              lstat(url.path, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_mode & 0o022 == 0,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= Self.maximumExecutableBytes
        else { throw PommeRecoveryStagingError.sourceRejected }
        do { try dependencies.verifyCodeSignature(url) }
        catch { throw PommeRecoveryStagingError.signatureRejected }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PommeRecoveryStagingError.sourceRejected }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_size == before.st_size
        else { throw PommeRecoveryStagingError.identityChanged }

        var data = Data(count: Int(opened.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return total }
                total += result
            }
            return total
        }
        var after = stat()
        guard count == data.count,
              lstat(url.path, &after) == 0,
              after.st_mode & S_IFMT == S_IFREG,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size,
              Self.sha256(data) == expectedSHA256
        else { throw PommeRecoveryStagingError.identityChanged }
        return data
    }

    private static func write(_ data: Data, name: String, mode: mode_t, root: URL) throws {
        guard PommeRecoveryArtifactNames.all.contains(name),
              PommeRecoveryArtifactNames.modes[name] == mode,
              !name.contains("/"), name != ".", name != ".."
        else { throw PommeRecoveryStagingError.invalidInput }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw PommeRecoveryStagingError.cleanupFailed }
        defer { close(rootFD) }
        let descriptor = openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw PommeRecoveryStagingError.unsafeArtifact }
        var committed = false
        defer {
            close(descriptor)
            if !committed { _ = unlinkat(rootFD, name, 0) }
        }
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return false }
                offset += result
            }
            return true
        }
        var info = stat()
        guard wroteAll,
              fchmod(descriptor, mode) == 0,
              fsync(descriptor) == 0,
              fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == mode,
              info.st_nlink == 1,
              fsync(rootFD) == 0
        else { throw PommeRecoveryStagingError.unsafeArtifact }
        committed = true
    }

    private static func sha256(_ data: Data) -> String {
        PommeRecoveryCrypto.hex(SHA256.hash(data: data))
    }
}
