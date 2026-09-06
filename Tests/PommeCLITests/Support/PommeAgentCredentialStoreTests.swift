import Foundation
import Security
import Testing

@Suite("Persistent agent Keychain store", .serialized)
struct PommeAgentCredentialStoreTests {
    @Test("Reads and creates only in the explicit UUID and account scope")
    func explicitTargetAndScope() throws {
        let fixture = try TemporaryKeychain()
        let otherFixture = try TemporaryKeychain()
        defer {
            fixture.cleanup()
            otherFixture.cleanup()
        }

        let store = PommeAgentCredentialStore(keychainPath: fixture.path)
        let otherStore = PommeAgentCredentialStore(keychainPath: otherFixture.path)
        let firstUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)
        let otherKeychainValue = String(repeating: "c", count: 64)

        #expect(
            try store.readOrCreate(vmUUID: firstUUID, account: "agent-token") { first }
                == first
        )
        #expect(
            try otherStore.readOrCreate(vmUUID: firstUUID, account: "agent-token") {
                otherKeychainValue
            } == otherKeychainValue
        )
        #expect(
            try store.readOrCreate(vmUUID: firstUUID, account: "other-account") { second }
                == second
        )
        #expect(
            try store.read(vmUUID: firstUUID, account: "agent-token") == first
        )
        #expect(
            try store.read(vmUUID: firstUUID, account: "other-account") == second
        )
        try store.remove(vmUUID: firstUUID, account: "agent-token")
        #expect(
            try otherStore.read(vmUUID: firstUUID, account: "agent-token") == otherKeychainValue
        )
        #expect(throws: PommeAgentCredentialStore.Error.self) {
            try store.read(vmUUID: secondUUID, account: "agent-token")
        }
    }

    @Test("Repeated creation preserves the first credential and does not call the generator")
    func repeatedCreatePreservesOriginal() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let store = PommeAgentCredentialStore(keychainPath: fixture.path)
        let vmUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let original = String(repeating: "c", count: 64)
        let replacement = String(repeating: "d", count: 64)
        var generationCount = 0

        #expect(
            try store.readOrCreate(vmUUID: vmUUID, account: "agent-token") { original }
                == original
        )
        #expect(
            try store.readOrCreate(vmUUID: vmUUID, account: "agent-token") {
                generationCount += 1
                return replacement
            } == original
        )
        #expect(generationCount == 0)
    }

    @Test("Scoped queries select the target Keychain and omit Data Protection attributes")
    func queryScopingAndAttributes() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let capture = SecItemCapture()
        let stored = String(repeating: "e", count: 64)
        let operations = PommeAgentCredentialStore.SecItemOperations(
            copyMatching: { query, result in
                capture.copyQueries.append(query)
                if capture.copyQueries.count == 1 {
                    return errSecItemNotFound
                }
                result.pointee = Data(stored.utf8) as CFTypeRef
                return errSecSuccess
            },
            add: { query in
                capture.addQueries.append(query)
                return errSecDuplicateItem
            },
            delete: { query in
                capture.deleteQueries.append(query)
                return errSecSuccess
            }
        )
        let store = PommeAgentCredentialStore(
            keychainPath: fixture.path,
            operations: operations
        )
        let vmUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let account = "agent.token:unchanged"

        #expect(
            try store.readOrCreate(vmUUID: vmUUID, account: account) { stored }
                == stored
        )

        let addQuery = try #require(capture.addQueries.first)
        let copyQuery = try #require(capture.copyQueries.first)
        #expect(addQuery[kSecUseKeychain as String] != nil)
        #expect(copyQuery[kSecMatchSearchList as String] != nil)
        #expect(addQuery[kSecAttrService as String] as? String == pommeCredentialService(forUUID: vmUUID.uuidString))
        #expect(addQuery[kSecAttrAccount as String] as? String == account)
        #expect(copyQuery[kSecAttrAccount as String] as? String == account)
        #expect(addQuery[kSecUseAuthenticationUI as String] != nil)
        #expect(copyQuery[kSecUseAuthenticationUI as String] != nil)

        for query in [addQuery, copyQuery] {
            #expect(query[kSecUseDataProtectionKeychain as String] == nil)
            #expect(query[kSecAttrAccessible as String] == nil)
            #expect(query[kSecAttrSynchronizable as String] == nil)
        }
    }

    @Test("Strict read reports a missing item without creating one")
    func strictReadDoesNotCreate() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let store = PommeAgentCredentialStore(keychainPath: fixture.path)
        let vmUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        #expect(
            throws: PommeAgentCredentialStore.Error.credentialMissing(status: errSecItemNotFound)
        ) {
            try store.read(vmUUID: vmUUID, account: "agent-token")
        }
    }

    @Test("A malformed existing item is rejected and never replaced")
    func malformedExistingIsNotReplaced() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let vmUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let account = "agent-token"
        let malformed = "not-a-pomme-agent-token"
        try fixture.add(service: pommeCredentialService(forUUID: vmUUID.uuidString), account: account, value: malformed)

        let store = PommeAgentCredentialStore(keychainPath: fixture.path)
        var generationCount = 0
        #expect(throws: PommeAgentCredentialStore.Error.malformedCredential) {
            try store.readOrCreate(vmUUID: vmUUID, account: account) {
                generationCount += 1
                return String(repeating: "f", count: 64)
            }
        }
        #expect(generationCount == 0)
        #expect(
            try fixture.readRaw(service: pommeCredentialService(forUUID: vmUUID.uuidString), account: account)
                == malformed
        )
    }

    @Test("A duplicate add rereads the winner and never updates it")
    func duplicateRaceReturnsWinner() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let capture = SecItemCapture()
        let winner = String(repeating: "1", count: 64)
        let candidate = String(repeating: "2", count: 64)
        let operations = PommeAgentCredentialStore.SecItemOperations(
            copyMatching: { query, result in
                capture.copyQueries.append(query)
                if capture.copyQueries.count == 1 {
                    return errSecItemNotFound
                }
                result.pointee = Data(winner.utf8) as CFTypeRef
                return errSecSuccess
            },
            add: { query in
                capture.addQueries.append(query)
                return errSecDuplicateItem
            },
            delete: { query in
                capture.deleteQueries.append(query)
                return errSecSuccess
            }
        )
        let store = PommeAgentCredentialStore(
            keychainPath: fixture.path,
            operations: operations
        )
        let vmUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        var generationCount = 0

        let result = try store.readOrCreate(vmUUID: vmUUID, account: "agent-token") {
            generationCount += 1
            return candidate
        }

        #expect(result == winner)
        #expect(generationCount == 1)
        #expect(capture.copyQueries.count == 2)
        #expect(capture.addQueries.count == 1)
        #expect(capture.deleteQueries.isEmpty)
        let addedData = try #require(capture.addQueries[0][kSecValueData as String] as? Data)
        #expect(String(data: addedData, encoding: .utf8) == candidate)
    }

    @Test("Denied read status is preserved without generation or mutation")
    func deniedReadIsNonMutating() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let capture = SecItemCapture()
        let operations = PommeAgentCredentialStore.SecItemOperations(
            copyMatching: { query, _ in
                capture.copyQueries.append(query)
                return errSecInteractionNotAllowed
            },
            add: { query in
                capture.addQueries.append(query)
                return errSecSuccess
            },
            delete: { query in
                capture.deleteQueries.append(query)
                return errSecSuccess
            }
        )
        let store = PommeAgentCredentialStore(
            keychainPath: fixture.path,
            operations: operations
        )
        var generationCount = 0
        #expect(
            throws: PommeAgentCredentialStore.Error.credentialReadFailed(
                status: errSecInteractionNotAllowed
            )
        ) {
            try store.readOrCreate(vmUUID: UUID(), account: "agent-token") {
                generationCount += 1
                return String(repeating: "3", count: 64)
            }
        }
        #expect(generationCount == 0)
        #expect(capture.addQueries.isEmpty)
        #expect(capture.deleteQueries.isEmpty)
    }

    @Test("A locked Keychain is non-mutating and does not generate a secret")
    func lockedKeychainIsNonMutating() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let store = PommeAgentCredentialStore(keychainPath: fixture.path)
        let vmUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let original = String(repeating: "4", count: 64)
        #expect(
            try store.readOrCreate(vmUUID: vmUUID, account: "agent-token") { original }
                == original
        )
        try fixture.lock()

        var generationCount = 0
        #expect(
            throws: PommeAgentCredentialStore.Error.keychainLocked(
                status: errSecInteractionNotAllowed
            )
        ) {
            try store.readOrCreate(vmUUID: vmUUID, account: "agent-token") {
                generationCount += 1
                return String(repeating: "5", count: 64)
            }
        }
        #expect(generationCount == 0)

        try fixture.unlock()
        #expect(try store.read(vmUUID: vmUUID, account: "agent-token") == original)
    }

    @Test("Removal is idempotent and exact to the UUID and account")
    func idempotentExactRemoval() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let store = PommeAgentCredentialStore(keychainPath: fixture.path)
        let firstUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let first = String(repeating: "6", count: 64)
        let sibling = String(repeating: "7", count: 64)
        #expect(
            try store.readOrCreate(vmUUID: firstUUID, account: "agent-token") { first } == first
        )
        #expect(
            try store.readOrCreate(vmUUID: firstUUID, account: "other-account") { sibling } == sibling
        )
        #expect(
            try store.readOrCreate(vmUUID: secondUUID, account: "agent-token") { sibling } == sibling
        )

        try store.remove(vmUUID: firstUUID, account: "agent-token")
        try store.remove(vmUUID: firstUUID, account: "agent-token")

        #expect(
            try store.read(vmUUID: firstUUID, account: "other-account") == sibling
        )
        #expect(
            try store.read(vmUUID: secondUUID, account: "agent-token") == sibling
        )
        #expect(throws: PommeAgentCredentialStore.Error.credentialMissing(status: errSecItemNotFound)) {
            try store.read(vmUUID: firstUUID, account: "agent-token")
        }
    }

    @Test("Errors redact all credential scope values while retaining status diagnostics")
    func errorsAreRedacted() throws {
        let fixture = try TemporaryKeychain()
        defer { fixture.cleanup() }

        let capture = SecItemCapture()
        let operations = PommeAgentCredentialStore.SecItemOperations(
            copyMatching: { _, _ in errSecAuthFailed },
            add: { _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )
        let store = PommeAgentCredentialStore(
            keychainPath: fixture.path,
            operations: operations
        )
        let vmUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let account = "account-with-sensitive-name"
        let service = pommeCredentialService(forUUID: vmUUID.uuidString)
        let secret = String(repeating: "8", count: 64)
        _ = capture

        do {
            try store.read(vmUUID: vmUUID, account: account)
            Issue.record("Expected the injected Keychain denial.")
        } catch {
            let description = String(describing: error)
            #expect(description.contains(String(errSecAuthFailed)))
            #expect(!description.contains(account))
            #expect(!description.contains(service))
            #expect(!description.contains(secret))
        }
    }
}

