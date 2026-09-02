import Foundation
import Security
import Testing

@Suite("Host Keychain storage")
struct HostKeychainTests {
    @Test("VM credentials use the single UUID-scoped Pomme service")
    func credentialServiceIsCanonical() {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(
            pommeCredentialService(forUUID: uuid.uuidString)
                == "\(Constants.credentialServicePrefix).\(uuid.uuidString.lowercased())"
        )
    }

    @Test("A credential in a custom Keychain can be updated")
    func updateExistingCustomKeychainCredential() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-keychain-\(UUID().uuidString).keychain-db")
            .path
        let keychainPassword = Array("test-keychain-password".utf8)
        var keychain: SecKeychain?
        let createStatus = keychainPassword.withUnsafeBytes { bytes in
            SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain)
        }
        #expect(createStatus == errSecSuccess)
        let createdKeychain = try #require(keychain)
        defer {
            SecKeychainDelete(createdKeychain)
            try? FileManager.default.removeItem(atPath: path)
        }

        let service = pommeCredentialService(forUUID: UUID().uuidString)
        _ = try storeHostKeychainPassword(
            service: service,
            account: "tester",
            password: "first",
            keychainPath: path,
            unlockPolicy: .disallowTTYPrompt
        )
        _ = try storeHostKeychainPassword(
            service: service,
            account: "tester",
            password: "second",
            keychainPath: path,
            unlockPolicy: .disallowTTYPrompt
        )

        #expect(
            try findHostKeychainPassword(
                service: service,
                account: "tester",
                keychainPath: path,
                unlockPolicy: .disallowTTYPrompt
            ) == "second"
        )
    }
}
