import Foundation
import ArgumentParser
import Testing

@Suite("Public UI utility command grammar")
struct UIUtilityCommandTests {
    @Test("Every VM-bound UI command names the VM with --vm")
    func vmOption() throws {
        let key = try UIKeyCommand.parse(["--vm", "dev", "--key", "return", "--format", "json"])
        let sequence = try UIKeySequenceCommand.parse(["--vm", "dev", "--", "left", "right"])
        let type = try UITypeCommand.parse(["--vm", "dev", "--text", "hi"])
        let click = try UIClickCommand.parse(["--vm", "dev", "--x", "1", "--y", "2"])

        #expect(key.target.name == "dev" && key.key == "return" && key.output.format == .json)
        #expect(sequence.target.name == "dev" && sequence.keys == ["left", "right"])
        #expect(type.target.name == "dev" && type.text == "hi")
        #expect(click.target.name == "dev")
    }

    @Test("Without --vm the target is left to POMME_VM_NAME")
    func vmOptionIsOptional() throws {
        let key = try UIKeyCommand.parse(["--key", "cmd-shift-t"])
        let sequence = try UIKeySequenceCommand.parse(["--", "dev", "return"])

        #expect(key.target.name == nil && key.key == "cmd-shift-t")
        // After --, a value that looks like a VM name is still a key.
        #expect(sequence.target.name == nil && sequence.keys == ["dev", "return"])
    }

    @Test("Keys after -- may look like options")
    func keysFollowTerminator() throws {
        let sequence = try UIKeySequenceCommand.parse(["--vm", "dev", "--", "-", "--json"])
        #expect(sequence.keys == ["-", "--json"])
        #expect(!sequence.output.json)
    }

    @Test("UI commands take no positional values", arguments: [
        (UIKeyCommand.self as ParsableCommand.Type, ["dev", "--key", "return"]),
        (UITypeCommand.self, ["dev", "--text", "hi"]),
        (UIClickCommand.self, ["dev", "--x", "1", "--y", "2"]),
        (UIScreenshotCommand.self, ["dev", "--output", "/tmp/s.png"])
    ])
    func positionalVMIsRejected(command: ParsableCommand.Type, arguments: [String]) {
        do {
            _ = try command.parse(arguments)
            Issue.record("\(command._commandName) accepted a positional VM name.")
        } catch {
            #expect(command.fullMessage(for: error).contains("Unexpected argument 'dev'"))
        }
    }

    @Test("ui key requires --key")
    func keyRequiresOption() {
        do {
            _ = try UIKeyCommand.parse(["--vm", "dev"])
            Issue.record("ui key accepted no key.")
        } catch {
            #expect(UIKeyCommand.fullMessage(for: error).contains("Missing expected argument '--key <key>'"))
        }
    }

    @Test("ui key-sequence requires keys after --", arguments: [
        ["--vm", "dev"],
        ["--vm", "dev", "--"],
        ["--vm", "dev", "return"]
    ])
    func keySequenceRequiresTerminatedKeys(arguments: [String]) {
        do {
            _ = try UIKeySequenceCommand.parse(arguments)
            Issue.record("ui key-sequence accepted \(arguments).")
        } catch {
            let message = UIKeySequenceCommand.fullMessage(for: error)
            #expect(message.contains("Put the keys after --") || message.contains("Unexpected argument 'return'"))
        }
    }

    @Test("ui ai is no longer a command")
    func aiIsRemoved() {
        #expect(!UICommand.configuration.subcommands.contains { $0._commandName == "ai" })
        do {
            _ = try PommeCLI.parseAsRoot(["ui", "ai", "settings"])
            Issue.record("ui ai settings still parses.")
        } catch {
            #expect(PommeCLI.fullMessage(for: error).contains("unexpected arguments: 'ai', 'settings'"))
        }
        #expect(!CommandCatalog.agentHelp.contains("ai settings"))
        #expect(!CommandCatalog.agentHelp.contains("ui-unavailable"))
    }
}

@Suite("UI type grammar")
struct UITypeCommandTests {
    @Test("--text and --text-env each supply the text")
    func textForms() throws {
        let text = try UITypeCommand.parse(["--vm", "t1", "--text", "hi"])
        let environmentText = try UITypeCommand.parse(["--text-env", "GREETING", "--replace"])

        #expect(text.target.name == "t1")
        #expect(text.text == "hi" && text.textEnvironment == nil)
        #expect(environmentText.target.name == nil)
        #expect(environmentText.textEnvironment == "GREETING" && environmentText.replace)
    }

