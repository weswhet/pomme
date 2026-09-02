import Foundation

/// The only lifecycle callbacks needed by the display-only first normal boot.
/// Keeping this vocabulary closed prevents a caller from smuggling a guest
/// transport, listener, input device, or credential into the barrier.
enum PommeFirstBootLifecycleOperation: String, Equatable, Sendable {
    case startNormal
    case stopNormal
}

enum PommeFirstBootLifecycleCancellationBehavior: Sendable {
    /// The initial start returns promptly when its parent task is cancelled.
    case failImmediately
    /// Cleanup waits for a late stop callback so a cancellation cannot leave a
    /// transitional VM behind while the caller proceeds to Recovery.
    case waitForCompletion
}

enum PommeFirstBootLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case invalidTimeout
    case timedOut(PommeFirstBootLifecycleOperation)

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Pomme first-normal-boot lifecycle requires a positive timeout."
        case .timedOut:
            "Pomme first-normal-boot lifecycle callback timed out."
        }
    }
}

/// One-shot bridge for a framework lifecycle callback. A callback can arrive
/// after timeout or cancellation; late results are ignored and can never
/// resume a continuation twice or enqueue a second lifecycle request.
enum PommeFirstBootLifecycleCallback {
    typealias Completion = @Sendable (Error?) -> Void
    typealias Sleep = @Sendable (UInt64) async -> Void

    static func awaitCompletion(
        operation: PommeFirstBootLifecycleOperation,
        timeout: TimeInterval,
        cancellationBehavior: PommeFirstBootLifecycleCancellationBehavior = .failImmediately,
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        start: @escaping @Sendable (@escaping Completion) -> Void
    ) async throws {
        guard timeout.isFinite, timeout > 0 else {
            throw PommeFirstBootLifecycleError.invalidTimeout
        }

        let gate = PommeFirstBootLifecycleResumeGate()
        let timeoutNanoseconds = max(
            UInt64(1),
            UInt64((timeout * 1_000_000_000).rounded(.up))
        )

        func waitForCompletion() async throws {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may publish its terminal result before this
                // continuation is installed. In that case resume the waiter,
                // but do not enqueue a new framework request.
                guard gate.install(continuation) else { return }
                start { error in
                    if let error {
                        gate.finish(.failure(error))
                    } else {
                        gate.finish(.success(()))
                    }
                }
                let timeoutTask = Task.detached {
                    await sleep(timeoutNanoseconds)
                    gate.finish(.failure(
                        PommeFirstBootLifecycleError.timedOut(operation)
                    ))
                }
                gate.setTimeoutTask(timeoutTask)
            }
        }

        switch cancellationBehavior {
        case .failImmediately:
            try await withTaskCancellationHandler {
                try await waitForCompletion()
            } onCancel: {
                gate.finish(.failure(CancellationError()))
            }
        case .waitForCompletion:
            try await waitForCompletion()
        }
    }
}

private final class PommeFirstBootLifecycleResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalResult: Result<Void, Error>?
    private var finished = false

    /// Returns false when a terminal result already exists. The caller must
    /// skip its side effect in that case, especially a late start or stop.
    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let terminalResult = lock.withLock { () -> Result<Void, Error>? in
            guard !finished else { return self.terminalResult }
            self.continuation = continuation
            return nil
        }
        guard let terminalResult else { return true }
        continuation.resume(with: terminalResult)
        return false
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            if finished { return true }
            timeoutTask = task
            return false
        }
        if cancel { task.cancel() }
    }

    func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !finished else { return nil }
            finished = true
            terminalResult = result
            timeoutTask?.cancel()
            timeoutTask = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

/// Closed lifecycle states used while reconciling a start callback that timed
/// out. A transitional state is never treated as stopped.
enum PommeFirstBootCleanupState: Sendable {
    case stopped
    case transitioning
    case stoppable
}

struct PommeFirstBootCleanupDependencies: Sendable {
    let state: @Sendable () async -> PommeFirstBootCleanupState
    let requestStop: @Sendable () async -> Void
    let now: @Sendable () -> Date
    let sleep: @Sendable (_ seconds: TimeInterval) async -> Void
}

