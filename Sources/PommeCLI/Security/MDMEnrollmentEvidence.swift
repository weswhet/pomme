import ArgumentParser
import CryptoKit
import Foundation

/// The enrollment state requested by the host workflow.
///
/// `supervised` is intentionally the default: callers must explicitly opt in
/// to accepting an enrolled profile that is not User Approved MDM. The mode is
/// a policy value, not a claim that the native command output has been proved.
enum MDMEnrollmentMode: String, Codable, Sendable, CaseIterable, ExpressibleByArgument {
    case supervised
    case unapproved

    static let defaultMode: Self = .supervised
    static let defaultValue: Self = .supervised

    init?(argument: String) {
        self.init(rawValue: argument)
    }
}

/// The SIP/AMFI state a successful enrollment leaves behind.
///
/// `restore` re-enables exactly what the workflow disabled. `disabled` keeps
/// what the workflow disabled switched off; settings it never changed stay as
/// they were found.
enum MDMFinalSecurity: String, Codable, Sendable, CaseIterable, ExpressibleByArgument {
    case restore
    case disabled

    init?(argument: String) {
        self.init(rawValue: argument)
    }
}

/// The non-secret identity extracted from the enrollment mobileconfig.
///
/// The digest covers the original profile bytes. It lets the caller retain a
/// precise source identity without retaining or returning the profile body.
struct MDMEnrollmentProfileIdentity: Codable, Equatable, Hashable, Sendable {
    let identifier: String
    let uuid: UUID
    let serverURL: String
    let digest: String

    var sha256: String { digest }
    var payloadIdentifier: String { identifier }
    var payloadUUID: String { uuid.uuidString.lowercased() }
    var mdmServerURL: String { serverURL }

    init(identifier: String, uuid: UUID, serverURL: String, digest: String) {
        self.identifier = identifier
        self.uuid = uuid
        self.serverURL = serverURL
        self.digest = digest
    }
}

/// The device-level identity observed by `profiles show`.
///
/// Native profile output does not contain the source mobileconfig bytes, so
/// it cannot produce a source digest. The digest is compared indirectly by
/// requiring this complete identity to match the parsed source identity.
struct MDMInstalledProfileIdentity: Codable, Equatable, Hashable, Sendable {
    let identifier: String
    let uuid: UUID
    let serverURL: String

    var payloadIdentifier: String { identifier }
    var payloadUUID: String { uuid.uuidString.lowercased() }
    var mdmServerURL: String { serverURL }

    func matches(_ expected: MDMEnrollmentProfileIdentity) -> Bool {
        identifier == expected.identifier
            && uuid == expected.uuid
            && serverURL == expected.serverURL
    }
}

/// The bounded result of `profiles status -type enrollment`.
struct MDMEnrollmentStatus: Codable, Equatable, Sendable {
    let enrolled: Bool
    let userApproved: Bool
    let serverURL: String?
    let enrolledViaDEP: Bool?

    var isEnrolled: Bool { enrolled }
    var mdmEnrolled: Bool { enrolled }
    var isUserApproved: Bool { userApproved }
    var userApprovedMDM: Bool { userApproved }
    var mdmServerURL: String? { serverURL }
}

/// The one device-management fact retained from `mdmclient` output.
struct MDMDeviceSupervision: Codable, Equatable, Sendable {
    let isSupervised: Bool

    var supervised: Bool { isSupervised }
}

/// Errors are deliberately closed and contain no native output, paths, URLs,
/// profile data, or diagnostics.
enum MDMEnrollmentEvidenceError: Error, Equatable, LocalizedError, Sendable {
    case missingEvidence
    case malformedEvidence
    case conflictingEvidence
    case profileIdentityMismatch
    case enrollmentModeMismatch

