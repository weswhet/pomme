import ArgumentParser
import Foundation

/// Direct (non-config) VM creation shared by `pomme create` and the
/// create-if-missing step of `pomme mdm`.
struct PommeCreationRequest: Equatable, Sendable {
    static let defaultDiskSize = "60GB"
    static let defaultMemory = "8GB"

    enum Source: Equatable, Sendable {
        case template(String)
        /// A version, build, or `latest`, resolved against the IPSW catalog.
        case version(String, ipswDevice: String?)
        case restoreImage(String)
    }

    let source: Source
    let diskSize: String
    let memory: String
    let boot: CLIBootMode

    /// Option rules for a direct create. `version` is already `latest` when
    /// `--latest` was given.
    static func validate(
        version: String?, restoreImage: String?, fromTemplate: String?, ipswDevice: String?,
        diskSize: String, memory: String
    ) throws {
        if fromTemplate != nil, version != nil || restoreImage != nil || ipswDevice != nil {
            throw ValidationError("--from-template cannot be combined with --version, --latest, --restore-image, or --ipsw-device.")
        }
        if version != nil, restoreImage != nil {
            throw ValidationError("Choose either --version or --restore-image.")
        }
        if let restoreImage, restoreImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--restore-image requires a file path.")
        }
        if restoreImage != nil, ipswDevice != nil {
            throw ValidationError("--ipsw-device is available only with --version.")
        }
        try IPSWDeviceIdentifier.validate(ipswDevice, flag: "--ipsw-device")
        for (flag, value) in [("--disk-size", diskSize), ("--memory", memory)] {
            guard let bytes = ByteSizeParser.parse(value), bytes > 0 else {
                throw ValidationError("\(flag) requires a valid size greater than zero.")
            }
        }
    }

    /// The validated source, or nil when none was given.
    static func source(
        version: String?, restoreImage: String?, fromTemplate: String?, ipswDevice: String?
    ) -> Source? {
        if let fromTemplate { return .template(fromTemplate) }
        if let version { return .version(version, ipswDevice: ipswDevice) }
        if let restoreImage { return .restoreImage(restoreImage) }
        return nil
    }

    /// Resolves the source exactly as `pomme create` does and creates the VM.
    /// An inherited lease keeps a longer workflow's exclusive hold.
    func create(name: String, lease: VMBundleMutationLease? = nil) async throws -> PommeOperationResult {
        try PommeCore.validateProvisionalMemoryFloor(ByteSizeParser.parse(memory) ?? 0)
        let restoreArguments: [String]
        var resolvedDiskSize = diskSize
        switch source {
        case .template(let name):
            let manifest = try Self.templateManifest(name, diskSize: diskSize)
            restoreArguments = ["--from-template", manifest.name]
            resolvedDiskSize = "\(manifest.diskSizeBytes / (1 << 20))MB"
        case .version(let selection, let device):
            let firmware = try await PommeCore.resolveIPSWFirmware(selection: selection, deviceIdentifier: device)
            Self.warnIfExperimental(try PommeRecoveryProfileSelector.select(for: firmware),
                                    version: firmware.version, build: firmware.buildid, vmName: name)
            restoreArguments = ["--version", firmware.buildid] + (device.map { ["--ipsw-device", $0] } ?? [])
        case .restoreImage(let path):
            restoreArguments = ["--restore-image", path]
        }
        return try await PommeApplication.create(
            name: name, restoreArgs: restoreArguments, diskSize: resolvedDiskSize, memory: memory,
            startMode: boot.startMode, lease: lease
        )
    }

    /// A host-only check of the source, without resolving a version over
    /// the network: a named template must exist and fit the requested disk
    /// size, and a restore image must be a readable file.
    var hostProblem: String? {
        switch source {
        case .template(let name):
            do { _ = try Self.templateManifest(name, diskSize: diskSize) } catch { return error.localizedDescription }
        case .restoreImage(let path):
            let absolute = PommeCore.absoluteHostPath(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: absolute) else {
                return "The restore image \(path) is not a readable file."
            }
        case .version:
            break
        }
        return nil
    }

    /// Template creates inherit the template's disk size. An explicit size
    /// other than the default must match it, because the cloned image already
    /// carries its APFS container geometry.
    static func templateManifest(_ name: String, diskSize: String) throws -> PommeTemplateManifest {
        let manifest = try PommeTemplateStore.manifest(for: name)
        if diskSize != defaultDiskSize, ByteSizeParser.parse(diskSize) != manifest.diskSizeBytes {
            throw PommeTemplateError.diskSizeMismatch(
                template: manifest.diskSizeBytes,
                requested: ByteSizeParser.parse(diskSize) ?? 0
            )
        }
        return manifest
    }

    static func warnIfExperimental(
        _ profile: PommeCreateRecoveryProfileDescriptor, version: String, build: String, vmName: String
    ) {
        guard profile.qualification == .experimental else { return }
        PommeCore.log(
            "Warning: macOS \(version) (\(build)) has not been qualified for Recovery automation; creation will attempt it with observed-screen checks.",
            vmName: vmName
        )
    }
}
