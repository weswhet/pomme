import Testing

@Suite("Pomme create resume contract")
struct CreateCommandTests {
    @Test("Resume accepts only a target and presentation options")
    func resumeGrammar() throws {
        var command = try CreateCommand.parse(["research-agent", "--resume", "--debug", "--json"])
        try command.validate()
        #expect(command.name == "research-agent")
        #expect(command.resume)
        #expect(command.output.debug)
        #expect(command.output.json)
    }

    @Test("Resume rejects creation parameters", arguments: [
        ["research-agent", "--resume", "--version", "26.6.0"],
        ["research-agent", "--resume", "--restore-image", "/tmp/Restore.ipsw"],
        ["research-agent", "--resume", "--config", "create.yaml"],
        ["research-agent", "--resume", "--dry-run"],
        ["research-agent", "--resume", "--parallel"]
    ])
    func resumeExclusivity(arguments: [String]) {
        #expect(throws: Error.self) {
            var command = try CreateCommand.parse(arguments)
            try command.validate()
        }
    }
}
