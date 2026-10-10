import Foundation
import Security

/// Stores the persistent Pomme agent credential in one explicitly selected
/// file-based host Keychain.
///
/// The initializer is side-effect free. Each operation opens the configured
/// Keychain and requires it to be unlocked before issuing a scoped Keychain
/// query. Callers that need serialization should provide it, because the
/// store itself does not cross an actor or queue boundary.
struct PommeAgentCredentialStore {
    /// The Security calls used by the store. The narrow seam keeps race and
    /// denied-status behavior testable without changing production queries.
    struct SecItemOperations {
        let copyMatching: (
            _ query: [String: Any],
            _ result: UnsafeMutablePointer<CFTypeRef?>
        ) -> OSStatus
        let add: (_ query: [String: Any]) -> OSStatus
        let delete: (_ query: [String: Any]) -> OSStatus

        /// Uses the real Security.framework operations.
        static var live: Self {
            Self(
                copyMatching: { query, result in
                    SecItemCopyMatching(query as CFDictionary, result)
                },
                add: { query in
                    SecItemAdd(query as CFDictionary, nil)
                },
                delete: { query in
                    SecItemDelete(query as CFDictionary)
                }
            )
        }
    }

    /// Errors intentionally contain no service, account, path, or credential
    /// values. Security status codes remain available for diagnostics.
    enum Error: Swift.Error, Equatable, PommeDescribedError {
        case keychainOpenFailed(status: OSStatus)
        case keychainLocked(status: OSStatus)
        case credentialMissing(status: OSStatus)
        case malformedCredential
        case unexpectedCredentialData
        case credentialReadFailed(status: OSStatus)
        case credentialCreateFailed(status: OSStatus)
        case duplicateCredentialReadFailed(status: OSStatus)
        case credentialRemoveFailed(status: OSStatus)

        var code: PommeErrorCode {
            switch self {
            case .credentialMissing: .agentCredentialMissing
            case .malformedCredential, .unexpectedCredentialData: .agentCredentialInvalid
            case .keychainOpenFailed, .keychainLocked, .credentialReadFailed, .credentialCreateFailed,
                 .duplicateCredentialReadFailed, .credentialRemoveFailed:
                .keychainError
            }
        }

        var errorDescription: String? {
            switch self {
            case .keychainOpenFailed(let status):
                "Pomme couldn't open your login Keychain to use the VM's agent credential: \(Self.reason(status))."
            case .keychainLocked(let status):
                "Your login Keychain is locked, so Pomme can't use the VM's agent credential: \(Self.reason(status))."
            case .credentialMissing(let status):
                "The VM's agent credential isn't in your login Keychain: \(Self.reason(status))."
            case .malformedCredential:
                "The VM's agent credential in your login Keychain has an invalid format."
            case .unexpectedCredentialData:
                "The Keychain returned data of an unexpected type for the VM's agent credential."
            case .credentialReadFailed(let status):
                "Pomme couldn't read the VM's agent credential from your login Keychain: \(Self.reason(status))."
            case .credentialCreateFailed(let status):
                "Pomme couldn't save the VM's agent credential in your login Keychain: \(Self.reason(status))."
            case .duplicateCredentialReadFailed(let status):
                "Another Pomme process created the VM's agent credential at the same time, and Pomme couldn't read it: \(Self.reason(status))."
            case .credentialRemoveFailed(let status):
                "Pomme couldn't remove the VM's agent credential from your login Keychain: \(Self.reason(status))."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .keychainLocked, .keychainOpenFailed:
                "Unlock your login Keychain, then retry."
            case .credentialMissing:
                "Run `pomme agent repair NAME` to reinstall the VM's agent and its credential."
            case .malformedCredential, .unexpectedCredentialData:
                "Run `pomme agent repair NAME` to reinstall the VM's agent and its credential."
            case .credentialReadFailed, .credentialCreateFailed, .duplicateCredentialReadFailed, .credentialRemoveFailed:
                "Unlock your login Keychain, then retry. If macOS asks whether `pomme` can access an item, allow it."
            }
        }

        /// The Security framework's text for `status`, with its number.
        private static func reason(_ status: OSStatus) -> String {
            let message = securityErrorMessage(status)
            guard message != "OSStatus \(status)" else { return message }
            let trimmed = message.hasSuffix(".") ? String(message.dropLast()) : message
            return "\(SystemErrorDescription.lowercasingFirstWord(trimmed)) (OSStatus \(status))"
        }
    }

    private enum LookupResult {
        case found(String)
        case missing
    }

    private let keychainPath: String
    private let operations: SecItemOperations

    /// Creates a store targeting the user's login Keychain by default.
    init(keychainPath: String = defaultLoginKeychainPath()) {
        self.init(keychainPath: keychainPath, operations: .live)
    }

    /// Creates a store with bounded Security-operation injection for tests.
    init(keychainPath: String, operations: SecItemOperations) {
        self.keychainPath = keychainPath
        self.operations = operations
    }

