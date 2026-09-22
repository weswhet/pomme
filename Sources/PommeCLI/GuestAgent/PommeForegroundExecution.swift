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

    // Temporary diagnostics: never interpolate an error or its associated text.
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

    // Temporary, closed diagnostics for the September 22 Aqua timeout investigation.
    static let aquaDebugKey = "_pommeDebugAqua20260922"
    static let aquaDebugNumbers = ["totalMicros", "startMicros", "eofMicros", "statusCount", "statusTotalMicros", "statusMaxMicros", "signalMicros"] + PommeAquaWaitDebug.fields
    static let aquaDebugBooleans = ["validPositiveStartPID", "lastExited", "exitFrameBeforeSignal", "signalExitFrame"]

    static func isAquaDebugPayload(_ payload: [String: JSONValue]) -> Bool {
        isAquaProofPayload(payload)
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

    private struct AquaTiming {
        var values: [String: JSONValue] = ["statusCount": .integer(0), "statusTotalMicros": .integer(0), "statusMaxMicros": .integer(0)]
        var statusCount: Int64 = 0
        var statusTotal: Int64 = 0
        var statusMax: Int64 = 0

        mutating func recordWaitSnapshot(_ terminal: [String: JSONValue]) {
            // Replace cumulative counters; never sum snapshots or retain stale
            // fields when an old guest supplies no diagnostic metadata.
            for field in PommeAquaWaitDebug.fields { values.removeValue(forKey: field) }
            guard let snapshot = terminal[PommeAquaWaitDebug.key]?.objectValue else { return }
            for field in PommeAquaWaitDebug.fields {
                guard case .integer(let number)? = snapshot[field], number >= 0,
                      field != "waitLastOutcome" || PommeAquaWaitDebug.Outcome(rawValue: number) != nil
                else { continue }
                values[field] = .integer(number)
            }
        }

        mutating func record(_ field: String, since start: ContinuousClock.Instant) {
            let duration = start.duration(to: ContinuousClock().now).components
            let micros = max(0, duration.seconds * 1_000_000 + duration.attoseconds / 1_000_000_000_000)
            if field == "status" {
                statusCount += 1
                statusTotal += micros
                statusMax = max(statusMax, micros)
                values["statusCount"] = .integer(statusCount)
                values["statusTotalMicros"] = .integer(statusTotal)
                values["statusMaxMicros"] = .integer(statusMax)
            } else { values[field] = .integer(micros) }
        }
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

    static func run(
        payload: JSONValue,
        timeout: TimeInterval,
        perform: @escaping Perform,
        sendStream: @escaping SendStream,
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        guard var startPayload = payload.objectValue else { throw Error.invalidPayload }
        let isDesktopProof = isDesktopProofPayload(startPayload)
        var aquaTiming: AquaTiming? = isAquaDebugPayload(startPayload) ? AquaTiming() : nil
        guard startPayload["detached"] != .bool(true) else { throw Error.detachedPayload }
        guard startPayload["pty"] != .bool(true) else { throw Error.unsupportedPTY }
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw Error.invalidTimeout }
        let input: Data
        if let encoded = startPayload.removeValue(forKey: "stdinDataBase64") {
            guard let text = encoded.stringValue, let decoded = Data(base64Encoded: text) else { throw Error.invalidPayload }
            input = decoded
        } else { input = Data() }
        startPayload.removeValue(forKey: "attachStdin")

        let clock = ContinuousClock()
        let executionStart = clock.now
        let deadline = executionStart.advanced(by: .seconds(timeout))
        var pollCount = 0
        func diagnose(_ error: any Swift.Error, at boundary: DesktopBoundary, jobEstablished: Bool) {
            guard isDesktopProof else { return }
            PommeCore.log("[DEBUG-desktop-transport-20260922] side=helper boundary=\(boundary.rawValue) "
                + "elapsedMs=\(desktopElapsedMilliseconds(since: executionStart)) "
                + "jobEstablished=\(jobEstablished) pollCount=\(pollCount) errorKind=\(desktopTransportErrorKind(error))")
        }
        try Task.checkCancellation()
        // This request is sent exactly once. If its outcome is uncertain there
        // is no safe job identity to retry, signal, or replace.
        let startTime = clock.now
        let started: PommeAgentCorrelatedResult
        do { started = try await perform("process.start", .object(startPayload)) }
        catch { diagnose(error, at: .start, jobEstablished: false); throw error }
        aquaTiming?.record("startMicros", since: startTime)
        guard let initial = started.result.objectValue,
              let text = initial["jobID"]?.stringValue, let jobID = UUID(uuidString: text)
        else {
            diagnose(Error.invalidCompletion, at: .startValidation, jobEstablished: false)
            throw Error.invalidCompletion
        }
        var state = OutputState(jobID: jobID)
        var terminal = initial
        if case .integer(let pid)? = initial["pid"] {
            aquaTiming?.values["validPositiveStartPID"] = .bool(pid > 0)
        } else { aquaTiming?.values["validPositiveStartPID"] = .bool(false) }

        var boundary = DesktopBoundary.frameAccept
        do {
            try await state.accept(started.streamFrames, onFrames: onFrames)
            var offset = 0
            while offset < input.count {
                try checkpoint(clock: clock, deadline: deadline)
                let end = min(input.count, offset + PommeAgentProtocol.maximumStreamChunkBytes)
                let frames = try await sendStream(jobID, .stdin, input.subdata(in: offset..<end))
                try await state.accept(frames, onFrames: onFrames)
                offset = end
            }
            boundary = .checkpoint
            try checkpoint(clock: clock, deadline: deadline)
            let eofFrames: [PommeAgentJobStreamFrame]
            do {
                boundary = .eof
                let start = clock.now
                defer { aquaTiming?.record("eofMicros", since: start) }
                eofFrames = try await sendStream(jobID, .eof, nil)
            }
            boundary = .frameAccept
            try await state.accept(eofFrames, onFrames: onFrames)

            while true {
                boundary = .checkpoint
                try checkpoint(clock: clock, deadline: deadline)
                let status: PommeAgentCorrelatedResult
                do {
                    boundary = .status
                    pollCount += 1
                    let start = clock.now
                    defer { aquaTiming?.record("status", since: start) }
                    status = try await perform("process.status", .object(["jobID": .string(jobID.uuidString.lowercased())]))
                }
                boundary = .statusValidation
                guard let values = status.result.objectValue,
                      let id = values["jobID"]?.stringValue, UUID(uuidString: id) == jobID,
                      case .bool = values["exited"]
                else { throw Error.invalidCompletion }
                terminal = initial.merging(values) { _, current in current }
                aquaTiming?.values["lastExited"] = values["exited"]
                aquaTiming?.recordWaitSnapshot(values)
                boundary = .frameAccept
                try await state.accept(status.streamFrames, onFrames: onFrames)
                if terminal["exited"] == .bool(true), state.receivedExit {
                    boundary = .terminalValidation
                    try validateTerminal(terminal)
                    aquaTiming?.values["exitFrameBeforeSignal"] = .bool(state.receivedExit)
                    aquaTiming?.record("totalMicros", since: executionStart)
                    if let aquaTiming { terminal[aquaDebugKey] = .object(aquaTiming.values) }
                    return state.result(requestID: started.requestID, terminal: terminal)
                }
                boundary = .wait
                try await Task.sleep(for: min(.milliseconds(25), clock.now.duration(to: deadline)))
            }
        } catch {
            diagnose(error, at: boundary, jobEstablished: true)
            // No automatic replay, replacement process, or reboot. A failed
            // signal is retained as uncertainty, not treated as cleanup proof.
            let signalled: Bool
            var reapedAndDrained = state.cleanupFramesValid && state.receivedExit
            aquaTiming?.values["exitFrameBeforeSignal"] = .bool(state.receivedExit)
            do {
                let start = clock.now
                defer { aquaTiming?.record("signalMicros", since: start) }
                let signalResponse = try await perform("process.signal", .object([
                    "jobID": .string(jobID.uuidString.lowercased()), "signal": .integer(Int64(SIGTERM))
                ]))
                aquaTiming?.values["signalExitFrame"] = .bool(signalResponse.streamFrames.contains {
                    $0.jobID == jobID && $0.frame.stream == .exit
                })
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
                aquaTiming?.record("totalMicros", since: executionStart)
                if let aquaTiming { terminal[aquaDebugKey] = .object(aquaTiming.values) }
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

    private static func checkpoint(clock: ContinuousClock, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw Error.deadlineReached }
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
