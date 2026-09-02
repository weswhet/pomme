import Testing

@Suite("Pause lifecycle command")
struct PauseCommandTests {
    @Test("Pause is public and suspend is absent from root help")
    func rootCommandVocabulary() {
        let help = PommeCLI.helpMessage()
        #expect(help.contains("pause"))
        #expect(!help.contains("suspend"))
    }

    @Test("Pause accepts a named target")
    func parsesPause() throws {
        let command = try PauseCommand.parse(["dev"])
        #expect(command.names == ["dev"])
    }

    @Test("Paused is accepted while suspended final state is rejected")
    func finalStateVocabulary() {
        #expect(VMFinalState(rawValue: "paused") == .paused)
        #expect(VMFinalState(rawValue: "suspended") == nil)
    }
}
