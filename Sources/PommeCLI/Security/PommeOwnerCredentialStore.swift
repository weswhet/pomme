import Foundation
import Security

/// A nonsecret, immutable pointer to one generated owner credential.
///
/// The password is deliberately absent.  The ownership marker is derived
/// from the VM identity and account fields and is stored as Keychain metadata
/// so a collision cannot silently replace or reuse an unrelated item.
struct PommeOwnerCredentialReference: Codable, Equatable, Hashable, Sendable {
    let vmUUID: UUID
    let machineIdentifierSHA256: String
    let diskImageFileResourceID: String
    let account: String
    let generatedUID: UUID?
    let service: String
    let ownershipMarker: String

    init(
        identity: PommeSecurityWorkflowIdentity,
        account: String,
        generatedUID: UUID? = nil
    ) throws {
        guard identity.isWellFormed(),
              Self.isSafeAccount(account)
        else { throw PommeOwnerCredentialStoreError.invalidReference }
        self.vmUUID = identity.vmUUID
        self.machineIdentifierSHA256 = identity.machineIdentifierSHA256
        self.diskImageFileResourceID = identity.diskImageFileResourceID
        self.account = account
        self.generatedUID = generatedUID
        self.service = pommeCredentialService(forUUID: identity.vmUUID.uuidString)
        self.ownershipMarker = Self.makeMarker(
            vmUUID: identity.vmUUID,
            machineIdentifierSHA256: identity.machineIdentifierSHA256,
            diskImageFileResourceID: identity.diskImageFileResourceID,
            account: account,
            generatedUID: generatedUID
        )
    }

    var username: String { account }

    func matches(_ identity: PommeSecurityWorkflowIdentity) -> Bool {
        vmUUID == identity.vmUUID
            && machineIdentifierSHA256 == identity.machineIdentifierSHA256
            && diskImageFileResourceID == identity.diskImageFileResourceID
            && service == pommeCredentialService(forUUID: identity.vmUUID.uuidString)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case vmUUID
        case machineIdentifierSHA256
        case diskImageFileResourceID
        case account
        case generatedUID
        case service
        case ownershipMarker
    }

    init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: AnyPommeOwnerCodingKey.self).allKeys
        guard Set(allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw PommeOwnerCredentialStoreError.invalidReference
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let vmUUID = try values.decode(UUID.self, forKey: .vmUUID)
        let machineHash = try values.decode(String.self, forKey: .machineIdentifierSHA256)
        let diskID = try values.decode(String.self, forKey: .diskImageFileResourceID)
        let account = try values.decode(String.self, forKey: .account)
        let generatedUID = try values.decodeIfPresent(UUID.self, forKey: .generatedUID)
        let service = try values.decode(String.self, forKey: .service)
        let marker = try values.decode(String.self, forKey: .ownershipMarker)
        guard Self.isSHA256(machineHash),
              Self.isSafeResourceID(diskID),
              Self.isSafeAccount(account),
              service == pommeCredentialService(forUUID: vmUUID.uuidString),
              marker == Self.makeMarker(
                  vmUUID: vmUUID,
                  machineIdentifierSHA256: machineHash,
                  diskImageFileResourceID: diskID,
                  account: account,
                  generatedUID: generatedUID
              )
        else { throw PommeOwnerCredentialStoreError.invalidReference }
        self.vmUUID = vmUUID
        self.machineIdentifierSHA256 = machineHash.lowercased()
        self.diskImageFileResourceID = diskID
        self.account = account
        self.generatedUID = generatedUID
        self.service = service
        self.ownershipMarker = marker
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(vmUUID, forKey: .vmUUID)
        try values.encode(machineIdentifierSHA256, forKey: .machineIdentifierSHA256)
        try values.encode(diskImageFileResourceID, forKey: .diskImageFileResourceID)
        try values.encode(account, forKey: .account)
        try values.encode(generatedUID, forKey: .generatedUID)
        try values.encode(service, forKey: .service)
        try values.encode(ownershipMarker, forKey: .ownershipMarker)
    }

    private static func makeMarker(
        vmUUID: UUID,
        machineIdentifierSHA256: String,
        diskImageFileResourceID: String,
        account: String,
        generatedUID: UUID?
    ) -> String {
        [
            "pomme-owner-v1",
            vmUUID.uuidString.lowercased(),
            machineIdentifierSHA256.lowercased(),
            diskImageFileResourceID,
            account
        ].joined(separator: "|")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isSafeResourceID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy {
                $0.value >= 0x21 && $0.value <= 0x7e && $0 != "/" && $0 != "\\"
            }
    }

    private static func isSafeAccount(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.range(of: "^[A-Za-z][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
}

/// An in-memory candidate.  It is intentionally not Codable or printable.
struct PommeOwnerCredentialIntent: Sendable {
    let reference: PommeOwnerCredentialReference
    fileprivate let passwordData: Data

    var account: String { reference.account }
    var generatedUID: UUID? { reference.generatedUID }
    var password: String {
        String(decoding: passwordData, as: UTF8.self)
    }

    init(reference: PommeOwnerCredentialReference, password: String) throws {
        let data = Data(password.utf8)
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
            throw PommeOwnerCredentialStoreError.invalidCredential
        }
        self.reference = reference
        self.passwordData = data
    }
}

