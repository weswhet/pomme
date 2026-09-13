import CryptoKit
import Foundation

enum PommeExecutableIdentityError: Error, Equatable, LocalizedError, Sendable {
    case identityRejected

    var errorDescription: String? {
        "Pomme rejected the running executable's identity evidence."
    }
}

/// Resolves and digests the process-owned executable so provisioning can pin
/// the exact agent binary it installs.
enum PommeExecutableIdentity {
    /// Resolves the process-owned executable independently of its invocation
    /// spelling (which may be a bare PATH name or a symlink).
    static func currentExecutableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            throw PommeExecutableIdentityError.identityRejected
        }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw PommeExecutableIdentityError.identityRejected
        }
        let path = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    static func executableDigest(at url: URL) throws -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == url.standardizedFileURL.path else {
            throw PommeExecutableIdentityError.identityRejected
        }
        let data: Data
        do { data = try Data(contentsOf: canonical, options: .mappedIfSafe) }
        catch { throw PommeExecutableIdentityError.identityRejected }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