/// Returns true only after this reconciliation observes stopped. It is safe to
/// call after cancellation because the injected sleep is nonthrowing and the
/// stop callback uses `.waitForCompletion`.
struct PommeFirstBootCleanupReconciler: Sendable {
    let dependencies: PommeFirstBootCleanupDependencies

    func reconcileStopped(timeout: TimeInterval) async -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        let deadline = dependencies.now().addingTimeInterval(timeout)
        while dependencies.now() < deadline {
            switch await dependencies.state() {
            case .stopped:
                return true
            case .stoppable:
                await dependencies.requestStop()
            case .transitioning:
                break
            }
            let remaining = deadline.timeIntervalSince(dependencies.now())
            guard remaining > 0 else { break }
            await dependencies.sleep(min(0.5, remaining))
        }
        return await dependencies.state() == .stopped
    }
}

enum PommeFirstBootStartTimeoutState: Sendable {
    case running
    case stopped
    case transitioning
}

enum PommeFirstBootStartTimeoutAction: Equatable, Sendable {
    case continueExistingStart
    case reconstructRetry
    case failClosed
}

/// A timed-out start can be reused only when the queue-confined state proves
/// it is already running. A stopped state gets one reconstruction opportunity;
/// an ambiguous transition never gets another start request.
enum PommeFirstBootStartTimeoutPolicy {
    static func action(
        state: PommeFirstBootStartTimeoutState,
        retryCount: Int
    ) -> PommeFirstBootStartTimeoutAction {
        switch state {
        case .running:
            .continueExistingStart
        case .stopped where retryCount == 0:
            .reconstructRetry
        case .stopped, .transitioning:
            .failClosed
        }
    }
}

enum PommeFirstBootObservationError: Error, Equatable, Sendable {
    /// The compositor/display publication gap is retryable and does not
    /// contribute an observation to the stability requirement.
    case displayUnavailable
    /// OCR failed after a frame was captured. This is closed failure, not an
    /// empty observation that could accidentally qualify the boot.
    case recognitionFailed
}

/// The observation is a redacted projection. OCR lines and screenshots never
/// cross this boundary or become part of a receipt/diagnostic. The production
/// constructor deliberately uses the existing closed Recovery OCR vocabulary.
struct PommeFirstBootObservation: Equatable, Sendable {
    let width: Int
    let height: Int
    let setupAssistantCountryOrRegion: Bool
    let setupAssistantLanguageOrLegal: Bool

    var setupAssistantReady: Bool {
        setupAssistantCountryOrRegion || setupAssistantLanguageOrLegal
    }

    static func fromOCR(
        width: Int,
        height: Int,
        lines: [SettingsAIOCRLine]
    ) -> Self {
        let observation = RecoveryUIObservation(lines: lines)
        return .init(
            width: width,
            height: height,
            setupAssistantCountryOrRegion: observation.isLikelySetupAssistantCountryOrRegion,
            setupAssistantLanguageOrLegal: observation.isLikelySetupAssistantLanguageOrLegal
        )
    }

    /// Test/integration seam for callers that already reduced OCR at their
    /// capture boundary. No text, pixels, or arbitrary classifier is stored.
    init(
        width: Int,
        height: Int,
        setupAssistantCountryOrRegion: Bool,
        setupAssistantLanguageOrLegal: Bool = false
    ) {
        self.width = width
        self.height = height
        self.setupAssistantCountryOrRegion = setupAssistantCountryOrRegion
        self.setupAssistantLanguageOrLegal = setupAssistantLanguageOrLegal
    }
}

/// A single reconstructed VM attempt. It exposes display observation and the
/// two lifecycle callbacks only—never input, listeners, guest transports, or
/// credentials. The integration owner constructs a fresh attempt for the one
/// permitted retry so auxiliary-storage ownership cannot be reused blindly.
struct PommeFirstBootAttempt: Sendable {
    typealias Completion = @Sendable (Error?) -> Void

