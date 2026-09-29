import CryptoKit
import Darwin
import Foundation
import ObjectiveC.runtime
import Security

/// Closed diagnostic vocabulary: values can never contain profile material or native error text.
enum GuestMDMDiagnostics {
    enum Stage: String, CaseIterable, Sendable {
        case helperValidation, profileValidation, profileRead, profileIdentity, installedProfileObservation
        case serverTrustProbe, serverTrustEvaluation, certificatePayloadSelection, trustProfileInstall, trustProfileVerification
        case profilesCommand, profilesParse, frameworkLoad, profileDictionary, profileInitialization
        case identityPayload, interactionPolicy, privateKeychainOpen, privateKeychainStatus, privateKeychainUnlock, privateKeychainCredential, privateKeychainFallback
        case systemKeychainOpen, systemKeychainStatus, certificateSnapshot, keySnapshot
        case pkcs12Import, certificateReference, legacyCertificateReference, privateKeyReference
        case identityAttachment, secureArchive, legacyArchive, xpcSetup, xpcInstall, installedProfileVerification, xpcApproval

        var precedesIdentityImport: Bool {
            switch self {
            case .helperValidation, .profileValidation, .profileRead, .profileIdentity,
                 .installedProfileObservation, .serverTrustProbe, .serverTrustEvaluation,
                 .certificatePayloadSelection, .trustProfileInstall, .trustProfileVerification,
                 .profilesCommand, .profilesParse,
                 .frameworkLoad, .profileDictionary, .profileInitialization,
                 .identityPayload, .interactionPolicy, .privateKeychainOpen,
                 .privateKeychainStatus, .privateKeychainUnlock, .privateKeychainCredential, .privateKeychainFallback, .systemKeychainOpen, .systemKeychainStatus,
                 .certificateSnapshot, .keySnapshot:
                true
            case .pkcs12Import, .certificateReference, .legacyCertificateReference,
                 .privateKeyReference, .identityAttachment, .secureArchive, .legacyArchive,
                 .xpcSetup, .xpcInstall, .installedProfileVerification, .xpcApproval:
                false
            }
        }
    }
    enum Event: String { case begin, result, succeeded, failed }
    @TaskLocal static var current: Collector?

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [JSONValue] = []
        private var lastStage: Stage?
        private var importAttempted = false
        private let started = DispatchTime.now().uptimeNanoseconds
        func record(_ stage: Stage, status: Int64? = nil, flags: Int64? = nil, event: Event? = nil, credentialError: PommeGuestOwnerCredentialError? = nil) {
            lock.lock(); defer { lock.unlock() }
            lastStage = stage
            if stage == .pkcs12Import { importAttempted = true }
            guard records.count < 128 else { return }
            var value: [String: JSONValue] = [
                "stage": .string(stage.rawValue),
                "event": .string((event ?? (status == nil ? .begin : .result)).rawValue),
                "elapsedMillis": .integer(Int64(min((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000, UInt64(UInt32.max))))
            ]
            if let status { value["status"] = .integer(status) }
            if let flags { value["flags"] = .integer(flags) }
            if let credentialError { value["credentialError"] = .string(credentialError.code) }
            records.append(.object(value))
        }
        var value: JSONValue {
            lock.lock(); defer { lock.unlock() }
            return .array(records)
        }
        var identityImportAttempted: Bool {
            lock.lock(); defer { lock.unlock() }
            return importAttempted
        }
        var failureStage: String? {
            lock.lock(); defer { lock.unlock() }
            return lastStage?.rawValue
        }
    }

    static func record(_ stage: Stage, status: Int64? = nil, flags: Int64? = nil) {
        current?.record(stage, status: status, flags: flags)
    }

    static func validated(from value: JSONValue) throws -> JSONValue? {
        guard let object = value.objectValue else { throw PommeMDMEnrollmentError.enrollmentFailed }
        return try validated(from: object)
    }

    /// Validate guest-provided diagnostics before rendering any of them on the host.
    static func validated(from object: [String: JSONValue]) throws -> JSONValue? {
        if let attempted = object["identityImportAttempted"] {
            guard case .bool = attempted, object["diagnostics"] != nil else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
        }
        if let stage = object["failureStage"] {
            guard let raw = stage.stringValue, Stage(rawValue: raw) != nil,
                  object["completed"] == .bool(false), object["diagnostics"] != nil else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
        }
        guard let value = object["diagnostics"] else { return nil }
        guard case .array(let records) = value, records.count <= 128 else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        for record in records {
            guard let fields = record.objectValue,
                  Set(fields.keys).isSubset(of: ["stage", "event", "elapsedMillis", "status", "flags", "credentialError"]),
                  let raw = fields["stage"]?.stringValue, Stage(rawValue: raw) != nil else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
            guard let event = fields["event"]?.stringValue, Event(rawValue: event) != nil,
                  case .integer(let elapsed)? = fields["elapsedMillis"], elapsed >= 0, elapsed <= Int64(UInt32.max) else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
            if let code = fields["credentialError"] {
                guard raw == Stage.privateKeychainCredential.rawValue,
                      let code = code.stringValue,
                      PommeGuestOwnerCredentialError.allCases.contains(where: { $0.code == code }) else {
                    throw PommeMDMEnrollmentError.enrollmentFailed
                }
            }
            for key in ["status", "flags"] {
                if let number = fields[key] {
                    guard case .integer(let integer) = number,
                          integer >= Int64(Int32.min), integer <= Int64(UInt32.max) else {
                        throw PommeMDMEnrollmentError.enrollmentFailed
                    }
                }
            }
        }
        if object["identityImportAttempted"] == .bool(false),
           records.contains(where: { $0.objectValue?["stage"] == .string(Stage.pkcs12Import.rawValue) }) {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        if let stage = object["failureStage"], records.last?.objectValue?["stage"] != stage {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        return value
    }
}

enum GuestInternalError: LocalizedError {
    case mdm(String)
    case timedOut
    case mdmOutcomeUnknown

    var errorDescription: String? {
        switch self {
        case .mdm(let message): message
        case .timedOut: "The guest MDM operation timed out."
        case .mdmOutcomeUnknown: "The MDM enrollment outcome is unknown; identity state was retained. Verify installed-profile state before retrying."
        }
    }
}

struct GuestOperationExecution {
    let exitCode: Int32
    let payload: [String: Any]
}

/// Errors for the private MDM staging boundary deliberately contain no
/// pathname, profile bytes, or filesystem diagnostics. The persistent agent
/// turns these into its redacted protocol error envelope.
enum GuestMDMStagingError: Error, LocalizedError, Equatable {
    case rootRequired
    case invalidRoot
    case invalidProfile
    case unsafeRoot
    case unsafeProfile
    case cleanupFailed
    case wheelGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .rootRequired: "MDM staging requires the root agent."
        case .invalidRoot: "The MDM staging root is invalid."
        case .invalidProfile: "The staged MDM profile path is invalid."
        case .unsafeRoot: "The MDM staging root is not owned and protected as required."
        case .unsafeProfile: "The staged MDM profile is not a private regular file."
        case .cleanupFailed: "The staged MDM profile could not be removed and verified."
        case .wheelGroupUnavailable: "The required MDM staging group is unavailable."
        }
    }
}

