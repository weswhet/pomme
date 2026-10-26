import Foundation
import os

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
                PommeUnifiedLog.recovery.error("Recovery runtime agent: timed out after \(timeout, privacy: .public)s waiting for launchd to reconnect")
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
            PommeUnifiedLog.recovery.notice("Recovery runtime agent: bootstrap started (timeout \(timeout, privacy: .public)s)")
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
            PommeUnifiedLog.recovery.error(
                "Recovery runtime agent: timed out after \(timeout, privacy: .public)s at stage \(self.stage.rawValue, privacy: .public)"
            )
            bootstrapTask = nil
            state = .failed
            stage = .failed
            errorCode = .timedOut
            return failurePayload(
                message: "Timed out waiting for the authenticated Recovery agent."
            )
        } catch is CancellationError {
            PommeUnifiedLog.recovery.notice("Recovery runtime agent: setup cancelled at stage \(self.stage.rawValue, privacy: .public)")
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
        PommeUnifiedLog.recovery.notice("Recovery runtime agent: cancel requested at stage \(self.stage.rawValue, privacy: .public)")
        errorCode = .cancelled
        bootstrapTask?.cancel()
        bootstrapTask = nil
        state = enabled ? .idle : .disabled
        stage = enabled ? .waitingForRecovery : .disabled
    }

    private func record(stage next: RecoveryRuntimeAgentStage) {
        guard state == .progressing || state == .reconnecting else { return }
        stage = next
        PommeUnifiedLog.recovery.notice("Recovery runtime agent: stage \(next.rawValue, privacy: .public)")
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
        PommeUnifiedLog.recovery.notice("Recovery runtime agent: bootstrap succeeded; state=\(self.state.rawValue, privacy: .public)")
    }

    private func bootstrapFailed(_ error: Error) {
        PommeUnifiedLog.error(error, context: "Recovery runtime agent bootstrap at stage \(stage.rawValue)", logger: PommeUnifiedLog.recovery)
        bootstrapTask = nil
        if errorCode == .timedOut || errorCode == .cancelled { return }
        state = .failed
        stage = .failed
        if error is CancellationError {
            errorCode = .cancelled
        } else if Self.isCredentialUnavailable(error) {
            errorCode = .credentialUnavailable
        } else {
            errorCode = .bootstrapFailed
        }
    }

    /// Whether the bootstrap stopped because no owner credential was
    /// available, judged by the stable code of the error or of any error
    /// underneath it, never by message text.
    private static func isCredentialUnavailable(_ error: Error) -> Bool {
        let report = PommeErrorReport(error, redaction: .none)
        return report.code == .credentialUnavailable
            || report.causes.contains { $0.domain == "pomme" && $0.code == PommeErrorCode.credentialUnavailable.rawValue }
    }

    private func refreshConnectionState() {
        let connected = isConnected()
        if state == .ready, !connected {
            PommeUnifiedLog.recovery.notice("Recovery runtime agent: connection lost; waiting for launchd to reconnect")
            state = .reconnecting
            stage = .reconnecting
        } else if state == .reconnecting, connected {
            PommeUnifiedLog.recovery.notice("Recovery runtime agent: reconnected")
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

private struct RecoveryRuntimeAgentTimeoutError: PommeDescribedError {
    var code: PommeErrorCode { .recoveryTimedOut }
    var errorDescription: String? { "Timed out waiting for the authenticated Recovery agent." }
}

private struct RecoveryRuntimeAgentBootstrapError: PommeDescribedError {
    var code: PommeErrorCode { .recoveryAgentFailed }
    var errorDescription: String? { "The authenticated Recovery agent couldn't be established." }
}

final class RecoveryRuntimeAgentStageReporter: @unchecked Sendable {
    private let body: RecoveryRuntimeAgentCoordinator.StageReporter

    init(_ body: @escaping RecoveryRuntimeAgentCoordinator.StageReporter) {
        self.body = body
    }

    func report(_ stage: RecoveryRuntimeAgentStage) async {
        await body(stage)
    }
}
