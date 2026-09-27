import Darwin
import Foundation

/// Closed failures for owner-credential recovery. Each case is a fixed
/// diagnostic; none carries guest text, the artifact's bytes, or the password.
enum PommeGuestOwnerCredentialError: Error, Equatable, LocalizedError, Sendable, CaseIterable {
    case rootRequired
    case invalidPayload
    case autoLoginUnavailable
    case accountMismatch
    case artifactMissing
    case artifactUnsafe
    case credentialUnreadable

    /// Stable, allowlisted wire code. Safe for a host log or a closed
    /// diagnostic field because it is derived from the case alone.
    var code: String {
        switch self {
        case .rootRequired: "owner-credential-root-required"
        case .invalidPayload: "owner-credential-invalid-payload"
        case .autoLoginUnavailable: "owner-credential-autologin-unavailable"
        case .accountMismatch: "owner-credential-account-mismatch"
        case .artifactMissing: "owner-credential-artifact-missing"
        case .artifactUnsafe: "owner-credential-artifact-unsafe"
        case .credentialUnreadable: "owner-credential-unreadable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .rootRequired:
            "Owner credential recovery requires the root persistent agent."
        case .invalidPayload:
            "The owner credential request payload was rejected."
        case .autoLoginUnavailable:
            "No automatic-login account is configured in this guest."
        case .accountMismatch:
            "The requested account is not this guest's automatic-login account."
        case .artifactMissing:
            "This guest has no automatic-login credential artifact."
        case .artifactUnsafe:
            "The automatic-login credential artifact is not the exact root-owned file macOS writes."
        case .credentialUnreadable:
            "The automatic-login credential artifact could not be decoded."
        }
    }
}

/// Exact metadata of the automatic-login artifact. Contents are deliberately
/// absent so a caller can prove the file is safe before anything reads it.
struct PommeGuestOwnerCredentialArtifact: Equatable, Sendable {
    let isRegularFile: Bool
    let userID: UInt32
    let groupID: UInt32
    let mode: UInt16
    let linkCount: UInt16

    /// macOS writes `/etc/kcpassword` as a root-owned regular file readable
    /// only by root. Both modes Apple has been observed to use are accepted;
    /// any group or other permission bit, symlink, or extra hard link makes
    /// the artifact untrusted and the recovery fails closed.
    var isSafe: Bool {
        isRegularFile
            && userID == 0
            && groupID == 0
            && linkCount == 1
            && (mode == 0o600 || mode == 0o400)
    }

    static func read(at path: String) -> Self? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return .init(
            isRegularFile: info.st_mode & S_IFMT == S_IFREG,
            userID: info.st_uid,
            groupID: info.st_gid,
            mode: UInt16(info.st_mode & 0o7777),
            linkCount: UInt16(truncatingIfNeeded: info.st_nlink)
        )
    }
}

/// Recovers the automatic-login password Pomme itself configured for a VM's
/// owner account, by reading that guest's own `/etc/kcpassword`.
///
/// A VM cloned from a provisioned template carries the owner account but no
/// host Keychain item, because that item is scoped to the UUID of the VM the
/// template was captured from. Resetting the password instead would discard
/// the account's Secure Token, so the host asks its root agent to recover the
/// credential already in place and then proves it by the ordinary owner
/// verification before trusting it.
///
/// This is deliberately not a general secret reader. It returns exactly one
/// value: the password of the account macOS is configured to log in
/// automatically, and only when the artifact is the exact root-owned file
/// macOS writes. The host still has to prove that account is an
/// administrator with a Secure Token and APFS ownership before the credential
/// is worth anything.
struct PommeGuestOwnerCredentialReader: Sendable {
    typealias ProcessRunner = @Sendable (String, [String]) throws -> (status: Int32, stdout: Data)
    typealias ArtifactReader = @Sendable (String) -> PommeGuestOwnerCredentialArtifact?
    typealias BytesReader = @Sendable (String) throws -> Data

