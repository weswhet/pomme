import Foundation
import Testing

@Suite("Guest request table text")
struct PommeApplicationGuestTextTests {
    private let jobID = "3b6be917-cfda-4eee-b73b-c99db830d685"

    private func request(_ path: String) -> GuestCommandRequest {
        GuestCommandRequest(path: path, arguments: [], timeout: 5)
    }

    @Test("A detached exec prints the job line jobs list uses")
    func detachedExecPrintsJobLine() throws {
        let payload: [String: Any] = [
            "ok": true,
            "requestID": UUID().uuidString,
            "result": ["detached": true, "jobID": jobID, "exited": false, "pid": 699],
            "streamFrames": [],
            "hostExitCode": 0
        ]
        let text = try PommeApplication.guestRequestText(for: .startBackground(request("/bin/sleep")), payload: payload)
        #expect(text == "RUNNING \(jobID) pid=699")
    }

    @Test("jobs inspect prints the job line with its output state")
    func jobInspectPrintsJobLine() throws {
        let running: [String: Any] = [
            "ok": true,
            "result": ["jobID": jobID, "pid": 689, "exited": false, "outputPending": false],
            "hostExitCode": 0
        ]
        let exited: [String: Any] = [
            "ok": true,
            "result": ["jobID": jobID, "pid": 689, "exited": true, "exitCode": 0, "outputPending": true],
            "hostExitCode": 0
        ]
        #expect(try PommeApplication.guestRequestText(for: .jobStatus(jobID), payload: running)
                == "RUNNING \(jobID) pid=689 outputPending=false")
        #expect(try PommeApplication.guestRequestText(for: .jobStatus(jobID), payload: exited)
                == "EXITED \(jobID) pid=689 exit=0 outputPending=true")
    }

    @Test("Other requests keep the generic text and failures keep their error")
    func genericTextIsUnchanged() throws {
        #expect(try PommeApplication.guestRequestText(for: .health, payload: ["ok": true, "state": "healthy"]) == "healthy")
        #expect(try PommeApplication.guestRequestText(for: .jobStatus(jobID), payload: ["ok": false, "error": "not-found"]) == "not-found")
        #expect(try PommeApplication.guestRequestText(for: .jobList, payload: ["ok": true, "result": ["jobs": []]]) == "No background jobs.")
    }

    @Test("A failed authenticated operation carries the helper's message")
    func authenticatedOperationFailureCarriesMessage() {
        let specific = PommeApplication.authenticatedOperationFailure(response: [
            "ok": false, "error": "Pomme agent request failed (not-found): No such file or directory: /nonexistent"
        ])
        let generic = PommeApplication.authenticatedOperationFailure(response: ["ok": false])

        #expect(specific.localizedDescription == "Pomme agent request failed (not-found): No such file or directory: /nonexistent")
        #expect(generic.localizedDescription == "The authenticated PommeAgent operation did not complete.")
    }
}
