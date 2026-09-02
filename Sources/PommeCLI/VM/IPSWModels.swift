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

