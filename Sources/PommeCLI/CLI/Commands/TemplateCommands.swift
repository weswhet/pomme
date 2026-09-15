import ArgumentParser
import Foundation

/// Installed-but-unprovisioned macOS images that `pomme create --from-template`
/// clones instead of restoring an IPSW.
struct TemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "Manage installed macOS templates for fast VM creation.",
        subcommands: [TemplateCreateCommand.self, TemplateListCommand.self, TemplateDeleteCommand.self]
    )
}

struct TemplateCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Restore a macOS image once so VMs can be cloned from it."
    )

    @Argument(help: "Template name.")
    var name: String

    @Option(name: .customLong("version"), help: "macOS version, build, or 'latest'.")
    var version: String?

    @Flag(name: .customLong("latest"), help: "Use the latest signed macOS version. Same as --version latest.")
    var latest = false

    @Option(name: .customLong("restore-image"), help: "Local IPSW path.")
    var restoreImage: String?

    @Option(name: .customLong("ipsw-device"), help: "Apple silicon Mac identifier used to resolve --version.")
    var ipswDevice: String?

    @Option(name: .customLong("disk-size"), help: "Virtual disk size; every VM cloned from the template inherits it.")
    var diskSize = "60GB"

    @Option(name: .customLong("memory"), help: "Guest memory used only while restoring the image.")
    var memory = "4GB"

    @Option(name: .customLong("from-template"), help: "Build on an existing installed template instead of restoring an image again. Only with --provisioned.")
    var fromTemplate: String?

    @Flag(name: .customLong("provisioned"), help: "Also prepare the owner account and leave SIP disabled with the AMFI override on, so a VM cloned from this template can run MDM enrollment as its first command with no security mutation. Every VM cloned from it inherits that posture.")
    var provisioned = false

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        if latest {
            if let version, version != "latest" {
                throw ValidationError("Choose either --latest or --version.")
            }
            version = "latest"
        }
        _ = try validateIdentifier(name, kind: .template)
        if version != nil, restoreImage != nil {
            throw ValidationError("Choose either --version or --restore-image.")
        }
        if restoreImage != nil, ipswDevice != nil {
            throw ValidationError("--ipsw-device is available only with --version.")
        }
        if let fromTemplate {
            guard provisioned else {
                throw ValidationError("--from-template is available only with --provisioned.")
            }
            guard version == nil, restoreImage == nil else {
                throw ValidationError("Choose either --from-template or a restore image source.")
            }
            _ = try validateIdentifier(fromTemplate, kind: .template)
        } else {
            guard version != nil || restoreImage != nil else {
                throw ValidationError("Template creation requires --version, --latest, --restore-image, or --from-template with --provisioned.")
            }
        }
        for (flag, value) in [("--disk-size", diskSize), ("--memory", memory)] {
            guard let bytes = ByteSizeParser.parse(value), bytes > 0 else {
                throw ValidationError("\(flag) requires a valid size greater than zero.")
            }
        }
    }

    mutating func run() async throws {
        if provisioned {
            var restoreArgs: [String] = []
            if let fromTemplate { restoreArgs += ["--from-template", fromTemplate] }
            if let version { restoreArgs += ["--version", version] }
            if let restoreImage { restoreArgs += ["--restore-image", restoreImage] }
            if let ipswDevice { restoreArgs += ["--ipsw-device", ipswDevice] }
            let payload = try await PommeProvisionedTemplate.create(
                name: name, restoreArgs: restoreArgs, diskSize: diskSize, memory: memory
            )
            let owner = PommeCore.stringValue(payload["ownerAccount"])
            let text = "OK created provisioned template \(name) macOS "
                + "\(PommeCore.stringValue(payload["version"])) "
                + "(\(PommeCore.stringValue(payload["build"]))) owner=\(owner)"
            try CLIOutputWriter.write(payload: payload, text: text, options: output)
            return
        }
        var options = CLIOptions()
        options.restoreImageVersionSelection = version
        options.restoreImagePath = restoreImage
        options.ipswDeviceIdentifier = ipswDevice
        options.resumeDownload = true
        options.sizeOptions.diskSizeBytes = ByteSizeParser.parse(diskSize) ?? 0
        options.sizeOptions.memorySizeBytes = ByteSizeParser.parse(memory) ?? 0
        options.hasCustomSizeOptions = true
        options.debug = output.debug
        let payload = try await PommeCore.createTemplatePayload(name: name, arguments: options)
        let text = "OK created template \(name) macOS \(PommeCore.stringValue(payload["version"])) (\(PommeCore.stringValue(payload["build"])))"
        try CLIOutputWriter.write(payload: payload, text: text, options: output)
    }
}

struct TemplateListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed templates.")

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let templates = try PommeTemplateStore.list()
        let payload: [String: Any] = [
            "ok": true,
            "hostExitCode": 0,
            "templates": templates.map { manifest -> [String: Any] in
                [
                    "name": manifest.name,
                    "version": manifest.version,
                    "build": manifest.build,
                    "diskSize": manifest.diskSizeBytes,
                    "restoreImageDigest": manifest.restoreImageDigest,
                    "provisioned": manifest.isProvisioned,
                    "securityDisabled": manifest.isSecurityDisabled,
                    "ownerAccount": manifest.provisionedOwnerAccount as Any,
                    "createdAt": ISO8601DateFormatter().string(from: manifest.createdAt)
                ]
            }
        ]
        let lines = templates.map {
            "\($0.name)\t\($0.version)\t\($0.build)\t\($0.diskSizeBytes / (1 << 30))GB"
                + "\t\($0.provisionedOwnerAccount ?? "-")"
                + "\t\($0.isSecurityDisabled ? "sip-off,amfi-off" : "default")"
        }
        let text = (["NAME\tVERSION\tBUILD\tDISK\tOWNER\tSECURITY"] + lines).joined(separator: "\n")
        try CLIOutputWriter.write(payload: payload, text: text, options: output)
    }
}

struct TemplateDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an installed template.")

    @Argument(help: "Template name.")
    var name: String

    @Flag(name: .customLong("force"), help: "Delete without prompting.")
    var force = false

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        if !force {
            guard isatty(STDIN_FILENO) == 1 else {
                throw ValidationError("Deletion requires an interactive terminal. Pass --force to delete without prompting.")
            }
            print("Delete template \(name)? Type the template name to confirm: ", terminator: "")
            guard readLine() == name else {
                throw ValidationError("Deletion cancelled.")
            }
        }
        let removed = try PommeTemplateStore.delete(name: name)
        try CLIOutputWriter.write(
            payload: ["ok": true, "hostExitCode": 0, "operation": "template-delete", "name": name, "bundlePath": removed.path],
            text: "OK deleted template \(name)",
            options: output
        )
    }
}