    /// Version of this recovery contract. The host preflights it through the
    /// opt-in describe receipt so an older pinned agent fails explicitly
    /// rather than looking like a guest with no owner.
    static let version = 1
    static let operation = "owner.credential.read"
    static let artifactPath = "/etc/kcpassword"
    /// A configured password is short; anything larger is not the artifact
    /// macOS writes and is refused before it is decoded.
    static let maximumArtifactBytes = 4 * 1024

    private let effectiveUserID: @Sendable () -> uid_t
    private let runProcess: ProcessRunner
    private let readArtifact: ArtifactReader
    private let readBytes: BytesReader

    init(
        effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
        runProcess: @escaping ProcessRunner = PommeGuestOwnerCredentialReader.runDefaults,
        readArtifact: @escaping ArtifactReader = { PommeGuestOwnerCredentialArtifact.read(at: $0) },
        readBytes: @escaping BytesReader = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) {
        self.effectiveUserID = effectiveUserID
        self.runProcess = runProcess
        self.readArtifact = readArtifact
        self.readBytes = readBytes
    }

    /// The response carries the password, so it is returned only over the
    /// authenticated agent session and is never logged by this type.
    func read(payload: JSONValue) throws -> JSONValue {
        guard effectiveUserID() == 0 else {
            throw PommeGuestOwnerCredentialError.rootRequired
        }
        let requestedAccount = try Self.requestedAccount(from: payload)
        let account = try autoLoginAccount()
        if let requestedAccount, requestedAccount != account {
            throw PommeGuestOwnerCredentialError.accountMismatch
        }
        let password = try recoverPassword()
        return .object([
            "operation": .string(Self.operation),
            "account": .string(account),
            "password": .string(password),
            "verified": .bool(true)
        ])
    }

    /// An absent `account` asks the guest which account it logs in
    /// automatically, which is what a freshly cloned template needs. A present
    /// one binds the request to the account the host already expects.
    static func requestedAccount(from payload: JSONValue) throws -> String? {
        guard let object = payload.objectValue else {
            throw PommeGuestOwnerCredentialError.invalidPayload
        }
        if object.isEmpty { return nil }
        guard Set(object.keys) == ["account"],
              let account = object["account"]?.stringValue,
              isSafeAccount(account)
        else { throw PommeGuestOwnerCredentialError.invalidPayload }
        return account
    }

    /// Account names are restricted to the shape macOS local records use, so
    /// a request can never smuggle a path or argument through this field.
    static func isSafeAccount(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 64
            && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private func autoLoginAccount() throws -> String {
        let result: (status: Int32, stdout: Data)
        do {
            result = try runProcess(
                "/usr/bin/defaults",
                ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"]
            )
        } catch {
            throw PommeGuestOwnerCredentialError.autoLoginUnavailable
        }
        guard result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8)
        else { throw PommeGuestOwnerCredentialError.autoLoginUnavailable }
        let account = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeAccount(account) else {
            throw PommeGuestOwnerCredentialError.autoLoginUnavailable
        }
        return account
    }

    private func recoverPassword() throws -> String {
        guard let artifact = readArtifact(Self.artifactPath) else {
            throw PommeGuestOwnerCredentialError.artifactMissing
        }
        guard artifact.isSafe else {
            throw PommeGuestOwnerCredentialError.artifactUnsafe
        }
        let data: Data
        do { data = try readBytes(Self.artifactPath) }
        catch { throw PommeGuestOwnerCredentialError.credentialUnreadable }
        guard !data.isEmpty, data.count <= Self.maximumArtifactBytes else {
            throw PommeGuestOwnerCredentialError.credentialUnreadable
        }
        guard let password = kcpasswordString(from: data), !password.isEmpty else {
            throw PommeGuestOwnerCredentialError.credentialUnreadable
        }
        return password
    }

    private static func runDefaults(
        _ executable: String, _ arguments: [String]
    ) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