/// Root-owned filesystem operations for the one fixed guest MDM directory.
/// The overloads accepting a root URL and identities are internal test seams;
/// the dispatcher-facing methods below always use the exact Pomme path and
/// root:wheel policy.
enum GuestMDMStaging {
    static let directory = GuestMDMEnrollment.stagingDirectory

    static func prepare() throws -> JSONValue {
        guard geteuid() == 0 else { throw GuestMDMStagingError.rootRequired }
        return try prepare(
            at: URL(fileURLWithPath: directory, isDirectory: true),
            effectiveOwner: 0,
            expectedOwner: 0,
            expectedGroup: try wheelGroupID()
        )
    }

    static func cleanup(profilePath: String) throws -> JSONValue {
        guard geteuid() == 0 else { throw GuestMDMStagingError.rootRequired }
        return try cleanup(
            profilePath: profilePath,
            rootURL: URL(fileURLWithPath: directory, isDirectory: true),
            effectiveOwner: 0,
            expectedOwner: 0,
            expectedGroup: try wheelGroupID()
        )
    }

    static func prepare(
        at rootURL: URL,
        effectiveOwner: uid_t,
        expectedOwner: uid_t,
        expectedGroup: gid_t
    ) throws -> JSONValue {
        guard effectiveOwner == expectedOwner else { throw GuestMDMStagingError.rootRequired }
        let (parentFD, name) = try openVerifiedParent(
            of: rootURL,
            expectedOwner: expectedOwner,
            expectedGroup: expectedGroup
        )
        defer { _ = Darwin.close(parentFD) }

        var created = false
        var rootFD = Darwin.openat(
            parentFD,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if rootFD < 0 {
            guard errno == ENOENT else { throw GuestMDMStagingError.unsafeRoot }
            if mkdirat(parentFD, name, mode_t(0o700)) == 0 {
                created = true
            } else {
                guard errno == EEXIST else { throw GuestMDMStagingError.unsafeRoot }
            }
            rootFD = Darwin.openat(
                parentFD,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard rootFD >= 0 else { throw GuestMDMStagingError.unsafeRoot }
        }
        defer { _ = Darwin.close(rootFD) }

        var info = stat()
        guard fstat(rootFD, &info) == 0 else { throw GuestMDMStagingError.unsafeRoot }
        if created {
            guard fchmod(rootFD, mode_t(0o700)) == 0,
                  fchown(rootFD, expectedOwner, expectedGroup) == 0,
                  fstat(rootFD, &info) == 0 else {
                throw GuestMDMStagingError.unsafeRoot
            }
        }
        guard validRoot(info, owner: expectedOwner, group: expectedGroup),
              fsync(rootFD) == 0 else {
            throw GuestMDMStagingError.unsafeRoot
        }
        if created {
            guard fsync(parentFD) == 0 else { throw GuestMDMStagingError.unsafeRoot }
        }
        return .object(["ready": .bool(true)])
    }

    static func cleanup(
        profilePath: String,
        rootURL: URL,
        effectiveOwner: uid_t,
        expectedOwner: uid_t,
        expectedGroup: gid_t
    ) throws -> JSONValue {
        guard effectiveOwner == expectedOwner else { throw GuestMDMStagingError.rootRequired }
        let profile = try validatedProfilePath(profilePath, rootURL: rootURL)
        let (parentFD, name) = try openVerifiedParent(
            of: rootURL,
            expectedOwner: expectedOwner,
            expectedGroup: expectedGroup
        )
        defer { _ = Darwin.close(parentFD) }

        let rootFD = Darwin.openat(
            parentFD,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if rootFD < 0, errno == ENOENT {
            // The fixed root is already absent, which is a verified absence
            // for this exact profile and is safe to report as idempotent
            // cleanup.
            return .object(["removed": .bool(true)])
        }
        guard rootFD >= 0 else { throw GuestMDMStagingError.unsafeRoot }
        defer { _ = Darwin.close(rootFD) }

        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              validRoot(rootInfo, owner: expectedOwner, group: expectedGroup) else {
            throw GuestMDMStagingError.unsafeRoot
        }

        var profileInfo = stat()
        guard fstatat(rootFD, profile.lastPathComponent, &profileInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                guard fsync(rootFD) == 0 else { throw GuestMDMStagingError.cleanupFailed }
                return .object(["removed": .bool(true)])
            }
            throw GuestMDMStagingError.unsafeProfile
        }
        guard profileInfo.st_mode & S_IFMT == S_IFREG,
              profileInfo.st_uid == expectedOwner,
              profileInfo.st_gid == expectedGroup,
              profileInfo.st_mode & 0o7777 == 0o600,
              profileInfo.st_nlink == 1,
              unlinkat(rootFD, profile.lastPathComponent, 0) == 0,
              fsync(rootFD) == 0 else {
            throw GuestMDMStagingError.unsafeProfile
        }

        var absent = stat()
        guard fstatat(rootFD, profile.lastPathComponent, &absent, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw GuestMDMStagingError.cleanupFailed
        }
        return .object(["removed": .bool(true)])
    }

    private static func wheelGroupID() throws -> gid_t {
        guard let record = getgrnam("wheel") else {
            throw GuestMDMStagingError.wheelGroupUnavailable
        }
        return record.pointee.gr_gid
    }

    private static func openVerifiedParent(
        of rootURL: URL,
        expectedOwner: uid_t,
        expectedGroup: gid_t
    ) throws -> (descriptor: Int32, name: String) {
        let root = rootURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              PommeMDMStagingHelper.isCanonicalPath(root.path),
              !root.path.contains("\0"),
              let name = root.path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init),
              name == root.lastPathComponent,
              !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw GuestMDMStagingError.invalidRoot
        }
        let parent = root.deletingLastPathComponent()
        let descriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw GuestMDMStagingError.unsafeRoot }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == expectedOwner,
              info.st_gid == expectedGroup,
              info.st_mode & 0o022 == 0 else {
            _ = Darwin.close(descriptor)
            throw GuestMDMStagingError.unsafeRoot
        }
        return (descriptor, name)
    }

    private static func validRoot(_ info: stat, owner: uid_t, group: gid_t) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == owner
            && info.st_gid == group
            && info.st_mode & 0o7777 == 0o700
            && info.st_nlink >= 2
    }

    private static func validatedProfilePath(_ path: String, rootURL: URL) throws -> URL {
        guard path.utf8.count <= 1_024,
              path.hasPrefix("/"),
              !path.contains("\0") else {
            throw GuestMDMStagingError.invalidProfile
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.dropFirst().contains(""), !components.contains("."), !components.contains("..") else {
            throw GuestMDMStagingError.invalidProfile
        }
        let root = rootURL
        let profile = URL(fileURLWithPath: path)
        guard profile.path == path,
              profile.deletingLastPathComponent().path == root.path,
              !profile.lastPathComponent.isEmpty,
              profile.lastPathComponent != ".",
              profile.lastPathComponent != ".." else {
            throw GuestMDMStagingError.invalidProfile
        }
        return profile
    }
}

