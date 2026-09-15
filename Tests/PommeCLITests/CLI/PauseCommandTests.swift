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

    @Test("Lifecycle text confirms a change and names a no-op", arguments: [
        (PommeLifecycleCommand.pause, true, "OK paused"),
        (.pause, false, "VM is already paused."),
        (.resume, true, "OK resumed"),
        (.resume, false, "VM is already running."),
        (.stop, true, "OK stopped"),
        (.stop, false, "VM is already stopped."),
        (.forceStop, true, "OK stopped (forced)"),
        (.forceStop, false, "VM is already stopped.")
    ])
    func lifecycleText(command: PommeLifecycleCommand, changed: Bool, text: String) {
        #expect(PommeApplication.lifecycleText(command, changed: changed) == text)
    }

    @Test("The helper's lifecycle reply says whether the state changed")
    func lifecycleReplyCarriesChanged() {
        let reply = PommeCore.lifecycleReply(.pause, changed: false)

        #expect(reply["changed"] as? Bool == false)
        #expect(reply["operation"] as? String == "pause")
        #expect(reply["ok"] as? Bool == true)
    }
}
