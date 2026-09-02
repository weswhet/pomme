import Foundation
import Testing

@Suite("Recovery runtime agent coordinator")
struct RecoveryRuntimeAgentCoordinatorTests {
    @Test(
        "Ready sessions transition through reconnecting without bootstrapping again",
        .timeLimit(.minutes(3))
    )
    func reconnectState() async {
        let connection = LockedRecoveryConnection()
        let attempts = LockedRecoveryCounter()
        let coordinator = RecoveryRuntimeAgentCoordinator(
            enabled: true,
            isConnected: { connection.value },
            bootstrap: { reporter in
                attempts.increment()
                await reporter.report(.openingTerminal)
                await reporter.report(.transferring)
                await reporter.report(.loadingLaunchd)
                connection.value = true
                await reporter.report(.connecting)
            }
        )

        // This suite runs alongside hundreds of async tests in the full
        // target, including process fixtures that can temporarily starve the
        // cooperative executor. Keep the product timeout active while giving
        // the immediate fixture enough scheduling headroom.
        let ready = await coordinator.ensure(timeout: 120)
        #expect(ready.ok)
        #expect(ready.status.state == .ready)
        #expect(ready.status.connected)
        #expect(attempts.value == 1)

        connection.value = false
        let reconnecting = await coordinator.snapshot()
        #expect(reconnecting.state == .reconnecting)
        #expect(reconnecting.stage == .reconnecting)

        connection.value = true
        let reconnected = await coordinator.snapshot()
        #expect(reconnected.state == .ready)
        #expect(attempts.value == 1)
    }

    @Test("A failed attempt is retryable with a fresh bootstrap")
    func retryAfterFailure() async {
        let connection = LockedRecoveryConnection()
        let attempts = LockedRecoveryCounter()
        let coordinator = RecoveryRuntimeAgentCoordinator(
            enabled: true,
            isConnected: { connection.value },
            bootstrap: { _ in
                attempts.increment()
                if attempts.value == 1 {
                    throw RunnerError.hostCommandFailed("fixture")
                }
                connection.value = true
            }
        )

        let failed = await coordinator.ensure(timeout: 1)
        #expect(!failed.ok)
        #expect(failed.status.state == .failed)
        #expect(failed.status.retryable)
        let ready = await coordinator.ensure(timeout: 1)
        #expect(ready.ok)
        #expect(attempts.value == 2)
    }

    @Test("Timeout cancels setup and leaves a retryable failed state")
    func timeout() async {
        let coordinator = RecoveryRuntimeAgentCoordinator(
            enabled: true,
            isConnected: { false },
            bootstrap: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )
        let result = await coordinator.ensure(timeout: 0.02)
        #expect(!result.ok)
        #expect(result.hostExitCode == 124)
        #expect(result.status.state == .failed)
        #expect(result.status.errorCode == .timedOut)
        #expect(result.status.retryable)
    }

    @Test(
        "Timeout waits for cancelled bootstrap cleanup before returning 124",
        .timeLimit(.minutes(2))
    )
    func timeoutWaitsForCancelledBootstrapCleanup() async throws {
        let cleanupStarted = RecoveryTestSignal()
        let releaseCleanup = RecoveryTestSignal()
        let ensureReturned = LockedRecoveryConnection()
        let coordinator = RecoveryRuntimeAgentCoordinator(
            enabled: true,
            isConnected: { false },
            bootstrap: { _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch is CancellationError {
                    await cleanupStarted.signal()
                    await releaseCleanup.wait()
                    throw CancellationError()
                }
            }
        )

        let ensure = Task {
            let result = await coordinator.ensure(timeout: 0.01)
            ensureReturned.value = true
            return result
        }
        // Await the cleanup boundary directly. A wall-clock polling deadline
        // can expire while this test task and the bootstrap task are both
        // descheduled by the full target's process-heavy fixtures.
        await cleanupStarted.wait()
        #expect(!ensureReturned.value)

        await releaseCleanup.signal()
        let result = await ensure.value
        #expect(result.hostExitCode == 124)
        #expect(result.status.errorCode == .timedOut)
    }

    @Test("Connecting progress does not attest launchd ownership")
    func connectingIsNotLaunchdProof() async {
        let reachedConnecting = LockedRecoveryConnection()
        let releaseBootstrap = LockedRecoveryConnection()
        let coordinator = RecoveryRuntimeAgentCoordinator(
            enabled: true,
            isConnected: { false },
            bootstrap: { reporter in
                await reporter.report(.connecting)
                reachedConnecting.value = true
                while !releaseBootstrap.value {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        )

        let task = Task { await coordinator.ensure(timeout: 1) }
        while !reachedConnecting.value {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.stage == .connecting)
        #expect(!snapshot.launchdManaged)

        releaseBootstrap.value = true
        let result = await task.value
        #expect(!result.ok)
        #expect(result.status.errorCode == .timedOut)
    }
}

private final class LockedRecoveryConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LockedRecoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private actor RecoveryTestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
