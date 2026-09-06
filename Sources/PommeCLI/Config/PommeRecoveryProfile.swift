import CryptoKit
import Foundation

/// Recovery environments that Pomme can place into a durable agent plan. The
/// descriptor is data, so UIAutomation can select the matching state machine
/// without accepting raw version text at its boundary. An experimental
/// descriptor permits a bounded attempt without claiming that the identity has
/// been reviewed or qualified.
struct PommeCreateRecoveryProfileDescriptor: Codable, Equatable, Sendable {
    enum Qualification: String, Codable, Equatable, Sendable {
        case accepted
        case externallyPending
        case experimental
    }

    let id: String
    let version: String
    let build: String
    let locale: String
    let displayWidth: Int
    let displayHeight: Int
    let qualification: Qualification

    var digest: String {
        let canonical = [
            id, version, build, locale, String(displayWidth), String(displayHeight), qualification.rawValue
        ].joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Immutable identity that creation passes to the agent journal owner. It is
/// deliberately separate from mutable IPSW metadata and includes the exact
/// selected profile digest.
struct PommeCreateAgentPlanRequest: Codable, Equatable, Sendable {
    let recoveryProfileID: String
    let recoveryProfileDigest: String

    init(profile: PommeCreateRecoveryProfileDescriptor) {
        recoveryProfileID = profile.id
        recoveryProfileDigest = profile.digest
    }
}

enum PommeRecoveryProfileSelectionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedRestoreIdentity(version: String, build: String)
    case externallyPending(profileID: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRestoreIdentity(let version, let build):
            "Pomme does not accept Recovery automation for macOS \(version) (\(build))."
        case .externallyPending(let profileID):
            "Recovery profile \(profileID) is pending external release acceptance."
        }
    }
}

/// The sole Recovery profile selector. Firmware planning and the
/// UIAutomation evidence gate both extend this namespace; callers cannot
/// accidentally choose from two competing profile registries.
enum PommeRecoveryProfileSelector {
    static let tahoe2660Build25G72 = PommeCreateRecoveryProfileDescriptor(
        id: "tahoe-26.6.0-25G72-en-1280x800",
        version: "26.6.0",
        build: "25G72",
        locale: "en",
        displayWidth: 1280,
        displayHeight: 800,
        qualification: .accepted
    )

    static let sequoia1561Build24G90 = PommeCreateRecoveryProfileDescriptor(
        id: "sequoia-15.6.1-24G90-en-1280x800",
        version: "15.6.1",
        build: "24G90",
        locale: "en",
        displayWidth: 1280,
        displayHeight: 800,
        qualification: .externallyPending
    )

    static func descriptor(version: String, build: String) throws -> PommeCreateRecoveryProfileDescriptor {
        guard let normalizedVersion = normalizedVersion(version),
              let normalizedBuild = normalizedBuild(build)
        else {
            throw PommeRecoveryProfileSelectionError.unsupportedRestoreIdentity(
                version: version,
                build: build
            )
        }

        return switch (normalizedVersion, normalizedBuild) {
        case (tahoe2660Build25G72.version, tahoe2660Build25G72.build):
            tahoe2660Build25G72
        case (sequoia1561Build24G90.version, sequoia1561Build24G90.build):
            // Preserve the pending Sequoia identity and identifier while
            // allowing a caller to make a bounded experimental attempt. It
            // remains distinct from the accepted Tahoe descriptor.
            experimentalDescriptor(
                version: normalizedVersion,
                build: normalizedBuild,
                identifier: sequoia1561Build24G90.id
            )
        default:
            experimentalDescriptor(
                version: normalizedVersion,
                build: normalizedBuild,
                identifier: nil
            )
        }
    }

    static func descriptor(for firmware: IPSWMEFirmware) throws -> PommeCreateRecoveryProfileDescriptor {
        try descriptor(version: firmware.version, build: firmware.buildid)
    }

    static func select(for firmware: IPSWMEFirmware) throws -> PommeCreateRecoveryProfileDescriptor {
        try descriptor(for: firmware)
    }

    private static func experimentalDescriptor(
        version: String,
        build: String,
        identifier: String?
    ) -> PommeCreateRecoveryProfileDescriptor {
        PommeCreateRecoveryProfileDescriptor(
            id: identifier ?? ("experimental-" + version + "-" + build + "-en-1280x800"),
            version: version,
            build: build,
            locale: "en",
            displayWidth: 1280,
            displayHeight: 800,
            qualification: .experimental
        )
    }

    private static func normalizedVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              components.allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy(isASCIIDigit)
              })
        else { return nil }

        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count else { return nil }
        let canonical = numbers.map(String.init)
        return canonical.count == 2
            ? canonical.joined(separator: ".") + ".0"
            : canonical.joined(separator: ".")
    }

    private static func normalizedBuild(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)
        guard scalars.count >= 3 else { return nil }

        var index = 0
        while index < scalars.count, isASCIIDigit(scalars[index]) { index += 1 }
        guard index > 0 else { return nil }

        let lettersStart = index
        while index < scalars.count, isASCIIletter(scalars[index]) { index += 1 }
        guard index > lettersStart, index < scalars.count else { return nil }

        let digitsStart = index
        while index < scalars.count, isASCIIDigit(scalars[index]) { index += 1 }
        guard index > digitsStart else { return nil }

        // Apple build identifiers may carry a lowercase release suffix, for
        // example 25A5351b. Keep that suffix as observed while canonicalizing
        // the numeric and primary-letter portions.
        let suffixStart = index
        while index < scalars.count, isASCIILowercaseLetter(scalars[index]) { index += 1 }
        guard index == scalars.count else { return nil }

        let numericPrefix = String(String.UnicodeScalarView(scalars[..<lettersStart]))
        let primaryLetters = String(String.UnicodeScalarView(scalars[lettersStart..<digitsStart])).uppercased()
        let numericRevision = String(String.UnicodeScalarView(scalars[digitsStart..<suffixStart]))
        let suffix = String(String.UnicodeScalarView(scalars[suffixStart...]))
        return numericPrefix + primaryLetters + numericRevision + suffix
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
    }

    private static func isASCIIletter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isASCIILowercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }
}
