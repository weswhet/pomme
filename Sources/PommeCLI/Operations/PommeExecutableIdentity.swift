import CryptoKit
import Foundation

enum PommeExecutableIdentityError: Error, Equatable, PommeDescribedError, Sendable {
    case identityRejected

    var code: PommeErrorCode { .executableIdentityRejected }

    var errorDescription: String? {
        "Pomme couldn't read or verify its own executable file, so it can't pin the agent that it installs."
    }

    var recoverySuggestion: String? {
        "Make sure that the `pomme` executable exists and is readable, or reinstall it with `pomme update`, then retry."
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