/// The closed, persistent-agent-only wire operation. Surplus fields are
/// rejected so credentials and profile bodies cannot be forwarded as generic
/// operation data or later appear in diagnostics.
enum PersistentMDMEnrollmentOperation: Equatable {
    case enroll(profilePath: String, timeout: TimeInterval)
    case approve(profileIdentifier: String, timeout: TimeInterval)

    init(payload: JSONValue) throws {
        guard let values = payload.objectValue,
              let action = values["action"]?.stringValue,
              let timeout = Self.timeout(values["timeout"])
        else {
            throw PommeAgentOperationError.invalid
        }

        switch action {
        case "enroll":
            guard Set(values.keys) == ["action", "profilePath", "timeout"],
                  let path = values["profilePath"]?.stringValue,
                  GuestMDMEnrollment.isStagedProfilePath(path) else {
                throw PommeAgentOperationError.invalid
            }
            self = .enroll(profilePath: path, timeout: timeout)
        case "approve":
            guard Set(values.keys) == ["action", "profileIdentifier", "timeout"],
                  let identifier = values["profileIdentifier"]?.stringValue,
                  Self.isProfileIdentifier(identifier) else {
                throw PommeAgentOperationError.invalid
            }
            self = .approve(profileIdentifier: identifier, timeout: timeout)
        default:
            throw PommeAgentOperationError.invalid
        }
    }

    /// Results exclude profile bytes, paths, credentials, raw private-XPC
    /// replies, and OSStatus diagnostics. Errors are reduced to one message
    /// before they can cross the persistent-agent boundary.
    func execute() throws -> JSONValue {
        do {
            switch self {
            case let .enroll(profilePath, timeout):
                let execution = try GuestMDMEnrollment(requestTimeout: timeout).enroll(profilePath: profilePath)
                let identifier = execution.payload["profileIdentifier"] as? String ?? ""
                return .object([
                    "completed": .bool(execution.exitCode == 0),
                    "profileIdentifier": .string(identifier)
                ])
            case let .approve(profileIdentifier, timeout):
                let execution = try GuestMDMEnrollment(requestTimeout: timeout)
                    .markUserApproved(profileIdentifier: profileIdentifier)
                return .object(["completed": .bool(execution.exitCode == 0)])
            }
        } catch {
            throw PersistentMDMEnrollmentError.failed
        }
    }

    private static func timeout(_ value: JSONValue?) -> TimeInterval? {
        let seconds: Double
        switch value {
        case let .integer(value): seconds = Double(value)
        case let .number(value): seconds = value
        default: return nil
        }
        guard seconds.isFinite, seconds >= 1, seconds <= 300 else { return nil }
        return seconds
    }

    private static func isProfileIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.contains("\0")
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }
}

private enum PersistentMDMEnrollmentError: LocalizedError {
    case failed

    var errorDescription: String? { "The MDM operation could not be completed." }
}

@objc private protocol PommeMDMPrivateProtocol {
    func privateRequest(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
}

struct GuestMDMIdentityKeychainOperations<Handle> {
    let open: (String) -> (OSStatus, Handle?)
    let status: (Handle) -> (OSStatus, SecKeychainStatus)
    var unlockPrivate: (Handle) throws -> OSStatus = { _ in errSecAuthFailed }
}

enum GuestMDMIdentityKeychain {
    static let privatePath = "/private/var/db/ConfigurationProfiles/Store/MCXPrivate.keychain"
    static let systemPath = "/Library/Keychains/System.keychain"

    static func select<Handle>(operations: GuestMDMIdentityKeychainOperations<Handle>) throws -> Handle {
        GuestMDMDiagnostics.record(.privateKeychainOpen)
        var (result, handle) = operations.open(privatePath)
        GuestMDMDiagnostics.record(.privateKeychainOpen, status: Int64(result))
        var systemSelected = false
        var observedStatus: (OSStatus, SecKeychainStatus)?
        if result == errSecSuccess, let privateHandle = handle {
            GuestMDMDiagnostics.record(.privateKeychainStatus)
            let observation = operations.status(privateHandle)
            observedStatus = observation
            GuestMDMDiagnostics.record(.privateKeychainStatus, status: Int64(observation.0), flags: Int64(observation.1))
        }
        // SecKeychainOpen may return a reference to a missing keychain on
        // Sequoia; absence is then reported by SecKeychainGetStatus.
        if result == errSecNoSuchKeychain || observedStatus?.0 == errSecNoSuchKeychain {
            GuestMDMDiagnostics.record(.systemKeychainOpen)
            (result, handle) = operations.open(systemPath)
            GuestMDMDiagnostics.record(.systemKeychainOpen, status: Int64(result))
            systemSelected = true
            observedStatus = nil
        }
        guard result == errSecSuccess, var handle else {
            throw GuestInternalError.mdm("Could not open the guest MDM identity keychain.")
        }
        var (statusResult, status) = observedStatus ?? operations.status(handle)
        if !systemSelected, statusResult == errSecSuccess, status & kSecUnlockStateStatus == 0 {
            GuestMDMDiagnostics.record(.privateKeychainUnlock)
            let unlockResult = try operations.unlockPrivate(handle)
            GuestMDMDiagnostics.record(.privateKeychainUnlock, status: Int64(unlockResult))
            if unlockResult == errSecAuthFailed, status & kSecReadPermStatus != 0 {
                // Choose an explicit system store before importing anything. A user's
                // autologin password need not unlock the managed private store.
                GuestMDMDiagnostics.record(.privateKeychainFallback, status: Int64(unlockResult))
                GuestMDMDiagnostics.record(.systemKeychainOpen)
                let (systemResult, systemHandle) = operations.open(systemPath)
                GuestMDMDiagnostics.record(.systemKeychainOpen, status: Int64(systemResult))
                guard systemResult == errSecSuccess, let systemHandle else {
                    throw GuestInternalError.mdm("Could not open the guest System identity keychain.")
                }
                handle = systemHandle
                systemSelected = true
            } else if unlockResult != errSecSuccess {
                throw GuestInternalError.mdm("Could not unlock the guest MDM identity keychain.")
            }
            (statusResult, status) = operations.status(handle)
        }
        GuestMDMDiagnostics.record(systemSelected ? .systemKeychainStatus : .privateKeychainStatus, status: Int64(statusResult), flags: Int64(status))
        guard statusResult == errSecSuccess,
              (systemSelected ? status & kSecReadPermStatus != 0
                              : status & kSecUnlockStateStatus != 0) else {
            throw GuestInternalError.mdm("The guest MDM identity keychain is locked or unavailable.")
        }
        // The System keychain can report readable but locked until securityd
        // services an operation. Noninteractive SecPKCS12Import remains the
        // authority for access; never guess a password or change its ACL.

        return handle
    }

