import Foundation

enum RecoveryRuntimeAgentStage: String, Codable, CaseIterable, Sendable {
    case disabled
    case waitingForRecovery
    case authenticating
    case openingTerminal
    case transferring
    case loadingLaunchd
    case connecting
    case ready
    case reconnecting
    case failed
}

enum RecoveryRuntimeAgentState: String, Codable, Sendable {
    case disabled
    case idle
    case progressing
    case ready
    case reconnecting
    case failed
}

enum RecoveryRuntimeAgentErrorCode: String, Sendable {
    case timedOut
    case credentialUnavailable
    case bootstrapFailed
    case cancelled
}

struct RecoveryRuntimeAgentStatus: Sendable {
    let enabled: Bool
    let state: RecoveryRuntimeAgentState
    let stage: RecoveryRuntimeAgentStage
    let launchdManaged: Bool
    let connected: Bool
    let retryable: Bool
    let errorCode: RecoveryRuntimeAgentErrorCode?

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "enabled": enabled,
            "state": state.rawValue,
            "stage": stage.rawValue,
            "launchdManaged": launchdManaged,
            "connected": connected,
            "retryable": retryable
        ]
        if let errorCode { payload["errorCode"] = errorCode.rawValue }
        return payload
    }
}

struct RecoveryRuntimeAgentEnsureResult: Sendable {
    let status: RecoveryRuntimeAgentStatus
    let ok: Bool
    let hostExitCode: Int
    let error: String?

    var payload: [String: Any] {
        var payload = status.payload
        payload["ok"] = ok
        payload["hostExitCode"] = hostExitCode
        if let error { payload["error"] = error }
        return payload
    }
}

