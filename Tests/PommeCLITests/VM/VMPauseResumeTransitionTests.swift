import Testing
@preconcurrency import Virtualization

@Suite("VM pause and resume transitions")
struct VMPauseResumeTransitionTests {
    @Test("Running-to-paused and paused-to-running submit one framework transition")
    func transitionsRequireFrameworkCalls() throws {
        #expect(try VMPauseResumeTransition.requiresFrameworkCall(
            .pause, state: .running, canPause: true, canResume: false
        ))
        #expect(try VMPauseResumeTransition.requiresFrameworkCall(
            .resume, state: .paused, canPause: false, canResume: true
        ))
    }

    @Test("Repeated pause and resume are idempotent")
    func repeatedRequestsAreNoOps() throws {
        #expect(try !VMPauseResumeTransition.requiresFrameworkCall(
            .pause, state: .paused, canPause: false, canResume: false
        ))
        #expect(try !VMPauseResumeTransition.requiresFrameworkCall(
            .resume, state: .running, canPause: false, canResume: false
        ))
    }

    @Test("Stopped and unavailable transitions fail without a framework call")
    func invalidStatesFail() {
        #expect(throws: RunnerError.self) {
            try VMPauseResumeTransition.requiresFrameworkCall(
                .pause, state: .stopped, canPause: false, canResume: false
            )
        }
        #expect(throws: RunnerError.self) {
            try VMPauseResumeTransition.requiresFrameworkCall(
                .resume, state: .stopped, canPause: false, canResume: false
            )
        }
        #expect(throws: RunnerError.self) {
            try VMPauseResumeTransition.requiresFrameworkCall(
                .pause, state: .running, canPause: false, canResume: false
            )
        }
        #expect(throws: RunnerError.self) {
            try VMPauseResumeTransition.requiresFrameworkCall(
                .resume, state: .paused, canPause: false, canResume: false
            )
        }
    }
}