    static func unlockWithGuestPassword(
        readPassword: () throws -> String,
        unlock: (Data) -> OSStatus
    ) throws -> OSStatus {
        GuestMDMDiagnostics.record(.privateKeychainCredential)
        var bytes: Data
        do {
            let password = try readPassword()
            guard !password.isEmpty else {
                throw GuestInternalError.mdm("The guest unlock credential is unavailable.")
            }
            bytes = Data(password.utf8)
        } catch {
            GuestMDMDiagnostics.current?.record(.privateKeychainCredential, event: .failed,
                credentialError: (error as? PommeGuestOwnerCredentialError) ?? .credentialUnreadable)
            throw GuestInternalError.mdm("The guest unlock credential is unavailable.")
        }
        GuestMDMDiagnostics.record(.privateKeychainCredential, status: 0)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        GuestMDMDiagnostics.record(.privateKeychainUnlock)
        return unlock(bytes)
    }

    static func openSelectedKeychain() throws -> SecKeychain {
        try select(operations: .init(
            open: { path in
                var handle: SecKeychain?
                return (SecKeychainOpen(path, &handle), handle)
            },
            status: { handle in
                var status: SecKeychainStatus = 0
                return (SecKeychainGetStatus(handle, &status), status)
            },
            unlockPrivate: { handle in
                // Read only this guest's validated autologin credential. Keep it in
                // this process; never put it in argv, diagnostics, or a host response.
                try unlockWithGuestPassword(readPassword: {
                    let credential = try PommeGuestOwnerCredentialReader().read(payload: .object([:]))
                    guard let password = credential.objectValue?["password"]?.stringValue else {
                        throw GuestInternalError.mdm("The guest unlock credential is unavailable.")
                    }
                    return password
                }, unlock: { bytes in
                    bytes.withUnsafeBytes { buffer in
                        SecKeychainUnlock(handle, UInt32(buffer.count), buffer.baseAddress, true)
                    }
                })
            }
        ))
    }
}

enum GuestMDMCertificateInclusion: Equatable, Sendable {
    case omitted
    case included
}

extension MDMServerTrustDecision {
    /// Closed numeric code for helper diagnostics.
    var diagnosticStatus: Int64 {
        switch self {
        case .publicTrust: 0
        case .profileRootTrust: 1
        case .untrusted: 2
        case .unreachable: 3
        case .notApplicable: 4
        }
    }
}

struct GuestMDMEnrollment {
    static let stagingDirectory = "/private/var/db/pomme-mdm-enrollment"
    var requestTimeout: TimeInterval = 60
    var request: ([String: Any], TimeInterval) throws -> [String: Any] = GuestMDMEnrollment.privateRequest
    var profileArchiveOverride: Data?
    /// Test-only source identity for an archive override. Real staged
    /// profiles are parsed from their bytes before any native side effect.
    var profileIdentityOverride: MDMEnrollmentProfileIdentity?
    /// A bounded, structured installed-profile observation. The production
    /// default invokes `profiles show -output stdout-xml`; tests inject a
    /// parser-backed result and never invoke native commands.
    var installedProfileObservation: ((MDMEnrollmentProfileIdentity, TimeInterval) throws -> MDMInstalledProfileIdentity?)?
    /// Test-only proof that identity import was not reached on a conflict.
    var identityImportObserver: (() -> Void)?
    /// Decides how this guest can trust the profile's MDM server. The
    /// production default probes each endpoint with the guest's own trust.
    var serverTrust: (MDMProfileTrustMaterial) -> MDMServerTrustReport = {
        MDMServerTrustPreflight.runBlocking($0, defaultAnchors: .platformDefault)
    }

    private struct ObservationContext {
        let expected: MDMEnrollmentProfileIdentity
        let sourceData: Data?
        let observe: () throws -> MDMInstalledProfileIdentity?
    }

    init(
        requestTimeout: TimeInterval = 60,
        request: @escaping ([String: Any], TimeInterval) throws -> [String: Any] = GuestMDMEnrollment.privateRequest,
        profileArchiveOverride: Data? = nil,
        profileIdentityOverride: MDMEnrollmentProfileIdentity? = nil,
        installedProfileObservation: ((MDMEnrollmentProfileIdentity, TimeInterval) throws -> MDMInstalledProfileIdentity?)? = nil,
        identityImportObserver: (() -> Void)? = nil,
        serverTrust: ((MDMProfileTrustMaterial) -> MDMServerTrustReport)? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.request = request
        self.profileArchiveOverride = profileArchiveOverride
        self.profileIdentityOverride = profileIdentityOverride
        self.installedProfileObservation = installedProfileObservation
        self.identityImportObserver = identityImportObserver
        if let serverTrust { self.serverTrust = serverTrust }
    }

    /// Dispatcher-facing typed operations. The persistent PommeAgent owns the
    /// authenticated call boundary; these methods expose only redacted proof
    /// and never profile contents or arbitrary filesystem paths.
    static func prepareStagingDirectory() throws -> JSONValue {
        try GuestMDMStaging.prepare()
    }

    static func cleanupStagedProfile(profilePath: String) throws -> JSONValue {
        try GuestMDMStaging.cleanup(profilePath: profilePath)
    }

