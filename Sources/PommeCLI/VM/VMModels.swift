import Foundation

struct VMSizeOptions: Sendable {
    var memorySizeBytes: UInt64
    var diskSizeBytes: UInt64
    static let `default` = VMSizeOptions(memorySizeBytes: Constants.defaultMemorySizeBytes, diskSizeBytes: Constants.defaultDiskSizeBytes)
}

struct VMReference: Sendable {
    let name: String?
    let bundle: BundleLayout
    var displayName: String { name ?? bundle.rootURL.path }
    var standardizedPath: String { bundle.rootURL.standardizedFileURL.path }
}

/// Host-owned identity of a running Pomme helper. The socket, PID, and start
/// time are kept together so a stale record cannot reuse a new helper's cache.
struct PommeRuntimeRecord: Codable, Sendable {
    var id: String
    var name: String?
    var bundlePath: String
    var socketPath: String
    var pid: Int32
    var startedAt: String
}

struct PommeRunningVM: Sendable {
    let reference: VMReference
    let pid: Int32
    let startedAt: String
    let socketPath: String
}

enum PommeAgentPort {
    static let persistentNormal: UInt32 = 505_051
    static let recoveryBootstrap: UInt32 = 505_052
    static let recoveryRuntime: UInt32 = 505_053
}

/// A closed status payload reported beneath `guestAgent` for both status and
/// inspect. No connection-channel detail is exposed.
struct GuestAgentStatusV1: Codable, Equatable, Sendable {
    enum ConnectionState: String, Codable, Sendable { case disconnected, connecting, connected, unavailable, failed }
    enum Role: String, Codable, Sendable { case normal, recovery }
    enum UpdateState: String, Codable, Sendable { case unknown, current, updating, required, failed, unavailable }

    let connection: ConnectionState
    let role: Role
    let protocolVersion: Int?
    let executableDigest: String?
    let capabilities: [String]
    let updateState: UpdateState

    static func offline(role: Role) -> Self {
        .init(connection: .disconnected, role: role, protocolVersion: nil, executableDigest: nil, capabilities: [], updateState: .unavailable)
    }

    static func described(_ value: JSONValue, role: Role) -> Self? {
        guard let object = value.objectValue,
              case .integer(let rawVersion)? = object["version"],
              let digest = object["executableSHA256"]?.stringValue,
              case .array(let rawCapabilities)? = object["capabilities"]
        else { return nil }
        let capabilities = rawCapabilities.compactMap(\.stringValue)
        guard capabilities.count == rawCapabilities.count,
              rawVersion >= 1, rawVersion <= Int64(Int.max)
        else { return nil }
        let updateState = object["updateState"]?.stringValue.flatMap(UpdateState.init(rawValue:)) ?? .unknown
        return .init(connection: .connected, role: role, protocolVersion: Int(rawVersion), executableDigest: digest, capabilities: capabilities, updateState: updateState)
    }
}

struct PommeVMListEntry: Sendable {
    let reference: VMReference
    let running: Bool
    let vmState: String
    let bootMode: String?
    let guestAgent: GuestAgentStatusV1
    let socketPath: String
}

struct ByteSizeParser {
    static func parse(_ rawValue: String) -> UInt64? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var number = ""
        var suffix = ""
        var decimal = false
        var readingSuffix = false
        for character in value {
            if !readingSuffix, character.isNumber { number.append(character) }
            else if !readingSuffix, character == ".", !decimal { decimal = true; number.append(character) }
            else { readingSuffix = true; if !character.isWhitespace { suffix.append(character) } }
        }
        guard let parsed = Double(number), parsed > 0 else { return nil }
        let factor: UInt64
        switch suffix.lowercased() {
        case "", "b", "byte", "bytes": factor = 1
        case "k", "kb", "kib": factor = 1_024
        case "m", "mb", "mib": factor = 1_024 * 1_024
        case "g", "gb", "gib": factor = 1_024 * 1_024 * 1_024
        case "t", "tb", "tib": factor = 1_024 * 1_024 * 1_024 * 1_024
        default: return nil
        }
        let bytes = parsed * Double(factor)
        guard bytes.isFinite, bytes >= 1, bytes <= Double(UInt64.max) else { return nil }
        return UInt64(bytes.rounded(.down))
    }
}

struct BundleLayout: Sendable {
    let rootURL: URL
    var diskImageURL: URL { rootURL.appendingPathComponent("Disk.img") }
    var auxiliaryStorageURL: URL { rootURL.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModelURL: URL { rootURL.appendingPathComponent("HardwareModel") }
    var machineIdentifierURL: URL { rootURL.appendingPathComponent("MachineIdentifier") }
    var metadataURL: URL { rootURL.appendingPathComponent("Metadata.json") }
    var securityStateURL: URL { rootURL.appendingPathComponent("SecurityState.json") }
    var helperLogURL: URL { rootURL.appendingPathComponent("pomme-helper.log") }
    var saveStateURL: URL { rootURL.appendingPathComponent("SaveFile.vzvmsave") }
    var snapshotsURL: URL { rootURL.appendingPathComponent("Snapshots", isDirectory: true) }
    var requiredSnapshotRestoreURL: URL { rootURL.appendingPathComponent("SnapshotRestore.required") }
    var pommeSocketURL: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pomme-\(stableIdentifier(for: rootURL.standardizedFileURL.path)).sock") }

    func createFreshDirectory() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) { try FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func createDiskImage(size: UInt64) throws {
        FileManager.default.createFile(atPath: diskImageURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: diskImageURL)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    func validateForRun() throws {
        for url in [diskImageURL, auxiliaryStorageURL, hardwareModelURL, machineIdentifierURL] where !FileManager.default.fileExists(atPath: url.path) {
            throw RunnerError.missingBundleFile(url.lastPathComponent)
        }
    }
}
