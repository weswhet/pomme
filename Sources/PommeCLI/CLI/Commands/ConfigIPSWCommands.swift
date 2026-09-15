import ArgumentParser
import Darwin
import Foundation

/// Supported create-config file formats.
enum CreateConfigFormat: String, CaseIterable, ExpressibleByArgument {
    case json
    case yaml
    case toml
    case pkl

    var pathExtension: String { rawValue }
}

/// Creates, validates, and renders VM creation configs.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage VM creation configs.",
        subcommands: [ConfigInitCommand.self, ConfigValidateCommand.self, ConfigRenderCommand.self]
    )
}

struct ConfigInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init", abstract: "Create a VM config interactively.")

    @Option(name: .customLong("format"), help: "Config format: json, yaml, toml, or pkl.")
    var format: CreateConfigFormat = .yaml

    @Option(name: .customLong("output"), help: "Output file path.")
    var outputPath: String?

    @Flag(name: .customLong("force"), help: "Replace an existing output file.")
    var force = false

    mutating func run() throws {
        guard isatty(STDIN_FILENO) == 1 else {
            throw ValidationError("config init requires an interactive terminal.")
        }
        let name = try validateVMName(prompt("Base VM name", defaultValue: "lab"))
        let versions = prompt("Versions separated by commas", defaultValue: "latest")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let diskSize = prompt("Disk size", defaultValue: "60GB")
        let memory = prompt("Memory", defaultValue: "8GB")
        let bootValue = prompt("Boot after creation (none, normal, recovery)", defaultValue: "none")
        guard let boot = ConfigBootMode(rawValue: bootValue) else {
            throw ValidationError("Boot must be none, normal, or recovery.")
        }

        let config = VMCreationConfigV1(
            schemaVersion: VMCreationConfigV1.supportedSchemaVersion,
            name: name,
            versions: versions,
            ipswDevice: nil,
            hardware: VMCreationConfigV1.Hardware(diskSize: diskSize, memory: memory),
            credentials: nil,
            workflow: nil,
            mdm: nil,
            boot: boot
        )
        let path = outputPath ?? "\(name).\(format.pathExtension)"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path), !force {
            throw ValidationError("Refusing to replace \(url.path). Pass --force to overwrite it.")
        }
        let data = try CreateConfigStore.encode(config, to: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    private func prompt(_ label: String, defaultValue: String) -> String {
        fputs("\(label) [\(defaultValue)]: ", stderr)
        let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultValue : value
    }
}

struct ConfigValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate a create config without resolving versions.")
    @Argument var path: String
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let config = try CreateConfigStore.load(path: path)
        let payload: [String: Any] = [
            "ok": true,
            "path": URL(fileURLWithPath: path).standardizedFileURL.path,
            "name": config.name,
            "versions": config.versions,
            "schemaVersion": config.schemaVersion,
            "hostExitCode": 0
        ]
        try CLIOutputWriter.write(payload: payload, text: "Config is valid.", options: output)
    }
}

struct ConfigRenderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "render", abstract: "Resolve versions and print the exact creation plan.")
    @Argument var path: String
    @OptionGroup var output: GlobalOptions

    mutating func run() async throws {
        let plans = try await CreateConfigRunner.plans(path: path)
        let payload: [String: Any] = [
            "ok": true,
            "path": URL(fileURLWithPath: path).standardizedFileURL.path,
            "vms": plans.map(\.payload),
            "hostExitCode": 0
        ]
        let text = plans.map {
            "\($0.name)\tmacOS \($0.firmware.version)\t\($0.firmware.buildid)\tboot=\(($0.config.boot ?? .none).rawValue)"
        }.joined(separator: "\n")
        try CLIOutputWriter.write(payload: payload, text: text, options: output)
    }
}

/// Lists and downloads macOS restore images.
struct IPSWCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipsw",
        abstract: "Manage macOS restore images.",
        subcommands: [IPSWListCommand.self, IPSWDownloadCommand.self]
    )
}

struct IPSWListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List available restore images.")
    @Option(name: .customLong("device"), help: "Apple silicon Mac identifier. Defaults to the host model.")
    var device: String?
    @Option(name: .customLong("limit"), parsing: .unconditional, help: "Maximum number of results.")
    var limit: Int?
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        if let limit, limit < 1 {
            throw ValidationError("--limit must be greater than zero.")
        }
    }

    mutating func run() async throws {
        let result = try await PommeCore.listIPSWFirmwares(deviceIdentifier: device, limit: limit)
        let firmwares = result.firmwares.map { firmware -> [String: Any] in
            [
                "version": firmware.version,
                "build": firmware.buildid,
                "signed": firmware.signed ?? false,
                "size": firmware.filesize as Any,
                "url": firmware.url
            ]
        }
        let payload: [String: Any] = [
            "ok": true,
            "device": result.device.identifier,
            "name": result.device.name,
            "firmwares": firmwares,
            "hostExitCode": 0
        ]
        let text = result.firmwares.map {
            "\($0.version)\t\($0.buildid)\tsigned=\($0.signed == true)"
        }.joined(separator: "\n")
        try CLIOutputWriter.write(payload: payload, text: text, options: output)
    }
}

struct IPSWDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "download", abstract: "Download a restore image.")
    @Argument(help: "macOS version, build, or 'latest'.")
    var selection: String
    @Option(name: .customLong("device"), help: "Apple silicon Mac identifier. Defaults to the host model.")
    var device: String?
    @OptionGroup var output: GlobalOptions

    mutating func run() async throws {
        let result = try await PommeCore.downloadIPSWFirmware(
            selection: selection,
            deviceIdentifier: device
        )
        let payload: [String: Any] = [
            "ok": true,
            "version": result.firmware.version,
            "build": result.firmware.buildid,
            "localPath": result.url.path,
            "hostExitCode": 0
        ]
        try CLIOutputWriter.write(payload: payload, text: result.url.path, options: output)
    }
}
