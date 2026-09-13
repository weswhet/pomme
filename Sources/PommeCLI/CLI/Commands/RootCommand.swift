import ArgumentParser

/// The public pomme command-line interface.
struct PommeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pomme",
        abstract: "Create and control macOS virtual machines.",
        subcommands: [
            CreateCommand.self,
            ListCommand.self,
            StartCommand.self,
            StopCommand.self,
            RestartCommand.self,
            PauseCommand.self,
            ResumeCommand.self,
            DeleteCommand.self,
            StatusCommand.self,
            InspectCommand.self,
            ExecCommand.self,
            ShellCommand.self,
            JobsCommand.self,
            SessionsCommand.self,
            CopyCommand.self,
            CatCommand.self,
            SIPCommand.self,
            AMFICommand.self,
            MDMCommand.self,
            RemoteLoginCommand.self,
            ScreenSharingCommand.self,
            SnapshotCommand.self,
            AgentCommand.self,
            ConfigCommand.self,
            IPSWCommand.self,
            UICommand.self,
            TUICommand.self,
            ToolsCommand.self,
            AgentHelpCommand.self
        ]
    )

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }
}