private final class SecItemCapture {
    var copyQueries: [[String: Any]] = []
    var addQueries: [[String: Any]] = []
    var deleteQueries: [[String: Any]] = []
}

private struct TemporaryKeychain {
    private static let password = Data("pomme-test-keychain-password".utf8)

    let path: String
    let keychain: SecKeychain

    init() throws {
        let fixturePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-agent-credential-\(UUID().uuidString).keychain-db")
            .path
        var created: SecKeychain?
        let status = Self.password.withUnsafeBytes { bytes in
            SecKeychainCreate(
                fixturePath,
                UInt32(bytes.count),
                bytes.baseAddress,
                false,
                nil,
                &created
            )
        }
        guard status == errSecSuccess, let created else {
            throw FixtureError.keychain(status: status)
        }
        path = fixturePath
        keychain = created
    }

    func add(service: String, account: String, value: String) throws {
        var query = hostKeychainQuery(service: service, account: account, keychain: keychain)
        query[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FixtureError.keychain(status: status)
        }
    }

    func readRaw(service: String, account: String) throws -> String {
        var query = hostKeychainLookupQuery(service: service, account: account, keychain: keychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw FixtureError.keychain(status: status)
        }
        return value
    }

    func lock() throws {
        let status = SecKeychainLock(keychain)
        guard status == errSecSuccess else {
            throw FixtureError.keychain(status: status)
        }
    }

    func unlock() throws {
        let status = Self.password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        guard status == errSecSuccess else {
            throw FixtureError.keychain(status: status)
        }
    }

    func cleanup() {
        _ = Self.password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        let status = SecKeychainDelete(keychain)
        if status != errSecSuccess {
            Issue.record("Temporary Keychain cleanup failed (Security status \(status)).")
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

private enum FixtureError: Swift.Error {
    case keychain(status: OSStatus)
}
