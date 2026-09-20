import Foundation
import Security
import Testing

@Suite("Security owner credential store", .serialized)
struct PommeOwnerCredentialStoreTests {
    @Test("Preboot reference preserves binding and strictly decodes")
    func prebootBinding() throws {
        let identity = CredentialFixture().identity
        let reference = try PommeOwnerCredentialReference(vmUUID: identity.vmUUID,
            machineIdentifierSHA256: identity.machineIdentifierSHA256,
            diskImageFileResourceID: identity.diskImageFileResourceID)
        #expect(reference == (try PommeOwnerCredentialReference(identity: identity, account: "pomme")))
        let encoded = try JSONEncoder().encode(reference)
        #expect(try JSONDecoder().decode(PommeOwnerCredentialReference.self, from: encoded) == reference)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["password"] = "forbidden-secret"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PommeOwnerCredentialReference.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object.removeValue(forKey: "password")
        object["service"] = "unrelated-service"
        #expect(throws: PommeOwnerCredentialStoreError.invalidReference) {
            try JSONDecoder().decode(PommeOwnerCredentialReference.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: PommeOwnerCredentialStoreError.invalidReference) {
            try PommeOwnerCredentialReference(vmUUID: identity.vmUUID, machineIdentifierSHA256: "bad", diskImageFileResourceID: "1:2")
        }
        #expect(throws: PommeOwnerCredentialStoreError.invalidReference) {
            try PommeOwnerCredentialReference(vmUUID: identity.vmUUID, machineIdentifierSHA256: identity.machineIdentifierSHA256,
                                             diskImageFileResourceID: "1:2", account: "other")
        }
        let uid = UUID()
        let bound = try reference.bindingGeneratedUID(uid)
        #expect(bound.generatedUID == uid)
        #expect(bound.ownershipMarker == reference.ownershipMarker)
        #expect(bound.service == reference.service)
        #expect(bound.matches(identity))
        #expect(try bound.bindingGeneratedUID(uid) == bound)
        #expect(throws: PommeOwnerCredentialStoreError.ownershipMismatch) { try bound.bindingGeneratedUID(UUID()) }
    }

    @Test("Read or create generates only on absence and resumes with the stored password")
    func readOrCreate() throws {
        let reference = try PommeOwnerCredentialReference(identity: CredentialFixture().identity, account: "pomme")
        let keychain = FakeOwnerKeychain()
        let store = PommeOwnerCredentialStore(keychain: keychain)
        let saved = try store.readOrCreate(reference: reference)
        let noGeneration = PommeOwnerCredentialStore(keychain: keychain, random: .init { _ in
            Issue.record("Existing credential must not generate entropy")
            return .failure(errSecIO)
        })
        #expect(try noGeneration.readOrCreate(reference: reference).password == saved.password)
        #expect(keychain.addCalls.count == 1)
        keychain.readResult = .found(passwordData: Data("secret".utf8), ownershipMarker: nil)
        #expect(throws: PommeOwnerCredentialStoreError.credentialCollision) { try noGeneration.readOrCreate(reference: reference) }
        keychain.readResult = .locked(status: errSecInteractionNotAllowed)
        #expect(throws: PommeOwnerCredentialStoreError.keychainLocked(status: errSecInteractionNotAllowed)) {
            try noGeneration.readOrCreate(reference: reference)
        }
    }

    @Test("Removal is exact, idempotent, and fails closed")
    func removal() throws {
        let reference = try PommeOwnerCredentialReference(identity: CredentialFixture().identity, account: "pomme")
        let keychain = FakeOwnerKeychain()
        let store = PommeOwnerCredentialStore(keychain: keychain)
        _ = try store.readOrCreate(reference: reference)
        try store.remove(reference: reference)
        try store.remove(reference: reference)
        #expect(keychain.removeCalls == 1)
        #expect(keychain.items.isEmpty)
        keychain.readResult = .locked(status: errSecInteractionNotAllowed)
        #expect(throws: PommeOwnerCredentialStoreError.keychainLocked(status: errSecInteractionNotAllowed)) { try store.remove(reference: reference) }
        keychain.readResult = .failed(status: errSecIO)
        #expect(throws: PommeOwnerCredentialStoreError.keychainReadFailed(status: errSecIO)) { try store.remove(reference: reference) }
        #expect(keychain.removeCalls == 1)
        keychain.readResult = .found(passwordData: Data("secret".utf8), ownershipMarker: nil)
        #expect(throws: PommeOwnerCredentialStoreError.credentialCollision) { try store.remove(reference: reference) }
        #expect(keychain.removeCalls == 1)
        keychain.readResult = .found(passwordData: Data("secret".utf8), ownershipMarker: Data(reference.ownershipMarker.utf8))
        keychain.removeResult = .locked(status: errSecInteractionNotAllowed)
        #expect(throws: PommeOwnerCredentialStoreError.keychainLocked(status: errSecInteractionNotAllowed)) { try store.remove(reference: reference) }
        keychain.removeResult = .failed(status: errSecIO)
        #expect(throws: PommeOwnerCredentialStoreError.keychainRemoveFailed(status: errSecIO)) { try store.remove(reference: reference) }
        keychain.removeResult = .missing
        keychain.readResults = [.found(passwordData: Data("secret".utf8), ownershipMarker: Data(reference.ownershipMarker.utf8)),
                                .found(passwordData: Data("collision-secret".utf8), ownershipMarker: nil)]
        #expect(throws: PommeOwnerCredentialStoreError.credentialCollision) { try store.remove(reference: reference) }
        #expect(!String(describing: PommeOwnerCredentialStoreError.keychainRemoveFailed(status: errSecIO)).contains("secret"))
        keychain.readResults = [.found(passwordData: Data("secret".utf8), ownershipMarker: Data(reference.ownershipMarker.utf8)), .missing]
        try store.remove(reference: reference)
    }

    @Test("A concurrent creator wins without replacement")
    func readOrCreateDuplicate() throws {
        let reference = try PommeOwnerCredentialReference(identity: CredentialFixture().identity, account: "pomme")
        let keychain = FakeOwnerKeychain()
        keychain.addResult = .duplicate
        keychain.readResults = [.missing, .missing,
            .found(passwordData: Data("winner-secret".utf8), ownershipMarker: Data(reference.ownershipMarker.utf8))]
        let store = PommeOwnerCredentialStore(keychain: keychain)
        #expect(try store.readOrCreate(reference: reference).password == "winner-secret")
        #expect(keychain.addCalls.count == 1)
        keychain.readResults = [.missing, .missing,
            .found(passwordData: Data("unrelated-secret".utf8), ownershipMarker: nil)]
        #expect(throws: PommeOwnerCredentialStoreError.credentialCollision) { try store.readOrCreate(reference: reference) }
    }
    @Test("Generates, stores, and reads an immutable identity-scoped credential")
    func generatedCredential() throws {
        let fixture = CredentialFixture()
        let keychain = FakeOwnerKeychain()
        let random = PommeOwnerCredentialRandomSource { count in
            .success(Data(repeating: 0x42, count: count))
        }
        let store = PommeOwnerCredentialStore(keychain: keychain, random: random)
        let intent = try store.prepare(
            identity: fixture.identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        let saved = try store.store(intent)
        #expect(saved.reference == intent.reference)
        #expect(saved.password == intent.password)
        #expect(keychain.addCalls.count == 1)
        #expect(try store.read(intent.reference).password == intent.password)
        #expect(intent.reference.ownershipMarker.contains(intent.password) == false)
        #expect(!String(describing: intent).contains(intent.password))
        #expect(!String(reflecting: saved).contains(saved.password))
        #expect(!String(decoding: try JSONEncoder().encode(intent.reference), as: UTF8.self).contains(intent.password))
    }

    @Test("A retry with the same reference reuses the stored password")
    func retryReusesStoredCredential() throws {
        let fixture = CredentialFixture()
        let keychain = FakeOwnerKeychain()
        let store = PommeOwnerCredentialStore(keychain: keychain)
        let reference = try PommeOwnerCredentialReference(
            identity: fixture.identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        let firstIntent = try PommeOwnerCredentialIntent(
            reference: reference,
            password: "first-generated-password"
        )
        let saved = try store.store(firstIntent)
        let retryIntent = try PommeOwnerCredentialIntent(
            reference: reference,
            password: "different-retry-candidate"
        )

        let retried = try store.store(retryIntent)

        #expect(retried.password == saved.password)
        #expect(retried.password == "first-generated-password")
        #expect(keychain.addCalls.count == 1)
    }

    @Test("Never replaces an existing unknown item in the exact scope")
    func collisionIsRejected() throws {
        let fixture = CredentialFixture()
        let keychain = FakeOwnerKeychain()
        let store = PommeOwnerCredentialStore(
            keychain: keychain,
            random: PommeOwnerCredentialRandomSource { _ in
                .success(Data(repeating: 0x10, count: 32))
            }
        )
        let intent = try store.prepare(
            identity: fixture.identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        keychain.items[intent.reference.service + "|" + intent.reference.account] = .init(
            passwordData: Data("unknown-secret".utf8),
            marker: Data("unrelated-owner".utf8)
        )
        #expect(throws: PommeOwnerCredentialStoreError.credentialCollision) {
            try store.store(intent)
        }
        #expect(keychain.addCalls.isEmpty)
        #expect(
            keychain.items[intent.reference.service + "|" + intent.reference.account]?
                .passwordData == Data("unknown-secret".utf8)
        )
    }

    @Test("Locked, missing-after-add, and duplicate reads fail closed")
    func partialAndLocked() throws {
        let fixture = CredentialFixture()
        let locked = FakeOwnerKeychain()
        locked.readResult = .locked(status: errSecInteractionNotAllowed)
        let lockedStore = PommeOwnerCredentialStore(keychain: locked)
        let reference = try PommeOwnerCredentialReference(
            identity: fixture.identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        let intent = try PommeOwnerCredentialIntent(reference: reference, password: "candidate-secret")
        #expect(throws: PommeOwnerCredentialStoreError.keychainLocked(status: errSecInteractionNotAllowed)) {
            try lockedStore.store(intent)
        }

        let partial = FakeOwnerKeychain()
        partial.addResult = .stored
        partial.readResults = [.missing, .missing]
        let partialStore = PommeOwnerCredentialStore(keychain: partial)
        #expect(throws: PommeOwnerCredentialStoreError.credentialMissingAfterStore) {
            try partialStore.store(intent)
        }

        let duplicate = FakeOwnerKeychain()
        duplicate.addResult = .duplicate
        duplicate.readResults = [
            .missing,
            .found(
                passwordData: Data("winner-secret".utf8),
                ownershipMarker: Data(reference.ownershipMarker.utf8)
            )
        ]
        let duplicateStore = PommeOwnerCredentialStore(keychain: duplicate)
        #expect(try duplicateStore.store(intent).password == "winner-secret")
    }

    @Test("Error descriptions and redacted references contain no password")
    func redaction() throws {
        let fixture = CredentialFixture()
        let keychain = FakeOwnerKeychain()
        keychain.readResult = .found(
            passwordData: Data("private-owner-password".utf8),
            ownershipMarker: Data("wrong".utf8)
        )
        let store = PommeOwnerCredentialStore(keychain: keychain)
        let reference = try PommeOwnerCredentialReference(
            identity: fixture.identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        let error: Error
        do {
            try store.read(reference)
            Issue.record("Expected a collision")
            return
        } catch let caught {
            error = caught
        }
        let description = String(describing: error)
        #expect(!description.contains("private-owner-password"))
        #expect(!description.contains(reference.account))
        #expect(!description.contains(reference.service))
    }

    @Test("Legacy owner read is exact service/account and read-only")
    func legacyOwnerRead() throws {
        let fixture = CredentialFixture()
        let keychain = FakeOwnerKeychain()
        let service = pommeCredentialService(forUUID: fixture.identity.vmUUID.uuidString)
        keychain.items[service + "|alice"] = .init(
            passwordData: Data("legacy-password".utf8),
            marker: nil
        )
        let store = PommeOwnerCredentialStore(keychain: keychain)
        #expect(try store.readExistingOwnerCredential(vmUUID: fixture.identity.vmUUID, account: "alice") == "legacy-password")
        #expect(keychain.addCalls.isEmpty)
    }
}

