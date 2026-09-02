import ArgumentParser
import Foundation

/// Manages System Integrity Protection through complete Recovery workflows.
struct SIPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sip",
        abstract: "Manage System Integrity Protection.",
        subcommands: [SIPStatusCommand.self, SIPEnableCommand.self, SIPDisableCommand.self]
    )
}

private struct SecurityWorkflowOptions: ParsableArguments {
    @Option(name: .customLong("final-state"), help: "Final VM state: previous, stopped, normal, recovery, or paused.")
    var finalState: VMFinalState = .previous

    @OptionGroup var output: GlobalOptions
}

struct SIPStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show SIP status and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            await PommeEnvironment.live().security.sip(target, .status, workflow.finalState),
            options: workflow.output
        )
    }
}

struct SIPEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable SIP and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            await PommeEnvironment.live().security.sip(target, .enable, workflow.finalState),
            options: workflow.output
        )
    }
}

struct SIPDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable SIP and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            await PommeEnvironment.live().security.sip(target, .disable, workflow.finalState),
            options: workflow.output
        )
    }
}

/// Manages AMFI boot-argument enforcement through complete Recovery workflows.
struct AMFICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amfi",
        abstract: "Manage AMFI boot-argument enforcement.",
        subcommands: [AMFIStatusCommand.self, AMFIEnableCommand.self, AMFIDisableCommand.self]
    )
}

struct AMFIStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show AMFI status and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            await PommeEnvironment.live().security.amfi(target, .status, workflow.finalState),
            options: workflow.output
        )
    }
}

struct AMFIEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable AMFI enforcement and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            await PommeEnvironment.live().security.amfi(target, .enable, workflow.finalState),
            options: workflow.output
        )
    }
}

struct AMFIDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable AMFI enforcement and restore the VM state.")
    @Argument var name: String?
    @OptionGroup private var workflow: SecurityWorkflowOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            await PommeEnvironment.live().security.amfi(target, .disable, workflow.finalState),
            options: workflow.output
        )
    }
}

/// Enrolls a VM in MDM while restoring its original security and run state.
struct MDMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mdm",
        abstract: "Manage MDM enrollment.",
        subcommands: [MDMEnrollCommand.self, MDMApproveCommand.self]
    )
}

/// Reproduces the private Profiles approval transition for an installed MDM
/// profile. This is intentionally explicit: the resulting state is technical
/// `UserApprovedMDM` state, not proof that a human approved the enrollment.
struct MDMApproveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Privileged synthetic transition: mark an installed MDM profile as user-intended."
    )

    @Argument var name: String?
    @Option(name: .customLong("profile-identifier"), help: "Installed device MDM profile identifier.")
    var profileIdentifier: String
    @Flag(name: .customLong("acknowledge-synthetic-approval"), help: "Acknowledge that this bypasses the human-consent ceremony.")
    var acknowledgeSyntheticApproval = false
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func run() async throws {
        guard acknowledgeSyntheticApproval else {
            throw ValidationError(
                "mdm approve is a privileged synthetic operation; pass --acknowledge-synthetic-approval explicitly."
            )
        }
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let result = try await PommeEnvironment.live().security.mdmApprove(
            target,
            profileIdentifier,
            timeout.value()
        )
        try CLIOutputWriter.write(result, options: output)
    }
}

struct MDMEnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enroll", abstract: "Enroll a VM using a mobileconfig profile.")

    @Argument var name: String?
    @Option(name: .customLong("profile"), help: "Host path to the enrollment mobileconfig.")
    var profile: String
    @Option(name: .customLong("guest-path"), help: "Temporary absolute guest path for the profile.")
    var guestPath: String?
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let result = try await PommeEnvironment.live().security.mdmEnroll(
            target, profile, guestPath, timeout.value()
        )
        try CLIOutputWriter.write(result, options: output)
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
        abstract: "Manage Screen Sharing.",
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
