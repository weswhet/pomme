import ArgumentParser
import Foundation

/// Boot modes accepted by lifecycle commands.
enum CLIBootMode: String, CaseIterable, ExpressibleByArgument {
    case none
    case normal
    case recovery

    var startMode: StartMode {
        switch self {
        case .none:
            return .none
        case .normal:
            return .normal
        case .recovery:
            return .recovery
        }
    }

    var runtimeMode: BootMode? {
        switch self {
        case .none:
            return nil
        case .normal:
            return .normal
        case .recovery:
            return .recovery
        }
    }
}

/// Creates one managed VM directly or creates a batch from a config file.
struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a managed macOS VM."
    )

    @Argument(help: "VM name for direct creation.")
    var name: String?

    @Option(name: .customLong("config"), help: "Create VMs from a JSON, YAML, TOML, or Pkl config.")
    var configPath: String?

    @Option(name: .customLong("version"), help: "macOS version, build, or 'latest'.")
    var version: String?

    @Flag(name: .customLong("latest"), help: "Use the latest signed macOS version. Same as --version latest.")
    var latest = false

    @Option(name: .customLong("restore-image"), help: "Local IPSW path. Available only in direct mode.")
    var restoreImage: String?

    @Option(name: .customLong("from-template"), help: "Clone an installed template (see `pomme template`) instead of restoring an IPSW.")
    var fromTemplate: String?

    @Option(name: .customLong("ipsw-device"), help: "Apple silicon Mac identifier used to resolve --version.")
    var ipswDevice: String?

    @Option(name: .customLong("disk-size"), help: "Virtual disk size.")
    var diskSize = "60GB"

    @Option(name: .customLong("memory"), help: "Guest memory size.")
    var memory = "8GB"

    @Option(name: .customLong("boot"), help: "State after creation: normal (default), recovery, or none.")
    var boot: CLIBootMode = .normal

    @Flag(name: .customLong("recovery"), help: "Leave the VM booted in Recovery after creation. Same as --boot recovery.")
    var recovery = false

    @Flag(name: .customLong("shutdown"), help: "Shut the VM down after the agent is installed and verified. Same as --boot none.")
    var shutdown = false

    @Flag(name: .customLong("dry-run"), help: "Resolve and print the creation plan without creating VMs.")
    var dryRun = false

    @Flag(
        name: .customLong("resume"),
        help: "Resume the durable Pomme agent workflow for this VM."
    )
    var resume = false

    @Flag(name: .customLong("parallel"), help: "Create config members two at a time instead of one after another. Virtualization allows at most two macOS guests, so the flag takes no count.")
    var parallel = false

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        // validate() runs during parse and may run again; keep the flag
        // mapping idempotent, like --latest.
        if recovery, shutdown {
            throw ValidationError("Choose either --recovery or --shutdown.")
        }
        if recovery {
            guard boot == .normal || boot == .recovery else {
                throw ValidationError("--recovery cannot be combined with --boot \(boot.rawValue).")
            }
            boot = .recovery
        }
        if shutdown {
            guard boot == .normal || boot == .none else {
                throw ValidationError("--shutdown cannot be combined with --boot \(boot.rawValue).")
            }
            boot = .none
        }
        if latest {
            if let version, version != "latest" {
                throw ValidationError("Choose either --latest or --version.")
            }
            version = "latest"
        }
        if resume {
            guard let name, !name.isEmpty else {
                throw ValidationError("--resume requires a VM name.")
            }
            _ = try validateVMName(name)
            let creationArgumentsSupplied = configPath != nil || version != nil || restoreImage != nil
                || fromTemplate != nil || ipswDevice != nil || diskSize != "60GB" || memory != "8GB" || boot != .normal
                || dryRun || parallel
            guard !creationArgumentsSupplied else {
                throw ValidationError("--resume accepts only a VM name and output or debug options.")
            }
            return
        }
        if let configPath {
            // A count after --parallel lands in the positional name slot; say
            // so instead of blaming the operator for naming a VM.
            if parallel, let name, Int(name) != nil {
                throw ValidationError("--parallel takes no value; config creation runs at most two VMs at once.")
            }
            let directSettingsWereSupplied = name != nil || version != nil || restoreImage != nil || ipswDevice != nil
                || fromTemplate != nil
                || diskSize != "60GB" || memory != "8GB" || boot != .normal
            if directSettingsWereSupplied {
                throw ValidationError("--config cannot be combined with a VM name or direct creation options.")
            }
            if configPath.isEmpty {
                throw ValidationError("--config requires a file path.")
            }
        } else {
            guard let name, !name.isEmpty else {
                throw ValidationError("Direct creation requires a VM name.")
            }
            _ = try validateVMName(name)
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
            if parallel {
                throw ValidationError("--parallel is available only with --config.")
            }
            for (flag, value) in [("--disk-size", diskSize), ("--memory", memory)] {
                guard let bytes = ByteSizeParser.parse(value), bytes > 0 else {
                    throw ValidationError("\(flag) requires a valid size greater than zero.")
                }
            }
        }
    }

    mutating func run() async throws {
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(output.debug) {
        if resume {
            let result = try await PommeApplication.createResume(name: try validateVMName(name!))
            try CLIOutputWriter.write(result, options: output)
            return
        }
        if let configPath {
            let limit = parallel ? VMCreationExecutor.maximumParallelism : 1
            let results = try await CreateConfigRunner.run(
                path: configPath,
                dryRun: dryRun,
                parallelism: limit
            )
            try CLIOutputWriter.write(results, options: output)
            return
        }

        let vmName = try validateVMName(name!)
        // Fail a too-small request before catalog or image resolution, so the
        // check is the same whether or not the image is at hand.
        let memoryBytes = ByteSizeParser.parse(memory) ?? 0
        try PommeCore.validateProvisionalMemoryFloor(memoryBytes)
        if let fromTemplate {
            try await runFromTemplate(fromTemplate, vmName: vmName, memoryBytes: memoryBytes)
            return
        }
        let restoreArguments: [String]
        var selectedProfile: PommeCreateRecoveryProfileDescriptor?
        var resolvedLocalRestoreImage: PommeLocalRestoreImageIdentity?
        var resolvedFirmware: IPSWMEFirmware?
        if let version {
            let firmware = try await PommeCore.resolveIPSWFirmware(
                selection: version,
                deviceIdentifier: ipswDevice
            )
            resolvedFirmware = firmware
            let profile = try PommeRecoveryProfileSelector.select(for: firmware)
            selectedProfile = profile
            if profile.qualification == .experimental {
                PommeCore.log(
                    "Warning: macOS \(firmware.version) (\(firmware.buildid)) has not been qualified for Recovery automation; creation will attempt it with observed-screen checks.",
                    vmName: vmName
                )
            }
            restoreArguments = ["--version", firmware.buildid]
                + (ipswDevice.map { ["--ipsw-device", $0] } ?? [])
        } else if let restoreImage {
            restoreArguments = ["--restore-image", restoreImage]
            if dryRun {
                let identity = try await PommeCore.inspectLocalRestoreImage(path: restoreImage)
                selectedProfile = identity.recoveryProfile
                resolvedLocalRestoreImage = identity
                if identity.recoveryProfile.qualification == .experimental {
                    PommeCore.log(
                        "Warning: macOS \(identity.version) (\(identity.build)) has not been qualified for Recovery automation; creation will attempt it with observed-screen checks.",
                        vmName: vmName
                    )
                }
            }
        } else {
            throw ValidationError("Direct creation requires --version or a verified --restore-image.")
        }
        if dryRun {
            guard let selectedProfile else {
                throw RunnerError.hostCommandFailed("Pomme could not qualify the requested restore image.")
            }
            let dryRunVersion: Any
            let dryRunRestoreImage: Any
            let memorySource: PommeCore.DryRunRestoreSource
            if let resolvedLocalRestoreImage {
                dryRunVersion = resolvedLocalRestoreImage.version
                dryRunRestoreImage = resolvedLocalRestoreImage.canonicalPath
                memorySource = .localImage(path: resolvedLocalRestoreImage.canonicalPath)
            } else if let resolvedFirmware {
                dryRunVersion = version as Any
                dryRunRestoreImage = restoreImage as Any
                memorySource = .firmware(resolvedFirmware)
            } else {
                throw RunnerError.hostCommandFailed("Pomme could not resolve a restore image source for the dry run.")
            }
            let memoryCheck = try await PommeCore.dryRunMemoryCheck(
                memoryBytes: memoryBytes,
                source: memorySource,
                vmName: vmName
            )
            var payload: [String: Any] = [
                "ok": true,
                "dryRun": true,
                "name": vmName,
                "version": dryRunVersion,
                "restoreImage": dryRunRestoreImage,
                "ipswDevice": ipswDevice as Any,
                "diskSize": diskSize,
                "memory": memory,
                "memoryMinimum": memoryCheck.payload,
                "boot": boot.rawValue,
                "recoveryProfile": [
                    "id": selectedProfile.id,
                    "version": selectedProfile.version,
                    "build": selectedProfile.build,
                    "qualification": selectedProfile.qualification.rawValue,
                    "digest": selectedProfile.digest
                ]
            ]
            payload.merge(PommeCore.provisioningDisclosure(virtualization:
                PommeCore.usesVirtualizationProvisioning(guestVersion: selectedProfile.version,
                    firstBootEligible: true))) { _, new in new }
            try CLIOutputWriter.write(
                payload: payload,
                text: "Would create \(vmName) (disk \(diskSize), memory \(memory), boot \(boot.rawValue)).",
                options: output
            )
            return
        }

        let result = try await PommeApplication.create(
            name: vmName,
            restoreArgs: restoreArguments,
            diskSize: diskSize,
            memory: memory,
            startMode: boot.startMode
        )
        try CLIOutputWriter.write(result, options: output)
        }
    }

    /// Template creates inherit the template's disk size. An explicit
    /// `--disk-size` is accepted only when it matches, because the cloned
    /// image already carries its APFS container geometry.
    private func runFromTemplate(_ templateName: String, vmName: String, memoryBytes: UInt64) async throws {
        let manifest = try PommeTemplateStore.manifest(for: templateName)
        let templateDiskSize = "\(manifest.diskSizeBytes / (1 << 20))MB"
        if diskSize != "60GB", ByteSizeParser.parse(diskSize) != manifest.diskSizeBytes {
            throw PommeTemplateError.diskSizeMismatch(
                template: manifest.diskSizeBytes,
                requested: ByteSizeParser.parse(diskSize) ?? 0
            )
        }
        let descriptor = try PommeRecoveryProfileSelector.descriptor(version: manifest.version, build: manifest.build)
        if dryRun {
            let memoryCheck = try await PommeCore.dryRunMemoryCheck(
                memoryBytes: memoryBytes,
                source: .template(manifest),
                vmName: vmName
            )
            var payload: [String: Any] = [
                "ok": true,
                "dryRun": true,
                "name": vmName,
                "template": manifest.name,
                "version": manifest.version,
                "build": manifest.build,
                "diskSize": manifest.diskSizeBytes,
                "memory": memory,
                "memoryMinimum": memoryCheck.payload,
                "boot": boot.rawValue,
                "recoveryProfile": [
                    "id": descriptor.id,
                    "version": descriptor.version,
                    "build": descriptor.build,
                    "qualification": descriptor.qualification.rawValue,
                    "digest": descriptor.digest
                ]
            ]
            payload.merge(PommeCore.provisioningDisclosure(virtualization:
                PommeCore.usesVirtualizationProvisioning(guestVersion: manifest.version,
                    firstBootEligible: !manifest.isProvisioned))) { _, new in new }
            try CLIOutputWriter.write(
                payload: payload,
                text: "Would create \(vmName) from template \(manifest.name) (macOS \(manifest.version) \(manifest.build), disk \(manifest.diskSizeBytes / (1 << 30))GB, memory \(memory), boot \(boot.rawValue)).",
                options: output
            )
            return
        }
        let result = try await PommeApplication.create(
            name: vmName,
            restoreArgs: ["--from-template", manifest.name],
            diskSize: templateDiskSize,
            memory: memory,
            startMode: boot.startMode
        )
        try CLIOutputWriter.write(result, options: output)
    }
}