private struct CredentialFixture {
    let identity: PommeSecurityWorkflowIdentity
    let generatedUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    init() {
        identity = try! PommeSecurityWorkflowIdentity(
            vmName: "credential-fixture",
            vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            machineIdentifierSHA256: String(repeating: "a", count: 64),
            diskImageFileResourceID: "1:2",
            startupVolumeGroupUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            immutableProvisioningPlanDigest: String(repeating: "b", count: 64)
        )
    }
}

private final class FakeOwnerKeychain: PommeOwnerCredentialKeychainClient, @unchecked Sendable {
    struct Item {
        let passwordData: Data
        let marker: Data?
    }

    var items: [String: Item] = [:]
    var readResult: PommeOwnerCredentialKeychainRead?
    var readResults: [PommeOwnerCredentialKeychainRead] = []
    var addResult: PommeOwnerCredentialKeychainAdd?
    var addCalls: [(String, String, Data, Data)] = []
    var removeCalls = 0
    var removeResult: PommeOwnerCredentialKeychainRemove?

    func remove(service: String, account: String, ownershipMarker: Data) -> PommeOwnerCredentialKeychainRemove {
        removeCalls += 1
        if let removeResult { return removeResult }
        let key = service + "|" + account
        guard let item = items[key], item.marker == ownershipMarker else { return .missing }
        items.removeValue(forKey: key)
        return .removed
    }

    func read(service: String, account: String) -> PommeOwnerCredentialKeychainRead {
        if !readResults.isEmpty { return readResults.removeFirst() }
        if let readResult { return readResult }
        guard let item = items[service + "|" + account] else { return .missing }
        return .found(passwordData: item.passwordData, ownershipMarker: item.marker)
    }

    func add(
        service: String,
        account: String,
        passwordData: Data,
        ownershipMarker: Data
    ) -> PommeOwnerCredentialKeychainAdd {
        addCalls.append((service, account, passwordData, ownershipMarker))
        if let addResult { return addResult }
        let key = service + "|" + account
        guard items[key] == nil else { return .duplicate }
        items[key] = .init(passwordData: passwordData, marker: ownershipMarker)
        return .stored
    }
}
