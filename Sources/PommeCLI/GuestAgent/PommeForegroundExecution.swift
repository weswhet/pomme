import Darwin
import Foundation

/// Owns one foreground job from its single start request through both process
/// termination and output EOF. Transport exchanges already have bounded frames;
/// this layer supplies the missing command lifetime, without retrying mutations.
enum PommeForegroundExecution {
    typealias Perform = @Sendable (String, JSONValue) async throws -> PommeAgentCorrelatedResult
    typealias SendStream = @Sendable (UUID, PommeAgentProtocol.Stream, Data?) async throws -> [PommeAgentJobStreamFrame]
    typealias FrameHandler = @Sendable ([PommeAgentJobStreamFrame]) async throws -> Void
    static let maximumBufferedOutputBytes = 64 * 1024 // per output channel
    static let desktopCleanupReceiptKey = "_pommeDesktopProofCleanupReceipt"

    // Closed diagnostics only: associated error text can contain guest data.
    static func desktopTransportErrorKind(_ error: any Swift.Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? POSIXError {
            return error.code == .ETIMEDOUT ? "posixDeadline" : "posix"
        }
        if let error = error as? Error {
            switch error {
            case .deadlineReached: return "foregroundDeadline"
            case .unrelatedJobFrame: return "unrelatedJobFrame"
            case .invalidCompletion: return "invalidCompletion"
            default: return "foregroundValidation"
            }
        }
        if error is PommeAgentProtocol.Error { return "agentProtocol" }
        if error is PommeAgentVSOCKError { return "vsockSession" }
        if let error = error as? RunnerError {
            switch error {
            case .posix(_, let code): return code == ETIMEDOUT ? "posixDeadline" : "posix"
            case .controlCommandFailed: return "controlCommandFailed"
            case .noRunningVM: return "noHelper"
            case .invalidControlResponse, .incompatibleHelperProtocol: return "controlProtocol"
            case .guestAgentTimedOut, .guestAgentProbeTimedOut: return "agentTimeout"
            case .guestAgentProtocol: return "agentProtocol"
            case .guestAgentDisconnected: return "agentDisconnected"
            case .guestAgentUnavailable: return "agentUnavailable"
            case .guestAgentConnecting: return "agentConnecting"
            case .guestAgentError: return "agentError"
            default: return "runnerOther"
            }
        }
        return "other"
    }

    static func desktopElapsedMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let duration = start.duration(to: ContinuousClock.now).components
        return max(0, duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    private enum DesktopBoundary: String {
        case start, startValidation, frameAccept, eof, status, statusValidation
        case terminalValidation, checkpoint, wait, signal
    }

    static func isAquaProofPayload(_ payload: [String: JSONValue]) -> Bool {
        guard Set(payload.keys).isSubset(of: ["path", "arguments", "timeout", "detached"]),
              payload["path"] == .string("/bin/sh"),
              payload["detached"] == nil || payload["detached"] == .bool(false),
              case .array(let arguments)? = payload["arguments"], arguments.count == 4,
              arguments[0] == .string("-c"),
              arguments[1] == .string("exec /bin/launchctl print \"gui/$1\" >/dev/null"),
              arguments[2] == .string("pomme-aqua-proof"),
              let uid = arguments[3].stringValue, !uid.isEmpty,
              uid.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt32(uid), number > 0, String(number) == uid
        else { return false }
        return true
    }

    static func isDesktopProofPayload(_ payload: [String: JSONValue]) -> Bool {
        if isAquaProofPayload(payload) { return true }
        guard Set(payload.keys).isSubset(of: ["path", "arguments", "timeout", "detached"]),
              payload["detached"] == nil || payload["detached"] == .bool(false)
        else { return false }
        return (payload["path"] == .string("/usr/bin/stat")
            && payload["arguments"] == .array(["-f", "%Su:%u", "/dev/console"].map(JSONValue.string)))
            || (payload["path"] == .string("/bin/ps")
            && payload["arguments"] == .array(["-axo", "uid=,comm="].map(JSONValue.string)))
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case detachedPayload, unsupportedPTY, invalidPayload, invalidTimeout
        case unrelatedJobFrame, invalidCompletion, deadlineReached

        var errorDescription: String? {
            switch self {
            case .detachedPayload: "Detached jobs cannot use foreground execution."
            case .unsupportedPTY: "Interactive PTY execution requires the terminal stream workflow."
            case .invalidPayload: "Invalid foreground process payload."
            case .invalidTimeout: "Foreground timeout must be finite and between zero and 300 seconds."
            case .unrelatedJobFrame: "Foreground output belongs to another job."
            case .invalidCompletion: "Foreground process completion is invalid."
            case .deadlineReached: "Foreground command deadline was reached."
            }
        }
    }

    struct PollTiming: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let sleep: @Sendable (Duration) async throws -> Void

        init(
            now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.now = now
            self.sleep = sleep
        }
    }