struct PommeOwnerCredential: Sendable {
    let reference: PommeOwnerCredentialReference
    let password: String
}

enum PommeOwnerCredentialKeychainRead: Sendable {
    case found(passwordData: Data, ownershipMarker: Data?)
    case missing
    case locked(status: OSStatus)
    case failed(status: OSStatus)
}

enum PommeOwnerCredentialKeychainAdd: Sendable {
    case stored
    case duplicate
    case locked(status: OSStatus)
    case failed(status: OSStatus)
}

protocol PommeOwnerCredentialKeychainClient: Sendable {
    func read(service: String, account: String) -> PommeOwnerCredentialKeychainRead
    func add(
        service: String,
        account: String,
        passwordData: Data,
        ownershipMarker: Data
    ) -> PommeOwnerCredentialKeychainAdd
}

/// Strict file-login Keychain access.  Every operation opens the configured
/// file and checks its unlocked state before any query.  This type never calls
/// the repository's auto-unlock or TTY-prompt helpers.
struct PommeSystemOwnerCredentialKeychainClient: PommeOwnerCredentialKeychainClient {
    let keychainPath: String

    init(keychainPath: String = defaultLoginKeychainPath()) {
        self.keychainPath = keychainPath
    }

    func read(service: String, account: String) -> PommeOwnerCredentialKeychainRead {
        withUnlockedKeychain { keychain in
            var query = hostKeychainLookupQuery(
                service: service,
                account: account,
                keychain: keychain
            )
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let attributes = item as? [String: Any],
                      let passwordData = attributes[kSecValueData as String] as? Data
                else { return .failed(status: errSecDecode) }
                return .found(
                    passwordData: passwordData,
                    ownershipMarker: attributes[kSecAttrGeneric as String] as? Data
                )
            case errSecItemNotFound:
                return .missing
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                return .locked(status: status)
            default:
                return .failed(status: status)
            }
        }
    }

    func add(
        service: String,
        account: String,
        passwordData: Data,
        ownershipMarker: Data
    ) -> PommeOwnerCredentialKeychainAdd {
        withUnlockedKeychain { keychain in
            var query = hostKeychainQuery(
                service: service,
                account: account,
                keychain: keychain
            )
            query[kSecValueData as String] = passwordData
            query[kSecAttrGeneric as String] = ownershipMarker
            query[kSecAttrLabel as String] = "Pomme owner credential"
            let status = SecItemAdd(query as CFDictionary, nil)
            switch status {
            case errSecSuccess: return .stored
            case errSecDuplicateItem: return .duplicate
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                return .locked(status: status)
            default:
                return .failed(status: status)
            }
        }
    }

    private func withUnlockedKeychain(
        _ body: (SecKeychain) -> PommeOwnerCredentialKeychainRead
    ) -> PommeOwnerCredentialKeychainRead {
        var keychain: SecKeychain?
        let openStatus = SecKeychainOpen(keychainPath, &keychain)
        guard openStatus == errSecSuccess, let keychain else {
            return .failed(status: openStatus)
        }
        guard (try? hostKeychainIsUnlocked(keychain)) == true else {
            return .locked(status: errSecInteractionNotAllowed)
        }
        return body(keychain)
    }

    private func withUnlockedKeychain(
        _ body: (SecKeychain) -> PommeOwnerCredentialKeychainAdd
    ) -> PommeOwnerCredentialKeychainAdd {
        var keychain: SecKeychain?
        let openStatus = SecKeychainOpen(keychainPath, &keychain)
        guard openStatus == errSecSuccess, let keychain else {
            return .failed(status: openStatus)
        }
        guard (try? hostKeychainIsUnlocked(keychain)) == true else {
            return .locked(status: errSecInteractionNotAllowed)
        }
        return body(keychain)
    }
}

