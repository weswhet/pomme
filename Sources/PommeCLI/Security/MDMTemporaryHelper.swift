import CryptoKit
import Foundation

/// Host-side names for one temporary MDM helper invocation. All guest paths
/// are fixed direct children of the root-owned MDM staging directory; neither
/// the CLI nor the helper accepts a caller-selected workspace.
struct PommeMDMTemporaryHelperWorkspace: Equatable, Sendable {
    static let helperPrefix = "helper-"

    let requestID: UUID
    let root: String

    init(requestID: UUID, root: String = MDMProfileStaging.guestDirectory) throws {
        let normalizedRoot = root
        guard normalizedRoot == MDMProfileStaging.guestDirectory else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        self.requestID = requestID
        self.root = normalizedRoot
    }

    private var stem: String { "\(root)/\(Self.helperPrefix)\(requestID.uuidString.lowercased())" }
    var helperPath: String { "\(stem).bin" }
    var entitlementsPath: String { "\(stem).entitlements.plist" }
    var requestPath: String { "\(stem).request.json" }

    func owns(_ path: String) -> Bool {
        [helperPath, entitlementsPath, requestPath].contains(path)
    }

    /// The authenticated staging cleanup operation accepts only one of the
    /// three artifacts for a UUID-derived helper workspace.  Profile paths are
    /// deliberately handled by `MDMProfileStaging` and never by this helper
    /// predicate.
    static func isArtifactPath(_ path: String) -> Bool {
        let normalized = path
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\0"), !components.dropFirst().contains(""),
              !components.contains("."), !components.contains("..") else { return false }
        guard normalized.hasPrefix(MDMProfileStaging.guestDirectory + "/"),
              URL(fileURLWithPath: normalized).deletingLastPathComponent().path
                == MDMProfileStaging.guestDirectory else {
            return false
        }
        let name = URL(fileURLWithPath: normalized).lastPathComponent
        guard name.hasPrefix(Self.helperPrefix) else { return false }
        let suffixes = [".bin", ".entitlements.plist", ".request.json"]
        guard let suffix = suffixes.first(where: { name.hasSuffix($0) }) else {
            return false
        }
        let rawID = String(name.dropFirst(Self.helperPrefix.count).dropLast(suffix.count))
        guard let id = UUID(uuidString: rawID) else { return false }
        return rawID == id.uuidString.lowercased()
    }
}

/// The request contains integrity data and an expiry, never profile bytes,
/// credentials, host locations, private entitlements, or AMFI claims.
struct PommeMDMTemporaryHelperRequest: Codable, Equatable, Sendable {
    static let version = 1
    static let action = "enroll"
    static let maximumProfileBytes = 16 * 1024 * 1024

    let version: Int
    let action: String
    let requestID: String
    /// ISO-8601 UTC text is shared byte-for-byte with the guest helper's
    /// request decoder.  A Foundation `Date`'s default Codable form is not
    /// accepted at this boundary.
    let expiresAt: String
    let helperSHA256: String
    let profilePath: String
    let profileSHA256: String
    let profileBytes: UInt64
    let mode: MDMEnrollmentMode

    init(
        requestID: UUID,
        expiresAt: Date,
        helperSHA256: String,
        profile: PommeMDMProfileTransferReceipt,
        mode: MDMEnrollmentMode = .unapproved
    ) throws {
        guard Self.isDigest(helperSHA256),
              Self.isDigest(profile.sha256),
              (try? MDMProfileStaging.destination(requestedPath: profile.destination)) == profile.destination,
              profile.bytes > 0,
              profile.bytes <= Self.maximumProfileBytes else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        version = Self.version
        action = Self.action
        self.requestID = requestID.uuidString.lowercased()
        self.expiresAt = Self.iso8601String(expiresAt)
        self.helperSHA256 = helperSHA256
        profilePath = profile.destination
        profileSHA256 = profile.sha256
        profileBytes = UInt64(profile.bytes)
        self.mode = mode
    }