    static func run(
        payload: JSONValue,
        timeout: TimeInterval,
        perform: @escaping Perform,
        sendStream: @escaping SendStream,
        pollTiming: PollTiming = .init(),
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        guard var startPayload = payload.objectValue else { throw Error.invalidPayload }
        let isDesktopProof = isDesktopProofPayload(startPayload)
        guard startPayload["detached"] != .bool(true) else { throw Error.detachedPayload }
        guard startPayload["pty"] != .bool(true) else { throw Error.unsupportedPTY }
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw Error.invalidTimeout }
        let input: Data
        if let encoded = startPayload.removeValue(forKey: "stdinDataBase64") {
            guard let text = encoded.stringValue, let decoded = Data(base64Encoded: text) else { throw Error.invalidPayload }
            input = decoded
        } else { input = Data() }
        startPayload.removeValue(forKey: "attachStdin")

        let deadline = pollTiming.now().advanced(by: .seconds(timeout))
        let diagnosticStart = ContinuousClock.now
        var pollCount = 0
        func diagnose(_ error: any Swift.Error, at boundary: DesktopBoundary, jobEstablished: Bool) {
            guard isDesktopProof else { return }
            PommeCore.log("[DEBUG-desktop-transport-20260923] side=helper boundary=\(boundary.rawValue) "
                + "elapsedMs=\(desktopElapsedMilliseconds(since: diagnosticStart)) "
                + "jobEstablished=\(jobEstablished) pollCount=\(pollCount) errorKind=\(desktopTransportErrorKind(error))")
        }
        try Task.checkCancellation()
        // This request is sent exactly once. If its outcome is uncertain there
        // is no safe job identity to retry, signal, or replace.
        let started: PommeAgentCorrelatedResult
        do { started = try await perform("process.start", .object(startPayload)) }
        catch { diagnose(error, at: .start, jobEstablished: false); throw error }
        guard let initial = started.result.objectValue,
              let text = initial["jobID"]?.stringValue, let jobID = UUID(uuidString: text)
        else {
            diagnose(Error.invalidCompletion, at: .startValidation, jobEstablished: false)
            throw Error.invalidCompletion
        }
        var state = OutputState(jobID: jobID)
        var terminal = initial
        var boundary = DesktopBoundary.frameAccept
        do {
            try await state.accept(started.streamFrames, onFrames: onFrames)
            var offset = 0
            while offset < input.count {
                try checkpoint(timing: pollTiming, deadline: deadline)
                let end = min(input.count, offset + PommeAgentProtocol.maximumStreamChunkBytes)
                let frames = try await sendStream(jobID, .stdin, input.subdata(in: offset..<end))
                try await state.accept(frames, onFrames: onFrames)
                offset = end
            }
            boundary = .checkpoint
            try checkpoint(timing: pollTiming, deadline: deadline)
            boundary = .eof
            let eofFrames = try await sendStream(jobID, .eof, nil)
            boundary = .frameAccept
            try await state.accept(eofFrames, onFrames: onFrames)

            while true {
                boundary = .checkpoint
                try checkpoint(timing: pollTiming, deadline: deadline)
                boundary = .status
                pollCount += 1
                let status = try await perform("process.status", .object(["jobID": .string(jobID.uuidString.lowercased())]))
                boundary = .statusValidation
                guard let values = status.result.objectValue,
                      let id = values["jobID"]?.stringValue, UUID(uuidString: id) == jobID,
                      case .bool = values["exited"]
                else { throw Error.invalidCompletion }
                terminal = initial.merging(values) { _, current in current }
                boundary = .frameAccept
                try await state.accept(status.streamFrames, onFrames: onFrames)
                if terminal["exited"] == .bool(true), state.receivedExit {
                    boundary = .terminalValidation
                    try validateTerminal(terminal)
                    return state.result(requestID: started.requestID, terminal: terminal)
                }
                boundary = .wait
                try await pollTiming.sleep(min(.milliseconds(25), pollTiming.now().duration(to: deadline)))
            }
        } catch {
            diagnose(error, at: boundary, jobEstablished: true)
            // No automatic replay, replacement process, or reboot. A failed
            // signal is retained as uncertainty, not treated as cleanup proof.
            let signalled: Bool
            var reapedAndDrained = state.cleanupFramesValid && state.receivedExit
            do {
                let signalResponse = try await perform("process.signal", .object([
                    "jobID": .string(jobID.uuidString.lowercased()), "signal": .integer(Int64(SIGTERM))
                ]))
                if let identity = signalResponse.result.objectValue?["jobID"]?.stringValue,
                   UUID(uuidString: identity) == jobID,
                   state.cleanupFramesValid,
                   Self.validCleanupFrames(signalResponse.streamFrames, jobID: jobID),
                   signalResponse.streamFrames.filter({ $0.frame.stream == .exit }).count == 1 {
                    reapedAndDrained = true
                }
                signalled = true
            } catch {
                diagnose(error, at: .signal, jobEstablished: true)
                signalled = false
            }
            if error is CancellationError || (error as? Error) == .deadlineReached {
                terminal["timedOut"] = .bool(!(error is CancellationError))
                terminal["cancelled"] = .bool(error is CancellationError)
                terminal["terminationRequested"] = .bool(signalled)
                return state.result(requestID: started.requestID, terminal: terminal,
                                    desktopCleanupVerified: isDesktopProof && reapedAndDrained)
            }
            throw error
        }
    }

    /// What to tell the operator when a foreground request ends without the
    /// guest process exiting. A foreground job is never in `jobs list`, which
    /// only holds detached ones, and both paths signal the process before
    /// giving up, so the message says what actually happened to it.
    static func interruptionMessage(timedOut: Bool, terminationRequested: Bool?) -> String {
        let ending = timedOut ? "Foreground command timed out" : "Foreground command was cancelled"
        guard terminationRequested == true else {
            return ending + " and the guest process could not be signalled; it may still be running in the guest."
        }
        return ending + "; the guest process was signalled to stop."
            + (timedOut ? " Use --detach to run a command that outlives the request." : "")
    }

    private static func checkpoint(timing: PollTiming, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard timing.now() < deadline else { throw Error.deadlineReached }
    }

    private static func validateTerminal(_ values: [String: JSONValue]) throws {
        if case .integer(let code)? = values["exitCode"], (0...255).contains(code), values["signal"] == nil { return }
        if case .integer(let signal)? = values["signal"], (1...127).contains(signal), values["exitCode"] == nil { return }
        throw Error.invalidCompletion
    }

    private static func validCleanupFrames(_ frames: [PommeAgentJobStreamFrame], jobID: UUID) -> Bool {
        frames.allSatisfy {
            guard $0.jobID == jobID, $0.frame.dimensions == nil else { return false }
            switch $0.frame.stream {
            case .stdout, .stderr: return $0.frame.data != nil && $0.frame.signal == nil
            case .exit:
                return $0.frame.data == nil && ($0.frame.signal.map { (1...127).contains($0) } ?? true)
            default: return false
            }
        } && frames.filter { $0.frame.stream == .exit }.count <= 1
    }

    private struct OutputState {
        let jobID: UUID
        var receivedExit = false
        var cleanupFramesValid = true
        var frames: [PommeAgentJobStreamFrame] = []
        var stdoutBytes = 0
        var stderrBytes = 0
        var stdoutTruncated = false
        var stderrTruncated = false

        mutating func accept(_ values: [PommeAgentJobStreamFrame], onFrames: FrameHandler?) async throws {
            guard values.allSatisfy({ $0.jobID == jobID }) else { throw Error.unrelatedJobFrame }
            guard values.allSatisfy({ [.stdout, .stderr, .exit].contains($0.frame.stream) }) else { throw Error.invalidCompletion }
            cleanupFramesValid = cleanupFramesValid && PommeForegroundExecution.validCleanupFrames(values, jobID: jobID)
            if values.contains(where: { $0.frame.stream == .exit }) { receivedExit = true }
            if let onFrames {
                if !values.isEmpty { try await onFrames(values) }
                return
            }
            for value in values {
                if value.frame.stream == .exit {
                    if !frames.contains(where: { $0.frame.stream == .exit }) { frames.append(value) }
                    continue
                }
                let data = value.frame.data ?? Data()
                let isStdout = value.frame.stream == .stdout
                let remaining = maximumBufferedOutputBytes - (isStdout ? stdoutBytes : stderrBytes)
                let retained = frames.count < 128 ? Data(data.prefix(remaining)) : Data()
                if retained.count != data.count {
                    if isStdout { stdoutTruncated = true } else { stderrTruncated = true }
                }
                if !retained.isEmpty {
                    frames.append(try .init(jobID: jobID, frame: .init(
                        requestID: value.frame.requestID, stream: value.frame.stream, data: retained
                    )))
                    if isStdout { stdoutBytes += retained.count } else { stderrBytes += retained.count }
                }
            }
        }

        func result(requestID: UUID, terminal: [String: JSONValue], desktopCleanupVerified: Bool = false) -> PommeAgentCorrelatedResult {
            var values = terminal
            // A guest result can never supply this host-generated receipt.
            values.removeValue(forKey: PommeForegroundExecution.desktopCleanupReceiptKey)
            if desktopCleanupVerified {
                values[PommeForegroundExecution.desktopCleanupReceiptKey] = .object([
                    "jobID": .string(jobID.uuidString.lowercased()), "reapedAndDrained": .bool(true)
                ])
            }
            values["outputComplete"] = .bool(receivedExit)
            values["stdoutTruncated"] = .bool(stdoutTruncated)
            values["stderrTruncated"] = .bool(stderrTruncated)
            return .init(requestID: requestID, result: .object(values), streamFrames: frames)
        }
    }
}

