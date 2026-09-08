import CryptoKit
import Darwin
import Foundation
import Security

/// The short-lived guest process used for the private Configuration Profiles
/// enrollment path.  It is deliberately separate from the persistent agent:
/// the host stages and ad-hoc signs a copy of the canonical executable, then
/// invokes that copy with a request UUID and request-file digest. No environment value participates
/// in this protocol.
enum PommeMDMPrivateHelper {
    static let flag = "--pomme-mdm-private-helper"
    static let requestVersion = 1
    static let signingIdentifier = "com.github.weswhet.pomme.mdm-helper"
    static let stagingDirectory = GuestMDMEnrollment.stagingDirectory
    static let maximumRequestBytes: UInt64 = 64 * 1024
    static let maximumProfileBytes: UInt64 = 16 * 1024 * 1024
    static let maximumHelperBytes: UInt64 = 128 * 1024 * 1024
    static let maximumRequestLifetime: TimeInterval = 300

    /// These are the only entitlements permitted on the temporary helper.
    /// The host runner never carries either of these guest-only entitlements.
    static let requiredPrivateEntitlements: Set<String> = [
        "com.apple.private.managedclient.mdmclient-private",
        "com.apple.private.security.storage.ConfigurationProfilesPrivate",
    ]

    enum FailureCode: String, Equatable, Sendable {
        case invalidArguments = "invalid-arguments"
        case notRoot = "not-root"
        case invalidRequest = "invalid-request"
        case unsafeFiles = "unsafe-files"
        case leaseBusy = "lease-busy"
        case digestMismatch = "digest-mismatch"
        case entitlementsRejected = "entitlements-rejected"
        case amfiEnabled = "amfi-enabled"
        case enrollmentFailed = "enrollment-failed"
        case enrollmentOutcomeUnknown = "enrollment-outcome-unknown"
    }

    /// This is the exact JSON shape written by the host before launching the
    /// helper. The parser rejects every additional key; only the pre-mode
    /// version-1 shape is accepted as a legacy form and defaults safely to
    /// unapproved.
    struct Request: Codable, Equatable, Sendable {
        let version: Int
        let action: String
        let requestID: String
        let expiresAt: String
        let helperSHA256: String
        let profilePath: String
        let profileSHA256: String
        let profileBytes: UInt64
        let mode: MDMEnrollmentMode

        static let keys: Set<String> = [
            "version", "action", "requestID", "expiresAt", "helperSHA256",
            "profilePath", "profileSHA256", "profileBytes", "mode",
        ]
        static let legacyKeys = keys.subtracting(["mode"])

        init(
            version: Int,
            action: String,
            requestID: String,
            expiresAt: String,
            helperSHA256: String,
            profilePath: String,
            profileSHA256: String,
            profileBytes: UInt64,
            mode: MDMEnrollmentMode = .unapproved
        ) {
            self.version = version
            self.action = action
            self.requestID = requestID
            self.expiresAt = expiresAt
            self.helperSHA256 = helperSHA256
            self.profilePath = profilePath
            self.profileSHA256 = profileSHA256
            self.profileBytes = profileBytes
            self.mode = mode
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case action
            case requestID
            case expiresAt
            case helperSHA256
            case profilePath
            case profileSHA256
            case profileBytes
            case mode
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            action = try values.decode(String.self, forKey: .action)
            requestID = try values.decode(String.self, forKey: .requestID)
            expiresAt = try values.decode(String.self, forKey: .expiresAt)
            helperSHA256 = try values.decode(String.self, forKey: .helperSHA256)
            profilePath = try values.decode(String.self, forKey: .profilePath)
            profileSHA256 = try values.decode(String.self, forKey: .profileSHA256)
            profileBytes = try values.decode(UInt64.self, forKey: .profileBytes)
            // Requests emitted before mode selection are intentionally treated
            // as unapproved. This preserves the old helper contract without
            // ever granting synthetic user intent implicitly.
            mode = values.contains(.mode)
                ? try values.decode(MDMEnrollmentMode.self, forKey: .mode)
                : .unapproved
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.version == rhs.version
                && lhs.action == rhs.action
                && lhs.requestID == rhs.requestID
                && lhs.expiresAt == rhs.expiresAt
                && lhs.helperSHA256 == rhs.helperSHA256
                && lhs.profilePath == rhs.profilePath
                && lhs.profileSHA256 == rhs.profileSHA256
                && lhs.profileBytes == rhs.profileBytes
                && lhs.mode.rawValue == rhs.mode.rawValue
        }
    }