enum PommeOwnerCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidReference
    case invalidCredential
    case keychainOpenFailed(status: OSStatus)
    case keychainLocked(status: OSStatus)
    case keychainMissing
    case keychainReadFailed(status: OSStatus)
    case keychainCreateFailed(status: OSStatus)
    case keychainReadBackFailed(status: OSStatus)
    case credentialMissingAfterStore
    case credentialCollision
    case ownershipMismatch
    case malformedStoredCredential
    case secretGenerationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidReference: "Pomme owner credential reference is invalid."
        case .invalidCredential: "Pomme owner credential has an invalid format."
        case .keychainOpenFailed: "Pomme owner credential Keychain could not be opened."
        case .keychainLocked: "Pomme owner credential Keychain is locked."
        case .keychainMissing: "Pomme owner credential is missing."
        case .keychainReadFailed: "Pomme owner credential Keychain read failed."
        case .keychainCreateFailed: "Pomme owner credential Keychain creation failed."
        case .keychainReadBackFailed: "Pomme owner credential could not be read back after creation."
        case .credentialMissingAfterStore: "Pomme owner credential is missing after a successful account transaction."
        case .credentialCollision: "Pomme owner credential scope is occupied by an unrelated item."
        case .ownershipMismatch: "Pomme owner credential belongs to a different immutable VM identity."
        case .malformedStoredCredential: "Pomme owner credential has an invalid stored format."
        case .secretGenerationFailed: "Pomme owner credential could not be generated."
        }
    }
}

enum PommeOwnerCredentialRandomResult: Sendable {
    case success(Data)
    case failure(OSStatus)
}

struct PommeOwnerCredentialRandomSource: Sendable {
    let bytes: @Sendable (_ count: Int) -> PommeOwnerCredentialRandomResult

    static let live = Self { count in
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return status == errSecSuccess ? .success(data) : .failure(status)
    }
}

struct PommeOwnerCredentialStore: Sendable {
    private let keychain: PommeOwnerCredentialKeychainClient
    private let random: PommeOwnerCredentialRandomSource

    init(
        keychain: PommeOwnerCredentialKeychainClient = PommeSystemOwnerCredentialKeychainClient(),
        random: PommeOwnerCredentialRandomSource = .live
    ) {
        self.keychain = keychain
        self.random = random
    }

    init(
        keychainPath: String,
        random: PommeOwnerCredentialRandomSource = .live
    ) {
        self.init(
            keychain: PommeSystemOwnerCredentialKeychainClient(keychainPath: keychainPath),
            random: random
        )
    }

    func prepare(
        identity: PommeSecurityWorkflowIdentity,
        account: String,
        generatedUID: UUID? = nil
    ) throws -> PommeOwnerCredentialIntent {
        let reference = try PommeOwnerCredentialReference(
            identity: identity,
            account: account,
            generatedUID: generatedUID
        )
        let entropyResult = random.bytes(32)
        guard case .success(let entropy) = entropyResult else {
            if case .failure(let status) = entropyResult {
                throw PommeOwnerCredentialStoreError.secretGenerationFailed(status: status)
            }
            throw PommeOwnerCredentialStoreError.secretGenerationFailed(status: errSecIO)
        }
        let password = entropy.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try PommeOwnerCredentialIntent(reference: reference, password: password)
    }

    func store(_ intent: PommeOwnerCredentialIntent) throws -> PommeOwnerCredential {
        let reference = intent.reference
        let marker = Data(reference.ownershipMarker.utf8)
        switch keychain.read(service: reference.service, account: reference.account) {
        case .found(let passwordData, let storedMarker):
            return try resolveFound(
                reference: reference,
                passwordData: passwordData,
                storedMarker: storedMarker
            )
        case .missing:
            break
        case .locked(let status):
            throw PommeOwnerCredentialStoreError.keychainLocked(status: status)
        case .failed(let status):
            throw PommeOwnerCredentialStoreError.keychainReadFailed(status: status)
        }

        switch keychain.add(
            service: reference.service,
            account: reference.account,
            passwordData: intent.passwordData,
            ownershipMarker: marker
        ) {
        case .stored:
            return try readBack(reference: reference)
        case .duplicate:
            return try readBackAfterDuplicate(reference: reference)
        case .locked(let status):
            throw PommeOwnerCredentialStoreError.keychainLocked(status: status)
        case .failed(let status):
            throw PommeOwnerCredentialStoreError.keychainCreateFailed(status: status)
        }
    }

