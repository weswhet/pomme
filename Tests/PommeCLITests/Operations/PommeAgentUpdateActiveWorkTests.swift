import Foundation
import Testing

@Suite("Agent update active work")
struct PommeAgentUpdateActiveWorkTests {
    @Test func reportsOnlyWorkThatHasNotExited() {
        let jobs: [JSONValue] = [
            .object(["jobID": .string("job-running"), "exited": .bool(false)]),
            .object(["jobID": .string("job-done"), "exited": .bool(true)]),
        ]
        let sessions: [JSONValue] = [
            .object(["sessionID": .string("session-done"), "state": .string("exited")]),
            .object(["sessionID": .string("session-lost"), "state": .string("lost")]),
            .object(["sessionID": .string("session-detached"), "state": .string("detached")]),
        ]
        let active = PommeAgentUpdateActiveWork.running(jobs: jobs, sessions: sessions)
        #expect(active.jobs == ["job-running"])
        #expect(active.sessions == ["session-detached"])
    }

    @Test func treatsUnreadableStateAsRunning() {
        let active = PommeAgentUpdateActiveWork.running(
            jobs: [.object(["jobID": .string("job-unknown")])],
            sessions: [.object(["state": .string("attached")])])
        #expect(active.jobs == ["job-unknown"])
        #expect(active.sessions == ["unknown"])
    }

    @Test func noWorkAllowsTheUpdate() {
        let active = PommeAgentUpdateActiveWork.running(jobs: [], sessions: [])
        #expect(active.jobs.isEmpty && active.sessions.isEmpty)
    }
}
