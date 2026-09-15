import Foundation
import ArgumentParser
@preconcurrency import AppKit
import Security
// Virtualization reference types are confined to their documented serial VM queue below.
// Remove this when the SDK models these queue-confined APIs with Sendable-aware annotations.
@preconcurrency import Virtualization
import Darwin

struct IPSWMEDeviceResponse: Codable {
    let name: String
    let identifier: String
    let firmwares: [IPSWMEFirmware]
}

struct IPSWMEFirmware: Codable {
    let identifier: String
    let version: String
    let buildid: String
    let filesize: Int64?
    let url: String
    let releasedate: String?
    let uploaddate: String?
    let signed: Bool?
    let sha1sum: String?
    let md5sum: String?
    let sha256sum: String?

    var displayName: String {
        "\(version) (\(buildid))"
    }
}

/// Shape check for Apple model identifiers such as `Mac16,10` or
/// `VirtualMac2,1`, so a typo is named before any catalog request.
enum IPSWDeviceIdentifier {
    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z]+[0-9]+,[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Throws a `ValidationError` naming `flag` when `value` is present and malformed.
    static func validate(_ value: String?, flag: String) throws {
        guard let value, !isValid(value) else { return }
        throw ValidationError("\(flag) must be an Apple model identifier such as Mac16,10.")
    }
}
