import CryptoKit
import Darwin
import Foundation
import Security

/// Resolves the immutable, signed Pomme agent executable retained for a
/// provisioning plan.  The resolver never creates or modifies the store.  A
/// caller may therefore use it while resuming an old journal without changing
/// the plan's pinned digest.
struct PommeAgentArtifactStore: Sendable {
    static let artifactDirectoryName = "AgentArtifacts"
    static let digestDirectoryName = "sha256"
    static let artifactName = "pomme-agent"
    static let maximumExecutableBytes = 128 * 1_024 * 1_024

    /// This is the stable Developer ID requirement used by the signed local
    /// build.  It deliberately binds both the Pomme identifier and team, so a
    /// valid signature from another product cannot enter the retained store.
    static let signingRequirement = "anchor apple generic and identifier \"com.github.weswhet.pomme\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"2D8XQ77EBQ\""

    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidDigest
        case storeUnavailable
        case unsafeStore
        case artifactMissing
        case artifactRejected
        case signatureRejected
        case identityChanged
        case digestMismatch

        var errorDescription: String? {
            switch self {
            case .invalidDigest:
                "The pinned Pomme agent digest is not a lowercase SHA-256 value."
            case .storeUnavailable:
                "The pinned Pomme agent artifact store is unavailable."
            case .unsafeStore:
                "The pinned Pomme agent artifact store is not private and stable."
            case .artifactMissing:
                "The pinned Pomme agent artifact is not retained on this host."
            case .artifactRejected:
                "The retained Pomme agent artifact is not a private regular file."
            case .signatureRejected:
                "The retained Pomme agent artifact has an untrusted signature."
            case .identityChanged:
                "The retained Pomme agent artifact changed while it was read."
            case .digestMismatch:
                "The retained Pomme agent artifact does not match the pinned digest."
            }
        }
    }

    struct Dependencies: Sendable {
        var verifyCodeSignature: @Sendable (URL) throws -> Void

        init(
            verifyCodeSignature: @escaping @Sendable (URL) throws -> Void = {
                try Self.verifyCodeSignature($0)
            }
        ) {
            self.verifyCodeSignature = verifyCodeSignature
        }

        private static func verifyCodeSignature(_ url: URL) throws {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code
            else { throw Error.signatureRejected }

            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(
                PommeAgentArtifactStore.signingRequirement as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
            ) == errSecSuccess
            else { throw Error.signatureRejected }
        }
    }

    private let configuredRootURL: URL?
    private let dependencies: Dependencies

    /// `rootURL` is the Pomme application-support root, not the
    /// `AgentArtifacts` directory.  Leaving it nil selects the normal
    /// `POMME_APP_SUPPORT_DIR` override or the user's Pomme application
    /// support directory without creating it.
    init(rootURL: URL? = nil, dependencies: Dependencies = .init()) {
        configuredRootURL = rootURL
        self.dependencies = dependencies
    }

    /// Returns the retained executable only after independently checking the
    /// exact digest path, every Pomme store directory, file ownership/mode,
    /// code signature, stable inode, and SHA-256 bytes.  This method is
    /// strictly read-only.
    func resolve(sha256 expectedSHA256: String) throws -> URL {
        guard Self.isLowercaseSHA256(expectedSHA256) else {
            throw Error.invalidDigest
        }

        let rootCandidate = try configuredRootURL ?? Self.defaultRootURL()
        let root = rootCandidate.standardizedFileURL
        guard root.path.hasPrefix("/"),
              rootCandidate.path == root.path,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Error.unsafeStore }
        try Self.validateDirectory(root, missingError: .storeUnavailable)

        let artifacts = root.appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let digests = artifacts.appendingPathComponent(Self.digestDirectoryName, isDirectory: true)
        let digestDirectory = digests.appendingPathComponent(expectedSHA256, isDirectory: true)
        try Self.validateDirectory(artifacts, missingError: .storeUnavailable)
        try Self.validateDirectory(digests, missingError: .storeUnavailable)
        try Self.validateDirectory(digestDirectory, missingError: .artifactMissing)

        let executable = digestDirectory.appendingPathComponent(Self.artifactName, isDirectory: false)
        try validateExecutable(at: executable, expectedSHA256: expectedSHA256)
        return executable
    }

    /// Computes the path used by the append-only archiver.  This helper does
    /// not inspect, create, or modify the filesystem.
    func path(for sha256: String) throws -> URL {
        guard Self.isLowercaseSHA256(sha256) else { throw Error.invalidDigest }
        let root = try configuredRootURL ?? Self.defaultRootURL()
        return root
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.digestDirectoryName, isDirectory: true)
            .appendingPathComponent(sha256, isDirectory: true)
            .appendingPathComponent(Self.artifactName, isDirectory: false)
    }

    private func validateExecutable(at url: URL, expectedSHA256: String) throws {
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            if errno == ENOENT { throw Error.artifactMissing }
            throw Error.artifactRejected
        }
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & 0o022 == 0,
              before.st_size > 0,
              before.st_size <= off_t(Self.maximumExecutableBytes)
        else { throw Error.artifactRejected }

        do { try dependencies.verifyCodeSignature(url) }
        catch { throw Error.signatureRejected }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.artifactRejected }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              opened.st_mode & 0o022 == 0,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_size == before.st_size
        else { throw Error.identityChanged }

        var bytes = Data(count: Int(opened.st_size))
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total
                )
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return total }
                total += result
            }
            return total
        }

        var after = stat()
        guard count == bytes.count,
              lstat(url.path, &after) == 0,
              after.st_mode & S_IFMT == S_IFREG,
              after.st_uid == geteuid(),
              after.st_nlink == 1,
              after.st_mode & 0o022 == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size
        else { throw Error.identityChanged }

        guard Self.sha256(bytes) == expectedSHA256 else {
            throw Error.digestMismatch
        }
    }

    private static func validateDirectory(
        _ url: URL,
        missingError: Error
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw missingError }
            throw Error.unsafeStore
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_nlink >= 2,
              info.st_mode & 0o022 == 0
        else { throw Error.unsafeStore }
    }

    private static func defaultRootURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["POMME_APP_SUPPORT_DIR"],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            guard override.hasPrefix("/"),
                  url.path == URL(fileURLWithPath: override, isDirectory: true).path
            else {
                throw Error.unsafeStore
            }
            return url
        }

        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw Error.storeUnavailable }
        return base.appendingPathComponent(Constants.appSupportDirectoryName, isDirectory: true)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
