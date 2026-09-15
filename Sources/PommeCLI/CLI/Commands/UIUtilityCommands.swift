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
            UIKeysCommand.self,
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

/// Resolves UI actions whose first positional value can otherwise be mistaken
/// for an optional VM name. Fixed-arity actions preserve the established
/// `[<vm>] <action>` grammar. A key sequence with an environment target only
/// accepts a positional VM when the first value cannot be a display key; the
/// remaining overlap is rejected rather than guessing which guest receives it.
enum UIPositionalTargetResolver {
    static func singleAction(
        arguments: [String],
        environmentTarget: String? = ProcessInfo.processInfo.environment["POMME_VM_NAME"],
        action: String
    ) throws -> (target: String, action: String) {
        switch arguments.count {
        case 1:
            return (try self.environmentTarget(environmentTarget), arguments[0])
        case 2:
            return (try validateVMName(arguments[0]), arguments[1])
        default:
            let value = action == "ai settings" ? "goal" : "key"
            throw ValidationError("Usage: pomme ui \(action) [<vm>] <\(value)> (or set POMME_VM_NAME).")
        }
    }

    static func keySequence(
        arguments: [String],
        explicitTarget: String?,
        environmentTarget: String? = ProcessInfo.processInfo.environment["POMME_VM_NAME"]
    ) throws -> (target: String, keys: [String]) {
        if let explicitTarget {
            guard !arguments.isEmpty else {
                throw ValidationError("key-sequence requires at least one key.")
            }
            return (try validateVMName(explicitTarget), arguments)
        }

        if let environmentTarget, !environmentTarget.isEmpty {
            guard !arguments.isEmpty else {
                throw ValidationError("key-sequence requires at least one key.")
            }
            if arguments.count == 1 {
                return (try self.environmentTarget(environmentTarget), arguments)
            }

            let first = arguments[0]
            if HostDisplayKey.lookup(first) == nil {
                return (try validateVMName(first), Array(arguments.dropFirst()))
            }
            if (try? validateVMName(first)) != nil {
                throw ValidationError(
                    "POMME_VM_NAME makes \(first) ambiguous as either a VM name or a key; use --vm <vm> to select the target."
                )
            }
            return (try self.environmentTarget(environmentTarget), arguments)
        }

        guard arguments.count >= 2 else {
            throw ValidationError("Usage: pomme ui key-sequence <vm> <key>... (or set POMME_VM_NAME for one key, or use --vm <vm>).")
        }
        return (try validateVMName(arguments[0]), Array(arguments.dropFirst()))
    }

    private static func environmentTarget(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else {
            throw ValidationError("Specify a VM name or set POMME_VM_NAME.")
        }
        return try validateVMName(value)
    }
}

struct UITypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into the guest display.")
    @Argument var name: String?
    @Option(name: .customLong("text"), help: "Text to type.") var text: String?
    @Option(name: .customLong("text-env"), help: "Environment variable containing text to type.") var textEnvironment: String?
    @Flag(name: .customLong("replace"), help: "Press Command-A before typing so the text replaces the focused field's contents. Off by default.") var replace = false
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
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press a guest key. Uses POMME_VM_NAME when the VM is omitted.")
    @Argument(help: "[VM name] key. Uses POMME_VM_NAME when the VM name is omitted.") var arguments: [String] = []
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func validate() throws {
        _ = try UIPositionalTargetResolver.singleAction(arguments: arguments, action: "key")
    }
    mutating func run() throws {
        let resolved = try UIPositionalTargetResolver.singleAction(arguments: arguments, action: "key")
        try runUIRequest(
            name: resolved.target,
            request: GuestUIRequest(operation: .key, agentPayload: ["operation": "key", "key": resolved.action], timeout: timeout.value()),
            output: output
        )
    }
}

struct UIKeySequenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key-sequence",
        abstract: "Press a sequence of guest keys. Use --vm when POMME_VM_NAME makes the first value ambiguous."
    )
    @Option(name: .customLong("vm"), help: "VM name for an unambiguous key sequence.") var explicitTarget: String?
    @Argument(help: "[VM name] key...; with POMME_VM_NAME, use --vm for a multiple-key sequence that could begin with a VM name.") var arguments: [String] = []
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func validate() throws {
        _ = try UIPositionalTargetResolver.keySequence(arguments: arguments, explicitTarget: explicitTarget)
    }
    mutating func run() throws {
        let resolved = try UIPositionalTargetResolver.keySequence(arguments: arguments, explicitTarget: explicitTarget)
        try runUIRequest(
            name: resolved.target,
            request: GuestUIRequest(operation: .keySequence, agentPayload: ["operation": "key-sequence", "keys": resolved.keys], timeout: timeout.value()),
            output: output
        )
    }
}