/// Lists every managed VM.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all managed VMs.",
        aliases: ["ls"]
    )

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let payload = try PommeApplication.listVMsPayload()
        let entries = payload["vms"] as? [[String: Any]] ?? []
        let lines = entries.map { entry in
            let name = PommeCore.stringValue(entry["name"])
            let state = PommeCore.stringValue(entry["vmState"])
            let mode = PommeCore.stringValue(entry["bootMode"])
            return [name, state, mode.isEmpty ? "-" : mode].joined(separator: "\t")
        }
        let text = (["NAME\tSTATE\tMODE"] + lines).joined(separator: "\n")
        try CLIOutputWriter.write(payload: payload, text: text, options: output, jsonlCollection: "vms")
    }
}

/// Starts or resumes one or more VMs.
struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start or resume VMs.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @Option(name: .customLong("mode"), help: "Boot mode: normal or recovery.")
    var mode: BootMode = .normal

    @Option(name: .customLong("timeout"), parsing: .unconditional, help: "Agent readiness timeout in seconds for normal and Recovery boots.")
    var timeout: Double = Constants.defaultRecoveryAgentTimeout

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard timeout.isFinite, timeout > 0 else { throw ValidationError("--timeout must be greater than zero.") }
    }

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        var options = CLIOptions()
        options.timeout = timeout
        options.debug = output.debug
        let results = try targets.map {
            try PommeApplication.boot(name: $0, mode: mode, options: options)
        }
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Gracefully stops one or more VMs and force-stops after the runtime timeout.
struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop VMs.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @Flag(name: .customLong("force"), help: "Skip graceful guest shutdown.")
    var force = false

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        let results = try targets.map { try PommeEnvironment.live().lifecycle.stop($0, force) }
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Restarts one or more VMs, preserving their boot mode unless overridden.
struct RestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart VMs.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @Option(name: .customLong("mode"), help: "Override the preserved boot mode.")
    var mode: BootMode?

    @Option(name: .customLong("timeout"), parsing: .unconditional, help: "Agent readiness timeout in seconds for normal and Recovery boots.")
    var timeout: Double = Constants.defaultRecoveryAgentTimeout

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard timeout.isFinite, timeout > 0 else { throw ValidationError("--timeout must be greater than zero.") }
    }

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        var options = CLIOptions()
        options.timeout = timeout
        options.debug = output.debug
        let results = try targets.map {
            try PommeApplication.restart(name: $0, mode: mode, options: options)
        }
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Pauses one or more running VMs.
struct PauseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause VMs.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        let results = try targets.map(PommeEnvironment.live().lifecycle.pause)
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Resumes one or more paused VMs.
struct ResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume paused VMs.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        let results = try targets.map(PommeEnvironment.live().lifecycle.resume)
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Deletes one or more managed VMs.
struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete managed VMs.",
        aliases: ["rm"]
    )

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @Flag(name: .customLong("force"), help: "Delete without prompting.")
    var force = false

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        try CLIConfirmation.confirmDeletion(of: targets, force: force)
        let results = try targets.map(PommeEnvironment.live().lifecycle.destroy)
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Prints concise state for one or more VMs.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show VM state.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        let results = try targets.map(PommeEnvironment.live().lifecycle.status)
        try CLIOutputWriter.write(results, options: output)
    }
}

/// Prints detailed configuration, health, and guest-agent capabilities.
struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect VM configuration and health.")

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        let results = try targets.map(PommeEnvironment.live().lifecycle.inspect)
        try CLIOutputWriter.write(results, options: output)
    }
}
