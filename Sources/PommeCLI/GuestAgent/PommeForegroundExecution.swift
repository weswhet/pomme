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
        try Task.checkCancellation()
        // This request is sent exactly once. If its outcome is uncertain there
        // is no safe job identity to retry, signal, or replace.
        let started = try await perform("process.start", .object(startPayload))
        guard let initial = started.result.objectValue,
              let text = initial["jobID"]?.stringValue, let jobID = UUID(uuidString: text)
        else {
            throw Error.invalidCompletion
        }
        var state = OutputState(jobID: jobID)
        var terminal = initial

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
            try checkpoint(timing: pollTiming, deadline: deadline)
            let eofFrames = try await sendStream(jobID, .eof, nil)
            try await state.accept(eofFrames, onFrames: onFrames)

            while true {
                try checkpoint(timing: pollTiming, deadline: deadline)
                let status = try await perform("process.status", .object(["jobID": .string(jobID.uuidString.lowercased())]))
                guard let values = status.result.objectValue,
                      let id = values["jobID"]?.stringValue, UUID(uuidString: id) == jobID,
                      case .bool = values["exited"]
                else { throw Error.invalidCompletion }
                terminal = initial.merging(values) { _, current in current }
                try await state.accept(status.streamFrames, onFrames: onFrames)
                if terminal["exited"] == .bool(true), state.receivedExit {
                    try validateTerminal(terminal)
                    return state.result(requestID: started.requestID, terminal: terminal)
                }
                try await pollTiming.sleep(min(.milliseconds(25), pollTiming.now().duration(to: deadline)))
            }
        } catch {
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