    let startNormal: @Sendable (@escaping Completion) -> Void
    let stopNormal: @Sendable (@escaping Completion) -> Void
    let observe: @Sendable () async throws -> PommeFirstBootObservation
    let cleanupState: @Sendable () async -> PommeFirstBootCleanupState

    init(
        startNormal: @escaping @Sendable (@escaping Completion) -> Void,
        stopNormal: @escaping @Sendable (@escaping Completion) -> Void,
        observe: @escaping @Sendable () async throws -> PommeFirstBootObservation,
        cleanupState: @escaping @Sendable () async -> PommeFirstBootCleanupState
    ) {
        self.startNormal = startNormal
        self.stopNormal = stopNormal
        self.observe = observe
        self.cleanupState = cleanupState
    }
}

struct PommeFirstBootBarrierDependencies: Sendable {
    let makeAttempt: @Sendable () async throws -> PommeFirstBootAttempt
    let now: @Sendable () -> Date
    let sleep: @Sendable (_ seconds: TimeInterval) async -> Void

    init(
        makeAttempt: @escaping @Sendable () async throws -> PommeFirstBootAttempt,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (_ seconds: TimeInterval) async -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            await Task.detached {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }.value
        }
    ) {
        self.makeAttempt = makeAttempt
        self.now = now
        self.sleep = sleep
    }
}

enum PommeFirstBootBarrierError: Error, Equatable, LocalizedError, Sendable {
    case invalidTimeout
    case startFailed
    case startReconciled
    case reconstructionFailed
    case setupAssistantObservationFailed
    case setupAssistantNotObserved
    case stoppedStateNotProven
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Pomme could not start its first normal boot barrier because its timeout was invalid."
        case .startFailed:
            "Pomme could not complete the first normal boot lifecycle start."
        case .startReconciled:
            "Pomme reconciled an uncertain first normal boot but could not safely continue."
        case .reconstructionFailed:
            "Pomme could not reconstruct the first normal boot attempt."
        case .setupAssistantObservationFailed:
            "Pomme could not classify the first normal boot display."
        case .setupAssistantNotObserved:
            "Pomme could not prove a reviewed Setup Assistant readiness screen."
        case .stoppedStateNotProven:
            "Pomme could not prove the first normal boot stopped before Recovery."
        case .cleanupFailed:
            "Pomme could not complete first normal boot cleanup."
        }
    }
}

/// A content-free receipt suitable for a provisioning phase digest. It proves
/// only closed booleans/counts; no OCR text, image bytes, paths, or framework
/// errors are retained.
struct PommeFirstBootReceipt: Equatable, Sendable {
    let setupAssistantSurfaceProven: Bool
    let stableObservationCount: Int
    let reconstructionCount: Int
    let stoppedStateProven: Bool
}

/// Display-only first normal boot barrier for a newly restored Pomme VM.
///
/// The caller supplies a fresh attempt factory. This type performs no input,
/// listener, guest-agent, credential, or screenshot persistence operation. It
/// requires two consecutive accepted OCR classifications, bounds lifecycle
/// callbacks, reconciles late transitions, and permits at most one fresh
/// reconstruction after a timed-out start that independently proves stopped.
struct PommeFirstBootBarrier: Sendable {
    static let requiredStableObservations = 2
    static let expectedDisplayWidth = 1280
    static let expectedDisplayHeight = 800

    let dependencies: PommeFirstBootBarrierDependencies