/// Lists the vocabulary `ui key` and `ui key-sequence` accept. It reads the
/// same table the helper validates against, so it needs no VM.
struct UIKeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keys", abstract: "List the key names accepted by ui key and ui key-sequence.")
    @OptionGroup var output: GlobalOptions

    static let characterNote = "Any single character on a US keyboard; an uppercase letter or shifted symbol implies Shift."
    static let chainingNote = "Modifier prefixes chain left to right, for example cmd-shift-t; `+` is accepted in place of `-`."

    mutating func run() throws {
        let named = HostDisplayKey.namedKeys
        let modifiers = HostDisplayKey.modifierPrefixes
        var lines = ["KEY\tALIASES"]
        lines += named.map { "\($0.name)\t\($0.aliases.joined(separator: ", "))" }
        lines += ["", "MODIFIER\tALIASES"]
        lines += modifiers.map { "\($0.prefix)\t\($0.aliases.joined(separator: ", "))" }
        lines += ["", "Characters: \(Self.characterNote)", "Chaining: \(Self.chainingNote)"]
        let payload: [String: Any] = [
            "ok": true,
            "hostExitCode": 0,
            "namedKeys": named.map { ["name": $0.name, "aliases": $0.aliases] },
            "modifierPrefixes": modifiers.map { ["prefix": $0.prefix, "aliases": $0.aliases] },
            "characters": Self.characterNote,
            "chaining": Self.chainingNote,
            "separators": ["-", "+"]
        ]
        let elements = named.map { ["kind": "key", "name": $0.name, "aliases": $0.aliases] as [String: Any] }
            + modifiers.map { ["kind": "modifier", "prefix": $0.prefix, "aliases": $0.aliases] as [String: Any] }
        try CLIOutputWriter.write(payload: payload, text: lines.joined(separator: "\n"), options: output, jsonlElements: elements)
    }
}

struct UIClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click guest display coordinates.")
    @Argument var name: String?
    @Option(name: .customLong("x"), parsing: .unconditional, help: "Display x coordinate in points, from the left edge.") var x: Double
    @Option(name: .customLong("y"), parsing: .unconditional, help: "Display y coordinate in points, from the top edge.") var y: Double
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func validate() throws {
        for (flag, value) in [("--x", x), ("--y", y)] where !(value.isFinite && value >= 0) {
            throw ValidationError("\(flag) must be a finite display coordinate of zero or more.")
        }
    }

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
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Run guided UI automation. Currently unavailable without a guest accessibility bridge.",
        subcommands: [UIAISettingsCommand.self]
    )
}

extension SettingsAIMode: ExpressibleByArgument {}

struct UIAISettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Navigate System Settings toward a goal. Currently unavailable without a guest accessibility bridge."
    )
    @Argument(help: "[VM name] goal. Uses POMME_VM_NAME when the VM name is omitted.") var arguments: [String] = []
    @Option(name: .customLong("mode"), help: "suggest proposes one action, step performs one, loop repeats up to --max-steps.")
    var mode: SettingsAIMode = .suggest
    @Option(name: .customLong("max-steps"), parsing: .unconditional, help: "Most actions a loop run performs.")
    var maxSteps = SettingsAIRequest.defaultMaxSteps
    @Option(name: .customLong("confidence"), parsing: .unconditional, help: "Minimum model confidence, from 0 to 1, required to act.")
    var confidence = SettingsAIRequest.defaultConfidence
    @Option(name: .customLong("model-timeout"), parsing: .unconditional, help: "Seconds to wait for each model answer.")
    var modelTimeout = SettingsAIRequest.defaultModelTimeout
    @Flag(name: .customLong("deterministic-fallback"), help: "Fall back to text-matching navigation when the model is unavailable. Off by default.")
    var deterministicFallback = false
    @Flag(name: .customLong("no-open"), help: "Use the window already on screen instead of opening System Settings first.")
    var noOpen = false
    @Option(name: .customLong("settings-url"), help: "x-apple.systempreferences URL to open first. Defaults to System Settings' main window.")
    var settingsURL: String?
    @Option(name: .customLong("until-text"), help: "Stop once this text is visible on screen. Unset by default.")
    var untilText: String?
    @Option(name: .customLong("screenshot-output"), help: "Host directory for per-step screenshots. Defaults to a new temporary directory.")
    var screenshotOutput: String?
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions
    mutating func validate() throws {
        _ = try request()
    }

    mutating func run() throws {
        let resolved = try request()
        try runUIRequest(name: resolved.target, request: resolved.request, output: output)
    }

    private func request() throws -> (target: String, request: GuestUIRequest) {
        let resolved = try UIPositionalTargetResolver.singleAction(arguments: arguments, action: "ai settings")
        let settings = SettingsAIRequest(
            goal: resolved.action,
            mode: mode,
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
        return (
            resolved.target,
            GuestUIRequest(operation: .settingsAI, agentPayload: settings.jsonPayload, timeout: try timeout.value())
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
            payload: [
                "ok": true,
                "schemaVersion": 2,
                "groups": groups.map(\.publicPayload),
                "uiCapabilities": PommeUICapabilities.publicPayload,
                "hostExitCode": 0
            ],
            text: groups.map { "\($0.name): \($0.commands.joined(separator: ", "))" }.joined(separator: "\n"),
            options: output,
            jsonlCollection: "groups"
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
        Group(name: "access", commands: ["remote-login", "screen-sharing", "ui click|key|key-sequence|keys|type|screenshot|ai settings"]),
        Group(name: "config", commands: ["config init", "config validate", "config render", "ipsw"]),
        Group(name: "utility", commands: ["tui", "tools", "agent-help"])
    ]

    static let agentHelp = """
    pomme-agent-help v1; target=<vm>|POMME_VM_NAME; output=--format table|json|jsonl|--json; common=--debug|--help|-h
    vm=create|list|ls|start|stop|restart|pause|resume|delete|rm|status|inspect|snapshot; agent=status|repair
    snapshot=create|list|restore|delete
    guest=exec|shell|jobs|cp|cat; security=sip|amfi|mdm; access=remote-login|screen-sharing
    ui=click|key|key-sequence|keys|type|screenshot|ai settings
    ui-unavailable=ai settings
    config=config init|validate|render; ipsw=list|download; utility=tui|tools|agent-help
    """
}
