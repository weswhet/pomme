import ArgumentParser
import Foundation

/// Host-display UI input, screenshots, and guided Settings automation.
struct UICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Automate the guest through the host display.",
        subcommands: [
            UITypeCommand.self,
            UIKeyCommand.self,
            UIKeySequenceCommand.self,
            UIClickCommand.self,
            UIScreenshotCommand.self,
            UIAICommand.self
        ]
    )
}

private func runUIRequest(name: String?, request: GuestUIRequest, output: GlobalOptions) throws {
    let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
    try CLIOutputWriter.write(PommeEnvironment.live().guest.ui(target, request), options: output)
}

struct UITypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into the guest display.")
    @Argument var name: String?
    @Option(name: .customLong("text"), help: "Text to type.") var text: String?
    @Option(name: .customLong("text-env"), help: "Environment variable containing text to type.") var textEnvironment: String?
    @Flag(name: .customLong("replace")) var replace = false
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard (text != nil) != (textEnvironment != nil) else {
            throw ValidationError("Choose exactly one of --text or --text-env.")
        }
    }

    mutating func run() throws {
        let resolved: String
        if let text {
            resolved = text
        } else if let name = textEnvironment, let value = ProcessInfo.processInfo.environment[name] {
            resolved = value
        } else {
            throw ValidationError("Environment variable \(textEnvironment ?? "") is not set.")
        }
        try runUIRequest(
            name: name,
            request: GuestUIRequest(
                operation: .type,
                agentPayload: ["operation": "type", "text": resolved, "replace": replace],
                timeout: timeout.value()
            ),
            output: output
        )
    }
}

struct UIKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press a guest key.")
    @Argument var name: String?
    @Argument var key: String
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        try runUIRequest(
            name: name,
            request: GuestUIRequest(operation: .key, agentPayload: ["operation": "key", "key": key], timeout: timeout.value()),
            output: output
        )
    }
}

struct UIKeySequenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key-sequence", abstract: "Press a sequence of guest keys.")
    @Argument var name: String?
    @Argument var keys: [String] = []
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func validate() throws {
        if keys.isEmpty { throw ValidationError("key-sequence requires at least one key.") }
    }
    mutating func run() throws {
        try runUIRequest(
            name: name,
            request: GuestUIRequest(operation: .keySequence, agentPayload: ["operation": "key-sequence", "keys": keys], timeout: timeout.value()),
            output: output
        )
    }
}

struct UIClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click guest display coordinates.")
    @Argument var name: String?
    @Option(name: .customLong("x")) var x: Double
    @Option(name: .customLong("y")) var y: Double
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        try runUIRequest(
            name: name,
            request: GuestUIRequest(operation: .click, agentPayload: ["operation": "click", "x": x, "y": y], timeout: timeout.value()),
            output: output
        )
    }
}

struct UIScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "screenshot", abstract: "Capture the guest display.")
    @Argument var name: String?
    @Option(name: .customLong("output"), help: "Host output file path.") var outputPath: String
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var format: GlobalOptions
    mutating func run() throws {
        try runUIRequest(
            name: name,
            request: GuestUIRequest(
                operation: .screenshot,
                agentPayload: ["operation": "screenshot"],
                timeout: timeout.value(),
                hostOutputPath: PommeCore.absoluteHostPath(outputPath)
            ),
            output: format
        )
    }
}

struct UIAICommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ai", abstract: "Run guided UI automation.", subcommands: [UIAISettingsCommand.self])
}

struct UIAISettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Navigate System Settings toward a goal.")
    @Argument var name: String?
    @Argument var goal: String
    @Option(name: .customLong("mode")) var mode = "suggest"
    @Option(name: .customLong("max-steps")) var maxSteps = SettingsAIRequest.defaultMaxSteps
    @Option(name: .customLong("confidence")) var confidence = SettingsAIRequest.defaultConfidence
    @Option(name: .customLong("model-timeout")) var modelTimeout = SettingsAIRequest.defaultModelTimeout
    @Flag(name: .customLong("deterministic-fallback")) var deterministicFallback = false
    @Flag(name: .customLong("no-open")) var noOpen = false
    @Option(name: .customLong("settings-url")) var settingsURL: String?
    @Option(name: .customLong("until-text")) var untilText: String?
    @Option(name: .customLong("screenshot-output")) var screenshotOutput: String?
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let settings = SettingsAIRequest(
            goal: goal,
            mode: try SettingsAIMode.parse(mode),
            provider: .appleLocal,
            maxSteps: maxSteps,
            confidenceThreshold: confidence,
            modelTimeout: modelTimeout,
            deterministicFallback: deterministicFallback,
            openSettings: !noOpen,
            settingsURL: settingsURL,
            untilText: untilText,
            screenshotOutputDirectory: screenshotOutput.map(PommeCore.absoluteHostPath)
        )
        _ = try SettingsAIRequest.parse(from: settings.jsonPayload)
        try runUIRequest(
            name: name,
            request: GuestUIRequest(operation: .settingsAI, agentPayload: settings.jsonPayload, timeout: timeout.value()),
            output: output
        )
    }
}

struct TUICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tui", abstract: "Open the interactive terminal UI.")
    @Argument var name: String?

    @MainActor mutating func run() async throws {
        guard PommeTUI.isInteractiveTerminal else { throw ValidationError("tui requires an interactive terminal.") }
        var tui = PommeTUI(initialVMName: try name.map(validateVMName))
        try await tui.run()
    }
}

struct ToolsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tools", abstract: "Print command and capability discovery data.", shouldDisplay: false)
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        let groups = CommandCatalog.groups
        try CLIOutputWriter.write(
            payload: ["ok": true, "schemaVersion": 2, "groups": groups.map(\.publicPayload), "hostExitCode": 0],
            text: groups.map { "\($0.name): \($0.commands.joined(separator: ", "))" }.joined(separator: "\n"),
            options: output
        )
    }
}

struct AgentHelpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent-help", abstract: "Print a compact command inventory for coding agents.", shouldDisplay: false)
    mutating func run() throws { print(CommandCatalog.agentHelp) }
}

enum CommandCatalog {
    struct Group: Codable, Sendable {
        let name: String
        let commands: [String]
        var publicPayload: [String: Any] { ["name": name, "commands": commands] }
    }

    static let groups: [Group] = [
        Group(name: "vm", commands: ["create", "list|ls", "start", "stop", "restart", "pause", "resume", "delete|rm", "status", "inspect", "snapshot"]),
        Group(name: "agent", commands: ["agent status", "agent repair"]),
        Group(name: "guest", commands: ["exec", "shell", "jobs", "cp", "cat"]),
        Group(name: "security", commands: ["sip", "amfi", "mdm"]),
        Group(name: "access", commands: ["remote-login", "screen-sharing", "ui click|key|key-sequence|type|screenshot|ai settings"]),
        Group(name: "config", commands: ["config init", "config validate", "config render", "ipsw"]),
        Group(name: "utility", commands: ["tui", "tools", "agent-help"])
    ]

    static let agentHelp = """
    pomme-agent-help v1; target=<vm>|POMME_VM_NAME; output=--format table|json|jsonl|raw|--json; common=--debug|--help|-h
    vm=create|list|ls|start|stop|restart|pause|resume|delete|rm|status|inspect|snapshot; agent=status|repair
    snapshot=create|list|restore|delete
    guest=exec|shell|jobs|cp|cat; security=sip|amfi|mdm; access=remote-login|screen-sharing
    ui=click|key|key-sequence|type|screenshot|ai settings
    config=config init|validate|render; ipsw=list|download; utility=tui|tools|agent-help
    """
}