    struct FileReceipt: Equatable, Sendable {
        let bytes: UInt64
        let sha256: String
    }

    /// Injectable seams keep the helper's security gates testable without a
    /// signed guest executable, a live AMFI boot argument, or a real MDM
    /// identity keychain.
    struct Dependencies {
        var now: () -> Date
        var executableURL: () throws -> URL
        var signedEntitlements: (URL) throws -> Set<String>
        var bootArguments: () throws -> String?
        var readFile: (URL, UInt64, uid_t, gid_t, mode_t) throws -> (Data, FileReceipt)
        var fileReceipt: (URL, UInt64, uid_t, gid_t, mode_t) throws -> FileReceipt
        var enroll: (String, MDMEnrollmentMode, TimeInterval) throws -> GuestOperationExecution

        init(
            now: @escaping () -> Date = Date.init,
            executableURL: @escaping () throws -> URL = PommeMDMPrivateHelper.currentExecutableURL,
            signedEntitlements: @escaping (URL) throws -> Set<String> = PommeMDMPrivateHelper.entitlements,
            bootArguments: @escaping () throws -> String? = PommeMDMPrivateHelper.currentBootArguments,
            readFile: @escaping (URL, UInt64, uid_t, gid_t, mode_t) throws -> (Data, FileReceipt) = PommeMDMPrivateHelper.readRegularFile,
            fileReceipt: @escaping (URL, UInt64, uid_t, gid_t, mode_t) throws -> FileReceipt = PommeMDMPrivateHelper.regularFileReceipt,
            enroll: @escaping (String, MDMEnrollmentMode, TimeInterval) throws -> GuestOperationExecution = { path, mode, timeout in
                try GuestMDMEnrollment(requestTimeout: timeout).enroll(profilePath: path, mode: mode)
            }
        ) {
            self.now = now
            self.executableURL = executableURL
            self.signedEntitlements = signedEntitlements
            self.bootArguments = bootArguments
            self.readFile = readFile
            self.fileReceipt = fileReceipt
            self.enroll = enroll
        }

        init(
            now: @escaping () -> Date = Date.init,
            executableURL: @escaping () throws -> URL = PommeMDMPrivateHelper.currentExecutableURL,
            signedEntitlements: @escaping (URL) throws -> Set<String> = PommeMDMPrivateHelper.entitlements,
            bootArguments: @escaping () throws -> String? = PommeMDMPrivateHelper.currentBootArguments,
            readFile: @escaping (URL, UInt64, uid_t, gid_t, mode_t) throws -> (Data, FileReceipt) = PommeMDMPrivateHelper.readRegularFile,
            fileReceipt: @escaping (URL, UInt64, uid_t, gid_t, mode_t) throws -> FileReceipt = PommeMDMPrivateHelper.regularFileReceipt,
            enroll: @escaping (String, TimeInterval) throws -> GuestOperationExecution
        ) {
            self.init(
                now: now,
                executableURL: executableURL,
                signedEntitlements: signedEntitlements,
                bootArguments: bootArguments,
                readFile: readFile,
                fileReceipt: fileReceipt,
                enroll: { path, _, timeout in try enroll(path, timeout) }
            )
        }
    }

    /// Runs the hidden entrypoint and writes exactly one redacted JSON result.
    /// The caller must terminate the process with the returned exit code.
    static func run(arguments: [String], dependencies: Dependencies = .init()) -> Int32 {
        do {
            guard geteuid() == 0 else { throw Failure.notRoot }
            guard arguments.count == 3,
                  arguments[0] == flag,
                  let requestID = normalizedRequestID(arguments[1]),
                  validSHA256(arguments[2]) else {
                throw Failure.invalidArguments
            }

            let paths = try Paths(requestID: requestID)
            // The request file is also the shared capability used to serialize
            // helper instances. It is never created or replaced by the helper.
            let lease = try SharedFileLease.acquire(at: paths.request)
            defer { lease.release() }

            let requestData = try dependencies.readFile(
                paths.request,
                maximumRequestBytes,
                0,
                try wheelGroupID(),
                0o600
            ).0
            let request = try parseBoundRequest(
                requestData,
                expectedRequestID: requestID,
                expectedSHA256: arguments[2]
            )
            let validation = try validate(
                request: request,
                paths: paths,
                dependencies: dependencies
            )

            let execution: GuestOperationExecution
            do {
                execution = try dependencies.enroll(request.profilePath, request.mode, validation.timeout)
            } catch GuestInternalError.mdmOutcomeUnknown {
                throw Failure.enrollmentOutcomeUnknown
            } catch {
                throw Failure.enrollmentFailed
            }
            guard execution.exitCode == 0,
                  let identifier = execution.payload["profileIdentifier"] as? String,
                  validProfileIdentifier(identifier) else {
                throw Failure.enrollmentFailed
            }
            emit(.success(profileIdentifier: identifier))
            return 0
        } catch let failure as Failure {
            emit(.failure(failure.code))
            return failure.exitCode
        } catch {
            // Never expose a localized XPC, filesystem, Security.framework, or
            // keychain error. The host owns cleanup and detailed transaction
            // diagnostics; this process has a closed result vocabulary.
            emit(.failure(.invalidRequest))
            return Failure.invalidRequest.exitCode
        }
    }

