import Foundation

enum Constants {
    static let appSupportDirectoryName = "pomme"
    static let vmDirectoryName = "VMs"
    static let configDirectoryName = "Configs"
    static let restoreImageDirectoryName = "RestoreImages"
    static let runtimeDirectoryName = "Runtime"
    static let vmNameEnvironmentVariable = "POMME_VM_NAME"
    static let defaultMemorySizeBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let defaultDiskSizeBytes: UInt64 = 60 * 1024 * 1024 * 1024
    static let pommeAgentPort: UInt32 = 505_051
    static let pommeRecoverySessionPort: UInt32 = 505_052
    static let pommeRecoveryRuntimePort: UInt32 = 505_053
    static let defaultRecoveryAgentTimeout: TimeInterval = 300
    static let defaultSIPBootstrapUser = "pommesip"
    static let defaultSIPBootstrapFullName = "Pomme SIP Admin"
    /// All host credentials use this one UUID-scoped Keychain service namespace.
    /// Operation-specific purpose belongs in the account and metadata, not in a
    /// second service prefix that would make lookup ambiguous.
    static let credentialServicePrefix = "com.github.weswhet.pomme.vm"
    static let vmUUIDMetadataKey = "vmUUID"
    static let credentialStoreMetadataKey = "credentialStore"
    static let guestKCPasswordCredentialStore = "guestKCPassword"
    static let guestKCPasswordUserMetadataKey = "guestKCPasswordUser"
    static let gracefulStopTimeoutSeconds: TimeInterval = 30
    /// How long a normal-booted guest gets to power itself down after the
    /// framework's stop request. macOS can spend a minute on its shutdown
    /// confirmation alone, and cutting power before it finishes risks leaving
    /// the guest's boot state unusable. recoveryOS never acts on the request
    /// and holds no user data, so a Recovery stop keeps the shorter window.
    static let guestShutdownTimeoutSeconds: TimeInterval = 120
    /// How long a VM resumed only so it can be shut down cleanly gets to
    /// report its agent usable again before the ordinary stop takes over.
    static let resumedGuestAgentReadyTimeoutSeconds: TimeInterval = 15
    static let defaultGuestCommandTimeout: TimeInterval = 60
    static let defaultSIPTimeout: TimeInterval = 300
    static let agentRoundTripTimeout: TimeInterval = 5
    static let agentTransferTimeout: TimeInterval = 3600
}

extension Date {
    var pommeISO8601String: String {
        formatted(.iso8601)
    }

    var pommeFileTimestamp: String {
        pommeISO8601String.replacingOccurrences(of: ":", with: "-")
    }
}

extension UInt8 {
    var twoDigitHexString: String {
        let hex = String(self, radix: 16)
        return hex.count == 1 ? "0\(hex)" : hex
    }
}

func lowercaseHexString(_ value: UInt64, width: Int) -> String {
    let hex = String(value, radix: 16)
    let padding = max(0, width - hex.count)
    return String(repeating: "0", count: padding) + hex
}