    func run(timeout: TimeInterval) async throws -> PommeFirstBootReceipt {
        guard timeout.isFinite, timeout > 0 else {
            throw PommeFirstBootBarrierError.invalidTimeout
        }

        var attempt: PommeFirstBootAttempt?
        do {
            attempt = try await dependencies.makeAttempt()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PommeFirstBootBarrierError.reconstructionFailed
        }

        var reconstructionCount = 0
        do {
            while true {
                let outcome: StartOutcome
                do {
                    guard let currentAttempt = attempt else {
                        throw PommeFirstBootBarrierError.reconstructionFailed
                    }
                    outcome = try await startAttemptOrTimeout(
                        currentAttempt,
                        timeout: lifecycleTimeout(for: timeout)
                    )
                }

                switch outcome {
                case .started:
                    break
                case .timedOut(let state):
                    try Task.checkCancellation()
                    switch PommeFirstBootStartTimeoutPolicy.action(
                        state: state,
                        retryCount: reconstructionCount
                    ) {
                    case .continueExistingStart:
                        break
                    case .reconstructRetry:
                        let stopped: Bool
                        do {
                            guard let oldAttempt = attempt else {
                                throw PommeFirstBootBarrierError.reconstructionFailed
                            }
                            // The old attempt remains in scope only for its
                            // stop/reap proof. The scope ends before `attempt`
                            // is nilled and the replacement factory is called,
                            // releasing captured queue/VZ resources first.
                            stopped = await reconcileStopped(oldAttempt, timeout: timeout)
                        }
                        guard stopped else {
                            throw PommeFirstBootBarrierError.stoppedStateNotProven
                        }
                        attempt = nil
                        do {
                            attempt = try await dependencies.makeAttempt()
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw PommeFirstBootBarrierError.reconstructionFailed
                        }
                        reconstructionCount += 1
                        continue
                    case .failClosed:
                        let stopped: Bool
                        do {
                            guard let currentAttempt = attempt else {
                                throw PommeFirstBootBarrierError.reconstructionFailed
                            }
                            stopped = await reconcileStopped(currentAttempt, timeout: timeout)
                        }
                        guard stopped else {
                            throw PommeFirstBootBarrierError.cleanupFailed
                        }
                        throw PommeFirstBootBarrierError.startReconciled
                    }
                }

                break
            }

            let stableCount: Int
            do {
                guard let currentAttempt = attempt else {
                    throw PommeFirstBootBarrierError.reconstructionFailed
                }
                stableCount = try await observeSetupAssistant(
                    on: currentAttempt,
                    timeout: timeout
                )
                guard await reconcileStopped(currentAttempt, timeout: timeout) else {
                    throw PommeFirstBootBarrierError.stoppedStateNotProven
                }
            }
            return .init(
                setupAssistantSurfaceProven: true,
                stableObservationCount: stableCount,
                reconstructionCount: reconstructionCount,
                stoppedStateProven: true
            )
        } catch let error as PommeFirstBootBarrierError {
            if let currentAttempt = attempt {
                guard await reconcileStopped(currentAttempt, timeout: timeout) else {
                    throw PommeFirstBootBarrierError.cleanupFailed
                }
            }
            throw error
        } catch is CancellationError {
            if let currentAttempt = attempt {
                guard await reconcileStopped(currentAttempt, timeout: timeout) else {
                    throw PommeFirstBootBarrierError.cleanupFailed
                }
            }
            throw CancellationError()
        } catch {
            if let currentAttempt = attempt {
                guard await reconcileStopped(currentAttempt, timeout: timeout) else {
                    throw PommeFirstBootBarrierError.cleanupFailed
                }
            }
            throw PommeFirstBootBarrierError.setupAssistantObservationFailed
        }
    }

    private enum StartOutcome: Sendable {
        case started
        case timedOut(PommeFirstBootStartTimeoutState)
    }