    var errorDescription: String? {
        switch self {
        case .missingEvidence:
            "Required MDM enrollment evidence is missing."
        case .malformedEvidence:
            "MDM enrollment evidence is malformed."
        case .conflictingEvidence:
            "MDM enrollment evidence conflicts."
        case .profileIdentityMismatch:
            "The installed MDM profile identity does not match the requested profile."
        case .enrollmentModeMismatch:
            "The observed MDM enrollment mode does not match the requested mode."
        }
    }
}

/// The safe, structured evidence accepted by the MDM enrollment transaction.
/// No raw command output or mobileconfig contents cross this boundary.
struct MDMEnrollmentEvidence: Codable, Equatable, Sendable {
    let expectedProfile: MDMEnrollmentProfileIdentity
    let installedProfile: MDMInstalledProfileIdentity
    let enrollmentStatus: MDMEnrollmentStatus
    let deviceSupervision: MDMDeviceSupervision
    let mode: MDMEnrollmentMode

    var profileIdentity: MDMInstalledProfileIdentity { installedProfile }
    var enrollment: MDMEnrollmentStatus { enrollmentStatus }
    var supervision: MDMDeviceSupervision { deviceSupervision }
    var isMDMEnrolled: Bool { enrollmentStatus.enrolled }
    var isUserApproved: Bool { enrollmentStatus.userApproved }
    var isSupervised: Bool { deviceSupervision.isSupervised }

    /// A supervised observation is never silently downgraded to an
    /// unapproved result, and a missing approval marker or supervision proof
    /// is never upgraded to supervised evidence. An unapproved result is exact:
    /// both User Approved MDM and device supervision must be false.
    var observedMode: MDMEnrollmentMode? {
        if enrollmentStatus.userApproved && deviceSupervision.isSupervised {
            return .supervised
        }
        if !enrollmentStatus.userApproved && !deviceSupervision.isSupervised {
            return .unapproved
        }
        return nil
    }

    init(
        expectedProfile: MDMEnrollmentProfileIdentity,
        installedProfile: MDMInstalledProfileIdentity,
        enrollmentStatus: MDMEnrollmentStatus,
        deviceSupervision: MDMDeviceSupervision,
        mode: MDMEnrollmentMode
    ) {
        self.expectedProfile = expectedProfile
        self.installedProfile = installedProfile
        self.enrollmentStatus = enrollmentStatus
        self.deviceSupervision = deviceSupervision
        self.mode = mode
    }
}

/// Pure parsers and the final evidence gate for native MDM command receipts.
enum MDMEnrollmentEvidenceParser {
    private static let maximumProfileBytes = 16 * 1024 * 1024
    private static let maximumCommandBytes = 16 * 1024 * 1024
    private static let maximumStatusBytes = 64 * 1024
    private static let maximumStringBytes = 4 * 1024
    private static let maximumReportedProfiles = 4_096

    // MARK: Source profile

    /// Parses a source enrollment mobileconfig into a safe identity.
    static func parseProfileIdentity(fromMobileconfig data: Data) throws -> MDMEnrollmentProfileIdentity {
        guard data.count <= maximumProfileBytes, !data.isEmpty else {
            throw data.isEmpty ? MDMEnrollmentEvidenceError.missingEvidence : .malformedEvidence
        }
        let root = try propertyListDictionary(data, maximumBytes: maximumProfileBytes)
        let identity = try profileIdentity(from: root)
        return .init(
            identifier: identity.identifier,
            uuid: identity.uuid,
            serverURL: identity.serverURL,
            digest: digest(of: data)
        )
    }

    // MARK: Installed profile

    /// Parses only the device-level (`_computerlevel`) profiles emitted by
    /// `profiles show -output stdout-xml`. User-level profiles are ignored.
    static func parseInstalledProfileIdentity(fromProfilesShow data: Data) throws -> MDMInstalledProfileIdentity {
        guard data.count <= maximumCommandBytes, !data.isEmpty else {
            throw data.isEmpty ? MDMEnrollmentEvidenceError.missingEvidence : .malformedEvidence
        }
        let root = try propertyListDictionary(data, maximumBytes: maximumCommandBytes, requiredFormat: .xml)
        let profileKeys = ["_computerlevel", "_computerLevel"].filter { root[$0] != nil }
        guard profileKeys.count == 1 else {
            throw profileKeys.isEmpty
                ? MDMEnrollmentEvidenceError.missingEvidence
                : MDMEnrollmentEvidenceError.conflictingEvidence
        }
        guard let rawProfiles = root[profileKeys[0]] else {
            throw MDMEnrollmentEvidenceError.missingEvidence
        }
        guard let profiles = rawProfiles as? [Any] else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }

