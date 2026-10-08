import CryptoKit
import Darwin
import Foundation

/// Adds a signed Pomme executable to the append-only agent artifact store,
/// as Scripts/archive-agent.sh does. VM creation retains the executable that
/// its plan pins, so that a later repair or resumed creation can install that
/// exact agent after Homebrew, the install script, or `pomme update` has
/// replaced `pomme`.
struct PommeAgentArtifactArchiver: Sendable {
    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unsafeStore
        case sourceRejected
        case digestMismatch
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unsafeStore:
                "The Pomme agent artifact store is not a private directory."
            case .sourceRejected:
                "The Pomme executable is not a readable regular file."
            case .digestMismatch:
                "The Pomme executable changed while it was copied."
            case .writeFailed:
                "The Pomme agent artifact couldn't be written."
            }
        }
    }

    private let rootURL: URL
    private let dependencies: PommeAgentArtifactStore.Dependencies

    /// `rootURL` is the Pomme application-support root, which must already
    /// exist.
    init(rootURL: URL, dependencies: PommeAgentArtifactStore.Dependencies = .init()) {
        self.rootURL = rootURL
        self.dependencies = dependencies
    }

    /// Copies the executable into the store and returns the retained copy.
    /// An existing entry for the digest is verified and reused, never
    /// replaced. The copy must pass the store's own checks, including the
    /// Developer ID signature requirement, before it's added.
    @discardableResult
    func retain(executableAt source: URL, sha256: String) throws -> URL {
        let store = PommeAgentArtifactStore(rootURL: rootURL, dependencies: dependencies)
        let destination = try store.path(for: sha256)
        let digestDirectory = destination.deletingLastPathComponent()
        let digests = digestDirectory.deletingLastPathComponent()
        let artifacts = digests.deletingLastPathComponent()
        try Self.ensurePrivateDirectory(rootURL, create: false)
        for directory in [artifacts, digests, digestDirectory] {
            try Self.ensurePrivateDirectory(directory, create: true)
        }

        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            return try store.resolve(sha256: sha256)
        }

        do {
            try add(source, sha256: sha256, to: destination)
        } catch {
            // Leave no empty digest directory behind. rmdir removes only an
            // empty one, so another process's entry stays.
            rmdir(digestDirectory.path)
            throw error
        }
        return try store.resolve(sha256: sha256)
    }

    private func add(_ source: URL, sha256: String, to destination: URL) throws {
        let bytes = try Self.readExecutable(source)
        guard Self.sha256(bytes) == sha256 else { throw Error.digestMismatch }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".pomme-agent.\(UUID().uuidString)")
        defer { unlink(temporary.path) }
        try Self.write(bytes, to: temporary)
        do { try dependencies.verifyCodeSignature(temporary) }
        catch { throw PommeAgentArtifactStore.Error.signatureRejected }

        // RENAME_EXCL never replaces an entry that another process added
        // first. That entry is checked like any other.
        if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0, errno != EEXIST {
            throw Error.writeFailed
        }
    }

    private static func ensurePrivateDirectory(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard create, errno == ENOENT, mkdir(url.path, 0o700) == 0 || errno == EEXIST,
                  lstat(url.path, &info) == 0
            else { throw Error.unsafeStore }
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0
        else { throw Error.unsafeStore }
    }

    private static func readExecutable(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Error.sourceRejected }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              info.st_size <= off_t(PommeAgentArtifactStore.maximumExecutableBytes)
        else { throw Error.sourceRejected }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let result = read(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if result < 0, errno == EINTR { continue }
                if result <= 0 { break }
                total += result
            }
            return total
        }
        guard count == bytes.count else { throw Error.sourceRejected }
        return bytes
    }

    private static func write(_ bytes: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Error.writeFailed }
        defer { close(descriptor) }
        let written = bytes.withUnsafeBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if result < 0, errno == EINTR { continue }
                if result <= 0 { break }
                total += result
            }
            return total
        }
        guard written == bytes.count, fchmod(descriptor, 0o555) == 0, fsync(descriptor) == 0 else {
            throw Error.writeFailed
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