    init(
        requestID: UUID,
        expiresAt: Date,
        helperSHA256: String,
        mode: MDMEnrollmentMode,
        profile: PommeMDMProfileTransferReceipt
    ) throws {
        try self.init(
            requestID: requestID,
            expiresAt: expiresAt,
            helperSHA256: helperSHA256,
            profile: profile,
            mode: mode
        )
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
        // Version 1 requests predate enrollment mode. Treating an omitted
        // mode as unapproved keeps old internal callers safe while every new
        // host request still writes the selected mode explicitly.
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

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

struct PommeMDMTemporaryHelperResult: Equatable, Sendable {
    let profileIdentifier: String

    init(profileIdentifier: String) throws {
        guard !profileIdentifier.isEmpty,
              profileIdentifier.utf8.count <= 255,
              !profileIdentifier.contains("\0"),
              profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) == profileIdentifier else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        self.profileIdentifier = profileIdentifier
    }

    static func decode(_ value: JSONValue) throws -> Self {
        guard let object = value.objectValue else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        if Set(object.keys) == ["completed", "profileIdentifier"],
           object["completed"] == .bool(true),
           let identifier = object["profileIdentifier"]?.stringValue {
            return try .init(profileIdentifier: identifier)
        }

        // A closed failure response is useful only when the helper has
        // definitely completed.  The outcome-unknown code is kept distinct
        // because finalInstallProfile may already have committed before the
        // helper lost its reply; callers must verify state before retrying.
        guard Set(object.keys) == ["completed", "errorCode"],
              object["completed"] == .bool(false),
              let errorCode = object["errorCode"]?.stringValue,
              PommeMDMPrivateHelper.FailureCode(rawValue: errorCode) != nil else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        if errorCode == PommeMDMPrivateHelper.FailureCode.enrollmentOutcomeUnknown.rawValue {
            throw PommeMDMEnrollmentError.enrollmentOutcomeUnknown
        }
        throw PommeMDMEnrollmentError.enrollmentFailed
    }
}

/// The live implementation uses only the existing authenticated pinned-agent
/// file and process operations. It may not select a new agent or modify the
/// immutable provisioning plan.
protocol PommeMDMTemporaryHelperTransport: Sendable {
    func enroll(
        profile: PommeMDMProfileTransferReceipt,
        mode: MDMEnrollmentMode,
        baseline: PommeMDMEnrollmentStateBaseline,
        timeout: TimeInterval
    ) async throws -> PommeMDMTemporaryHelperResult
}

extension PommeMDMTemporaryHelperTransport {
    /// Source compatibility for callers that predate selectable enrollment
    /// modes. Such calls deliberately use the least-privileged unapproved
    /// behavior.
    func enroll(
        profile: PommeMDMProfileTransferReceipt,
        baseline: PommeMDMEnrollmentStateBaseline,
        timeout: TimeInterval
    ) async throws -> PommeMDMTemporaryHelperResult {
        try await enroll(
            profile: profile,
            mode: .unapproved,
            baseline: baseline,
            timeout: timeout
        )
    }

    /// Equivalent mode-aware spelling with the legacy arguments kept in their
    /// original order. This makes it possible for the durable transaction to
    /// add mode without forcing older call sites to reorder their labels.
    func enroll(
        profile: PommeMDMProfileTransferReceipt,
        baseline: PommeMDMEnrollmentStateBaseline,
        timeout: TimeInterval,
        mode: MDMEnrollmentMode
    ) async throws -> PommeMDMTemporaryHelperResult {
        try await enroll(
            profile: profile,
            mode: mode,
            baseline: baseline,
            timeout: timeout
        )
    }
}

struct PommeMDMTemporaryHelperArtifact: Equatable, Sendable {
    let source: URL
    let sha256: String

    init(source: URL, sha256: String) throws {
        guard source.isFileURL, source.path.hasPrefix("/"), Self.isDigest(sha256) else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        self.source = source.standardizedFileURL
        self.sha256 = sha256
    }

    private static func isDigest(_ value: String) -> Bool {
        PommeMDMTemporaryHelperRequest.isDigest(value)
    }
}

/// Receipt returned by an authenticated generic file transfer.  The generic
/// layer accepts the profile direct child and the three UUID-derived helper
/// artifacts; the public profile wrapper below remains profile-only.
struct PommeMDMAuthenticatedFileTransferReceipt: Equatable, Sendable {
    let destination: String
    let bytes: Int
    let sha256: String