/// Streams a long-running, non-interactive guest process without retaining its
/// output. This is deliberately separate from `PommeForegroundExecution`:
/// normal foreground commands keep their five-minute lifetime and partial
/// output result semantics, while a log stream needs an unbounded lifetime and
/// proof that its owned process exited when the client goes away.
enum PommeLogStreamExecution {
    typealias Perform = @Sendable (String, JSONValue) async throws -> PommeAgentCorrelatedResult
    typealias SendStream = @Sendable (UUID, PommeAgentProtocol.Stream, Data?) async throws -> [PommeAgentJobStreamFrame]
    typealias FrameHandler = @Sendable ([PommeAgentJobStreamFrame]) async throws -> Void
    typealias CancellationProbe = @Sendable () async -> Bool

    enum CancellationReason: Equatable, Sendable {
        case cancelled
        case disconnected
        case timedOut
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case detachedPayload
        case unsupportedPTY
        case invalidPayload
        case invalidTimeout
        case unrelatedJobFrame
        case invalidCompletion
        case interrupted(reason: CancellationReason)
        case cleanupUnconfirmed(reason: CancellationReason)

        var errorDescription: String? {
            switch self {
            case .detachedPayload: "Detached jobs cannot use log streaming."
            case .unsupportedPTY: "Log streaming does not support PTY execution."
            case .invalidPayload: "Invalid log stream process payload."
            case .invalidTimeout: "Log stream timeout must be finite and greater than zero."
            case .unrelatedJobFrame: "Log stream output belongs to another job."
            case .invalidCompletion: "Log stream process completion is invalid."
            case .interrupted(let reason): "Log stream interrupted (\(reason.text))."
            case .cleanupUnconfirmed(let reason): "Log stream cleanup could not be confirmed (\(reason.text))."
            }
        }
    }