    /// Reads the existing UUID-scoped persistent-agent credential.
    ///
    /// This method is strict: a missing item is reported as an error and does
    /// not generate or create a replacement credential.
    ///
    /// - Parameters:
    ///   - vmUUID: The immutable VM identity used in the service name.
    ///   - account: The Keychain account, passed through unchanged.
    /// - Returns: The normalized agent credential.
    /// - Throws: ``Error`` when the Keychain is unavailable, the item is
    ///   missing, or the stored bytes are malformed.
    func read(vmUUID: UUID, account: String) throws -> String {
        try withUnlockedKeychain { keychain in
            switch try lookup(vmUUID: vmUUID, account: account, keychain: keychain) {
            case .found(let credential):
                return credential
            case .missing:
                throw Error.credentialMissing(status: errSecItemNotFound)
            }
        }
    }

    /// Reads an existing credential or creates one exactly once when absent.
    ///
    /// The generator is called only after a scoped read returns
    /// ``errSecItemNotFound``. If another writer wins the add race, that
    /// credential is reread and returned; the generated candidate is never
    /// used to replace an existing item.
    ///
    /// - Parameters:
    ///   - vmUUID: The immutable VM identity used in the service name.
    ///   - account: The Keychain account, passed through unchanged.
    ///   - generate: Produces a candidate credential only after a missing read.
    /// - Returns: The normalized existing or newly created credential.
    /// - Throws: ``Error`` when the Keychain, generator, candidate, or item is
    ///   invalid or unavailable.
    func readOrCreate(
        vmUUID: UUID,
        account: String,
        generate: () throws -> String
    ) throws -> String {
        try withUnlockedKeychain { keychain in
            switch try lookup(vmUUID: vmUUID, account: account, keychain: keychain) {
            case .found(let credential):
                return credential
            case .missing:
                break
            }

            let candidate = try normalizedGeneratedCredential(try generate())
            var addQuery = hostKeychainQuery(
                service: pommeCredentialService(forUUID: vmUUID.uuidString),
                account: account,
                keychain: keychain
            )
            addQuery[kSecValueData as String] = Data(candidate.utf8)

            let addStatus = operations.add(addQuery)
            switch addStatus {
            case errSecSuccess:
                return candidate
            case errSecDuplicateItem:
                do {
                    switch try lookup(vmUUID: vmUUID, account: account, keychain: keychain) {
                    case .found(let credential):
                        return credential
                    case .missing:
                        throw Error.duplicateCredentialReadFailed(status: errSecItemNotFound)
                    }
                } catch let error as Error {
                    switch error {
                    case .credentialReadFailed(let status):
                        throw Error.duplicateCredentialReadFailed(status: status)
                    case .credentialMissing(let status):
                        throw Error.duplicateCredentialReadFailed(status: status)
                    default:
                        throw error
                    }
                }
            default:
                throw Error.credentialCreateFailed(status: addStatus)
            }
        }
    }

    /// Removes exactly one UUID-and-account scoped credential.
    ///
    /// Removing an already absent item succeeds, making cleanup idempotent.
    /// Locked or denied Keychain operations are surfaced and never retried by
    /// deleting or replacing another item.
    ///
    /// - Parameters:
    ///   - vmUUID: The immutable VM identity used in the service name.
    ///   - account: The Keychain account, passed through unchanged.
    /// - Throws: ``Error`` when the Keychain is unavailable or deletion fails.
    func remove(vmUUID: UUID, account: String) throws {
        try withUnlockedKeychain { keychain in
            let query = hostKeychainLookupQuery(
                service: pommeCredentialService(forUUID: vmUUID.uuidString),
                account: account,
                keychain: keychain
            )
            let status = operations.delete(query)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                return
            default:
                throw Error.credentialRemoveFailed(status: status)
            }
        }
    }

    private func withUnlockedKeychain<T>(
        _ body: (SecKeychain) throws -> T
    ) throws -> T {
        var keychain: SecKeychain?
        let openStatus = SecKeychainOpen(keychainPath, &keychain)
        guard openStatus == errSecSuccess, let keychain else {
            throw Error.keychainOpenFailed(status: openStatus)
        }

        guard try hostKeychainIsUnlocked(keychain) else {
            throw Error.keychainLocked(status: errSecInteractionNotAllowed)
        }
        return try body(keychain)
    }

    private func lookup(
        vmUUID: UUID,
        account: String,
        keychain: SecKeychain
    ) throws -> LookupResult {
        var query = hostKeychainLookupQuery(
            service: pommeCredentialService(forUUID: vmUUID.uuidString),
            account: account,
            keychain: keychain
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = operations.copyMatching(query, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw Error.unexpectedCredentialData
            }
            return .found(try normalizedStoredCredential(data))
        case errSecItemNotFound:
            return .missing
        default:
            throw Error.credentialReadFailed(status: status)
        }
    }

    private func normalizedStoredCredential(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw Error.malformedCredential
        }
        do {
            return try PommeAgentAuthentication.normalized(value)
        } catch {
            throw Error.malformedCredential
        }
    }

    private func normalizedGeneratedCredential(_ value: String) throws -> String {
        do {
            return try PommeAgentAuthentication.normalized(value)
        } catch {
            throw Error.malformedCredential
        }
    }
}