actor RecoveryRuntimeAgentCoordinator {
    typealias StageReporter = @Sendable (RecoveryRuntimeAgentStage) async -> Void
    typealias Bootstrap = @Sendable (RecoveryRuntimeAgentStageReporter) async throws -> Void

    private var enabled: Bool
    private var state: RecoveryRuntimeAgentState
    private var stage: RecoveryRuntimeAgentStage
    private var errorCode: RecoveryRuntimeAgentErrorCode?
    private var launchdManaged = false
    private var bootstrapTask: Task<Void, Error>?
    private let isConnected: @Sendable () -> Bool
    private let bootstrap: Bootstrap

    init(
        enabled: Bool,
        isConnected: @escaping @Sendable () -> Bool,
        bootstrap: @escaping Bootstrap
    ) {
        self.enabled = enabled
        state = enabled ? .idle : .disabled
        stage = enabled ? .waitingForRecovery : .disabled
        self.isConnected = isConnected
        self.bootstrap = bootstrap
    }

    func ensure(timeout: TimeInterval) async -> RecoveryRuntimeAgentEnsureResult {
        enabled = true
        if isConnected() {
            state = .ready
            stage = .ready
            errorCode = nil
            return successResult()
        }
        if state == .reconnecting, bootstrapTask == nil {
            do {
                try await waitForReconnect(timeout: timeout)
                state = .ready
                stage = .ready
                errorCode = nil
                return successResult()
            } catch {
                state = .failed
                stage = .failed
                errorCode = .timedOut
                return failurePayload(
                    message: "Timed out waiting for launchd to reconnect the Recovery agent."
                )
            }
        }

        let task: Task<Void, Error>
        if let bootstrapTask, state == .progressing || state == .reconnecting {
            task = bootstrapTask
        } else {
            state = .progressing
            stage = .waitingForRecovery
            errorCode = nil
            launchdManaged = false
            let bootstrap = self.bootstrap
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    let reporter = RecoveryRuntimeAgentStageReporter { next in
                        await self.record(stage: next)
                    }
                    try await bootstrap(reporter)
                    await self.bootstrapSucceeded()
                } catch {
                    await self.bootstrapFailed(error)
                    throw error
                }
            }
            bootstrapTask = task
        }

        do {
            try await waitForBootstrap(timeout: timeout)
        } catch is RecoveryRuntimeAgentTimeoutError {
            task.cancel()
            // A cancelled Recovery bootstrap owns bounded receipt collection
            // and exact workspace cleanup. Wait for that task before
            // publishing 124 so its helper result cannot race cleanup.
            _ = await task.result
            bootstrapTask = nil
            state = .failed
            stage = .failed
            errorCode = .timedOut
            return failurePayload(
                message: "Timed out waiting for the authenticated Recovery agent."
            )
        } catch is CancellationError {
            task.cancel()
            bootstrapTask = nil
            state = .failed
            stage = .failed
            errorCode = .cancelled
            return failurePayload(message: "Recovery agent setup was cancelled.")
        } catch {
            return failurePayload(message: failureMessage(for: errorCode ?? .bootstrapFailed))
        }
        return successResult()
    }

    func snapshot() -> RecoveryRuntimeAgentStatus {
        refreshConnectionState()
        return status()
    }

    func cancel() {
        errorCode = .cancelled
        bootstrapTask?.cancel()
        bootstrapTask = nil
        state = enabled ? .idle : .disabled
        stage = enabled ? .waitingForRecovery : .disabled
    }

    private func record(stage next: RecoveryRuntimeAgentStage) {
        guard state == .progressing || state == .reconnecting else { return }
        stage = next
        // `.connecting` records only that the Recovery bootstrap secret was
        // submitted. It is not proof that launchd accepted or relaunched the
        // runtime agent; that proof arrives through bootstrapSucceeded after
        // an authenticated session is observed.
        if next == .ready || next == .reconnecting {
            launchdManaged = true
        }
    }

    private func bootstrapSucceeded() {
        bootstrapTask = nil
        errorCode = nil
        launchdManaged = true
        if isConnected() {
            state = .ready
            stage = .ready
        } else {
            state = .reconnecting
            stage = .reconnecting
        }
    }

    private func bootstrapFailed(_ error: Error) {
        bootstrapTask = nil
        if errorCode == .timedOut || errorCode == .cancelled { return }
        state = .failed
        stage = .failed
        if error is CancellationError {
            errorCode = .cancelled
        } else if (error as? RunnerError).map({
            if case .sipCredentialUnavailable = $0 { return true }
            return false
        }) == true || error.localizedDescription.contains("stage=recoveryAuthentication") {
            errorCode = .credentialUnavailable
        } else {
            errorCode = .bootstrapFailed
        }
    }

    private func refreshConnectionState() {
        let connected = isConnected()
        if state == .ready, !connected {
            state = .reconnecting
            stage = .reconnecting
        } else if state == .reconnecting, connected {
            state = .ready
            stage = .ready
            errorCode = nil
        }
    }

    private func status() -> RecoveryRuntimeAgentStatus {
        let connected = isConnected()
        return RecoveryRuntimeAgentStatus(
            enabled: enabled,
            state: state,
            stage: stage,
            launchdManaged: launchdManaged,
            connected: connected,
            retryable: state == .failed || state == .reconnecting,
            errorCode: errorCode
        )
    }

    private func successResult() -> RecoveryRuntimeAgentEnsureResult {
        RecoveryRuntimeAgentEnsureResult(
            status: status(),
            ok: state == .ready && isConnected(),
            hostExitCode: state == .ready && isConnected() ? 0 : 1,
            error: nil
        )
    }

    private func failurePayload(message: String) -> RecoveryRuntimeAgentEnsureResult {
        RecoveryRuntimeAgentEnsureResult(
            status: status(),
            ok: false,
            hostExitCode: errorCode == .timedOut ? 124 : 1,
            error: message
        )
    }

    private func failureMessage(for code: RecoveryRuntimeAgentErrorCode) -> String {
        switch code {
        case .timedOut:
            "Timed out waiting for the authenticated Recovery agent."
        case .credentialUnavailable:
            "Recovery owner authentication is required, but no preconfigured credential is available."
        case .bootstrapFailed:
            "The authenticated Recovery agent could not be established."
        case .cancelled:
            "Recovery agent setup was cancelled."
        }
    }

    private func waitForBootstrap(timeout: TimeInterval) async throws {
        guard timeout > 0 else { throw RecoveryRuntimeAgentTimeoutError() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .ready:
                return
            case .failed:
                throw RecoveryRuntimeAgentBootstrapError()
            case .disabled, .idle, .progressing, .reconnecting:
                break
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RecoveryRuntimeAgentTimeoutError()
    }

    private func waitForReconnect(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if isConnected() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RecoveryRuntimeAgentTimeoutError()
    }
}

private struct RecoveryRuntimeAgentTimeoutError: Error {}
private struct RecoveryRuntimeAgentBootstrapError: Error {}

final class RecoveryRuntimeAgentStageReporter: @unchecked Sendable {
    private let body: RecoveryRuntimeAgentCoordinator.StageReporter

    init(_ body: @escaping RecoveryRuntimeAgentCoordinator.StageReporter) {
        self.body = body
    }

    func report(_ stage: RecoveryRuntimeAgentStage) async {
        await body(stage)
    }
}