    func enroll(
        profilePath: String,
        mode: MDMEnrollmentMode = .unapproved
    ) throws -> GuestOperationExecution {
        GuestMDMDiagnostics.record(.profileValidation)
        let validatedProfile = try Self.validatedStagedProfile(
            profilePath,
            requireRegularFile: profileArchiveOverride == nil
        )

        // This probe must precede archive construction and identity import. A
        // conflicting installed identity therefore cannot cause either an XPC
        // request or a new keychain identity to be created.
        GuestMDMDiagnostics.record(.profileIdentity)
        let observationContext = try makeObservationContext(profileURL: validatedProfile)
        GuestMDMDiagnostics.record(.installedProfileObservation)
        if let observationContext,
           let installed = try observationContext.observe() {
            guard installed.matches(observationContext.expected) else {
                throw GuestInternalError.mdm("The installed MDM profile does not match the requested profile.")
            }
            var payload: [String: Any] = [
                "reused": true,
                "profileIdentifier": installed.identifier
            ]
            if case .supervised = mode {
                do {
                    let approval = try markUserApproved(profileIdentifier: installed.identifier)
                    payload.merge(approval.payload) { current, _ in current }
                } catch {
                    // A dispatched approval with no trustworthy reply is an
                    // unknown outcome. Never turn that into a reinstall.
                    throw GuestInternalError.mdmOutcomeUnknown
                }
            }
            return GuestOperationExecution(exitCode: 0, payload: payload)
        }

        let archive: Data
        let expectedProfileIdentifier: String?
        if let profileArchiveOverride {
            archive = profileArchiveOverride
            expectedProfileIdentifier = observationContext?.expected.identifier
        } else {
            let sourceData = try observationContext?.sourceData
                ?? Data(contentsOf: URL(fileURLWithPath: validatedProfile.path))
            if try certificateInclusion(profileData: sourceData) == .included {
                try installTrustProfile(profileData: sourceData)
            }
            let built = try buildProfileArchiveWithIdentity(
                profilePath: validatedProfile.path,
                profileData: sourceData
            )
            archive = built.archive
            expectedProfileIdentifier = built.profileIdentifier
        }
        // Once dispatched, a lost reply cannot prove absence of enrollment
        // effects. Preserve the identity referenced by the profile on every
        // ambiguous outcome, and require verification before another attempt.
        do {
            GuestMDMDiagnostics.record(.xpcSetup)
            let setupReply = try request([
                "Command": "InstallMDMv1Profile",
                "CommandDesc": "pomme mdm private-xpc setup",
                "MDMProfileArchive": archive,
                "UpdatingEnrollment": false
            ], requestTimeout)
            GuestMDMDiagnostics.record(.xpcSetup, status: Self.replySuccess(setupReply) ? 0 : 1)
            guard Self.replySuccess(setupReply),
                  let response = setupReply["Response"] as? [String: Any],
                  let updatedArchive = response["UpdatedMDMProfileArchive"] as? Data,
                  !updatedArchive.isEmpty else {
                throw GuestInternalError.mdmOutcomeUnknown
            }
            GuestMDMDiagnostics.record(.xpcInstall)
            let installReply = try request([
                "Command": "InstallProfile",
                "CommandDesc": "pomme mdm private-xpc install",
                "ProfileArchive": updatedArchive
            ], requestTimeout)
            GuestMDMDiagnostics.record(.xpcInstall, status: Self.replySuccess(installReply) ? 0 : 1)
            guard Self.replySuccess(installReply) else { throw GuestInternalError.mdmOutcomeUnknown }
            let installResponse = installReply["Response"] as? [String: Any]
            let identifier = (installResponse?["ProfileIdentifier"] ?? installResponse?["profileIdentifier"]) as? String ?? ""
            guard !identifier.isEmpty,
                  identifier.utf8.count <= 255,
                  !identifier.contains("\0"),
                  identifier.trimmingCharacters(in: .whitespacesAndNewlines) == identifier,
                  expectedProfileIdentifier == nil || expectedProfileIdentifier == identifier else {
                // A successful install reply for a different profile is a
                // conflict. Never mark that unexpected profile user-intended.
                throw GuestInternalError.mdmOutcomeUnknown
            }
            var payload: [String: Any] = [
                "setupSuccess": true,
                "installSuccess": true,
                "setupArchiveBytes": archive.count,
                "updatedArchiveBytes": updatedArchive.count,
                "profileIdentifier": identifier
            ]
            if let perUser = (installResponse?["ServerSupportsPerUserConnections"] as? NSNumber)?.boolValue {
                payload["serverSupportsPerUserConnections"] = perUser
            }
            if case .supervised = mode {
                if let observationContext {
                    GuestMDMDiagnostics.record(.installedProfileVerification)
                    guard let installed = try observationContext.observe(),
                          installed.matches(observationContext.expected),
                          installed.identifier == identifier else {
                        // Installation already happened, so the state is no
                        // longer safe to classify as a clean failure.
                        throw GuestInternalError.mdmOutcomeUnknown
                    }
                }
                let approval = try markUserApproved(profileIdentifier: identifier)
                payload.merge(approval.payload) { current, _ in current }
            }
            return GuestOperationExecution(exitCode: 0, payload: payload)
        } catch {
            throw GuestInternalError.mdmOutcomeUnknown
        }
    }

    static func isStagedProfilePath(_ path: String) -> Bool {
        (try? validatedStagedProfile(path, requireRegularFile: false)) != nil
    }

