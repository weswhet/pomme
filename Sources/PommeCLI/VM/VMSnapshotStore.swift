import CryptoKit
import Darwin
import Foundation

/// The public, UI-friendly description of an immutable local snapshot.
struct VMSnapshotRecord: Codable, Equatable, Sendable {
    let name: String
    let createdAt: Date
    let sourceState: String
    let drift: [String]
    let machineStateBytes: Int64
    let diskBytes: Int64
    let auxiliaryStorageBytes: Int64
}

struct VMSnapshotManifest: Codable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let record: VMSnapshotRecord
    let machineStateSHA256: String
    let vmUUID: String
    let configurationSHA256: String
    let hardwareModelSHA256: String
    let machineIdentifierSHA256: String
    let diskFingerprint: VMSnapshotExternalFingerprint
    let auxiliaryStorageFingerprint: VMSnapshotExternalFingerprint
    let createdOSVersion: String
}

/// Non-secret, bounded drift evidence for large mutable backing files.  This
/// deliberately avoids hashing sparse guest disks during snapshot operations.
struct VMSnapshotExternalFingerprint: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modifiedNanoseconds: Int64
}

/// Snapshot filesystem work is deliberately local to the VM bundle and treats
/// every name and control-wire stage identifier as untrusted input.
enum VMSnapshotStore {
    static let manifestName = "Manifest.json"
    static let machineStateName = "MachineState.vzvmsave"
    static let tombstonePrefix = ".pomme-snapshot-delete-"
    static let stagePrefix = ".pomme-snapshot-stage-"
    static let rollbackPrefix = ".pomme-snapshot-rollback-"

    static func snapshotName(_ value: String) throws -> String { try validateVMName(value) }

    static func snapshotURL(bundle: BundleLayout, name: String) throws -> URL {
        bundle.snapshotsURL.appendingPathComponent(try snapshotName(name), isDirectory: true)
    }

    static func stageURL(bundle: BundleLayout, name: String) throws -> URL {
        let id = try snapshotName(name)
        try ensureRoot(bundle.snapshotsURL)
        return bundle.snapshotsURL.appendingPathComponent("\(stagePrefix)\(id)-\(UUID().uuidString)", isDirectory: true)
    }

    static func machineStateURL(in directory: URL) -> URL {
        directory.appendingPathComponent(machineStateName)
    }

