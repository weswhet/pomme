import CryptoKit
import Darwin
import Foundation

/// The persistent agent digest a VM runs after `pomme agent update`. The
/// creation record stays immutable and keeps pinning the agent it installed;
/// this record, authenticated with the same per-VM journal key and bound to
/// that creation record, supersedes the pin for later normal-agent checks.
struct PommeAgentUpdateRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let fileName = "agent-update-v1.json"

    struct Unsigned: Codable, Equatable, Sendable {
        let schema: Int
        let vmUUID: UUID
        let planDigest: String
        let previousExecutableDigest: String
        let executableDigest: String
        let updatedAt: Int64
    }

    let unsigned: Unsigned
    let integrity: String

    var executableDigest: String { unsigned.executableDigest }

    static func make(
        plan: PommeProvisioningPlan,
        previousExecutableDigest: String,
        executableDigest: String,
        key: Data,
        now: Date = Date()
    ) throws -> Self {
        let unsigned = Unsigned(
            schema: schemaVersion,
            vmUUID: plan.vm.uuid,
            planDigest: plan.digest,
            previousExecutableDigest: try PommeAgentAuthentication.normalized(previousExecutableDigest),
            executableDigest: try PommeAgentAuthentication.normalized(executableDigest),
            updatedAt: Int64(now.timeIntervalSince1970)
        )
        return .init(unsigned: unsigned, integrity: try signature(unsigned, key: key))
    }

    /// Returns the digest only for a record authenticated by this VM's key and
    /// bound to its exact creation record.
    func verifiedDigest(plan: PommeProvisioningPlan, key: Data) throws -> String {
        guard unsigned.schema == Self.schemaVersion,
              unsigned.vmUUID == plan.vm.uuid,
              unsigned.planDigest == plan.digest,
              PommeProvisioningDigest.isSHA256(unsigned.executableDigest),
              let code = Data(base64Encoded: integrity),
              HMAC<SHA256>.isValidAuthenticationCode(
                code, authenticating: try PommeProvisioningCoding.encode(unsigned),
                using: try Self.symmetricKey(key))
        else { throw PommeProvisioningError.integrityFailure }
        return unsigned.executableDigest
    }

    private static func signature(_ unsigned: Unsigned, key: Data) throws -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: try PommeProvisioningCoding.encode(unsigned), using: try symmetricKey(key)
        )).base64EncodedString()
    }

    private static func symmetricKey(_ key: Data) throws -> SymmetricKey {
        guard key.count >= 32 else { throw PommeProvisioningError.integrityFailure }
        return SymmetricKey(data: key)
    }

    // MARK: Storage

    static func load(at url: URL) throws -> Self? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw PommeProvisioningError.integrityFailure }
            return nil
        }
        let data = try PommeSSHBootstrap.privateRead(url, owner: geteuid(), allowedModes: [0o600])
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func write(to url: URL) throws {
        let data = try PommeProvisioningCoding.encode(self)
        let stage = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PommeProvisioningError.integrityFailure }
        do {
            try PommeAgentFileTransaction.writeAll(descriptor, data: data)
            guard fsync(descriptor) == 0 else { throw PommeProvisioningError.integrityFailure }
            _ = Darwin.close(descriptor)
            guard rename(stage.path, url.path) == 0 else { throw PommeProvisioningError.integrityFailure }
            try PommeAgentFileTransaction.fsyncParentDirectory(of: url)
        } catch {
            _ = Darwin.close(descriptor)
            _ = unlink(stage.path)
            throw error
        }
    }
}