    /// Injectable time source used by the ordinary follow loop and the two
    /// bounded cleanup phases. `nil` timeout deliberately has no wall-clock
    /// deadline; every individual authenticated exchange remains bounded by
    /// the agent transport.
    struct PollTiming: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let sleep: @Sendable (Duration) async throws -> Void

        init(
            now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.now = now
            self.sleep = sleep
        }
    }

    private static let pollInterval = Duration.milliseconds(25)
    private static let terminateGrace = Duration.seconds(5)
    private static let killGrace = Duration.seconds(2)

    /// Starts exactly one guest process, closes its stdin, then forwards every
    /// valid output frame through `onFrames`. The returned result intentionally
    /// contains no output frames, so callers cannot accidentally reintroduce
    /// aggregate buffering for a long log history or follow session.
    static func run(
        payload: JSONValue,
        timeout: TimeInterval?,
        perform: @escaping Perform,
        sendStream: @escaping SendStream,
        shouldCancel: @escaping CancellationProbe,
        pollTiming: PollTiming = .init(),
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        guard var startPayload = payload.objectValue else { throw Error.invalidPayload }
        guard startPayload["detached"] != .bool(true) else { throw Error.detachedPayload }
        guard startPayload["pty"] != .bool(true) else { throw Error.unsupportedPTY }
        if let timeout, (!timeout.isFinite || timeout <= 0) { throw Error.invalidTimeout }

        // A log command never supplies input. Remove these transport-only
        // fields before start, then close stdin with one explicit EOF frame.
        startPayload.removeValue(forKey: "stdinDataBase64")
        startPayload.removeValue(forKey: "attachStdin")
        let deadline = timeout.map { pollTiming.now().advanced(by: .seconds($0)) }

        if Task.isCancelled { throw Error.interrupted(reason: .cancelled) }
        if await shouldCancel() { throw Error.interrupted(reason: .disconnected) }

        // Start has no retry: after an uncertain start reply, there is no safe
        // job identity to signal or replace.
        let started = try await perform("process.start", .object(startPayload))
        guard let initial = started.result.objectValue,
              let rawJobID = initial["jobID"]?.stringValue,
              let jobID = UUID(uuidString: rawJobID)
        else { throw Error.invalidCompletion }

        let state = OutputState(jobID: jobID)
        var terminal = initial
        do {
            try await state.accept(started.streamFrames, onFrames: onFrames)
            let eofFrames = try await sendStream(jobID, .eof, nil)
            try await state.accept(eofFrames, onFrames: onFrames)

            while true {
                if let reason = await interruptionReason(
                    deadline: deadline, shouldCancel: shouldCancel, timing: pollTiming
                ) {
                    throw Error.interrupted(reason: reason)
                }

                let status = try await perform("process.status", .object([
                    "jobID": .string(jobID.uuidString.lowercased())
                ]))
                let values = try state.acceptStatus(status)
                terminal = initial.merging(values) { _, current in current }
                try await state.accept(status.streamFrames, onFrames: onFrames)
                if state.isConfirmedExit {
                    try validateTerminal(terminal)
                    return .init(requestID: started.requestID, result: .object(terminal), streamFrames: [])
                }

                // Check again after a quiet status exchange before sleeping.
                // This observes a client disconnect even if `/usr/bin/log`
                // has produced no bytes since the prior poll.
                if let reason = await interruptionReason(
                    deadline: deadline, shouldCancel: shouldCancel, timing: pollTiming
                ) {
                    throw Error.interrupted(reason: reason)
                }
                try await sleepForPolling(timing: pollTiming, until: deadline)
            }
        } catch {
            let reason = reasonForCleanup(error)
            let confirmed = await cleanup(
                jobID: jobID,
                state: state,
                perform: perform,
                pollTiming: pollTiming
            )
            guard confirmed else { throw Error.cleanupUnconfirmed(reason: reason) }
            if let error = error as? Error, case .interrupted = error { throw error }
            if error is CancellationError { throw Error.interrupted(reason: .cancelled) }
            throw error
        }
    }

    private static func interruptionReason(
        deadline: ContinuousClock.Instant?,
        shouldCancel: CancellationProbe,
        timing: PollTiming
    ) async -> CancellationReason? {
        if Task.isCancelled { return .cancelled }
        if await shouldCancel() { return .disconnected }
        if let deadline, timing.now() >= deadline { return .timedOut }
        return nil
    }

    private static func reasonForCleanup(_ error: any Swift.Error) -> CancellationReason {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let error = error as? Error, case .interrupted(let reason) = error { return reason }
        // A callback, protocol, or transport error means the client can no
        // longer safely observe cleanup. Reuse the disconnect reason in the
        // explicit unconfirmed-cleanup result without exposing guest data.
        return .disconnected
    }

    private static func cleanup(
        jobID: UUID,
        state: OutputState,
        perform: @escaping Perform,
        pollTiming: PollTiming
    ) async -> Bool {
        do {
            // The process can exit after the follow loop's last status poll.
            // Try to establish that proof before signalling: PommeAgent
            // rejects a signal for an already reaped job, but the exit is
            // still a confirmed cleanup outcome. A failed proof is not a
            // reason to skip the required termination request.
            if (try? await observeConfirmedExit(state: state, perform: perform)) == true {
                return true
            }
            if try await signalOrObserveExit(
                SIGTERM, jobID: jobID, state: state, perform: perform
            ) {
                return true
            }
            if try await pollForConfirmedExit(
                state: state,
                perform: perform,
                timing: pollTiming,
                grace: terminateGrace
            ) {
                return true
            }
            if try await signalOrObserveExit(
                SIGKILL, jobID: jobID, state: state, perform: perform
            ) {
                return true
            }
            return try await pollForConfirmedExit(
                state: state,
                perform: perform,
                timing: pollTiming,
                grace: killGrace
            )
        } catch {
            return false
        }
    }

    /// A failed signal may mean the agent reaped the process immediately
    /// before the request. Check that exact job once before treating the
    /// cleanup transport as unconfirmed.
    private static func signalOrObserveExit(
        _ value: Int32,
        jobID: UUID,
        state: OutputState,
        perform: @escaping Perform
    ) async throws -> Bool {
        do {
            try await signal(value, jobID: jobID, state: state, perform: perform)
            return false
        } catch {
            if try await observeConfirmedExit(state: state, perform: perform) {
                return true
            }
            throw error
        }
    }

    private static func signal(
        _ value: Int32,
        jobID: UUID,
        state: OutputState,
        perform: @escaping Perform
    ) async throws {
        let response = try await perform("process.signal", .object([
            "jobID": .string(jobID.uuidString.lowercased()),
            "signal": .integer(Int64(value))
        ]))
        guard let values = response.result.objectValue,
              values["jobID"]?.stringValue == jobID.uuidString.lowercased(),
              values["signalled"] == .bool(true)
        else { throw Error.invalidCompletion }
        // The client may already be gone. Continue draining and validating
        // output locally, but do not call its failed output callback.
        try await state.accept(response.streamFrames, onFrames: nil)
    }

    private static func pollForConfirmedExit(
        state: OutputState,
        perform: @escaping Perform,
        timing: PollTiming,
        grace: Duration
    ) async throws -> Bool {
        let deadline = timing.now().advanced(by: grace)
        while timing.now() < deadline {
            if try await observeConfirmedExit(state: state, perform: perform) { return true }
            try await sleepForPolling(timing: timing, until: deadline)
        }
        return false
    }

    /// Drains one status exchange without invoking the client callback. It is
    /// used during cleanup both to avoid retaining bytes and to prove a race
    /// with guest reaping before or during `process.signal`.
    private static func observeConfirmedExit(
        state: OutputState,
        perform: @escaping Perform
    ) async throws -> Bool {
        let status = try await perform("process.status", .object([
            "jobID": .string(state.jobID.uuidString.lowercased())
        ]))
        let values = try state.acceptStatus(status)
        try await state.accept(status.streamFrames, onFrames: nil)
        if state.isConfirmedExit {
            try validateTerminal(values)
            return true
        }
        return false
    }

    private static func sleepForPolling(
        timing: PollTiming,
        until deadline: ContinuousClock.Instant?
    ) async throws {
        let duration: Duration
        if let deadline {
            let remaining = timing.now().duration(to: deadline)
            guard remaining > .zero else { return }
            duration = min(pollInterval, remaining)
        } else {
            duration = pollInterval
        }
        do {
            try await timing.sleep(duration)
        } catch is CancellationError {
            // A cancelled task still owns cleanup. The detached wait avoids a
            // hot loop when `Task.sleep` immediately observes cancellation.
            try await Task.detached(priority: .utility) {
                try await Task.sleep(for: duration)
            }.value
        }
    }

    private static func validateTerminal(_ values: [String: JSONValue]) throws {
        if case .integer(let code)? = values["exitCode"], (0...255).contains(code), values["signal"] == nil { return }
        if case .integer(let signal)? = values["signal"], (1...127).contains(signal), values["exitCode"] == nil { return }
        throw Error.invalidCompletion
    }

    private final class OutputState: @unchecked Sendable {
        let jobID: UUID
        private var sawExit = false
        private var statusExited = false

        init(jobID: UUID) {
            self.jobID = jobID
        }

        var isConfirmedExit: Bool { sawExit && statusExited }

        func acceptStatus(_ response: PommeAgentCorrelatedResult) throws -> [String: JSONValue] {
            guard let values = response.result.objectValue,
                  values["jobID"]?.stringValue == jobID.uuidString.lowercased(),
                  case .bool(let exited)? = values["exited"]
            else { throw Error.invalidCompletion }
            statusExited = exited
            return values
        }

        func accept(
            _ frames: [PommeAgentJobStreamFrame],
            onFrames: FrameHandler?
        ) async throws {
            guard frames.allSatisfy({ $0.jobID == jobID }) else { throw Error.unrelatedJobFrame }
            for frame in frames {
                guard frame.frame.dimensions == nil else { throw Error.invalidCompletion }
                switch frame.frame.stream {
                case .stdout, .stderr:
                    guard frame.frame.data != nil, frame.frame.signal == nil else {
                        throw Error.invalidCompletion
                    }
                case .exit:
                    guard !sawExit,
                          frame.frame.data == nil,
                          frame.frame.signal.map({ (1...127).contains($0) }) ?? true
                    else { throw Error.invalidCompletion }
                    sawExit = true
                case .stdin, .eof, .resize, .signal:
                    throw Error.invalidCompletion
                }
            }
            if let onFrames, !frames.isEmpty { try await onFrames(frames) }
        }
    }
}

private extension PommeLogStreamExecution.CancellationReason {
    var text: String {
        switch self {
        case .cancelled: "cancelled"
        case .disconnected: "disconnected"
        case .timedOut: "timed out"
        }
    }
}
