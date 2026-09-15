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
            "ok": true, "sessionID": "abc", "state": "running", "executable": "/bin/sh", "transcriptOffset": 12
        ]
        #expect(PommeApplication.terminalSessionText(operation: "terminal.inspect", response: response)
                == "abc running /bin/sh offset=12")
    }
}