    static func list(bundle: BundleLayout) throws -> [VMSnapshotRecord] {
        guard FileManager.default.fileExists(atPath: bundle.snapshotsURL.path) else { return [] }
        try requireDirectory(bundle.snapshotsURL)
        return try FileManager.default.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url in
                guard let manifest = try? loadManifest(at: url, verifyingMachineState: false) else { return nil }
                let currentDrift = (try? drift(bundle: bundle, manifest: manifest)) ?? ["unreadable"]
                return VMSnapshotRecord(
                    name: manifest.record.name, createdAt: manifest.record.createdAt,
                    sourceState: manifest.record.sourceState, drift: currentDrift,
                    machineStateBytes: manifest.record.machineStateBytes,
                    diskBytes: manifest.record.diskBytes,
                    auxiliaryStorageBytes: manifest.record.auxiliaryStorageBytes
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func prepare(bundle: BundleLayout, name: String) throws -> URL {
        let final = try snapshotURL(bundle: bundle, name: name)
        guard !FileManager.default.fileExists(atPath: final.path) else {
            throw RunnerError.hostCommandFailed("Snapshot \(name) already exists.")
        }
        let stage = try stageURL(bundle: bundle, name: name)
        guard mkdir(stage.path, 0o700) == 0 else { throw RunnerError.posix(function: "create snapshot stage", code: errno) }
        return stage
    }

    static func prepareRollback(bundle: BundleLayout) throws -> URL {
        try ensureRoot(bundle.snapshotsURL)
        let stage = bundle.snapshotsURL.appendingPathComponent("\(rollbackPrefix)\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw RunnerError.posix(function: "create snapshot rollback stage", code: errno) }
        return stage
    }

    static func installRollbackMachineState(bundle: BundleLayout, stage: URL) throws {
        try installRequiredMachineState(machineStateURL(in: stage), bundle: bundle)
    }

    /// Resolves the only host path the helper may hand to Virtualization.framework.
    /// The wire carries a generated direct-child identifier, never an arbitrary path.
    static func writableMachineStateURL(bundle: BundleLayout, stageName: String) throws -> URL {
        guard stageName.count <= 256,
              stageName == URL(fileURLWithPath: stageName).lastPathComponent,
              stageName.hasPrefix(stagePrefix) || stageName.hasPrefix(rollbackPrefix)
        else {
            throw RunnerError.invalidControlCommand("snapshot-save")
        }
        try requireDirectory(bundle.snapshotsURL)
        let stage = bundle.snapshotsURL.appendingPathComponent(stageName, isDirectory: true)
        try requireDirectory(stage)
        guard stage.deletingLastPathComponent().standardizedFileURL == bundle.snapshotsURL.standardizedFileURL else {
            throw RunnerError.invalidControlCommand("snapshot-save")
        }
        let target = machineStateURL(in: stage)
        var value = stat()
        guard lstat(target.path, &value) != 0, errno == ENOENT else {
            throw RunnerError.invalidControlCommand("snapshot-save")
        }
        return target
    }

    static func complete(
        bundle: BundleLayout,
        name: String,
        stage: URL,
        sourceState: String
    ) throws -> VMSnapshotRecord {
        try requireDirectory(stage)
        let state = machineStateURL(in: stage)
        try requireRegularFile(state)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        let metadata = try metadataPayload(bundle: bundle)
        guard let uuid = vmUUID(from: metadata) else { throw RunnerError.hostCommandFailed("Snapshot requires a VM UUID.") }
        let record = VMSnapshotRecord(
            name: try snapshotName(name), createdAt: Date(), sourceState: sourceState, drift: [],
            machineStateBytes: byteCount(state), diskBytes: byteCount(bundle.diskImageURL),
            auxiliaryStorageBytes: byteCount(bundle.auxiliaryStorageURL)
        )
        let manifest = VMSnapshotManifest(
            schemaVersion: VMSnapshotManifest.schemaVersion, record: record, machineStateSHA256: try digest(state), vmUUID: uuid,
            configurationSHA256: try configurationDigest(bundle),
            hardwareModelSHA256: try digest(bundle.hardwareModelURL),
            machineIdentifierSHA256: try digest(bundle.machineIdentifierURL),
            diskFingerprint: try externalFingerprint(bundle.diskImageURL),
            auxiliaryStorageFingerprint: try externalFingerprint(bundle.auxiliaryStorageURL),
            createdOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        let data = try JSONEncoder.snapshot.encode(manifest)
        try data.write(to: stage.appendingPathComponent(manifestName), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(manifestName).path)
        try syncFile(state)
        try syncFile(stage.appendingPathComponent(manifestName))
        try syncDirectory(stage)
        let final = try snapshotURL(bundle: bundle, name: name)
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, final.path, UInt32(RENAME_EXCL)) == 0 else {
            throw RunnerError.posix(function: "publish snapshot", code: errno)
        }
        try syncDirectory(bundle.snapshotsURL)
        return record
    }

    static func manifest(bundle: BundleLayout, name: String) throws -> VMSnapshotManifest {
        try loadManifest(at: try snapshotURL(bundle: bundle, name: name), verifyingMachineState: true)
    }

    static func drift(bundle: BundleLayout, manifest: VMSnapshotManifest) throws -> [String] {
        var drift: [String] = []
        let metadata = try metadataPayload(bundle: bundle)
        if vmUUID(from: metadata) != manifest.vmUUID { drift.append("vmUUID") }
        if try configurationDigest(bundle) != manifest.configurationSHA256 { drift.append("configuration") }
        if try digest(bundle.hardwareModelURL) != manifest.hardwareModelSHA256 { drift.append("hardwareModel") }
        if try digest(bundle.machineIdentifierURL) != manifest.machineIdentifierSHA256 { drift.append("machineIdentifier") }
        if try externalFingerprint(bundle.diskImageURL) != manifest.diskFingerprint { drift.append("disk") }
        if try externalFingerprint(bundle.auxiliaryStorageURL) != manifest.auxiliaryStorageFingerprint { drift.append("auxiliaryStorage") }
        return drift
    }

    static func delete(bundle: BundleLayout, name: String) throws {
        let source = try snapshotURL(bundle: bundle, name: name)
        _ = try loadManifest(at: source, verifyingMachineState: false)
        let tombstone = bundle.snapshotsURL.appendingPathComponent("\(tombstonePrefix)\(UUID().uuidString)", isDirectory: true)
        guard rename(source.path, tombstone.path) == 0 else { throw RunnerError.posix(function: "tombstone snapshot", code: errno) }
        try syncDirectory(bundle.snapshotsURL)
        try FileManager.default.removeItem(at: tombstone)
        try syncDirectory(bundle.snapshotsURL)
    }

    static func installMachineState(bundle: BundleLayout, name: String) throws {
        let source = try snapshotURL(bundle: bundle, name: name).appendingPathComponent(machineStateName)
        try installRequiredMachineState(source, bundle: bundle)
    }

    private static func loadManifest(at snapshot: URL, verifyingMachineState: Bool) throws -> VMSnapshotManifest {
        try requireDirectory(snapshot)
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshot.path)
        guard Set(names) == Set([manifestName, machineStateName]) else {
            throw RunnerError.hostCommandFailed("Snapshot contains unexpected artifacts.")
        }
        let data = try Data(contentsOf: snapshot.appendingPathComponent(manifestName))
        let manifest = try JSONDecoder.snapshot.decode(VMSnapshotManifest.self, from: data)
        guard manifest.schemaVersion == VMSnapshotManifest.schemaVersion, manifest.record.name == snapshot.lastPathComponent else {
            throw RunnerError.hostCommandFailed("Snapshot manifest is incompatible or invalid.")
        }
        try requireRegularFile(snapshot.appendingPathComponent(manifestName))
        try requireRegularFile(machineStateURL(in: snapshot))
        if verifyingMachineState {
            guard byteCount(machineStateURL(in: snapshot)) == manifest.record.machineStateBytes else {
                throw RunnerError.hostCommandFailed("Snapshot machine state size does not match its manifest.")
            }
            if try digest(machineStateURL(in: snapshot)) != manifest.machineStateSHA256 {
                throw RunnerError.hostCommandFailed("Snapshot machine state checksum does not match its manifest.")
            }
        }
        return manifest
    }

    static func removeRequiredRestoreArtifacts(bundle: BundleLayout) throws {
        for url in [bundle.saveStateURL, bundle.requiredSnapshotRestoreURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try syncDirectory(bundle.rootURL)
    }

    private static func installRequiredMachineState(_ source: URL, bundle: BundleLayout) throws {
        guard !FileManager.default.fileExists(atPath: bundle.saveStateURL.path),
              !FileManager.default.fileExists(atPath: bundle.requiredSnapshotRestoreURL.path)
        else {
            throw RunnerError.virtualMachineState("A pending VM saved-state restore already exists.")
        }
        do {
            // Marker-first ordering is fail-closed: a partial installation can
            // never take a cold-start path after partial installation.
            try Data("required\n".utf8).write(to: bundle.requiredSnapshotRestoreURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.requiredSnapshotRestoreURL.path)
            try clone(source, to: bundle.saveStateURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.saveStateURL.path)
            try syncFile(bundle.requiredSnapshotRestoreURL)
            try syncFile(bundle.saveStateURL)
            try syncDirectory(bundle.rootURL)
        } catch {
            do {
                try removeRequiredRestoreArtifacts(bundle: bundle)
            } catch let cleanupError {
                throw RunnerError.virtualMachineState(
                    "Saved-state restore staging failed and cleanup could not be proven: \(error.localizedDescription); cleanup: \(cleanupError.localizedDescription)"
                )
            }
            throw error
        }
    }

    private static func ensureRoot(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try requireDirectory(url); return }
        guard mkdir(url.path, 0o700) == 0 else { throw RunnerError.posix(function: "create snapshot root", code: errno) }
    }

    private static func requireDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw RunnerError.hostCommandFailed("Unsafe snapshot directory \(url.lastPathComponent).")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            throw RunnerError.hostCommandFailed("Snapshot is missing a regular \(url.lastPathComponent) artifact.")
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        try requireRegularFile(source)
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let cloneError = errno
        guard cloneError == ENOTSUP || cloneError == EXDEV else { throw RunnerError.posix(function: "clone snapshot artifact", code: cloneError) }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RunnerError.posix(function: "open snapshot artifact for sync", code: errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RunnerError.posix(function: "sync snapshot artifact", code: errno) }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RunnerError.posix(function: "open snapshot directory for sync", code: errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RunnerError.posix(function: "sync snapshot directory", code: errno) }
    }

    private static func digest(_ url: URL) throws -> String {
        try requireRegularFile(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return digest(data)
    }

    /// Hash only inputs that shape the normal-boot VZ configuration. Metadata
    /// also contains mutable guest-agent bookkeeping that
    /// must not make an otherwise compatible saved state fail closed.
    private static func configurationDigest(_ bundle: BundleLayout) throws -> String {
        let metadata = try metadataPayload(bundle: bundle)
        let machineIdentifierData = try Data(contentsOf: bundle.machineIdentifierURL, options: .mappedIfSafe)
        return try configurationCompatibilityDigest(
            machineIdentifierData: machineIdentifierData,
            memorySize: uint64Value(metadata["memorySize"]) ?? Constants.defaultMemorySizeBytes
        )
    }

    static func configurationCompatibilityDigest(
        machineIdentifierData: Data,
        memorySize: UInt64
    ) throws -> String {
        let payload: [String: Any] = [
            "revision": 2,
            "memorySize": memorySize,
            "cpuPolicy": "host-bounded-four",
            "storageDevices": ["primary-virtio-block"],
            "display": "1280x800@80",
            "socketDevices": 1,
            "network": [
                "attachment": "nat",
                "device": "virtio",
                "macAddress": PommeCore.stableVMMACAddress(machineIdentifierData: machineIdentifierData)
            ]
        ]
        return digest(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func byteCount(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func externalFingerprint(_ url: URL) throws -> VMSnapshotExternalFingerprint {
        try requireRegularFile(url)
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw RunnerError.posix(function: "stat snapshot artifact", code: errno) }
        return .init(
            device: UInt64(value.st_dev), inode: UInt64(value.st_ino), byteCount: Int64(value.st_size),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)
        )
    }
}

private extension JSONEncoder {
    static var snapshot: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}

private extension JSONDecoder {
    static var snapshot: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
