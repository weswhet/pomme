import Foundation
import Security
import Testing

@Suite("Security owner credential store", .serialized)
struct PommeOwnerCredentialStoreTests {
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
