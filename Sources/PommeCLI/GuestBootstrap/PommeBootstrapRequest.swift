import CryptoKit
import Foundation

/// The manifest contains identities and an authentication tag, never the token or password.
struct PommeBootstrapRequest: Codable, Equatable, Sendable, CustomStringConvertible {
    let version: Int
    let vmUUID: UUID
    let requestID: UUID
    let planSHA256: String
    let executableSHA256: String
    let expiresAt: Int64
    let stagingOwner: UInt32
    let tokenSHA256: String
    let authentication: String
    var description: String { "PommeBootstrapRequest(redacted)" }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, vmUUID, requestID, planSHA256, executableSHA256, expiresAt, stagingOwner, tokenSHA256, authentication
    }
    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else { throw PommeSSHBootstrapError.invalid }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        vmUUID = try c.decode(UUID.self, forKey: .vmUUID)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        planSHA256 = try c.decode(String.self, forKey: .planSHA256)
        executableSHA256 = try c.decode(String.self, forKey: .executableSHA256)
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        stagingOwner = try c.decode(UInt32.self, forKey: .stagingOwner)
        tokenSHA256 = try c.decode(String.self, forKey: .tokenSHA256)
        authentication = try c.decode(String.self, forKey: .authentication)
        try validateShape()
    }
    init(vmUUID: UUID, requestID: UUID, planSHA256: String, executableSHA256: String, expiresAt: Int64, stagingOwner: UInt32, token: Data) throws {
        version = 1; self.vmUUID = vmUUID; self.requestID = requestID
        self.planSHA256 = planSHA256; self.executableSHA256 = executableSHA256
        self.expiresAt = expiresAt; self.stagingOwner = stagingOwner
        tokenSHA256 = Self.digest(token)
        authentication = Self.tag(vmUUID: vmUUID, requestID: requestID, plan: planSHA256, executable: executableSHA256, expires: expiresAt, owner: stagingOwner, tokenDigest: tokenSHA256, token: token)
        try validateShape()
    }
    func verify(token: Data, now: Date, vmUUID: UUID, planSHA256: String, executableSHA256: String) throws {
        try authenticate(token: token, vmUUID: vmUUID, planSHA256: planSHA256, executableSHA256: executableSHA256)
        guard expiresAt > Int64(now.timeIntervalSince1970), expiresAt <= Int64(now.timeIntervalSince1970) + 3600 else { throw PommeSSHBootstrapError.invalid }
    }
    /// Renewal authenticates the old immutable bindings even after expiry. The
    /// caller must separately prove the exact remote staging hashes before
    /// replacing only request.json; installation never accepts an expired form.
    func renewed(token: Data, now: Date, vmUUID: UUID, planSHA256: String, executableSHA256: String, requestID: UUID, stagingOwner: UInt32) throws -> Self {
        try authenticate(token: token, vmUUID: vmUUID, planSHA256: planSHA256, executableSHA256: executableSHA256)
        guard self.requestID == requestID, self.stagingOwner == stagingOwner else { throw PommeSSHBootstrapError.invalid }
        guard expiresAt <= Int64(now.timeIntervalSince1970) + 3600 else { throw PommeSSHBootstrapError.invalid }
        return try .init(vmUUID: vmUUID, requestID: requestID, planSHA256: planSHA256, executableSHA256: executableSHA256,
                         expiresAt: Int64(now.timeIntervalSince1970) + 3600, stagingOwner: stagingOwner, token: token)
    }
    func authenticate(token: Data, vmUUID: UUID, planSHA256: String, executableSHA256: String) throws {
        try validateShape()
        guard self.vmUUID == vmUUID, self.planSHA256 == planSHA256, self.executableSHA256 == executableSHA256,
              Self.digest(token) == tokenSHA256,
              let tag = Data(hexString: authentication),
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: authenticatedData, using: SymmetricKey(data: token))
        else { throw PommeSSHBootstrapError.invalid }
    }
    private func validateShape() throws {
        guard version == 1, stagingOwner > 0, expiresAt > 0,
              [planSHA256, executableSHA256, tokenSHA256, authentication].allSatisfy({ $0.count == 64 && $0.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) }) else { throw PommeSSHBootstrapError.invalid }
    }
    private var authenticatedData: Data { Self.message(vmUUID: vmUUID, requestID: requestID, plan: planSHA256, executable: executableSHA256, expires: expiresAt, owner: stagingOwner, tokenDigest: tokenSHA256) }
    private static func message(vmUUID: UUID, requestID: UUID, plan: String, executable: String, expires: Int64, owner: UInt32, tokenDigest: String) -> Data {
        Data(["pomme-ssh-bootstrap-v1", vmUUID.uuidString.lowercased(), requestID.uuidString.lowercased(), plan, executable, String(expires), String(owner), "pomme", "agent.token", tokenDigest].joined(separator: "\n").utf8)
    }
    private static func tag(vmUUID: UUID, requestID: UUID, plan: String, executable: String, expires: Int64, owner: UInt32, tokenDigest: String, token: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: message(vmUUID: vmUUID, requestID: requestID, plan: plan, executable: executable, expires: expires, owner: owner, tokenDigest: tokenDigest), using: SymmetricKey(data: token)).map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count == 64 else { return nil }
        var bytes: [UInt8] = []; var index = hexString.startIndex
        while index != hexString.endIndex {
            let end = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        self.init(bytes)
    }
}
