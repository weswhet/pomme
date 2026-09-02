import Testing

@Suite("Public Pomme agent command contract")
struct AgentCommandTests {
    @Test("Agent is the only public durable-workflow group")
    func publicCommandVisibility() {
        #expect(PommeCLI.configuration.commandName == "pomme")
        #expect(PommeCLI.helpMessage().contains("agent"))
        #expect(!PommeCLI.helpMessage().contains("import"))
        #expect(!PommeCLI.helpMessage().contains("lab"))
        #expect(AgentCommand.helpMessage().contains("status"))
        #expect(AgentCommand.helpMessage().contains("repair"))
    }

    @Test("Status accepts one Pomme-owned name and output options")
    func statusGrammar() throws {
        var command = try AgentStatusCommand.parse(["research-agent", "--json"])
        try command.validate()
        #expect(command.name == "research-agent")
        #expect(command.output.json)
        #expect(throws: Error.self) { _ = try AgentStatusCommand.parse(["research-agent", "--force"]) }
    }

    @Test("Repair accepts only final-state previous")
    func repairGrammar() throws {
        var command = try AgentRepairCommand.parse([
            "research-agent", "--final-state", "previous", "--format", "json"
        ])
        try command.validate()
        #expect(command.name == "research-agent")
        #expect(command.finalState == .previous)
        #expect(command.output.format == .json)
        #expect(throws: Error.self) {
            _ = try AgentRepairCommand.parse(["research-agent", "--final-state", "normal"])
        }
    }

    @Test("Retired workflow consent grammar is rejected")
    func retiredGrammar() {
        let removedPolicy = "--fall" + "back-only"
        #expect(throws: Error.self) {
            _ = try AgentCommand.parse(["create", "research-agent", removedPolicy])
        }
        #expect(!AgentCommand.helpMessage().contains("fall" + "back"))
        #expect(!AgentCommand.helpMessage().contains("adopt"))
    }
}
