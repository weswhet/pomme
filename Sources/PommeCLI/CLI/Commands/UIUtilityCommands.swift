import ArgumentParser
import Foundation

/// Host-display UI input and screenshots.
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
            UIScreenshotCommand.self
        ]
    )
}

private func runUIRequest(name: String?, request: GuestUIRequest, output: GlobalOptions) throws {
    let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
    try CLIOutputWriter.write(PommeEnvironment.live().guest.ui(target, request), options: output)
}

/// The VM a `ui` command acts on. It's an option rather than a positional,
/// so it never competes with the text, key, or keys that the command sends.
struct UITargetOptions: ParsableArguments {
    @Option(name: .customLong("vm"), help: "VM name. Uses POMME_VM_NAME when omitted.")
    var name: String?
}

struct UITypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into the guest display.")
    @OptionGroup var target: UITargetOptions
    @Option(name: .customLong("text"), help: "Text to type.") var text: String?
    @Option(name: .customLong("text-env"), help: "Environment variable containing text to type.") var textEnvironment: String?
    @Flag(name: .customLong("replace"), help: "Press Command-A before typing so the text replaces the focused field's contents. Off by default.") var replace = false
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard (text == nil) != (textEnvironment == nil) else {
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
            name: target.name,
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
    @OptionGroup var target: UITargetOptions
    @Option(name: .customLong("key"), help: "Key name, such as return or cmd-shift-t. Run `pomme ui keys` for the names.") var key: String
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        try runUIRequest(
            name: target.name,
            request: GuestUIRequest(operation: .key, agentPayload: ["operation": "key", "key": key], timeout: timeout.value()),
            output: output
        )
    }
}

struct UIKeySequenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key-sequence", abstract: "Press a sequence of guest keys.")
    @OptionGroup var target: UITargetOptions
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    // Like `exec`, only tokens after `--` are keys, so no key can be taken
    // for an option or a VM name.
    @Argument(parsing: .postTerminator, help: "Key names after --, pressed in order.")
    var keys: [String] = []

    mutating func validate() throws {
        guard !keys.isEmpty else {
            throw ValidationError("Put the keys after --, for example: pomme ui key-sequence --vm dev -- down return.")
        }
    }

    mutating func run() throws {
        try runUIRequest(
            name: target.name,
            request: GuestUIRequest(operation: .keySequence, agentPayload: ["operation": "key-sequence", "keys": keys], timeout: timeout.value()),
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
    @OptionGroup var target: UITargetOptions
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
            name: target.name,
            request: GuestUIRequest(operation: .click, agentPayload: ["operation": "click", "x": x, "y": y], timeout: timeout.value()),
            output: output
        )
    }
}

struct UIScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "screenshot", abstract: "Capture the guest display.")
    @OptionGroup var target: UITargetOptions
    @Option(name: .customLong("output"), help: "Host output file path.") var outputPath: String
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var format: GlobalOptions

    /// The helper writes the file as this user on this filesystem, so a
    /// missing parent or a directory leaf is reported before any VM lookup.
    mutating func validate() throws {
        try Self.validateOutputPath(outputPath)
    }

    static func validateOutputPath(_ path: String) throws {
        let absolute = PommeCore.absoluteHostPath(path)
        let parent = (absolute as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("No such directory: \(parent)")
        }
        if FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ValidationError("\(absolute) is a directory; give a file path.")
        }
    }

    mutating func run() throws {
        try runUIRequest(
            name: target.name,
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
            payload: CommandCatalog.publicPayload,
            text: groups.map { "\($0.name): \($0.commands.joined(separator: ", "))" }.joined(separator: "\n"),
            options: output,
            jsonlCollection: "groups"
        )
    }
}

struct AgentHelpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent-help", abstract: "Print a compact command inventory for coding agents.", shouldDisplay: false)
    @OptionGroup var output: GlobalOptions
    mutating func run() throws {
        try CLIOutputWriter.write(
            payload: CommandCatalog.publicPayload,
            text: CommandCatalog.agentHelp,
            options: output,
            jsonlCollection: "groups"
        )
    }
}

enum CommandCatalog {
    struct Group: Codable, Sendable {
        let name: String
        let commands: [String]
        var publicPayload: [String: Any] { ["name": name, "commands": commands] }
    }

    static let groups: [Group] = [
        Group(name: "vm", commands: ["create", "list|ls", "start", "stop", "restart", "pause", "resume", "delete|rm", "status", "inspect", "snapshot", "template"]),
        Group(name: "agent", commands: ["agent status", "agent repair", "agent update"]),
        Group(name: "guest", commands: ["exec", "shell", "log", "jobs", "sessions", "cp", "cat"]),
        Group(name: "security", commands: ["sip", "amfi", "mdm"]),
        Group(name: "access", commands: ["remote-login", "screen-sharing", "ui click|key|key-sequence|keys|type|screenshot"]),
        Group(name: "config", commands: ["config init", "config validate", "config render", "ipsw"]),
        Group(name: "utility", commands: ["update", "tui", "tools", "agent-help"])
    ]

    static var publicPayload: [String: Any] {
        [
            "ok": true,
            "schemaVersion": 1,
            "groups": groups.map(\.publicPayload),
            "uiCapabilities": PommeUICapabilities.publicPayload,
            "hostExitCode": 0
        ]
    }

    /// Preserve the compact v1 layout while taking group membership and aliases
    /// from the same catalog as machine-readable discovery.
    private static func compactGroup(_ name: String, excluding: Set<String> = [], removingPrefix: String = "") -> String {
        groups.filter { $0.name == name }.flatMap(\.commands)
            .filter { !excluding.contains($0.components(separatedBy: " ")[0]) }
            .map { command in
                command.hasPrefix(removingPrefix) ? String(command.dropFirst(removingPrefix.count)) : command
            }
            .joined(separator: "|")
    }

    private static var compactUI: String {
        groups.filter { $0.name == "access" }.flatMap(\.commands)
            .filter { $0.hasPrefix("ui ") }
            .map { String($0.dropFirst(3)) }
            .joined(separator: "|")
    }

    static var agentHelp: String { """
    pomme-agent-help v1; target=<vm>|POMME_VM_NAME; output=--format table|json|jsonl|--json; common=--debug|--help|-h
    vm=\(compactGroup("vm")); agent=\(compactGroup("agent", removingPrefix: "agent "))
    snapshot=create|list|restore|delete
    template=create|list|delete
    guest=\(compactGroup("guest")); security=\(compactGroup("security")); access=\(compactGroup("access", excluding: ["ui"]))
    sessions=list|ls|inspect|attach|logs|terminate|delete
    ui=\(compactUI)
    config=config \(compactGroup("config", excluding: ["ipsw"], removingPrefix: "config ")); ipsw=list|download; utility=\(compactGroup("utility"))
    """ }
}
