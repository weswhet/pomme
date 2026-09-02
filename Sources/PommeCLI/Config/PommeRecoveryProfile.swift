import CryptoKit
import Foundation

/// Closed Recovery environments that Pomme can place into a durable agent
/// plan. The descriptor is data, so UIAutomation can select the matching
/// state machine without accepting raw version text at its boundary.
struct PommeCreateRecoveryProfileDescriptor: Codable, Equatable, Sendable {
    enum Qualification: String, Codable, Equatable, Sendable {
        case accepted
        case externallyPending
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
        switch (version, build) {
        case (tahoe2660Build25G72.version, tahoe2660Build25G72.build),
             ("26.6", tahoe2660Build25G72.build):
            tahoe2660Build25G72
        case (sequoia1561Build24G90.version, sequoia1561Build24G90.build):
            sequoia1561Build24G90
        default:
            throw PommeRecoveryProfileSelectionError.unsupportedRestoreIdentity(
                version: version,
                build: build
            )
        }
    }

    static func descriptor(for firmware: IPSWMEFirmware) throws -> PommeCreateRecoveryProfileDescriptor {
        try descriptor(version: firmware.version, build: firmware.buildid)
    }

    static func select(for firmware: IPSWMEFirmware) throws -> PommeCreateRecoveryProfileDescriptor {
        let descriptor = try descriptor(for: firmware)
        guard descriptor.qualification == .accepted else {
            throw PommeRecoveryProfileSelectionError.externallyPending(profileID: descriptor.id)
        }
        return descriptor
    }
}