    func read(_ reference: PommeOwnerCredentialReference) throws -> PommeOwnerCredential {
        switch keychain.read(service: reference.service, account: reference.account) {
        case .found(let data, let marker):
            return try resolveFound(
                reference: reference,
                passwordData: data,
                storedMarker: marker
            )
        case .missing:
            throw PommeOwnerCredentialStoreError.keychainMissing
        case .locked(let status):
            throw PommeOwnerCredentialStoreError.keychainLocked(status: status)
        case .failed(let status):
            throw PommeOwnerCredentialStoreError.keychainReadFailed(status: status)
        }
    }

    func readExistingOwnerCredential(
        identity: PommeSecurityWorkflowIdentity,
        account: String
    ) throws -> String? {
        try readExistingOwnerCredential(vmUUID: identity.vmUUID, account: account)
    }

    func saveOwnerCredential(
        identity: PommeSecurityWorkflowIdentity,
        account: String,
        generatedUID: UUID? = nil,
        password: String
    ) throws -> PommeOwnerCredential {
        let reference = try PommeOwnerCredentialReference(
            identity: identity,
            account: account,
            generatedUID: generatedUID
        )
        return try store(try PommeOwnerCredentialIntent(reference: reference, password: password))
    }

    func save(
        identity: PommeSecurityWorkflowIdentity,
        account: String,
        generatedUID: UUID? = nil,
        password: String
    ) throws -> PommeOwnerCredential {
        try saveOwnerCredential(
            identity: identity,
            account: account,
            generatedUID: generatedUID,
            password: password
        )
    }

    /// Reads the pre-existing UUID/account owner item used by older Pomme
    /// versions.  It is read-only and deliberately does not assign ownership
    /// metadata or replace the item.
    func readExistingOwnerCredential(vmUUID: UUID, account: String) throws -> String? {
        let service = pommeCredentialService(forUUID: vmUUID.uuidString)
        switch keychain.read(service: service, account: account) {
        case .found(let data, _):
            guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw PommeOwnerCredentialStoreError.malformedStoredCredential
            }
            return password
        case .missing:
            return nil
        case .locked(let status):
            throw PommeOwnerCredentialStoreError.keychainLocked(status: status)
        case .failed(let status):
            throw PommeOwnerCredentialStoreError.keychainReadFailed(status: status)
        }
    }

    private func readBack(
        reference: PommeOwnerCredentialReference
    ) throws -> PommeOwnerCredential {
        switch keychain.read(service: reference.service, account: reference.account) {
        case .found(let data, let marker):
            return try resolveFound(
                reference: reference,
                passwordData: data,
                storedMarker: marker
            )
        case .missing:
            throw PommeOwnerCredentialStoreError.credentialMissingAfterStore
        case .locked(let status):
            throw PommeOwnerCredentialStoreError.keychainReadBackFailed(status: status)
        case .failed(let status):
            throw PommeOwnerCredentialStoreError.keychainReadBackFailed(status: status)
        }
    }

    private func readBackAfterDuplicate(
        reference: PommeOwnerCredentialReference
    ) throws -> PommeOwnerCredential {
        do {
            return try readBack(reference: reference)
        } catch PommeOwnerCredentialStoreError.credentialMissingAfterStore {
            throw PommeOwnerCredentialStoreError.credentialMissingAfterStore
        } catch PommeOwnerCredentialStoreError.keychainReadBackFailed(let status) {
            throw PommeOwnerCredentialStoreError.keychainReadBackFailed(status: status)
        } catch {
            throw error
        }
    }

    private func resolveFound(
        reference: PommeOwnerCredentialReference,
        passwordData: Data,
        storedMarker: Data?
    ) throws -> PommeOwnerCredential {
        guard storedMarker == Data(reference.ownershipMarker.utf8) else {
            throw PommeOwnerCredentialStoreError.credentialCollision
        }
        guard let password = String(data: passwordData, encoding: .utf8), !password.isEmpty else {
            throw PommeOwnerCredentialStoreError.malformedStoredCredential
        }
        return PommeOwnerCredential(reference: reference, password: password)
    }
}

private struct AnyPommeOwnerCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
