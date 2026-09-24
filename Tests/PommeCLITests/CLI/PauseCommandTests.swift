import Foundation
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

    @Test("A restart ends on its boot line")
    func restartTextEndsOnTheBoot() {
        let clean: [String: Any] = ["stopMethod": "guest-stopped", "forceRequested": false]

        #expect(PommeApplication.restartText(
            stopText: "OK stopped", stopPayload: clean, bootText: "OK boot mode=normal"
        ) == "OK boot mode=normal")
        #expect(PommeApplication.restartText(
            stopText: "OK stopped", stopPayload: [:], bootText: "OK Recovery ready"
        ) == "OK Recovery ready")
    }

    @Test("A restart that had to power the guest off keeps that line above the boot")
    func restartTextKeepsAForcedStop() {
        let forced: [String: Any] = ["stopMethod": "forced", "forceRequested": false]
        let text = PommeApplication.restartText(
            stopText: "OK stopped (forced; the guest did not shut itself down)",
            stopPayload: forced,
            bootText: "OK boot mode=normal"
        )

        #expect(text == "OK stopped (forced; the guest did not shut itself down)\nOK boot mode=normal")
        #expect(text.split(separator: "\n").last.map(String.init) == "OK boot mode=normal")
    }

    @Test("Restart payload reports each stop method and keeps ordered phase payloads", arguments: [
        VMStopOutcome.guestStopped.rawValue,
        VMStopOutcome.forced.rawValue,
        VMStopOutcome.alreadyStopped.rawValue
    ])
    func restartPayloadCopiesStopMethod(_ stopMethod: String) throws {
        let status: [String: Any] = ["phase": "status", "vmState": "running"]
        let stop: [String: Any] = ["phase": "stop", "stopMethod": stopMethod, "stopMarker": "from-stop"]
        let boot: [String: Any] = [
            "phase": "boot",
            "bootMarker": "from-boot",
            "stopMethod": "boot-conflict",
            "operation": "boot",
            "preservedMode": false,
            "ok": true
        ]

        let payload = PommeApplication.restartPayload(
            status: status,
            stop: stop,
            boot: boot,
            preservedMode: true
        )

        #expect(payload["operation"] as? String == "restart")
        #expect(payload["preservedMode"] as? Bool == true)
        #expect(payload["stopMethod"] as? String == stopMethod)
        #expect(payload["bootMarker"] as? String == "from-boot")
        #expect(payload["phase"] as? String == "boot")

        let steps = try #require(payload["steps"] as? [[String: Any]])
        #expect(steps.count == 3)
        #expect(steps[0]["phase"] as? String == "status")
        #expect(steps[1]["phase"] as? String == "stop")
        #expect(steps[1]["stopMarker"] as? String == "from-stop")
        #expect(steps[1]["stopMethod"] as? String == stopMethod)
        #expect(steps[2]["phase"] as? String == "boot")
        #expect(steps[2]["stopMethod"] as? String == "boot-conflict")
    }

    @Test("Restart payload uses JSON null when the stop method is unavailable")
    func restartPayloadUsesNullForMissingStopMethod() throws {
        let stop: [String: Any] = ["phase": "stop", "changed": false]
        let payload = PommeApplication.restartPayload(
            status: ["phase": "status"],
            stop: stop,
            boot: ["phase": "boot", "stopMethod": "boot-conflict"],
            preservedMode: false
        )

        #expect(payload["stopMethod"] is NSNull)
        let steps = try #require(payload["steps"] as? [[String: Any]])
        #expect(steps[1]["stopMethod"] == nil)
        let serialized = try JSONSerialization.data(withJSONObject: payload)
        #expect(!serialized.isEmpty)
    }

    @Test("A stopped synthetic bundle produces a complete no-op stop result")
    func alreadyStoppedSyntheticBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-already-stopped-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root.appendingPathComponent("synthetic.bundle", isDirectory: true))
        try FileManager.default.createDirectory(at: bundle.rootURL, withIntermediateDirectories: true)
        let reference = VMReference(name: "synthetic-stopped", bundle: bundle)
        let status = try PommeCore.vmStatusPayload(reference: reference)

        #expect(status["helperRunning"] as? Bool == false)
        #expect(status["vmState"] as? String == "stopped")

        let result = PommeApplication.alreadyStoppedStopResult(
            reference: reference,
            statusPayload: status,
            force: false
        )

        #expect(result.ok)
        #expect(result.hostExitCode == 0)
        #expect(result.text == "VM is already stopped.")
        #expect(result.payload["operation"] as? String == "stop")
        #expect(result.payload["stopMethod"] as? String == VMStopOutcome.alreadyStopped.rawValue)
        #expect(result.payload["changed"] as? Bool == false)
        #expect(result.payload["guestShutdownRequested"] as? Bool == false)
        #expect(result.payload["forceRequested"] as? Bool == false)
    }

    @Test("Only a guest that was asked to shut down gets the longer window")
    func guestShutdownWindowFollowsTheRequest() {
        #expect(Constants.guestShutdownTimeoutSeconds > Constants.gracefulStopTimeoutSeconds)
        #expect(PommeVMRuntime.guestShutdownWindow(expectingGuestShutdown: true, bootMode: .normal)
                == Constants.guestShutdownTimeoutSeconds)
        // Nobody asked, so the framework request either lands quickly or not
        // at all; these keep the window they have always had.
        #expect(PommeVMRuntime.guestShutdownWindow(expectingGuestShutdown: false, bootMode: .normal)
                == Constants.gracefulStopTimeoutSeconds)
        #expect(PommeVMRuntime.guestShutdownWindow(expectingGuestShutdown: true, bootMode: .recovery)
                == Constants.gracefulStopTimeoutSeconds)
    }
}