    init(destination: String, bytes: Int, sha256: String) throws {
        guard Self.isAllowedDestination(destination),
              bytes > 0,
              sha256.count == 64,
              sha256 == sha256.lowercased(),
              sha256.allSatisfy(\.isHexDigit) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        self.destination = destination
        self.bytes = bytes
        self.sha256 = sha256
    }

    private static func isAllowedDestination(_ path: String) -> Bool {
        if (try? MDMProfileStaging.destination(requestedPath: path)) == path {
            return true
        }
        return PommeMDMTemporaryHelperWorkspace.isArtifactPath(path)
            || PommeMDMStagingHelper.isBootstrapPath(path)
    }
}

/// Offline-testable transaction for the existing pinned agent's file/process
/// capabilities. Production supplies authenticated operations; this type never
/// changes SIP/AMFI and never touches a provisioning plan or AgentArtifacts.
struct PommeMDMTemporaryHelperHost: PommeMDMTemporaryHelperTransport {
    static let requiredPrivateEntitlements: Set<String> = [
        "com.apple.private.managedclient.mdmclient-private",
        "com.apple.private.security.storage.ConfigurationProfilesPrivate",
    ]

    struct Dependencies: Sendable {
        let canonicalArtifact: @Sendable () throws -> PommeMDMTemporaryHelperArtifact
        let prepare: @Sendable (PommeMDMTemporaryHelperWorkspace) async throws -> Void
        let transferFile: @Sendable (URL, String) async throws -> PommeMDMAuthenticatedFileTransferReceipt
        let transferData: @Sendable (Data, String) async throws -> PommeMDMAuthenticatedFileTransferReceipt
        let resignAndVerify: @Sendable (PommeMDMTemporaryHelperWorkspace) async throws -> String
        let launch: @Sendable (PommeMDMTemporaryHelperWorkspace, PommeMDMTemporaryHelperRequest, String, TimeInterval) async throws -> JSONValue
        let cleanup: @Sendable (PommeMDMTemporaryHelperWorkspace) async throws -> Void
        let now: @Sendable () -> Date
    }

    let dependencies: Dependencies
    /// A durable workflow may reserve this workspace in its journal before
    /// the first guest effect. Legacy callers can omit it and retain the
    /// previous per-invocation UUID behavior.
    let reservedWorkspace: PommeMDMTemporaryHelperWorkspace?

    init(
        dependencies: Dependencies,
        workspace: PommeMDMTemporaryHelperWorkspace? = nil
    ) {
        self.dependencies = dependencies
        reservedWorkspace = workspace
    }

    init(
        dependencies: Dependencies,
        requestID: UUID
    ) throws {
        self.dependencies = dependencies
        reservedWorkspace = try PommeMDMTemporaryHelperWorkspace(requestID: requestID)
    }

