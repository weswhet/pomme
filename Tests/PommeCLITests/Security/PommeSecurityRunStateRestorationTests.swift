import Foundation
import Testing

@Suite("Security run-state restoration", .serialized)
struct PommeSecurityRunStateRestorationTests {
    @Test("Changing between normal and Recovery proves stopped before starting")
    func changingBootModesStopsBeforeStarting() async throws {
        let cases: [(VMRunStateSnapshot, VMRunStateSnapshot)] = [
            (.running(.normal), .running(.recovery)),
            (.running(.recovery), .running(.normal))
        ]

        for (initial, desired) in cases {
            let fixture = RunStateFixture(initial: initial)

            // When
            try await PommeSecurityRunStateRestoration.restore(
                desired: desired,
                observe: { try await fixture.observe() },
                stop: { try await fixture.stop() },
                start: { state in try await fixture.start(state) }
            )

            // Then
            #expect(fixture.state == desired)
            #expect(fixture.events == [
                .observe,
                .stop,
                .observe,
                .start(desired),
                .observe
            ])
        }
    }

    @Test("Matching stopped, booted, and paused states are idempotent")
    func matchingStatesDoNotIssueLifecycleEffects() async throws {
        let states: [VMRunStateSnapshot] = [
            .stopped,
            .running(.normal),
            .running(.recovery),
            .paused(previousBootMode: .normal),
            .paused(previousBootMode: .recovery)
        ]

        for state in states {
            let fixture = RunStateFixture(initial: state)

            // When
            try await PommeSecurityRunStateRestoration.restore(
                desired: state,
                observe: { try await fixture.observe() },
                stop: { try await fixture.stop() },
                start: { state in try await fixture.start(state) }
            )

            // Then
            #expect(fixture.state == state)
            #expect(fixture.events == [.observe])
        }
    }

    @Test("A paused target starts with the original boot mode")
    func pausedTargetPreservesOriginalMode() async throws {
        let cases: [(VMRunStateSnapshot, VMRunStateSnapshot)] = [
            (.running(.normal), .paused(previousBootMode: .normal)),
            (.running(.recovery), .paused(previousBootMode: .recovery))
        ]

        for (initial, desired) in cases {
            let fixture = RunStateFixture(initial: initial)

            // When
            try await PommeSecurityRunStateRestoration.restore(
                desired: desired,
                observe: { try await fixture.observe() },
                stop: { try await fixture.stop() },
                start: { state in try await fixture.start(state) }
            )

            // Then
            #expect(fixture.state == desired)
            #expect(fixture.startedStates == [desired])
        }
    }

    @Test("A stopped target returns after a verified stop without starting")
    func stoppedTargetEndsAfterStopProof() async throws {
        let fixture = RunStateFixture(initial: .running(.normal))

        // When
        try await PommeSecurityRunStateRestoration.restore(
            desired: .stopped,
            observe: { try await fixture.observe() },
            stop: { try await fixture.stop() },
            start: { state in try await fixture.start(state) }
        )

        // Then
        #expect(fixture.state == .stopped)
        #expect(fixture.startedStates.isEmpty)
        #expect(fixture.events == [.observe, .stop, .observe])
    }

    @Test("A stop failure prevents any start attempt")
    func stopFailureDoesNotStartWrongMode() async throws {
        let fixture = RunStateFixture(initial: .running(.normal))
        fixture.stopError = .stopFailed

        // When / Then
        do {
            try await PommeSecurityRunStateRestoration.restore(
                desired: .running(.recovery),
                observe: { try await fixture.observe() },
                stop: { try await fixture.stop() },
                start: { state in try await fixture.start(state) }
            )
            Issue.record("A failed stop unexpectedly completed")
        } catch {
            #expect(error as? RunStateTestError == .stopFailed)
        }
        #expect(fixture.startedStates.isEmpty)
        #expect(fixture.events == [.observe, .stop])
    }

    @Test("A failed stopped-state proof prevents any start")
    func failedStopProofDoesNotStart() async throws {
        let fixture = RunStateFixture(initial: .running(.normal))
        fixture.stopTransitionsToStopped = false

        // When / Then
        do {
            try await PommeSecurityRunStateRestoration.restore(
                desired: .running(.recovery),
                observe: { try await fixture.observe() },
                stop: { try await fixture.stop() },
                start: { state in try await fixture.start(state) }
            )
            Issue.record("An unproven stop unexpectedly completed")
        } catch {
            #expect(error as? PommeSecurityWorkflowError == .restorationIncomplete)
        }
        #expect(fixture.startedStates.isEmpty)
        #expect(fixture.events == [.observe, .stop, .observe])
    }

    @Test("A target-state proof mismatch is a closed restoration failure")
    func targetProofMismatchFailsClosed() async throws {
        let fixture = RunStateFixture(initial: .stopped)
        fixture.startOverride = .running(.normal)

        // When / Then
        do {
            try await PommeSecurityRunStateRestoration.restore(
                desired: .running(.recovery),
                observe: { try await fixture.observe() },
                stop: { try await fixture.stop() },
                start: { state in try await fixture.start(state) }
            )
            Issue.record("A mismatched target proof unexpectedly completed")
        } catch {
            #expect(error as? PommeSecurityWorkflowError == .restorationIncomplete)
        }
        #expect(fixture.startedStates == [.running(.recovery)])
        #expect(fixture.events == [.observe, .start(.running(.recovery)), .observe])
    }
}

private enum RunStateTestError: Error, Equatable, Sendable {
    case stopFailed
}

private final class RunStateFixture: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case observe
        case stop
        case start(VMRunStateSnapshot)
    }

    private let lock = NSLock()
    private var current: VMRunStateSnapshot
    private var recordedEvents: [Event] = []
    private var recordedStarts: [VMRunStateSnapshot] = []
    var stopError: RunStateTestError?
    var stopTransitionsToStopped = true
    var startOverride: VMRunStateSnapshot?

    init(initial: VMRunStateSnapshot) {
        current = initial
    }

    var state: VMRunStateSnapshot {
        lock.withLock { current }
    }

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    var startedStates: [VMRunStateSnapshot] {
        lock.withLock { recordedStarts }
    }

    func observe() async throws -> VMRunStateSnapshot {
        lock.withLock {
            recordedEvents.append(.observe)
            return current
        }
    }

    func stop() async throws {
        let error = lock.withLock { () -> RunStateTestError? in
            recordedEvents.append(.stop)
            return stopError
        }
        if let error { throw error }
        lock.withLock {
            if stopTransitionsToStopped { current = .stopped }
        }
    }

    func start(_ desired: VMRunStateSnapshot) async throws {
        lock.withLock {
            recordedEvents.append(.start(desired))
            recordedStarts.append(desired)
            current = startOverride ?? desired
        }
    }
}
