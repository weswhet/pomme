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

    @Test("A stop says whether the guest shut itself down or was powered off", arguments: [
        (PommeLifecycleCommand.stop, VMStopOutcome.guestStopped, "OK stopped"),
        (.stop, .forced, "OK stopped (forced; the guest did not shut itself down)"),
        (.forceStop, .forced, "OK stopped (forced)"),
        (.forceStop, .guestStopped, "OK stopped")
    ])
    func stopTextNamesTheMethod(command: PommeLifecycleCommand, outcome: VMStopOutcome, text: String) {
        #expect(PommeApplication.lifecycleText(command, changed: true, stopOutcome: outcome) == text)
    }

    @Test("An already-stopped VM reads the same whatever the method")
    func alreadyStoppedText() {
        #expect(PommeApplication.lifecycleText(.stop, changed: false, stopOutcome: .alreadyStopped)
                == "VM is already stopped.")
        #expect(VMStopOutcome.alreadyStopped.changedState == false)
        #expect(VMStopOutcome.guestStopped.changedState)
        #expect(VMStopOutcome.forced.changedState)
    }

    @Test("The helper's lifecycle reply says whether the state changed and how it stopped")
    func lifecycleReplyCarriesChanged() {
        let reply = PommeCore.lifecycleReply(.pause, changed: false)
        let stopped = PommeCore.lifecycleReply(.stop, changed: true, stopOutcome: .guestStopped)
        let forced = PommeCore.lifecycleReply(.forceStop, changed: true, stopOutcome: .forced)

        #expect(reply["changed"] as? Bool == false)
        #expect(reply["operation"] as? String == "pause")
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["stopMethod"] == nil)
        #expect(stopped["stopMethod"] as? String == "guest-stopped")
        #expect(forced["stopMethod"] as? String == "forced")
    }

    @Test("A guest shutdown is requested only for a running normal VM with a connected agent")
    func guestShutdownPreconditions() {
        func status(_ state: String, _ mode: String, _ connection: String) -> [String: Any] {
            ["vmState": state, "bootMode": mode, "guestAgent": ["connection": connection]]
        }

        #expect(PommeCore.shouldRequestGuestShutdown(status: status("running", "normal", "connected")))
        #expect(!PommeCore.shouldRequestGuestShutdown(status: status("running", "recovery", "connected")))
        #expect(!PommeCore.shouldRequestGuestShutdown(status: status("paused", "normal", "connected")))
        #expect(!PommeCore.shouldRequestGuestShutdown(status: status("running", "normal", "disconnected")))
        #expect(!PommeCore.shouldRequestGuestShutdown(status: [:]))
    }

    @Test("A normal guest gets a longer shutdown window than helper teardown")
    func guestShutdownWindowIsLongerThanTeardown() {
        #expect(Constants.guestShutdownTimeoutSeconds > Constants.gracefulStopTimeoutSeconds)
    }
}