    struct Paths: Equatable, Sendable {
        let requestID: String
        let helper: URL
        let request: URL
        let entitlements: URL
        let profileRoot: URL

        init(requestID: String, root: URL = URL(fileURLWithPath: stagingDirectory, isDirectory: true)) throws {
            guard let normalized = normalizedRequestID(requestID) else { throw Failure.invalidArguments }
            let prefix = "helper-\(normalized)"
            self.requestID = normalized
            profileRoot = root
            helper = root.appendingPathComponent(prefix + ".bin", isDirectory: false)
            request = root.appendingPathComponent(prefix + ".request.json", isDirectory: false)
            entitlements = root.appendingPathComponent(prefix + ".entitlements.plist", isDirectory: false)
        }
    }

    /// The lock is owner-private and process-shared. It deliberately persists
    /// as a known staging-root file; host cleanup only removes the three
    /// request artifacts after this descriptor is closed.
    final class SharedFileLease {
        private var descriptor: Int32

        private init(descriptor: Int32) { self.descriptor = descriptor }

        deinit { release() }

        static func acquire(
            at url: URL,
            expectedOwner: uid_t = 0,
            expectedGroup: gid_t? = nil,
            expectedMode: mode_t = 0o600
        ) throws -> SharedFileLease {
            let group: gid_t
            if let expectedGroup {
                group = expectedGroup
            } else {
                group = try wheelGroupID()
            }
            let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw Failure.unsafeFiles }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == expectedOwner,
                  info.st_gid == group,
                  info.st_mode & 0o7777 == expectedMode,
                  info.st_nlink == 1 else {
                _ = Darwin.close(descriptor)
                throw Failure.unsafeFiles
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(descriptor)
                if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.leaseBusy }
                throw Failure.unsafeFiles
            }
            return .init(descriptor: descriptor)
        }

        func release() {
            guard descriptor >= 0 else { return }
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private enum Failure: Error {
        case invalidArguments
        case notRoot
        case invalidRequest
        case unsafeFiles
        case leaseBusy
        case digestMismatch
        case entitlementsRejected
        case amfiEnabled
        case enrollmentFailed
        case enrollmentOutcomeUnknown

        var code: FailureCode {
            switch self {
            case .invalidArguments: .invalidArguments
            case .notRoot: .notRoot
            case .invalidRequest: .invalidRequest
            case .unsafeFiles: .unsafeFiles
            case .leaseBusy: .leaseBusy
            case .digestMismatch: .digestMismatch
            case .entitlementsRejected: .entitlementsRejected
            case .amfiEnabled: .amfiEnabled
            case .enrollmentFailed: .enrollmentFailed
            case .enrollmentOutcomeUnknown: .enrollmentOutcomeUnknown
            }
        }

        var exitCode: Int32 {
            switch self {
            case .invalidArguments, .invalidRequest: 64
            case .notRoot, .unsafeFiles, .entitlementsRejected, .amfiEnabled: 65
            case .leaseBusy: 73
            case .digestMismatch: 74
            case .enrollmentFailed, .enrollmentOutcomeUnknown: 70
            }
        }
    }

    private struct Validation {
        let timeout: TimeInterval
    }

    private enum Output {
        case success(profileIdentifier: String)
        case failure(FailureCode)

        var object: [String: Any] {
            switch self {
            case .success(let profileIdentifier):
                return ["completed": true, "profileIdentifier": profileIdentifier]
            case .failure(let code):
                return ["completed": false, "errorCode": code.rawValue]
            }
        }
    }

    private static func emit(_ output: Output) {
        guard JSONSerialization.isValidJSONObject(output.object),
              let data = try? JSONSerialization.data(withJSONObject: output.object, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0a)
        try? FileHandle.standardOutput.write(contentsOf: line)
    }

    static func parseBoundRequest(
        _ data: Data,
        expectedRequestID: String,
        expectedSHA256: String
    ) throws -> Request {
        guard validSHA256(expectedSHA256),
              data.count <= maximumRequestBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA256
        else { throw Failure.digestMismatch }
        return try parseRequest(data, expectedRequestID: expectedRequestID)
    }

    static func parseRequest(_ data: Data, expectedRequestID: String) throws -> Request {
        guard data.count <= maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any],
              (Set(dictionary.keys) == Request.keys || Set(dictionary.keys) == Request.legacyKeys) else {
            throw Failure.invalidRequest
        }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            throw Failure.invalidRequest
        }
        guard request.version == requestVersion,
              request.action == "enroll",
              request.requestID == expectedRequestID,
              normalizedRequestID(request.requestID) == request.requestID,
              validSHA256(request.helperSHA256),
              validSHA256(request.profileSHA256),
              request.profileBytes > 0,
              request.profileBytes <= maximumProfileBytes else {
            throw Failure.invalidRequest
        }
        return request
    }

    static func acceptsEntitlementSet(_ entitlements: Set<String>) -> Bool {
        entitlements == requiredPrivateEntitlements
    }

    static func hasAMFIOverride(_ bootArguments: String?) -> Bool {
        PommeBootArguments.containsOverride(bootArguments)
    }

    private static func validate(
        request: Request,
        paths: Paths,
        dependencies: Dependencies
    ) throws -> Validation {
        let now = dependencies.now()
        guard let expiry = iso8601Date(request.expiresAt),
              expiry > now,
              expiry.timeIntervalSince(now) <= maximumRequestLifetime else {
            throw Failure.invalidRequest
        }

        let executable = try dependencies.executableURL()
        guard executable.path == paths.helper.path else { throw Failure.unsafeFiles }
        let wheel = try wheelGroupID()

        // The staging root and all three request artifacts are fixed direct
        // children with root:wheel ownership. This closes path substitution and
        // prevents the helper from following a host-provided symlink.
        try requireDirectory(URL(fileURLWithPath: stagingDirectory, isDirectory: true), owner: 0, group: wheel, mode: 0o700)
        let helperReceipt = try dependencies.fileReceipt(paths.helper, maximumHelperBytes, 0, wheel, 0o700)
        guard helperReceipt.sha256 == request.helperSHA256 else {
            throw Failure.digestMismatch
        }
        let entitlementData = try dependencies.readFile(paths.entitlements, 64 * 1024, 0, wheel, 0o600).0
        try validateEntitlementPlist(entitlementData)

        guard hasAMFIOverride(try dependencies.bootArguments()) else {
            throw Failure.amfiEnabled
        }
        guard acceptsEntitlementSet(try dependencies.signedEntitlements(executable)) else {
            throw Failure.entitlementsRejected
        }

        let profileURL = URL(fileURLWithPath: request.profilePath)
        guard profileURL.path == request.profilePath,
              profileURL.deletingLastPathComponent().path == paths.profileRoot.path,
              profileURL.lastPathComponent.hasSuffix(".mobileconfig"),
              GuestMDMEnrollment.isStagedProfilePath(request.profilePath) else {
            throw Failure.invalidRequest
        }
        let profileReceipt = try dependencies.fileReceipt(
            profileURL,
            maximumProfileBytes,
            0,
            wheel,
            0o600
        )
        guard profileReceipt.bytes == request.profileBytes,
              profileReceipt.sha256 == request.profileSHA256 else {
            throw Failure.digestMismatch
        }

        // The helper's request timeout is bounded independently of the
        // process-start timeout used by the host.
        guard request.profileBytes <= maximumProfileBytes,
              let timeout = requestTimeout(from: request.expiresAt, now: now) else {
            throw Failure.invalidRequest
        }
        return Validation(timeout: timeout)
    }

    private static func requestTimeout(from expiry: String, now: Date) -> TimeInterval? {
        guard let date = iso8601Date(expiry) else { return nil }
        let timeout = date.timeIntervalSince(now)
        guard timeout.isFinite, timeout >= 1, timeout <= maximumRequestLifetime else { return nil }
        return timeout
    }

    private static func validateEntitlementPlist(_ data: Data) throws {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any],
              Set(dictionary.keys) == requiredPrivateEntitlements,
              dictionary.values.allSatisfy({ ($0 as? Bool) == true }) else {
            throw Failure.entitlementsRejected
        }
    }

    private static func requireDirectory(_ url: URL, owner: uid_t, group: gid_t, mode: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == owner,
              info.st_gid == group,
              info.st_mode & 0o7777 == mode,
              info.st_nlink >= 2 else {
            throw Failure.unsafeFiles
        }
    }

    private static func validProfileIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.contains("\0")
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }

    private static func normalizedRequestID(_ value: String) -> String? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        let normalized = uuid.uuidString.lowercased()
        return value == normalized ? normalized : nil
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
    }

    private static func iso8601Date(_ value: String) -> Date? {
        guard value.hasSuffix("Z"), !value.contains("\n"), !value.contains("\r") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func wheelGroupID() throws -> gid_t {
        guard let group = getgrnam("wheel") else { throw Failure.unsafeFiles }
        return group.pointee.gr_gid
    }

    private static func currentExecutableURL() throws -> URL {
        var size: UInt32 = 0
        guard _NSGetExecutablePath(nil, &size) == -1, size > 0 else {
            throw Failure.unsafeFiles
        }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard buffer.withUnsafeMutableBufferPointer({ pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size) == 0
        }) else {
            throw Failure.unsafeFiles
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }

    private static func currentBootArguments() throws -> String? {
        var size = 0
        guard sysctlbyname("kern.bootargs", nil, &size, nil, 0) == 0, size > 0 else {
            throw Failure.amfiEnabled
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootargs", &buffer, &size, nil, 0) == 0 else {
            throw Failure.amfiEnabled
        }
        return String(decoding: buffer.prefix(max(0, size - 1)), as: UTF8.self)
    }

    private static func entitlements(_ url: URL) throws -> Set<String> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(
                  code,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  nil
              ) == errSecSuccess else {
            throw Failure.entitlementsRejected
        }

        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        ) == errSecSuccess,
        let info = rawInfo as? [String: Any],
        let rawEntitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
        let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
        info[kSecCodeInfoIdentifier as String] as? String == signingIdentifier,
        info[kSecCodeInfoTeamIdentifier as String] == nil,
        flags.uint32Value & SecCodeSignatureFlags([.adhoc, .runtime]).rawValue
            == SecCodeSignatureFlags([.adhoc, .runtime]).rawValue else {
            throw Failure.entitlementsRejected
        }
        guard rawEntitlements.values.allSatisfy({ ($0 as? Bool) == true }) else {
            throw Failure.entitlementsRejected
        }
        return Set(rawEntitlements.keys)
    }

    private static func readRegularFile(
        _ url: URL,
        _ maximumBytes: UInt64,
        _ owner: uid_t,
        _ group: gid_t,
        _ mode: mode_t
    ) throws -> (Data, FileReceipt) {
        try readRegularFile(url, maximumBytes, owner, group, mode, retainContents: true)
    }

    private static func regularFileReceipt(
        _ url: URL, _ maximumBytes: UInt64, _ owner: uid_t, _ group: gid_t, _ mode: mode_t
    ) throws -> FileReceipt {
        try readRegularFile(url, maximumBytes, owner, group, mode, retainContents: false).1
    }

    private static func readRegularFile(
        _ url: URL, _ maximumBytes: UInt64, _ owner: uid_t, _ group: gid_t, _ mode: mode_t,
        retainContents: Bool
    ) throws -> (Data, FileReceipt) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafeFiles }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == owner,
              before.st_gid == group,
              before.st_mode & 0o7777 == mode,
              before.st_nlink == 1,
              before.st_size >= 0,
              UInt64(before.st_size) <= maximumBytes else {
            throw Failure.unsafeFiles
        }

        var data = Data()
        if retainContents { data.reserveCapacity(Int(before.st_size)) }
        var bytes: UInt64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                bytes += UInt64(count)
                guard bytes <= maximumBytes else { throw Failure.unsafeFiles }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                if retainContents { data.append(contentsOf: buffer.prefix(count)) }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw Failure.unsafeFiles
            }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              bytes == UInt64(after.st_size) else {
            throw Failure.unsafeFiles
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (data, .init(bytes: bytes, sha256: digest))
    }
}
