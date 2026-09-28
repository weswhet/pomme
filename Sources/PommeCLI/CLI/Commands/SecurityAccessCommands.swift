import ArgumentParser
import Foundation

/// Manages System Integrity Protection through complete Recovery workflows.
struct SIPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sip",
        abstract: "Manage System Integrity Protection; repeat the same enable/disable action and --final-state to resume a retained operation.",
        subcommands: [SIPStatusCommand.self, SIPEnableCommand.self, SIPDisableCommand.self]
    )
}

private struct SecurityWorkflowOptions: ParsableArguments {
    @Option(name: .customLong("final-state"), help: "Final VM state: previous, stopped, normal, recovery, or paused. For a retained enable/disable operation, repeat the same action and --final-state to resume.")
    var finalState: VMFinalState = .previous

    @OptionGroup var output: GlobalOptions
}

struct SIPStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show SIP status and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(workflow.output.debug) {
            try CLIOutputWriter.write(
                await PommeEnvironment.live().security.sip(target, .status, workflow.finalState, false),
                options: workflow.output
            )
        }
    }
}

struct SIPEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable SIP and restore the VM state.")
    @Argument var name: String?
    @Flag(help: "Allow owner creation and automatic login on a verified fresh VM without confirmation.")
    var force = false
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(workflow.output.debug) {
            try CLIOutputWriter.write(
                await PommeEnvironment.live().security.sip(target, .enable, workflow.finalState, force),
                options: workflow.output
            )
        }
    }
}

struct SIPDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable SIP and restore the VM state.")
    @Argument var name: String?
    @Flag(help: "Allow owner creation and automatic login on a verified fresh VM without confirmation.")
    var force = false
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(workflow.output.debug) {
            try CLIOutputWriter.write(
                await PommeEnvironment.live().security.sip(target, .disable, workflow.finalState, force),
                options: workflow.output
            )
        }
    }
}

/// Manages AMFI configuration through complete Recovery workflows.
struct AMFICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amfi",
        abstract: "Manage AMFI policy and boot-argument configuration; repeat the same enable/disable action and --final-state to resume a retained operation.",
        subcommands: [AMFIStatusCommand.self, AMFIEnableCommand.self, AMFIDisableCommand.self]
    )
}

struct AMFIStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show AMFI status and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(workflow.output.debug) {
            try CLIOutputWriter.write(
                await PommeEnvironment.live().security.amfi(target, .status, workflow.finalState, false),
                options: workflow.output
            )
        }
    }
}

struct AMFIEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Restore the saved AMFI configuration and the VM state.")
    @Argument var name: String?
    @Flag(help: "Allow owner creation and automatic login on a verified fresh VM without confirmation.")
    var force = false
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(workflow.output.debug) {
            try CLIOutputWriter.write(
                await PommeEnvironment.live().security.amfi(target, .enable, workflow.finalState, force),
                options: workflow.output
            )
        }
    }
}

struct AMFIDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Configure AMFI as disabled and restore the VM state.")
    @Argument var name: String?
    @Flag(help: "Allow owner creation and automatic login on a verified fresh VM without confirmation.")
    var force = false
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(workflow.output.debug) {
            try CLIOutputWriter.write(
                await PommeEnvironment.live().security.amfi(target, .disable, workflow.finalState, force),
                options: workflow.output
            )
        }
    }
}