    private func startAttemptOrTimeout(
        _ attempt: PommeFirstBootAttempt,
        timeout: TimeInterval
    ) async throws -> StartOutcome {
        do {
            try await PommeFirstBootLifecycleCallback.awaitCompletion(
                operation: .startNormal,
                timeout: timeout,
                // A cancelled caller must not begin cleanup while the
                // framework start callback is still unresolved. Waiting for
                // the callback (or its bounded timeout) makes the subsequent
                // queue-confined state observation authoritative.
                cancellationBehavior: .waitForCompletion,
                sleep: { nanoseconds in
                    await self.dependencies.sleep(
                        TimeInterval(nanoseconds) / 1_000_000_000
                    )
                },
                start: attempt.startNormal
            )
            return .started
        } catch let error as PommeFirstBootLifecycleError
            where error == .timedOut(.startNormal)
        {
            return .timedOut(
                await startTimeoutState(for: attempt, timeout: timeout)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PommeFirstBootBarrierError.startFailed
        }
    }

    private func observeSetupAssistant(
        on attempt: PommeFirstBootAttempt,
        timeout: TimeInterval
    ) async throws -> Int {
        let deadline = dependencies.now().addingTimeInterval(timeout)
        var prior: PommeFirstBootObservation?
        var stableCount = 0

        while dependencies.now() < deadline {
            try Task.checkCancellation()
            do {
                let observation = try await attempt.observe()
                guard observation.width == Self.expectedDisplayWidth,
                      observation.height == Self.expectedDisplayHeight,
                      observation.setupAssistantReady else {
                    prior = nil
                    stableCount = 0
                    await sleepUntilNextObservation(deadline: deadline)
                    continue
                }

                if observation == prior {
                    stableCount += 1
                } else {
                    prior = observation
                    stableCount = 1
                }
                if stableCount >= Self.requiredStableObservations {
                    return stableCount
                }
            } catch let error as PommeFirstBootObservationError {
                switch error {
                case .displayUnavailable:
                    prior = nil
                    stableCount = 0
                case .recognitionFailed:
                    throw PommeFirstBootBarrierError.setupAssistantObservationFailed
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PommeFirstBootBarrierError.setupAssistantObservationFailed
            }
            await sleepUntilNextObservation(deadline: deadline)
        }
        throw PommeFirstBootBarrierError.setupAssistantNotObserved
    }

    private func sleepUntilNextObservation(deadline: Date) async {
        let remaining = deadline.timeIntervalSince(dependencies.now())
        guard remaining > 0 else { return }
        await dependencies.sleep(min(0.5, remaining))
    }

    private func startTimeoutState(
        for attempt: PommeFirstBootAttempt,
        timeout: TimeInterval
    ) async -> PommeFirstBootStartTimeoutState {
        let deadline = dependencies.now().addingTimeInterval(timeout)
        while dependencies.now() < deadline {
            switch await attempt.cleanupState() {
            case .stoppable:
                return .running
            case .stopped:
                return .stopped
            case .transitioning:
                await dependencies.sleep(min(0.5, deadline.timeIntervalSince(dependencies.now())))
            }
        }
        switch await attempt.cleanupState() {
        case .stoppable: return .running
        case .stopped: return .stopped
        case .transitioning: return .transitioning
        }
    }

    private func reconcileStopped(
        _ attempt: PommeFirstBootAttempt,
        timeout: TimeInterval
    ) async -> Bool {
        let reconciler = PommeFirstBootCleanupReconciler(
            dependencies: .init(
                state: attempt.cleanupState,
                requestStop: {
                    do {
                        try await PommeFirstBootLifecycleCallback.awaitCompletion(
                            operation: .stopNormal,
                            timeout: stopCallbackTimeout(for: timeout),
                            cancellationBehavior: .waitForCompletion,
                            sleep: { nanoseconds in
                                await self.dependencies.sleep(
                                    TimeInterval(nanoseconds) / 1_000_000_000
                                )
                            },
                            start: attempt.stopNormal
                        )
                    } catch {
                        // The reconciliation deadline remains authoritative;
                        // a late stop callback can still produce `.stopped`.
                    }
                },
                now: dependencies.now,
                sleep: dependencies.sleep
            )
        )
        return await reconciler.reconcileStopped(timeout: cleanupTimeout(for: timeout))
    }

    private func lifecycleTimeout(for timeout: TimeInterval) -> TimeInterval {
        min(max(0.05, timeout), 60)
    }

    private func stopCallbackTimeout(for timeout: TimeInterval) -> TimeInterval {
        min(max(0.05, timeout), 5)
    }

    private func cleanupTimeout(for timeout: TimeInterval) -> TimeInterval {
        min(max(0.05, timeout), 60)
    }
}