    @Test("Exactly one of --text or --text-env is required", arguments: [
        ["--vm", "t1", "--text", "hi", "--text-env", "GREETING"],
        ["--vm", "t1"],
        [String]()
    ])
    func conflictingOrMissingForms(arguments: [String]) {
        do {
            _ = try UITypeCommand.parse(arguments)
            Issue.record("ui type accepted \(arguments).")
        } catch {
            #expect(UITypeCommand.fullMessage(for: error).contains("Choose exactly one of --text or --text-env."))
        }
    }

    @Test("Positional text is rejected")
    func positionalTextIsRejected() {
        do {
            _ = try UITypeCommand.parse(["--vm", "t1", "--text", "hi", "hello"])
            Issue.record("ui type accepted positional text.")
        } catch {
            #expect(UITypeCommand.fullMessage(for: error).contains("Unexpected argument 'hello'"))
        }
    }
}

@Suite("UI screenshot output path")
struct UIScreenshotOutputPathTests {
    @Test("A file path in an existing directory is accepted")
    func existingParentAccepted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try UIScreenshotCommand.validateOutputPath(directory.appendingPathComponent("s.png").path)
    }

    @Test("A missing parent directory is named")
    func missingParentRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("nonexistentdir").standardizedFileURL.path

        let error = #expect(throws: ValidationError.self) {
            try UIScreenshotCommand.validateOutputPath(missing + "/s.png")
        }
        #expect(error?.message == "No such directory: \(missing)")
    }

    @Test("A directory leaf is rejected")
    func directoryLeafRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.standardizedFileURL.path

        let error = #expect(throws: ValidationError.self) {
            try UIScreenshotCommand.validateOutputPath(path)
        }
        #expect(error?.message == "\(path) is a directory; give a file path.")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-screenshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

@Suite("UI command help")
struct UICommandHelpTests {
    @Test("Every UI command describes each of its options", arguments: [
        UITypeCommand.self as ParsableCommand.Type,
        UIKeyCommand.self,
        UIKeySequenceCommand.self,
        UIClickCommand.self,
        UIScreenshotCommand.self
    ])
    func helpDescribesEveryOption(_ command: ParsableCommand.Type) throws {
        #expect(try undescribedOptions(command).isEmpty)
        #expect(command.helpMessage(columns: 400).contains("--vm <vm>"))
    }

    @Test("config render names its output as the creation plan")
    func configRenderAbstract() {
        #expect(ConfigRenderCommand.helpMessage().contains("creation plan"))
    }

    /// Named options and flags whose help dump carries no abstract.
    private func undescribedOptions(_ command: ParsableCommand.Type) throws -> [String] {
        let dump = try #require(JSONSerialization.jsonObject(with: Data(command._dumpHelp().utf8)) as? [String: Any])
        let arguments = (dump["command"] as? [String: Any])?["arguments"] as? [[String: Any]] ?? []
        return arguments.compactMap { argument in
            guard argument["kind"] as? String != "positional",
                  (argument["abstract"] as? String ?? "").isEmpty else { return nil }
            return (argument["valueName"] as? String) ?? "?"
        }
    }
}

@Suite("UI keys listing")
struct UIKeysCommandTests {
    @Test("ui keys is registered and takes no VM")
    func keysIsRegistered() throws {
        _ = try UIKeysCommand.parse([])
        _ = try UIKeysCommand.parse(["--format", "json"])
        #expect(UICommand.helpMessage().contains("keys"))
        #expect(CommandCatalog.agentHelp.contains("keys"))
        #expect(CommandCatalog.groups.contains { $0.commands.contains { $0.contains("keys") } })
    }
}

@Suite("Command inventory")
struct CommandCatalogTests {
    @Test("The command inventory lists every agent and config subcommand")
    func inventoryListsSubcommands() {
        let listed = Set(CommandCatalog.groups.flatMap(\.commands))
        for parent in [AgentCommand.self, ConfigCommand.self] as [ParsableCommand.Type] {
            for child in parent.configuration.subcommands {
                let command = "\(parent._commandName) \(child._commandName)"
                #expect(listed.contains(command), "\(command) is missing from pomme tools and agent-help")
            }
        }
    }
}
