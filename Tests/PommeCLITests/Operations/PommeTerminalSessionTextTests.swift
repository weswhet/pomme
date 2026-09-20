import Foundation
import Testing

@Suite("Terminal session table text")
struct PommeTerminalSessionTextTests {
    @Test("A failure envelope renders its message for every operation", arguments: [
        "terminal.inspect", "terminal.list", "terminal.logs", "terminal.terminate"
    ])
    func failureEnvelopeRendersMessage(operation: String) {
        let response: [String: Any] = ["ok": false, "error": "The terminal session was not found.", "hostExitCode": 1]
        #expect(PommeApplication.terminalSessionText(operation: operation, response: response)
                == "The terminal session was not found.")
    }

    @Test("A logs offset past the end names the valid range")
    func logsOffsetBeyondEnd() {
        let response: [String: Any] = [
            "ok": false,
            "error": "The transcript offset 999999 is beyond the transcript end (1234 bytes).",
            "hostExitCode": 1,
            "fromOffset": 999999,
            "transcriptOffset": 1234
        ]
        #expect(PommeApplication.terminalSessionText(operation: "terminal.logs", response: response)
                == "--from-offset 999999 is beyond the transcript end (1234 bytes).")
    }

    @Test("A successful inspect still renders the session summary")
    func inspectSummary() {
        let response: [String: Any] = [
            "ok": true, "sessionID": "abc", "state": "running", "executable": "/bin/sh",
            "transcriptOffset": 12, "guestAgentConnection": "connected"
        ]
        #expect(PommeApplication.terminalSessionText(operation: "terminal.inspect", response: response)
                == "abc running /bin/sh offset=12")
    }

    @Test("A connected agent renders the listing without qualification")
    func listWithConnectedAgent() {
        let response: [String: Any] = [
            "ok": true,
            "guestAgentConnection": "connected",
            "sessions": [
                ["sessionID": "abc", "state": "running", "executable": "/bin/sh", "transcriptOffset": 12]
            ]
        ]
        #expect(PommeApplication.terminalSessionText(operation: "terminal.list", response: response)
                == "abc running /bin/sh offset=12")
    }

    /// The records are host-side and answer while the guest agent is away, so
    /// the reply has to say that each state is remembered rather than observed.
    @Test(
        "A listing made without the guest agent names its states as last recorded",
        arguments: ["disconnected", "connecting", "unavailable", "failed"]
    )
    func listNamesStaleStates(connection: String) {
        let response: [String: Any] = [
            "ok": true,
            "guestAgentConnection": connection,
            "sessions": [
                ["sessionID": "abc", "state": "running", "executable": "/bin/sh", "transcriptOffset": 12]
            ]
        ]
        #expect(PommeApplication.terminalSessionText(operation: "terminal.list", response: response)
                == "abc running /bin/sh offset=12\n"
                + "The guest agent is \(connection); each state is the last one recorded.")
    }

    @Test("An inspect made without the guest agent names its state as last recorded")
    func inspectNamesStaleState() {
        let response: [String: Any] = [
            "ok": true, "sessionID": "abc", "state": "running", "executable": "/bin/sh",
            "transcriptOffset": 12, "guestAgentConnection": "disconnected"
        ]
        #expect(PommeApplication.terminalSessionText(operation: "terminal.inspect", response: response)
                == "abc running /bin/sh offset=12\n"
                + "The guest agent is disconnected; each state is the last one recorded.")
    }

    /// An empty listing states a host-side fact that the agent cannot change,
    /// so it is never qualified.
    @Test("An empty listing is unqualified whatever the agent is doing")
    func emptyListingIsUnqualified() {
        for connection in ["connected", "disconnected", ""] {
            let response: [String: Any] = [
                "ok": true, "guestAgentConnection": connection, "sessions": [[String: Any]]()
            ]
            #expect(PommeApplication.terminalSessionText(operation: "terminal.list", response: response)
                    == "No terminal sessions.")
        }
    }
}