    private static func validatedStagedProfile(
        _ path: String,
        requireRegularFile: Bool
    ) throws -> URL {
        guard path.utf8.count <= 1_024, !path.contains("\0"), path.hasPrefix("/") else {
            throw GuestInternalError.mdm("The MDM profile path is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.dropFirst().contains(""), !components.contains("."), !components.contains("..") else {
            throw GuestInternalError.mdm("The MDM profile path is invalid.")
        }
        let profile = URL(fileURLWithPath: path)
        let root = URL(fileURLWithPath: stagingDirectory)
        guard profile.path == path,
              profile.deletingLastPathComponent().path == root.path,
              profile.lastPathComponent != ".",
              profile.lastPathComponent != ".." else {
            throw GuestInternalError.mdm("The MDM profile path is outside the private staging directory.")
        }
        guard requireRegularFile else { return profile }

        var info = stat()
        guard lstat(profile.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0 else {
            throw GuestInternalError.mdm("The staged MDM profile is unavailable.")
        }
        return profile
    }

    private func makeObservationContext(profileURL: URL) throws -> ObservationContext? {
        let expected: MDMEnrollmentProfileIdentity
        let sourceData: Data?

        if let profileIdentityOverride, profileArchiveOverride != nil {
            expected = profileIdentityOverride
            sourceData = nil
        } else if profileArchiveOverride == nil {
            let data: Data
            do {
                GuestMDMDiagnostics.record(.profileRead)
                data = try Data(contentsOf: profileURL, options: [.mappedIfSafe])
            } catch {
                throw GuestInternalError.mdm("The staged MDM profile is unavailable.")
            }
            guard data.count <= GuestMDMObservation.defaultMaximumOutputBytes else {
                throw GuestInternalError.mdm("The staged MDM profile is too large.")
            }
            do {
                GuestMDMDiagnostics.record(.profileIdentity)
                expected = try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: data)
            } catch {
                throw GuestInternalError.mdm("The staged MDM profile identity is invalid.")
            }
            sourceData = data
        } else {
            // Preserve the legacy archive-override seam: callers that do not
            // provide a source identity explicitly do not invoke a native
            // command against their synthetic archive bytes.
            return nil
        }

        let observer = installedProfileObservation ?? GuestMDMObservation.liveInstalledProfileIdentity
        let timeout = requestTimeout
        return ObservationContext(
            expected: expected,
            sourceData: sourceData,
            observe: { try observer(expected, timeout) }
        )
    }

    /// Marks an already-installed device MDM profile as user-intended through
    /// the same private daemon request used by the Profiles System Settings
    /// approval action. The caller must make the synthetic nature of this
    /// operation explicit; this method does not represent human consent.
    func markUserApproved(profileIdentifier: String) throws -> GuestOperationExecution {
        let identifier = profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw GuestInternalError.mdm("A profile identifier is required to mark MDM enrollment as user approved.")
        }
        GuestMDMDiagnostics.record(.xpcApproval)
        let reply = try request([
            "Command": "FlagAsUserIntended",
            "CommandDesc": "pomme mdm synthetic user-intent approval",
            "ProfileIdentifier": identifier
        ], requestTimeout)
        GuestMDMDiagnostics.record(.xpcApproval, status: Self.replySuccess(reply) ? 0 : 1)
        guard Self.replySuccess(reply) else {
            throw GuestInternalError.mdm(Self.replyError(reply))
        }
        return GuestOperationExecution(
            exitCode: 0,
            payload: [
                "profileIdentifier": identifier,
                "approvalCommand": "FlagAsUserIntended",
                "technicalUserApproval": true
            ]
        )
    }

    /// Whether the profile's certificate payloads must be installed before
    /// enrollment: only when the guest cannot already trust the server and
    /// the profile's own roots can. Otherwise enrollment stops here, before
    /// any identity import or daemon request, so a retry remains safe.
    func certificateInclusion(profileData: Data) throws -> GuestMDMCertificateInclusion {
        GuestMDMDiagnostics.record(.serverTrustProbe)
        let material: MDMProfileTrustMaterial
        do { material = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profileData) }
        catch { throw GuestInternalError.mdm("The enrollment profile's server or certificate payloads are invalid.") }
        let report = serverTrust(material)
        GuestMDMDiagnostics.record(.serverTrustEvaluation, status: report.decision.diagnosticStatus)
        let inclusion: GuestMDMCertificateInclusion
        switch report.decision {
        case .publicTrust, .notApplicable:
            inclusion = .omitted
        case .profileRootTrust:
            inclusion = .included
        case .untrusted:
            throw GuestInternalError.mdm("The guest cannot trust the MDM server with its own or the profile's certificates.")
        case .unreachable:
            throw GuestInternalError.mdm("The guest could not complete a TLS handshake with the MDM server.")
        }
        GuestMDMDiagnostics.record(.certificatePayloadSelection, status: inclusion == .included ? 1 : 0)
        return inclusion
    }

