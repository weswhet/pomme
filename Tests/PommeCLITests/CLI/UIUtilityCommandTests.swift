import Foundation
import ArgumentParser
import Testing

@Suite("Public UI utility command grammar")
struct UIUtilityCommandTests {
    @Test("Key and settings goals use POMME_VM_NAME for a single action")
    func fixedArityEnvironmentFallback() throws {
        let key = try UIPositionalTargetResolver.singleAction(
            arguments: ["return"], environmentTarget: "default-vm", action: "key"
        )
        let goal = try UIPositionalTargetResolver.singleAction(
            arguments: ["Open Keyboard settings"], environmentTarget: "default-vm", action: "ai settings"
        )

        #expect(key.target == "default-vm")
        #expect(key.action == "return")
        #expect(goal.target == "default-vm")
        #expect(goal.action == "Open Keyboard settings")
    }

    @Test("Fixed-arity UI actions preserve an explicit target")
    func fixedArityExplicitTargetOverridesEnvironment() throws {
        let key = try UIPositionalTargetResolver.singleAction(
            arguments: ["other-vm", "return"], environmentTarget: "default-vm", action: "key"
        )

        #expect(key.target == "other-vm")
        #expect(key.action == "return")
    }

    @Test("Fixed-arity UI actions reject missing, extra, and malformed fallback targets")
    func fixedArityFailures() {
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.singleAction(arguments: [], environmentTarget: nil, action: "key")
        }
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.singleAction(arguments: ["one", "two", "three"], environmentTarget: "default-vm", action: "key")
        }
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.singleAction(arguments: ["return"], environmentTarget: " ", action: "key")
        }
    }

    @Test("Key sequence preserves unambiguous explicit targets and a single environment key")
    func keySequenceUnambiguousResolution() throws {
        let explicit = try UIPositionalTargetResolver.keySequence(
            arguments: ["other-vm", "left", "right"], explicitTarget: nil, environmentTarget: "default-vm"
        )
        let omitted = try UIPositionalTargetResolver.keySequence(
            arguments: ["return"], explicitTarget: nil, environmentTarget: "default-vm"
        )
        let option = try UIPositionalTargetResolver.keySequence(
            arguments: ["left", "right"], explicitTarget: "override-vm", environmentTarget: "default-vm"
        )
        let modifierSequence = try UIPositionalTargetResolver.keySequence(
            arguments: ["cmd+shift+t", "return"], explicitTarget: nil, environmentTarget: "default-vm"
        )

        #expect(explicit.target == "other-vm")
        #expect(explicit.keys == ["left", "right"])
        #expect(omitted.target == "default-vm")
        #expect(omitted.keys == ["return"])
        #expect(option.target == "override-vm")
        #expect(option.keys == ["left", "right"])
        #expect(modifierSequence.target == "default-vm")
        #expect(modifierSequence.keys == ["cmd+shift+t", "return"])
    }

    @Test("Key sequence rejects an environment ambiguity before input")
    func keySequenceAmbiguity() {
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.keySequence(
                arguments: ["return", "right"], explicitTarget: nil, environmentTarget: "default-vm"
            )
        }
    }

    @Test("Key sequence rejects missing keys and malformed environment targets")
    func keySequenceFailures() {
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.keySequence(arguments: [], explicitTarget: "override-vm", environmentTarget: "default-vm")
        }
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.keySequence(arguments: ["return"], explicitTarget: nil, environmentTarget: " ")
        }
        #expect(throws: Error.self) {
            _ = try UIPositionalTargetResolver.keySequence(arguments: ["return"], explicitTarget: nil, environmentTarget: nil)
        }
    }

    @Test("UI positional actions and existing AI option bounds parse and validate")
    func commandGrammarAndAIValidation() throws {
        var key = try UIKeyCommand.parse(["dev", "return", "--format", "json"])
        var sequence = try UIKeySequenceCommand.parse(["--vm", "dev", "left", "right"])
        var settings = try UIAISettingsCommand.parse([
            "dev", "Open Keyboard settings", "--mode", "suggest", "--max-steps", "1", "--confidence", "0.5", "--model-timeout", "1"
        ])

        try key.validate()
        try sequence.validate()
        try settings.validate()
        #expect(key.arguments == ["dev", "return"])
        #expect(sequence.explicitTarget == "dev")
        #expect(sequence.arguments == ["left", "right"])
        #expect(settings.arguments == ["dev", "Open Keyboard settings"])

        #expect(throws: Error.self) {
            var invalid = try UIAISettingsCommand.parse(["dev", "Goal", "--max-steps", "0"])
            try invalid.validate()
        }
        #expect(throws: Error.self) {
            var invalid = try UIAISettingsCommand.parse(["dev", "Goal", "--confidence", "2"])
            try invalid.validate()
        }
        #expect(throws: Error.self) {
            var invalid = try UIAISettingsCommand.parse(["dev", "Goal", "--model-timeout", "0"])
            try invalid.validate()
        }
        #expect(throws: Error.self) {
            var invalid = try UIAISettingsCommand.parse(["dev", "Goal", "--mode", "unsupported"])
            try invalid.validate()
        }
    }
}

@Suite("UI type grammar")
struct UITypeCommandTests {
    @Test("Positional text follows an optional VM name")
    func positionalText() throws {
        let explicit = try UITypeCommand.parse(["t1", "hi"]).target(environmentTarget: nil)
        let environment = try UITypeCommand.parse(["hi"]).target(environmentTarget: "t2")

        #expect(explicit.name == "t1")
        #expect(explicit.positionalText == "hi")
        #expect(environment.name == "t2")
        #expect(environment.positionalText == "hi")
    }

    @Test("--text and --text-env take at most a VM name positionally")
    func explicitTextForms() throws {
        let text = try UITypeCommand.parse(["t1", "--text", "hi"]).target(environmentTarget: nil)
        let environmentText = try UITypeCommand.parse(["--text-env", "GREETING"]).target(environmentTarget: nil)

        #expect(text.name == "t1")
        #expect(text.positionalText == nil)
        #expect(environmentText.name == nil)
        #expect(environmentText.positionalText == nil)
    }

    @Test("Conflicting or missing text forms are rejected", arguments: [
        ["t1", "hi", "--text", "hi"],
        ["t1", "--text", "hi", "--text-env", "GREETING"],
        ["t1", "hi", "--text-env", "GREETING"],
        [String]()
    ])
    func conflictingForms(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try UITypeCommand.parse(arguments)
        }
    }

    @Test("Positional text without any target names the grammar")
    func missingTarget() throws {
        let command = try UITypeCommand.parse(["hi"])

        #expect(throws: ValidationError.self) {
            _ = try command.target(environmentTarget: nil)
        }
    }
}

@Suite("UI command help")
struct UICommandHelpTests {
    @Test("ui ai settings lists its modes and describes every option")
    func aiSettingsHelpDescribesEveryOption() throws {
        #expect(UIAISettingsCommand.helpMessage(columns: 400).contains("suggest, step, loop"))
        #expect(try undescribedOptions(UIAISettingsCommand.self).isEmpty)
    }

    @Test("ui type describes --replace")
    func typeHelpDescribesReplace() throws {
        #expect(try undescribedOptions(UITypeCommand.self).isEmpty)
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
