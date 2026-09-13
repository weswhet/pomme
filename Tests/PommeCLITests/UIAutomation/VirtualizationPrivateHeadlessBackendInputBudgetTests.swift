import Foundation
@preconcurrency import AppKit
import Testing

@Suite("Virtualization private direct-input budgets")
struct VirtualizationPrivateHeadlessBackendInputBudgetTests {
    @Test("Rejects a whole key plan before any event can be emitted")
    func rejectsOverBudgetPlanBeforeInput() throws {
        guard let key = HostDisplayKey.lookup("cmd-a") else {
            Issue.record("The qualified Command-A key plan was not available")
            return
        }
        let plan = key.inputEventPlan
        let required = HeadlessInputBudget.minimumDurationNanoseconds(for: [plan])
        let budget = try HeadlessInputBudget(
            timeout: Double(required) / 1_000_000_000 / 2,
            operation: "key",
            clock: { 0 }
        )

        do {
            try budget.requireFullPlan([plan])
            Issue.record("An over-budget key plan was accepted")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .inputTimeout)
            #expect(!error.partialInputPossible)
        } catch {
            Issue.record("Unexpected input-budget error: \(error)")
        }
    }

    @Test("Checks the deadline between complete key chords")
    func checksBetweenChordsWithPartialInputState() throws {
        guard let key = HostDisplayKey.lookup("right") else {
            Issue.record("The qualified Right key plan was not available")
            return
        }
        let plan = key.inputEventPlan
        let clock = InputBudgetTestClock()
        let budget = try HeadlessInputBudget(
            timeout: 0.1,
            operation: "key-sequence",
            clock: { clock.now }
        )

        try budget.requireFullPlan([plan, plan])
        try budget.requireNextChord(plan, partialInputPossible: false)
        // Leave less than one chord's minimum duration (the key-down dwell).
        clock.advance(nanoseconds: 100_000_000 - HeadlessInputTiming.keyDownDwellNanoseconds + 1)

        do {
            try budget.requireNextChord(plan, partialInputPossible: true)
            Issue.record("The second chord was allowed after its deadline")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .inputTimeout)
            #expect(error.partialInputPossible)
        } catch {
            Issue.record("Unexpected input-budget error: \(error)")
        }
    }

    @Test("Finishes a key chord after cancellation during its dwell")
    func cancellationFinishesKeyChord() async throws {
        guard let key = HostDisplayKey.lookup("cmd-a") else {
            Issue.record("The qualified Command-A key plan was not available")
            return
        }
        let delays = key.inputEventPlan.map { event in
            event.kind == .keyDown
                ? HeadlessInputTiming.keyDownDwellNanoseconds
                : HeadlessInputTiming.transitionGapNanoseconds
        }
        let recorder = InputDispatchRecorder()
        let sleeper = InputDispatchSleeper(cancellationCall: 1)

        do {
            _ = try await HeadlessInputEventDispatcher.dispatch(
                delayPlans: [delays],
                timeout: 1,
                operation: "key",
                clock: { 0 },
                sleep: { nanoseconds in
                    try sleeper.sleep(nanoseconds)
                },
                send: { unitIndex, eventIndex in
                    recorder.record(unitIndex: unitIndex, eventIndex: eventIndex)
                }
            )
            Issue.record("A cancelled key chord completed without reporting interruption")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .inputInterrupted)
            #expect(error.partialInputPossible)
            #expect(recorder.events == delays.indices.map {
                InputDispatchEvent(unitIndex: 0, eventIndex: $0)
            })
        } catch {
            Issue.record("Unexpected key-chord cancellation error: \(error)")
        }
    }

    @Test("Finishes a pointer button pair after cancellation between down and up")
    func cancellationFinishesPointerButtonPair() async throws {
        let delayPlans = [
            [HeadlessInputTiming.pointerHoverNanoseconds],
            [UInt64.zero, UInt64.zero],
        ]
        let recorder = InputDispatchRecorder()
        let sleeper = InputDispatchSleeper(cancellationCall: 2)

        do {
            _ = try await HeadlessInputEventDispatcher.dispatch(
                delayPlans: delayPlans,
                timeout: 1,
                operation: "click",
                clock: { 0 },
                sleep: { nanoseconds in
                    try sleeper.sleep(nanoseconds)
                },
                send: { unitIndex, eventIndex in
                    recorder.record(unitIndex: unitIndex, eventIndex: eventIndex)
                }
            )
            Issue.record("A cancelled pointer click completed without reporting interruption")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .inputInterrupted)
            #expect(error.partialInputPossible)
            #expect(recorder.events == [
                InputDispatchEvent(unitIndex: 0, eventIndex: 0),
                InputDispatchEvent(unitIndex: 1, eventIndex: 0),
                InputDispatchEvent(unitIndex: 1, eventIndex: 1),
            ])
        } catch {
            Issue.record("Unexpected pointer cancellation error: \(error)")
        }
    }

    @Test("Reserves the pointer hover interval before a click")
    func reservesPointerHoverBudget() throws {
        let budget = try HeadlessInputBudget(
            timeout: 0.2,
            operation: "click",
            clock: { 0 }
        )

        do {
            try budget.requireMinimumDuration(
                HeadlessInputTiming.pointerHoverNanoseconds,
                partialInputPossible: false
            )
            Issue.record("A click shorter than its hover interval was accepted")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .inputTimeout)
            #expect(!error.partialInputPossible)
        } catch {
            Issue.record("Unexpected input-budget error: \(error)")
        }
    }

    @Test("Rejects non-positive and non-finite input timeouts")
    func rejectsInvalidTimeouts() {
        for timeout in [0.0, -1.0, Double.infinity, -Double.infinity, Double.nan] {
            do {
                _ = try HeadlessInputBudget(
                    timeout: timeout,
                    operation: "type",
                    clock: { 0 }
                )
                Issue.record("Invalid timeout was accepted: \(timeout)")
            } catch let error as VirtualizationPrivateHeadlessError {
                #expect(error.code == .inputTimeout)
                #expect(!error.partialInputPossible)
            } catch {
                Issue.record("Unexpected timeout error: \(error)")
            }
        }
    }
}

private final class InputBudgetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var now: UInt64 { lock.withLock { value } }

    func advance(nanoseconds: UInt64) {
        lock.withLock {
            value &+= nanoseconds
        }
    }
}

private struct InputDispatchEvent: Equatable {
    let unitIndex: Int
    let eventIndex: Int
}

private final class InputDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [InputDispatchEvent] = []

    var events: [InputDispatchEvent] {
        lock.withLock { values }
    }

    func record(unitIndex: Int, eventIndex: Int) {
        lock.withLock {
            values.append(.init(unitIndex: unitIndex, eventIndex: eventIndex))
        }
    }
}

private final class InputDispatchSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationCall: Int
    private var calls = 0

    init(cancellationCall: Int) {
        self.cancellationCall = cancellationCall
    }

    func sleep(_ nanoseconds: UInt64) throws {
        _ = nanoseconds
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == cancellationCall {
            throw CancellationError()
        }
    }
}
