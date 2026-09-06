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
        let deadline = clock.now.advanced(by: .seconds(timeout))
        try Task.checkCancellation()
        // This request is sent exactly once. If its outcome is uncertain there
        // is no safe job identity to retry, signal, or replace.
        let started = try await perform("process.start", .object(startPayload))
        guard let initial = started.result.objectValue,
              let text = initial["jobID"]?.stringValue, let jobID = UUID(uuidString: text)
        else { throw Error.invalidCompletion }
        var state = OutputState(jobID: jobID)
        var terminal = initial

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
            try checkpoint(clock: clock, deadline: deadline)
            try await state.accept(try await sendStream(jobID, .eof, nil), onFrames: onFrames)

            while true {
                try checkpoint(clock: clock, deadline: deadline)
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
                try await Task.sleep(for: min(.milliseconds(25), clock.now.duration(to: deadline)))
            }
        } catch {
            // No automatic replay, replacement process, or reboot. A failed
            // signal is retained as uncertainty, not treated as cleanup proof.
            let signalled: Bool
            do {
                _ = try await perform("process.signal", .object([
                    "jobID": .string(jobID.uuidString.lowercased()), "signal": .integer(Int64(SIGTERM))
                ]))
                signalled = true
            } catch { signalled = false }
            if error is CancellationError || (error as? Error) == .deadlineReached {
                terminal["timedOut"] = .bool(!(error is CancellationError))
                terminal["cancelled"] = .bool(error is CancellationError)
                terminal["terminationRequested"] = .bool(signalled)
                return state.result(requestID: started.requestID, terminal: terminal)
            }
            throw error
        }
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

    private struct OutputState {
        let jobID: UUID
        var receivedExit = false
        var frames: [PommeAgentJobStreamFrame] = []
        var stdoutBytes = 0
        var stderrBytes = 0
        var stdoutTruncated = false
        var stderrTruncated = false

        mutating func accept(_ values: [PommeAgentJobStreamFrame], onFrames: FrameHandler?) async throws {
            guard values.allSatisfy({ $0.jobID == jobID }) else { throw Error.unrelatedJobFrame }
            guard values.allSatisfy({ [.stdout, .stderr, .exit].contains($0.frame.stream) }) else { throw Error.invalidCompletion }
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

        func result(requestID: UUID, terminal: [String: JSONValue]) -> PommeAgentCorrelatedResult {
            var values = terminal
            values["outputComplete"] = .bool(receivedExit)
            values["stdoutTruncated"] = .bool(stdoutTruncated)
            values["stderrTruncated"] = .bool(stderrTruncated)
            return .init(requestID: requestID, result: .object(values), streamFrames: frames)
        }
    }
}
