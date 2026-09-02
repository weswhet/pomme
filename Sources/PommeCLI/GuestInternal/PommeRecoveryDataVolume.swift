import Darwin
import Foundation

/// Closed Recovery-side selection of the guest's normal Data volume.  No
/// caller provides a device, mount path, or command; the expected APFS volume
/// group UUID is bound to the single System+Data pair reported by diskutil.
struct PommeRecoveryDataVolumeResolver: Sendable {
    struct Volume: Equatable, Sendable {
        let volumeGroupUUID: UUID
        let systemDevice: String
        let dataDevice: String
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case malformed, ambiguous, noMatch, unsafeDevice, unsafeMount, diskutilFailed(String, Int32)
    }

    typealias ProcessRunner = @Sendable (String, [String]) throws -> (status: Int32, stdout: Data)
    private let run: ProcessRunner

    init(run: @escaping ProcessRunner = Self.runDiskutil) { self.run = run }

    func resolve(expectedVolumeGroupUUID: UUID?) throws -> URL {
        try resolveSelection(expectedVolumeGroupUUID: expectedVolumeGroupUUID).root
    }

    func resolveSelection(
        expectedVolumeGroupUUID: UUID?
    ) throws -> (volume: Volume, root: URL) {
        let groups = try run("/usr/sbin/diskutil", ["apfs", "listVolumeGroups", "-plist"])
        guard groups.status == 0 else { throw Error.diskutilFailed("listVolumeGroups", groups.status) }
        let volume = try Self.resolveDataVolume(from: groups.stdout, expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let mount = try run("/usr/sbin/diskutil", ["mount", volume.dataDevice])
        guard mount.status == 0 else { throw Error.diskutilFailed("mount", mount.status) }
        let info = try run("/usr/sbin/diskutil", ["info", "-plist", volume.dataDevice])
        guard info.status == 0 else { throw Error.diskutilFailed("info", info.status) }
        let root = try Self.dataMountURL(from: info.stdout, expected: volume)
        var statInfo = stat()
        guard lstat(root.path, &statInfo) == 0,
              statInfo.st_mode & S_IFMT == S_IFDIR,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Error.unsafeMount }
        return (volume, root)
    }

    static func resolveDataVolume(from data: Data, expectedVolumeGroupUUID: UUID?) throws -> Volume {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { throw Error.malformed }
        var candidates: [Volume] = []
        for container in containers {
            for group in container["VolumeGroups"] as? [[String: Any]] ?? [] {
                guard let text = group["APFSVolumeGroupUUID"] as? String,
                      let uuid = UUID(uuidString: text),
                      expectedVolumeGroupUUID == nil || uuid == expectedVolumeGroupUUID,
                      let volumes = group["Volumes"] as? [[String: Any]] else { continue }
                let system = volumes.filter { hasRole("System", in: $0) }
                let data = volumes.filter { hasRole("Data", in: $0) }
                guard system.count == 1, data.count == 1,
                      let systemDevice = system[0]["DeviceIdentifier"] as? String,
                      let dataDevice = data[0]["DeviceIdentifier"] as? String else { continue }
                guard safeDevice(systemDevice), safeDevice(dataDevice) else { throw Error.unsafeDevice }
                candidates.append(.init(volumeGroupUUID: uuid, systemDevice: systemDevice, dataDevice: dataDevice))
            }
        }
        guard candidates.count == 1 else {
            throw candidates.isEmpty ? Error.noMatch : Error.ambiguous
        }
        return candidates[0]
    }

    static func dataMountURL(from data: Data, expected: Volume) throws -> URL {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["DeviceIdentifier"] as? String == expected.dataDevice,
              (root["FilesystemType"] as? String)?.caseInsensitiveCompare("apfs") == .orderedSame,
              let group = (root["APFSVolumeGroupID"] as? String) ?? (root["APFSVolumeGroupUUID"] as? String),
              UUID(uuidString: group) == expected.volumeGroupUUID,
              let mount = root["MountPoint"] as? String else { throw Error.malformed }
        let url = URL(fileURLWithPath: mount, isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix("/Volumes/"), url.path != "/Volumes", url.path != "/",
              URL(fileURLWithPath: mount).standardizedFileURL.path == url.path else { throw Error.unsafeMount }
        return url
    }

    private static func safeDevice(_ value: String) -> Bool {
        guard value.hasPrefix("disk") else { return false }
        let suffix = value.dropFirst(4)
        guard let split = suffix.firstIndex(of: "s") else { return false }
        return !suffix[..<split].isEmpty && suffix[..<split].allSatisfy(\.isNumber)
            && !suffix[suffix.index(after: split)...].isEmpty && suffix[suffix.index(after: split)...].allSatisfy(\.isNumber)
    }

    private static func hasRole(_ expected: String, in volume: [String: Any]) -> Bool {
        let roles: [String]
        if let values = volume["Roles"] as? [String] { roles = values }
        else if let value = volume["Role"] as? String { roles = [value] }
        else if let value = volume["APFSVolumeRole"] as? String { roles = [value] }
        else { return false }
        return roles.contains { $0.caseInsensitiveCompare(expected) == .orderedSame }
    }

    private static func runDiskutil(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
}