    /// The daemon does not install certificate payloads carried inside an
    /// MDM enrollment archive before its first check-in, so they go first in
    /// a separate Pomme configuration profile with a deterministic identity.
    /// Reinstalling it replaces the same profile. This runs before identity
    /// import, and the server must then pass the guest's own trust check.
    func installTrustProfile(profileData: Data) throws {
        GuestMDMDiagnostics.record(.trustProfileInstall)
        guard let source = try? PropertyListSerialization.propertyList(from: profileData, format: nil) as? [String: Any],
              let dictionary = Self.trustProfileDictionary(from: source) else {
            throw GuestInternalError.mdm("The enrollment profile's certificate payloads are invalid.")
        }
        guard dlopen("/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/Versions/A/ConfigurationProfiles",
                     RTLD_LAZY) != nil, let profileClass = NSClassFromString("CPProfile") else {
            throw GuestInternalError.mdm("ConfigurationProfiles.framework is unavailable.")
        }
        let profile = try Self.makeProfile(profileClass: profileClass, dictionary: dictionary as NSDictionary)
        let archive: Data
        do { archive = try NSKeyedArchiver.archivedData(withRootObject: profile, requiringSecureCoding: true) }
        catch { archive = try NSKeyedArchiver.archivedData(withRootObject: profile, requiringSecureCoding: false) }
        let reply = try request([
            "Command": "InstallProfile",
            "CommandDesc": "pomme mdm server trust profile",
            "ProfileArchive": archive
        ], requestTimeout)
        GuestMDMDiagnostics.record(.trustProfileInstall, status: Self.replySuccess(reply) ? 0 : 1)
        guard Self.replySuccess(reply) else {
            throw GuestInternalError.mdm("The MDM server trust profile was not installed.")
        }
        GuestMDMDiagnostics.record(.trustProfileVerification)
        var decision = MDMServerTrustDecision.untrusted
        // Trust settings from the new profile reach trustd asynchronously.
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            let material = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profileData)
            decision = serverTrust(material).decision
            if decision == .publicTrust || decision == .notApplicable { break }
        }
        GuestMDMDiagnostics.record(.trustProfileVerification, status: decision.diagnosticStatus)
        guard decision == .publicTrust || decision == .notApplicable else {
            throw GuestInternalError.mdm("The guest still cannot trust the MDM server after installing the profile's certificates.")
        }
    }

    static let trustProfilePrefix = "com.github.weswhet.pomme.mdm-trust."

    /// Only the source's certificate payloads, under an identifier and UUID
    /// derived from the source profile's UUID. Identity (PKCS#12), MDM, and
    /// all other payloads are never included.
    static func trustProfileDictionary(from source: [String: Any]) -> [String: Any]? {
        guard let sourceUUID = (source["PayloadUUID"] as? String).flatMap(UUID.init(uuidString:)),
              let payloads = source["PayloadContent"] as? [[String: Any]] else { return nil }
        let certificates = payloads.filter {
            ($0["PayloadType"] as? String).map(MDMProfileTrustMaterial.certificatePayloadTypes.contains) == true
        }
        guard !certificates.isEmpty else { return nil }
        let source = sourceUUID.uuidString.lowercased()
        return [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": trustProfilePrefix + source,
            "PayloadUUID": derivedUUID("pomme-mdm-trust:" + source).uuidString,
            "PayloadDisplayName": "Pomme MDM server trust",
            "PayloadScope": "System",
            "PayloadContent": certificates,
        ]
    }

    private static func derivedUUID(_ name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func buildProfileArchiveWithIdentity(profilePath: String, profileData: Data? = nil) throws -> (
        archive: Data,
        importedIdentity: ImportedMDMIdentity,
        profileIdentifier: String
    ) {
        GuestMDMDiagnostics.record(.frameworkLoad)
        guard dlopen(
            "/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/Versions/A/ConfigurationProfiles",
            RTLD_LAZY
        ) != nil else {
            throw GuestInternalError.mdm("ConfigurationProfiles.framework is unavailable.")
        }
        let sourceData: Data
        if let profileData {
            sourceData = profileData
        } else {
            sourceData = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        }
        GuestMDMDiagnostics.record(.profileDictionary)
        guard let dictionary = try PropertyListSerialization.propertyList(from: sourceData, options: [], format: nil) as? [String: Any] else {
            throw GuestInternalError.mdm("Enrollment profile is not a property-list dictionary.")
        }
        guard let profileIdentifier = dictionary["PayloadIdentifier"] as? String,
              !profileIdentifier.isEmpty,
              profileIdentifier.utf8.count <= 255,
              !profileIdentifier.contains("\0"),
              profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) == profileIdentifier else {
            throw GuestInternalError.mdm("Enrollment profile identifier is invalid.")
        }
        var mdmOnly = dictionary
        let payloads = dictionary["PayloadContent"] as? [[String: Any]] ?? []
        let mdmPayloads = payloads.filter { $0["PayloadType"] as? String == "com.apple.mdm" }
        guard mdmPayloads.count == 1 else { throw GuestInternalError.mdm("Enrollment profile must contain exactly one com.apple.mdm payload.") }
        mdmOnly["PayloadContent"] = mdmPayloads

        guard let profileClass = NSClassFromString("CPProfile") else {
            throw GuestInternalError.mdm("CPProfile is unavailable.")
        }
        GuestMDMDiagnostics.record(.profileInitialization)
        let profile = try Self.makeProfile(profileClass: profileClass, dictionary: mdmOnly as NSDictionary)
        let importedIdentity = try importIdentityCertificate(profileDictionary: dictionary, mdmPayload: mdmPayloads[0])
        do {
            GuestMDMDiagnostics.record(.identityAttachment)
            try Self.attachKeychainItems(
                profile: profile,
                mdmPayload: mdmPayloads[0],
                persistentReference: importedIdentity.persistentReference
            )
            let archive: Data
            do {
                GuestMDMDiagnostics.record(.secureArchive)
                archive = try NSKeyedArchiver.archivedData(withRootObject: profile, requiringSecureCoding: true)
            } catch {
                GuestMDMDiagnostics.record(.legacyArchive)
                archive = try NSKeyedArchiver.archivedData(withRootObject: profile, requiringSecureCoding: false)
            }
            return (archive, importedIdentity, profileIdentifier)
        } catch {
            // Preserve imported identity state so a failed attempt can be inspected.
            throw error
        }
    }

    private func importIdentityCertificate(profileDictionary: [String: Any], mdmPayload: [String: Any]) throws -> ImportedMDMIdentity {
        identityImportObserver?()
        GuestMDMDiagnostics.record(.identityPayload)
        guard let identityUUID = mdmPayload["IdentityCertificateUUID"] as? String,
              let pkcs12 = (profileDictionary["PayloadContent"] as? [[String: Any]])?.first(where: {
                  $0["PayloadType"] as? String == "com.apple.security.pkcs12" && $0["PayloadUUID"] as? String == identityUUID
              }),
              let pkcs12Data = pkcs12["PayloadContent"] as? Data else {
            throw GuestInternalError.mdm("The MDM identity PKCS#12 payload is missing.")
        }
        let password = pkcs12["Password"] as? String ?? ""
        GuestMDMDiagnostics.record(.interactionPolicy)
        var previousInteraction: DarwinBoolean = false
        let interactionRead = SecKeychainGetUserInteractionAllowed(&previousInteraction)
        GuestMDMDiagnostics.record(.interactionPolicy, status: Int64(interactionRead), flags: previousInteraction.boolValue ? 1 : 0)
        guard interactionRead == errSecSuccess else {
            throw GuestInternalError.mdm("Could not establish noninteractive MDM identity access.")
        }
        let interactionWrite = SecKeychainSetUserInteractionAllowed(false)
        GuestMDMDiagnostics.record(.interactionPolicy, status: Int64(interactionWrite))
        guard interactionWrite == errSecSuccess else {
            throw GuestInternalError.mdm("Could not establish noninteractive MDM identity access.")
        }
        defer { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
        let keychain = try GuestMDMIdentityKeychain.openSelectedKeychain()
        let before = try ImportedMDMIdentity.snapshot(in: keychain)

        var imported: CFArray?
        let options: [CFString: Any] = [
            kSecImportExportPassphrase: password,
            kSecImportExportKeychain: keychain
        ]
        GuestMDMDiagnostics.record(.pkcs12Import)
        var status = SecPKCS12Import(pkcs12Data as CFData, options as CFDictionary, &imported)
        GuestMDMDiagnostics.record(.pkcs12Import, status: Int64(status))
        guard status == errSecSuccess,
              let items = imported as? [[CFString: Any]],
              let identity = items.compactMap({ $0[kSecImportItemIdentity] as! SecIdentity? }).first else {
            throw GuestInternalError.mdmOutcomeUnknown
        }
        var certificate: SecCertificate?
        GuestMDMDiagnostics.record(.certificateReference)
        status = SecIdentityCopyCertificate(identity, &certificate)
        GuestMDMDiagnostics.record(.certificateReference, status: Int64(status))
        guard status == errSecSuccess, let certificate else {
            throw GuestInternalError.mdmOutcomeUnknown
        }
        var result: CFTypeRef?
        var query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecReturnPersistentRef: true
        ]
        query[kSecMatchSearchList] = [keychain]
        status = SecItemCopyMatching(query as CFDictionary, &result)
        GuestMDMDiagnostics.record(.certificateReference, status: Int64(status))
        let persistentReference: Data
        if status == errSecSuccess, let data = result as? Data {
            persistentReference = data
        } else {
            var legacyReference: CFData?
            GuestMDMDiagnostics.record(.legacyCertificateReference)
            status = SecKeychainItemCreatePersistentReference(unsafeBitCast(certificate, to: SecKeychainItem.self), &legacyReference)
            GuestMDMDiagnostics.record(.legacyCertificateReference, status: Int64(status))
            guard status == errSecSuccess, let legacyReference else {
                throw GuestInternalError.mdmOutcomeUnknown
            }
            persistentReference = legacyReference as Data
        }
        return try ImportedMDMIdentity(identity: identity, certificateReference: persistentReference, before: before, keychain: keychain)
    }

    private static func makeProfile(profileClass: AnyClass, dictionary: NSDictionary) throws -> AnyObject {
        let selector = NSSelectorFromString("initWithConfigurationProfileDictionary:error:")
        guard let allocated = class_createInstance(profileClass, 0) as AnyObject?,
              let method = class_getInstanceMethod(profileClass, selector) else {
            throw GuestInternalError.mdm("Could not allocate CPProfile.")
        }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSDictionary, UnsafeMutableRawPointer?
        ) -> AnyObject?
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        var error: Unmanaged<CFError>?
        let result = withUnsafeMutablePointer(to: &error) { errorPointer in
            function(
                allocated,
                selector,
                dictionary,
                UnsafeMutableRawPointer(errorPointer)
            )
        }
        if let nativeError = error?.takeUnretainedValue() {
            GuestMDMDiagnostics.record(.profileInitialization, status: Int64(Int32(clamping: CFErrorGetCode(nativeError))))
        }
        guard let result else {
            throw GuestInternalError.mdm("CPProfile initialization failed.")
        }
        GuestMDMDiagnostics.record(.profileInitialization, status: 0)
        return result
    }

    private static func attachKeychainItems(
        profile: AnyObject,
        mdmPayload: [String: Any],
        persistentReference: Data
    ) throws {
        let selector = NSSelectorFromString("setUserData:forKey:")
        guard let identityUUID = mdmPayload["IdentityCertificateUUID"] as? String,
              let profileClass = object_getClass(profile),
              let method = class_getInstanceMethod(profileClass, selector) else {
            throw GuestInternalError.mdm("Could not attach MDM identity keychain data.")
        }
        let items = [identityUUID: [["Kind": "IdentityCertificate", "PersistRef": persistentReference]]] as NSDictionary
        let key = "KeychainItems" as NSString
        typealias Function = @convention(c) (AnyObject, Selector, NSDictionary, NSString) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(
            profile,
            selector,
            items,
            key
        )
    }

    private static func privateRequest(_ request: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let connection = NSXPCConnection(machServiceName: "com.apple.mdmclient.daemon", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PommeMDMPrivateProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let result = XPCResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.set(error: error.localizedDescription)
            semaphore.signal()
        }) as? PommeMDMPrivateProtocol else {
            throw GuestInternalError.mdm("Could not create the MDM daemon XPC proxy.")
        }
        proxy.privateRequest(request as NSDictionary) { reply in
            result.set(reply: reply as? [String: Any] ?? [:])
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw GuestInternalError.timedOut
        }
        if let error = result.error { throw GuestInternalError.mdm(error) }
        guard let reply = result.reply else { throw GuestInternalError.mdm("The MDM daemon returned no reply.") }
        return reply
    }

    private static func replySuccess(_ reply: [String: Any]) -> Bool {
        (reply["__Success__"] as? NSNumber)?.boolValue == true
    }

    private static func replyError(_ reply: [String: Any]) -> String {
        if let error = reply["Error"] { return String(describing: error) }
        if let chain = reply["ErrorChain"] { return String(describing: chain) }
        if let response = reply["Response"] as? [String: Any] {
            if let error = response["Error"] { return String(describing: error) }
            if let status = response["ResponseStatus"] { return String(describing: status) }
        }
        return String(describing: reply)
    }
}