    func enroll(
        profile: PommeMDMProfileTransferReceipt,
        mode: MDMEnrollmentMode = .unapproved,
        baseline: PommeMDMEnrollmentStateBaseline,
        timeout: TimeInterval
    ) async throws -> PommeMDMTemporaryHelperResult {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        try PommeMDMTemporaryHelperSecurityGate.requireSIPAndAMFIDisabled(baseline)
        let workspace = try reservedWorkspace
            ?? PommeMDMTemporaryHelperWorkspace(requestID: UUID())
        var prepared = false
        var primaryError: Error?
        var result: PommeMDMTemporaryHelperResult?
        do {
            let artifact = try dependencies.canonicalArtifact()
            try await dependencies.prepare(workspace)
            prepared = true
            let helperReceipt = try await dependencies.transferFile(artifact.source, workspace.helperPath)
            guard helperReceipt.destination == workspace.helperPath,
                  helperReceipt.sha256 == artifact.sha256 else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }
            let entitlementReceipt = try await dependencies.transferData(Self.entitlements, workspace.entitlementsPath)
            guard entitlementReceipt.destination == workspace.entitlementsPath,
                  entitlementReceipt.bytes == Self.entitlements.count,
                  entitlementReceipt.sha256 == PommeMDMTemporaryHelperRequest.digest(of: Self.entitlements) else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }
            let postSignDigest = try await dependencies.resignAndVerify(workspace)
            guard PommeMDMTemporaryHelperRequest.isDigest(postSignDigest) else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
            let request = try PommeMDMTemporaryHelperRequest(
                requestID: workspace.requestID,
                expiresAt: dependencies.now().addingTimeInterval(timeout),
                helperSHA256: postSignDigest,
                profile: profile,
                mode: mode
            )
            let requestData = try request.encoded()
            let requestReceipt = try await dependencies.transferData(requestData, workspace.requestPath)
            guard requestReceipt.destination == workspace.requestPath,
                  requestReceipt.bytes == requestData.count,
                  requestReceipt.sha256 == PommeMDMTemporaryHelperRequest.digest(of: requestData) else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }
            result = try PommeMDMTemporaryHelperResult.decode(
                try await dependencies.launch(
                    workspace,
                    request,
                    requestReceipt.sha256,
                    timeout
                )
            )
        } catch {
            primaryError = error
        }

        let helperProcessMayStillExist = (primaryError as? PommeMDMEnrollmentError)
            == .helperProcessTerminationUnproven
        if prepared, !helperProcessMayStillExist {
            do { try await dependencies.cleanup(workspace) }
            catch { throw PommeMDMEnrollmentError.cleanupFailed }
        }
        if let primaryError { throw primaryError }
        guard let result else { throw PommeMDMEnrollmentError.enrollmentFailed }
        return result
    }

    /// Exact guest-only entitlement payload. The host runner itself continues
    /// to use only its virtualization entitlement.
    static let entitlements: Data = {
        let values: [String: Any] = [
            "com.apple.private.managedclient.mdmclient-private": true,
            "com.apple.private.security.storage.ConfigurationProfilesPrivate": true,
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
    }()
}

struct PommeMDMTemporaryHelperDependencies: PommeMDMTemporaryHelperTransport {
    let run: @Sendable (PommeMDMProfileTransferReceipt, MDMEnrollmentMode, PommeMDMEnrollmentStateBaseline, TimeInterval) async throws -> PommeMDMTemporaryHelperResult

    init(
        run: @escaping @Sendable (PommeMDMProfileTransferReceipt, MDMEnrollmentMode, PommeMDMEnrollmentStateBaseline, TimeInterval) async throws -> PommeMDMTemporaryHelperResult
    ) {
        self.run = run
    }

    init(
        run: @escaping @Sendable (PommeMDMProfileTransferReceipt, PommeMDMEnrollmentStateBaseline, TimeInterval, MDMEnrollmentMode) async throws -> PommeMDMTemporaryHelperResult
    ) {
        self.run = { profile, mode, baseline, timeout in
            try await run(profile, baseline, timeout, mode)
        }
    }

    init(
        run: @escaping @Sendable (PommeMDMProfileTransferReceipt, PommeMDMEnrollmentStateBaseline, TimeInterval) async throws -> PommeMDMTemporaryHelperResult
    ) {
        self.run = { profile, _, baseline, timeout in
            try await run(profile, baseline, timeout)
        }
    }

    func enroll(
        profile: PommeMDMProfileTransferReceipt,
        mode: MDMEnrollmentMode,
        baseline: PommeMDMEnrollmentStateBaseline,
        timeout: TimeInterval
    ) async throws -> PommeMDMTemporaryHelperResult {
        try await run(profile, mode, baseline, timeout)
    }
}

enum PommeMDMTemporaryHelperSecurityGate {
    /// This is an explicit precondition for guest-only helper signing; MDM
    /// never changes SIP or AMFI itself. The values come from authenticated
    /// normal-agent configuration evidence captured by the enclosing transaction.
    static func requireSIPAndAMFIDisabled(_ baseline: PommeMDMEnrollmentStateBaseline) throws {
        let sip = try JSONDecoder().decode(JSONValue.self, from: baseline.sip)
        let amfi = try JSONDecoder().decode(JSONValue.self, from: baseline.amfi)
        guard sip.objectValue?["operation"] == .string("sip.status"),
              sip.objectValue?["sipDisabled"] == .bool(true),
              amfi.objectValue?["operation"] == .string("amfi.status"),
              amfi.objectValue?["amfiDisabled"] == .bool(true) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
    }
}