        var candidate: MDMInstalledProfileIdentity?
        for rawProfile in profiles {
            guard let profile = rawProfile as? [String: Any] else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
            let identity = try installedIdentity(profile: profile)
            guard let identity else { continue }
            guard candidate == nil else {
                throw MDMEnrollmentEvidenceError.conflictingEvidence
            }
            candidate = identity
        }
        guard let candidate else { throw MDMEnrollmentEvidenceError.missingEvidence }
        return candidate
    }

    // MARK: Enrollment status

    /// Parses the line-oriented output of `profiles status -type enrollment`.
    /// The native output may report approval inline as
    /// `MDM enrollment: Yes (User Approved)`. Absence of that marker is a
    /// valid, explicit unapproved result when enrollment itself is `Yes`.
    static func parseEnrollmentStatus(fromProfilesStatus data: Data) throws -> MDMEnrollmentStatus {
        guard data.count <= maximumStatusBytes, !data.isEmpty else {
            throw data.isEmpty ? MDMEnrollmentEvidenceError.missingEvidence : .malformedEvidence
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        return try parseEnrollmentStatusText(text)
    }

    private static func parseEnrollmentStatusText(_ text: String) throws -> MDMEnrollmentStatus {
        guard text.utf8.count <= maximumStatusBytes, !text.contains("\0") else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }

        var enrolled: Bool?
        var userApproved: Bool?
        var serverURL: String?
        var enrolledViaDEP: Bool?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lowercased = line.lowercased()

            if lowercased.hasPrefix("enrolled via dep:") {
                let value = String(line.dropFirst("Enrolled via DEP:".count))
                let parsed = try booleanStatusValue(value)
                try assign(&enrolledViaDEP, parsed)
            } else if lowercased.hasPrefix("mdm enrollment:") {
                let value = String(line.dropFirst("MDM enrollment:".count))
                let parsed = try enrollmentValue(value)
                try assign(&enrolled, parsed.enrolled)
                if let inlineApproval = parsed.userApproved {
                    try assign(&userApproved, inlineApproval)
                }
            } else if lowercased.hasPrefix("mdm server:") {
                let value = String(line.dropFirst("MDM server:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let validated = try validServerURL(value)
                try assign(&serverURL, validated)
            } else if lowercased.hasPrefix("user approved mdm:") {
                let value = String(line.dropFirst("User Approved MDM:".count))
                try assign(&userApproved, booleanStatusValue(value))
            } else if lowercased.hasPrefix("user approved:") {
                let value = String(line.dropFirst("User Approved:".count))
                try assign(&userApproved, booleanStatusValue(value))
            } else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
        }

        guard let enrolled else { throw MDMEnrollmentEvidenceError.missingEvidence }
        let approved = userApproved ?? false
        if enrolled {
            guard serverURL != nil else { throw MDMEnrollmentEvidenceError.missingEvidence }
        } else {
            guard serverURL == nil, !approved else {
                throw MDMEnrollmentEvidenceError.conflictingEvidence
            }
        }
        return .init(
            enrolled: enrolled,
            userApproved: approved,
            serverURL: serverURL,
            enrolledViaDEP: enrolledViaDEP
        )
    }

    // MARK: Supervision

    /// Parses the structured stdout of `mdmclient QueryDeviceInformation`.
    /// macOS emits an OpenStep dictionary on supported systems; XML plist is
    /// also accepted for releases/configurations that use that formatter.
    static func parseDeviceSupervision(fromMDMClient data: Data) throws -> MDMDeviceSupervision {
        guard data.count <= maximumCommandBytes, !data.isEmpty else {
            throw data.isEmpty ? MDMEnrollmentEvidenceError.missingEvidence : .malformedEvidence
        }
        let payload = try mdmClientPayload(from: data)
        let root = try propertyListDictionary(payload, maximumBytes: maximumCommandBytes)
        var observations: [Bool] = []
        var malformed = false
        collectSupervision(from: root, into: &observations, malformed: &malformed)
        guard !malformed else { throw MDMEnrollmentEvidenceError.malformedEvidence }
        guard !observations.isEmpty else { throw MDMEnrollmentEvidenceError.missingEvidence }
        guard Set(observations).count == 1, let value = observations.first else {
            throw MDMEnrollmentEvidenceError.conflictingEvidence
        }
        return .init(isSupervised: value)
    }

    // MARK: Aggregate gate

    static func parse(
        mobileconfig: Data,
        profilesShow: Data,
        profilesStatus: Data,
        queryDeviceInformation: Data,
        mode: MDMEnrollmentMode = .defaultMode
    ) throws -> MDMEnrollmentEvidence {
        let expected = try parseProfileIdentity(fromMobileconfig: mobileconfig)
        let installed = try parseInstalledProfileIdentity(fromProfilesShow: profilesShow)
        guard installed.matches(expected) else {
            throw MDMEnrollmentEvidenceError.profileIdentityMismatch
        }

        let enrollment = try parseEnrollmentStatus(fromProfilesStatus: profilesStatus)
        guard enrollment.enrolled,
              enrollment.serverURL == installed.serverURL else {
            throw enrollment.enrolled
                ? MDMEnrollmentEvidenceError.conflictingEvidence
                : MDMEnrollmentEvidenceError.missingEvidence
        }
        let supervision = try parseDeviceSupervision(fromMDMClient: queryDeviceInformation)

        switch mode {
        case .supervised:
            guard enrollment.userApproved, supervision.isSupervised else {
                throw MDMEnrollmentEvidenceError.enrollmentModeMismatch
            }
        case .unapproved:
            guard !enrollment.userApproved, !supervision.isSupervised else {
                throw MDMEnrollmentEvidenceError.enrollmentModeMismatch
            }
        }

        return .init(
            expectedProfile: expected,
            installedProfile: installed,
            enrollmentStatus: enrollment,
            deviceSupervision: supervision,
            mode: mode
        )
    }

    static func verify(
        mobileconfig: Data,
        profilesShow: Data,
        profilesStatus: Data,
        queryDeviceInformation: Data,
        mode: MDMEnrollmentMode = .defaultMode
    ) -> Bool {
        (try? parse(
            mobileconfig: mobileconfig,
            profilesShow: profilesShow,
            profilesStatus: profilesStatus,
            queryDeviceInformation: queryDeviceInformation,
            mode: mode
        )) != nil
    }

    // MARK: Private parsing helpers

    /// Parses the endpoints and certificate payloads that decide whether the
    /// guest can trust the MDM server. PKCS#12 and every other payload type
    /// are ignored; certificate payloads must decode as certificates.
    static func parseTrustMaterial(fromMobileconfig data: Data) throws -> MDMProfileTrustMaterial {
        let root = try propertyListDictionary(data, maximumBytes: maximumProfileBytes)
        let serverURL = try profileIdentity(from: root).serverURL
        let payloads = root["PayloadContent"] as? [[String: Any]] ?? []
        let mdm = payloads.first { $0["PayloadType"] as? String == "com.apple.mdm" }
        let checkInURL = try (mdm?["CheckInURL"] as? String).map(validServerURL)
        var certificates: [Data] = []
        for payload in payloads {
            guard let type = payload["PayloadType"] as? String,
                  MDMProfileTrustMaterial.certificatePayloadTypes.contains(type) else { continue }
            guard let content = payload["PayloadContent"] as? Data,
                  let decoded = MDMProfileTrustMaterial.certificates(fromPayloadContent: content) else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
            certificates.append(contentsOf: decoded)
            guard certificates.count <= MDMProfileTrustMaterial.maximumCertificates else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
        }
        guard let server = URL(string: serverURL) else { throw MDMEnrollmentEvidenceError.malformedEvidence }
        return .init(serverURL: server, checkInURL: checkInURL.flatMap(URL.init(string:)), certificates: certificates)
    }

    private static func profileIdentity(from profile: [String: Any]) throws -> (identifier: String, uuid: UUID, serverURL: String) {
        guard let identifier = profile["PayloadIdentifier"] as? String,
              let uuidValue = profile["PayloadUUID"] as? String,
              let uuid = canonicalUUID(uuidValue),
              let rawPayloads = profile["PayloadContent"],
              let payloads = rawPayloads as? [Any] else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        var mdmPayloads: [[String: Any]] = []
        for rawPayload in payloads {
            guard let payload = rawPayload as? [String: Any] else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
            if payload["PayloadType"] as? String == "com.apple.mdm" {
                mdmPayloads.append(payload)
            }
        }
        guard mdmPayloads.count == 1 else {
            throw mdmPayloads.isEmpty
                ? MDMEnrollmentEvidenceError.missingEvidence
                : MDMEnrollmentEvidenceError.conflictingEvidence
        }
        guard let serverURL = mdmPayloads.first?["ServerURL"] as? String else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        return (try validIdentifier(identifier), uuid, try validServerURL(serverURL))
    }

    private static func installedIdentity(profile: [String: Any]) throws -> MDMInstalledProfileIdentity? {
        if profile["ProfileItems"] != nil {
            guard profile["ProfileType"] as? String == "Configuration",
                  let identifier = profile["ProfileIdentifier"] as? String,
                  let uuidValue = profile["ProfileUUID"] as? String,
                  let uuid = canonicalUUID(uuidValue),
                  let rawItems = profile["ProfileItems"] as? [Any] else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
            var mdmItems: [[String: Any]] = []
            for rawItem in rawItems {
                guard let item = rawItem as? [String: Any] else {
                    throw MDMEnrollmentEvidenceError.malformedEvidence
                }
                if item["PayloadType"] as? String == "com.apple.mdm" {
                    mdmItems.append(item)
                }
            }
            guard mdmItems.count <= 1 else {
                throw MDMEnrollmentEvidenceError.conflictingEvidence
            }
            guard let mdmItem = mdmItems.first else { return nil }
            guard let content = mdmItem["PayloadContent"] as? [String: Any],
                  let serverURL = content["ServerURL"] as? String else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
            return .init(
                identifier: try validIdentifier(identifier),
                uuid: uuid,
                serverURL: try validServerURL(serverURL)
            )
        }

        guard profile["PayloadType"] as? String == "Configuration",
              let rawPayloads = profile["PayloadContent"],
              let payloads = rawPayloads as? [Any] else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        var mdmPayloads: [[String: Any]] = []
        for rawPayload in payloads {
            guard let payload = rawPayload as? [String: Any] else {
                throw MDMEnrollmentEvidenceError.malformedEvidence
            }
            if payload["PayloadType"] as? String == "com.apple.mdm" {
                mdmPayloads.append(payload)
            }
        }
        guard mdmPayloads.count <= 1 else {
            throw MDMEnrollmentEvidenceError.conflictingEvidence
        }
        guard let mdmPayload = mdmPayloads.first else { return nil }
        let identity = try profileIdentity(from: profile.merging(["PayloadContent": [mdmPayload]]) { current, _ in current })
        return .init(identifier: identity.identifier, uuid: identity.uuid, serverURL: identity.serverURL)
    }

    private static func propertyListDictionary(
        _ data: Data,
        maximumBytes: Int,
        requiredFormat: PropertyListSerialization.PropertyListFormat? = nil
    ) throws -> [String: Any] {
        guard data.count <= maximumBytes, !data.isEmpty else {
            throw data.isEmpty ? MDMEnrollmentEvidenceError.missingEvidence : .malformedEvidence
        }
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ),
        let dictionary = object as? [String: Any],
        requiredFormat == nil || requiredFormat == format else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        return dictionary
    }

    private static func mdmClientPayload(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        guard let firstBrace = text.firstIndex(of: "{") else {
            return data
        }
        if text[..<firstBrace].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return data
        }
        guard let lastBrace = text.lastIndex(of: "}"), firstBrace <= lastBrace else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }

        let prefix = String(text[..<firstBrace])
        let suffix = String(text[text.index(after: lastBrace)...])
        let prefixLines = prefix.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let countPrefix = "Number of <Device> profiles found: "
        let countSuffix = " (Filtered: 0)"
        guard prefixLines.count == 3,
              prefixLines[0] == "=== CPF_GetInstalledProfiles === (<Device>)",
              prefixLines[1].hasPrefix(countPrefix),
              prefixLines[1].hasSuffix(countSuffix),
              !String(prefixLines[1].dropFirst(countPrefix.count).dropLast(countSuffix.count)).isEmpty,
              String(prefixLines[1].dropFirst(countPrefix.count).dropLast(countSuffix.count)).allSatisfy(\.isNumber),
              let reportedCount = UInt64(String(prefixLines[1].dropFirst(countPrefix.count).dropLast(countSuffix.count))),
              reportedCount <= UInt64(maximumReportedProfiles),
              prefixLines[2] == "Daemon response: ",
              (suffix == "\nAgent response: (null)\n" || suffix == "\nAgent response: (null)") else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        return Data(text[firstBrace...lastBrace].utf8)
    }

    private static func collectSupervision(
        from dictionary: [String: Any],
        into observations: inout [Bool],
        malformed: inout Bool
    ) {
        for (key, value) in dictionary {
            if key == "IsSupervised" || key == "Supervised" {
                if let parsed = strictBoolean(value) {
                    observations.append(parsed)
                } else {
                    malformed = true
                }
            } else if let nested = value as? [String: Any],
                      key == "DeviceInformation" || key == "Device" || key == "QueryResponses" {
                collectSupervision(from: nested, into: &observations, malformed: &malformed)
            }
        }
    }

    private static func strictBoolean(_ value: Any) -> Bool? {
        if let value = value as? String {
            switch value {
            case "0": return false
            case "1": return true
            default: return nil
            }
        }
        guard let number = value as? NSNumber else { return nil }
        guard number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { return nil }
        guard number.intValue == 0 || number.intValue == 1 else { return nil }
        return number.intValue == 1
    }

    private static func booleanStatusValue(_ raw: String) throws -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: throw MDMEnrollmentEvidenceError.malformedEvidence
        }
    }

    private static func enrollmentValue(_ raw: String) throws -> (enrolled: Bool, userApproved: Bool?) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "yes":
            return (true, nil)
        case "no":
            return (false, nil)
        case "yes (user approved)", "yes (user approved mdm)", "yes (user-approved)", "yes (user-approved mdm)":
            return (true, true)
        default:
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
    }

    private static func assign<T: Equatable>(_ value: inout T?, _ newValue: T) throws {
        if let value, value != newValue {
            throw MDMEnrollmentEvidenceError.conflictingEvidence
        }
        value = newValue
    }

    private static func validIdentifier(_ value: String) throws -> String {
        guard value.utf8.count <= maximumStringBytes,
              !value.isEmpty,
              !value.contains("\0"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        return value
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard value.utf8.count <= maximumStringBytes,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame else {
            return nil
        }
        return uuid
    }

    private static func validServerURL(_ value: String) throws -> String {
        guard value.utf8.count <= maximumStringBytes,
              !value.isEmpty,
              !value.contains("\0"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 }),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw MDMEnrollmentEvidenceError.malformedEvidence
        }
        return value
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
