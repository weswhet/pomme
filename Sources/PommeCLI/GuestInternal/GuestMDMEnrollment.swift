import Darwin
import Foundation
import ObjectiveC.runtime
import Security

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
}

enum GuestMDMIdentityKeychain {
    static let privatePath = "/private/var/db/ConfigurationProfiles/Store/MCXPrivate.keychain"
    static let systemPath = "/Library/Keychains/System.keychain"

    static func select<Handle>(operations: GuestMDMIdentityKeychainOperations<Handle>) throws -> Handle {
        var (result, handle) = operations.open(privatePath)
        var systemSelected = false
        var observedStatus: (OSStatus, SecKeychainStatus)?
        if result == errSecSuccess, let privateHandle = handle {
            observedStatus = operations.status(privateHandle)
        }
        // SecKeychainOpen may return a reference to a missing keychain on
        // Sequoia; absence is then reported by SecKeychainGetStatus.
        if result == errSecNoSuchKeychain || observedStatus?.0 == errSecNoSuchKeychain {
            (result, handle) = operations.open(systemPath)
            systemSelected = true
            observedStatus = nil
        }
        guard result == errSecSuccess, let handle else {
            throw GuestInternalError.mdm("Could not open the guest MDM identity keychain.")
        }
        let (statusResult, status) = observedStatus ?? operations.status(handle)
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

    static func openSelectedKeychain() throws -> SecKeychain {
        try select(operations: .init(
            open: { path in
                var handle: SecKeychain?
                return (SecKeychainOpen(path, &handle), handle)
            },
            status: { handle in
                var status: SecKeychainStatus = 0
                return (SecKeychainGetStatus(handle, &status), status)
            }
        ))
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
        identityImportObserver: (() -> Void)? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.request = request
        self.profileArchiveOverride = profileArchiveOverride
        self.profileIdentityOverride = profileIdentityOverride
        self.installedProfileObservation = installedProfileObservation
        self.identityImportObserver = identityImportObserver
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
        let validatedProfile = try Self.validatedStagedProfile(
            profilePath,
            requireRegularFile: profileArchiveOverride == nil
        )

        // This probe must precede archive construction and identity import. A
        // conflicting installed identity therefore cannot cause either an XPC
        // request or a new keychain identity to be created.
        let observationContext = try makeObservationContext(profileURL: validatedProfile)
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
            let built = try buildProfileArchiveWithIdentity(
                profilePath: validatedProfile.path,
                profileData: observationContext?.sourceData
            )
            archive = built.archive
            expectedProfileIdentifier = built.profileIdentifier
        }
        // Once dispatched, a lost reply cannot prove absence of enrollment
        // effects. Preserve the identity referenced by the profile on every
        // ambiguous outcome, and require verification before another attempt.
        do {
            let setupReply = try request([
                "Command": "InstallMDMv1Profile",
                "CommandDesc": "pomme mdm private-xpc setup",
                "MDMProfileArchive": archive,
                "UpdatingEnrollment": false
            ], requestTimeout)
            guard Self.replySuccess(setupReply),
                  let response = setupReply["Response"] as? [String: Any],
                  let updatedArchive = response["UpdatedMDMProfileArchive"] as? Data,
                  !updatedArchive.isEmpty else {
                throw GuestInternalError.mdmOutcomeUnknown
            }
            let installReply = try request([
                "Command": "InstallProfile",
                "CommandDesc": "pomme mdm private-xpc install",
                "ProfileArchive": updatedArchive
            ], requestTimeout)
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
                data = try Data(contentsOf: profileURL, options: [.mappedIfSafe])
            } catch {
                throw GuestInternalError.mdm("The staged MDM profile is unavailable.")
            }
            guard data.count <= GuestMDMObservation.defaultMaximumOutputBytes else {
                throw GuestInternalError.mdm("The staged MDM profile is too large.")
            }
            do {
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
        let reply = try request([
            "Command": "FlagAsUserIntended",
            "CommandDesc": "pomme mdm synthetic user-intent approval",
            "ProfileIdentifier": identifier
        ], requestTimeout)
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

    private func buildProfileArchiveWithIdentity(profilePath: String, profileData: Data? = nil) throws -> (
        archive: Data,
        importedIdentity: ImportedMDMIdentity,
        profileIdentifier: String
    ) {
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
        let profile = try Self.makeProfile(profileClass: profileClass, dictionary: mdmOnly as NSDictionary)
        let importedIdentity = try importIdentityCertificate(profileDictionary: dictionary, mdmPayload: mdmPayloads[0])
        do {
            try Self.attachKeychainItems(
                profile: profile,
                mdmPayload: mdmPayloads[0],
                persistentReference: importedIdentity.persistentReference
            )
            let archive: Data
            do {
                archive = try NSKeyedArchiver.archivedData(withRootObject: profile, requiringSecureCoding: true)
            } catch {
                archive = try NSKeyedArchiver.archivedData(withRootObject: profile, requiringSecureCoding: false)
            }
            return (archive, importedIdentity, profileIdentifier)
        } catch {
            do {
                try importedIdentity.removeOnlyNewItems()
            } catch {
                throw GuestInternalError.mdm(
                    "Could not build the MDM profile archive and newly imported identity cleanup failed: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func importIdentityCertificate(profileDictionary: [String: Any], mdmPayload: [String: Any]) throws -> ImportedMDMIdentity {
        identityImportObserver?()
        guard let identityUUID = mdmPayload["IdentityCertificateUUID"] as? String,
              let pkcs12 = (profileDictionary["PayloadContent"] as? [[String: Any]])?.first(where: {
                  $0["PayloadType"] as? String == "com.apple.security.pkcs12" && $0["PayloadUUID"] as? String == identityUUID
              }),
              let pkcs12Data = pkcs12["PayloadContent"] as? Data else {
            throw GuestInternalError.mdm("The MDM identity PKCS#12 payload is missing.")
        }
        let password = pkcs12["Password"] as? String ?? ""
        var previousInteraction: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
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
        var status = SecPKCS12Import(pkcs12Data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess,
              let items = imported as? [[CFString: Any]],
              let identity = items.compactMap({ $0[kSecImportItemIdentity] as! SecIdentity? }).first else {
            throw GuestInternalError.mdmOutcomeUnknown
        }
        var certificate: SecCertificate?
        status = SecIdentityCopyCertificate(identity, &certificate)
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
        let persistentReference: Data
        if status == errSecSuccess, let data = result as? Data {
            persistentReference = data
        } else {
            var legacyReference: CFData?
            status = SecKeychainItemCreatePersistentReference(unsafeBitCast(certificate, to: SecKeychainItem.self), &legacyReference)
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
        guard let result else {
            let description = error?.takeUnretainedValue().localizedDescription ?? "unknown error"
            throw GuestInternalError.mdm("CPProfile initialization failed: \(description)")
        }
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
            let status = SecItemCopyMatching(query as CFDictionary, &result)
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
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
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
