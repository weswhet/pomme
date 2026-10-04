import ArgumentParser

/// Durable Pomme agent workflow controls. This is the only public agent repair
/// and update surface.
struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Inspect, repair, and update Pomme-owned durable agent workflows.",
        subcommands: [AgentStatusCommand.self, AgentRepairCommand.self, AgentUpdateCommand.self]
    )
}

/// Projects a verified Pomme-owned agent journal without guest interaction.
struct AgentStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show durable agent workflow status."
    )

    @Argument(help: "Pomme-owned VM name.")
    var name: String

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try validateVMName(name)
    }

    mutating func run() async throws {
        let result = try await PommeApplication.agentStatus(name: name)
        try CLIOutputWriter.write(payload: result.payload, text: result.text, options: output)
        guard result.ok, result.hostExitCode == 0 else {
            throw ExitCode(result.hostExitCode)
        }
    }
}

/// The public repair contract deliberately supports only restoration to the
/// captured prior state. The application adapter owns provenance validation,
/// journal reconciliation, and the actual final-state transition.
struct AgentRepairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Repair a Pomme-owned agent workflow and restore its prior state."
    )

    @Argument(help: "Pomme-owned VM name.")
    var name: String

    @Option(name: .customLong("final-state"), help: "Final VM state: previous.")
    var finalState: AgentRepairFinalState = .previous

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try validateVMName(name)
    }

    mutating func run() async throws {
        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(output.debug) {
            let result = try await PommeApplication.agentRepair(
                name: name,
                finalState: finalState.rawValue
            )
            try CLIOutputWriter.write(result, options: output)
        }
    }
}

/// Replaces the persistent agent in a running VM with this host's signed
/// Pomme executable. The application adapter verifies the reconnected agent
/// before recording its digest for later security checks.
struct AgentUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update the Pomme agent in a running VM to this host's Pomme build.",
        discussion: """
        The VM must be running normal macOS with a connected agent. The agent is \
        replaced in place and restarted; no Recovery boot or guest reboot is needed. \
        It refuses while background jobs or terminal sessions are running, because \
        the restarted agent could no longer manage them. Running it again when the agent already matches makes no change. \
        `pomme agent repair` reinstalls the agent the VM was created with.
        """
    )

    @Argument(help: "Pomme-owned VM name.")
    var name: String

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try validateVMName(name)
    }

    mutating func run() async throws {
        let result = try await PommeApplication.agentUpdate(name: name)
        try CLIOutputWriter.write(result, options: output)
    }
}

enum AgentRepairFinalState: String, CaseIterable, ExpressibleByArgument {
    case previous
}