/// Brings a VM from any state to the requested MDM enrollment.
struct MDMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mdm",
        abstract: "Enroll a VM in MDM from any state: create or finish it, finish retained SIP/AMFI work, prepare only the security enrollment needs, and enroll.",
        discussion: "Repeat the same command to resume after a failure. Creation options apply only when the VM does not exist."
    )

    @Argument var name: String?
    @Option(name: .customLong("profile"), help: "Host path to the enrollment mobileconfig.")
    var profile: String
    @Option(name: .customLong("guest-path"), help: "Temporary absolute guest path for the profile.")
    var guestPath: String?
    @Option(name: .customLong("enrollment-mode"), help: "Enrollment mode: supervised (user approved, default) or unapproved.")
    var enrollmentMode: MDMEnrollmentMode = .supervised
    @Option(name: .customLong("final-security"), help: "SIP/AMFI after enrollment: restore (default) re-enables what enrollment disabled; disabled leaves it off.")
    var finalSecurity: MDMFinalSecurity = .restore
    @Flag(help: "Allow owner creation and automatic login on a verified fresh VM without confirmation.")
    var force = false
    @Flag(name: .customLong("dry-run"), help: "Report the detected state and planned steps without changing the VM.")
    var dryRun = false
    @Flag(name: .customLong("skip-server-preflight"), help: "Do not stop when the host cannot validate the MDM server's certificate.")
    var skipServerPreflight = false

    @Option(name: .customLong("from-template"), help: "If the VM is missing, clone it from this template.")
    var fromTemplate: String?
    @Option(name: .customLong("version"), help: "If the VM is missing, install this macOS version, build, or 'latest'.")
    var version: String?
    @Flag(name: .customLong("latest"), help: "If the VM is missing, install the latest signed macOS. Same as --version latest.")
    var latest = false
    @Option(name: .customLong("restore-image"), help: "If the VM is missing, install from this local IPSW.")
    var restoreImage: String?
    @Option(name: .customLong("ipsw-device"), help: "Apple silicon Mac identifier used to resolve --version.")
    var ipswDevice: String?
    @Option(name: .customLong("memory"), help: "Guest memory for a created VM (default 8GB).")
    var memory: String?
    @Option(name: .customLong("disk-size"), help: "Disk size for a created VM (default 60GB; a template supplies its own).")
    var diskSize: String?
    @Option(name: .customLong("boot"), help: "State of a created VM before enrollment, and after it: normal (default) or none.")
    var boot: CLIBootMode?

    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        let value = try timeout.value()
        guard value.isFinite, (1...300).contains(value) else {
            throw ValidationError("--timeout must be between 1 and 300 seconds.")
        }
        if latest {
            if let version, version != "latest" {
                throw ValidationError("Choose either --latest or --version.")
            }
            version = "latest"
        }
        if boot == .recovery {
            throw ValidationError("--boot for MDM creation must be normal or none.")
        }
        try PommeCreationRequest.validate(
            version: version, restoreImage: restoreImage, fromTemplate: fromTemplate, ipswDevice: ipswDevice,
            diskSize: diskSize ?? PommeCreationRequest.defaultDiskSize,
            memory: memory ?? PommeCreationRequest.defaultMemory)
    }

    /// The creation that applies only when the VM is missing.
    var creation: PommeCreationRequest? {
        PommeCreationRequest.source(version: version, restoreImage: restoreImage, fromTemplate: fromTemplate,
                                    ipswDevice: ipswDevice).map {
            .init(source: $0, diskSize: diskSize ?? PommeCreationRequest.defaultDiskSize,
                  memory: memory ?? PommeCreationRequest.defaultMemory, boot: boot ?? .normal)
        }
    }

    var creationOptionsSupplied: Bool {
        creation != nil || ipswDevice != nil || memory != nil || diskSize != nil || boot != nil
    }

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let request = PommeMDMCommandRequest(
            name: target, profilePath: profile, guestPath: guestPath, timeout: try timeout.value(),
            enrollmentMode: enrollmentMode, finalSecurity: finalSecurity, force: force, dryRun: dryRun,
            skipServerPreflight: skipServerPreflight, creation: creation,
            creationOptionsSupplied: creationOptionsSupplied, interactive: isatty(STDIN_FILENO) == 1)
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(output.debug) {
            try CLIOutputWriter.write(try await PommeEnvironment.live().security.mdm(request), options: output)
        }
    }
}

/// Manages macOS Remote Login in a running VM.
struct RemoteLoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-login",
        abstract: "Manage Remote Login.",
        subcommands: [
            RemoteLoginStatusCommand.self,
            RemoteLoginEnableCommand.self,
            RemoteLoginDisableCommand.self
        ]
    )
}

private func remoteLoginResult(
    name: String,
    enabled: Bool,
    output: GlobalOptions
) throws {
    let result = try PommeEnvironment.live().guest.request(
        name,
        .remoteLogin(RemoteLoginRequest(
            enabled: enabled
        )),
        "Remote Login"
    )
    try CLIOutputWriter.write(result, options: output)
}

struct RemoteLoginStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show Remote Login status.")
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let request = GuestCommandRequest(
            path: "/usr/sbin/systemsetup",
            arguments: ["-getremotelogin"],
            timeout: Constants.defaultGuestCommandTimeout
        )
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.execute(target, request),
            options: output
        )
    }
}

struct RemoteLoginEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable Remote Login.")
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try remoteLoginResult(
            name: target,
            enabled: true,
            output: output
        )
    }
}

struct RemoteLoginDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable Remote Login.")
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try remoteLoginResult(name: target, enabled: false, output: output)
    }
}

/// Manages macOS Screen Sharing in a running VM.
struct ScreenSharingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen-sharing",
        abstract: "Manage Screen Sharing. Requires a guest agent with Screen Sharing support.",
        subcommands: [
            ScreenSharingStatusCommand.self,
            ScreenSharingEnableCommand.self,
            ScreenSharingDisableCommand.self
        ]
    )
}

private func screenSharingResult(
    name: String,
    action: ScreenSharingAction,
    output: GlobalOptions
) throws {
    let result = try PommeEnvironment.live().guest.request(
        name, .screenSharing(ScreenSharingRequest(action: action)), "Screen Sharing"
    )
    try CLIOutputWriter.write(result, options: output)
}

struct ScreenSharingStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show Screen Sharing status.")
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try screenSharingResult(name: target, action: .status, output: output)
    }
}

struct ScreenSharingEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable Screen Sharing.")
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try screenSharingResult(name: target, action: .enable, output: output)
    }
}

struct ScreenSharingDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable Screen Sharing.")
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try screenSharingResult(name: target, action: .disable, output: output)
    }
}