/// Tracks only the certificate/key persistent references that did not exist
/// before this enrollment attempt. Existing MDM identities are never touched.
private struct ImportedMDMIdentity {
    let persistentReference: Data
    private let newItems: [(CFString, Data)]
    private let keychain: SecKeychain?

    static func snapshot(in keychain: SecKeychain?) throws -> Set<Data> {
        var references = Set<Data>()
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            var query: [CFString: Any] = [
                kSecClass: itemClass,
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitAll
            ]
            if let keychain { query[kSecMatchSearchList] = [keychain] }
            var result: CFTypeRef?
            let stage: GuestMDMDiagnostics.Stage = itemClass == kSecClassCertificate ? .certificateSnapshot : .keySnapshot
            GuestMDMDiagnostics.record(stage)
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            GuestMDMDiagnostics.record(stage, status: Int64(status))
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let values = result as? [Data] else {
                throw GuestInternalError.mdm("Could not establish the existing MDM identity baseline.")
            }
            references.formUnion(values)
        }
        return references
    }

    init(identity: SecIdentity, certificateReference: Data, before: Set<Data>, keychain: SecKeychain?) throws {
        var newItems: [(CFString, Data)] = []
        if !before.contains(certificateReference) {
            newItems.append((kSecClassCertificate, certificateReference))
        }
        var privateKey: SecKey?
        GuestMDMDiagnostics.record(.privateKeyReference)
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        GuestMDMDiagnostics.record(.privateKeyReference, status: Int64(keyStatus))
        guard keyStatus == errSecSuccess, let privateKey,
              let reference = Self.persistentReference(for: privateKey, itemClass: kSecClassKey, keychain: keychain) else {
            throw GuestInternalError.mdmOutcomeUnknown
        }
        if !before.contains(reference) {
            newItems.append((kSecClassKey, reference))
        }
        self.persistentReference = certificateReference
        self.newItems = newItems
        self.keychain = keychain
    }

    func removeOnlyNewItems() throws {
        for (itemClass, reference) in newItems {
            var query: [CFString: Any] = [
                kSecClass: itemClass,
                kSecValuePersistentRef: reference
            ]
            if let keychain { query[kSecMatchSearchList] = [keychain] }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw GuestInternalError.mdm("Could not remove the newly imported MDM identity (OSStatus \(status)).")
            }
        }
    }

    private static func persistentReference(
        for item: CFTypeRef,
        itemClass: CFString,
        keychain: SecKeychain?
    ) -> Data? {
        var query: [CFString: Any] = [
            kSecClass: itemClass,
            kSecValueRef: item,
            kSecReturnPersistentRef: true
        ]
        if let keychain { query[kSecMatchSearchList] = [keychain] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        GuestMDMDiagnostics.record(.privateKeyReference, status: Int64(status))
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}

private final class XPCResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reply: [String: Any]?
    private(set) var error: String?

    func set(reply: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        self.reply = reply
    }

    func set(error: String) {
        lock.lock(); defer { lock.unlock() }
        self.error = error
    }
}
