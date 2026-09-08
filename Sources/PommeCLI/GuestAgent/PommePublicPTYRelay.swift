import Darwin
import Foundation

/// Bridges a public interactive PTY across the authenticated control stream.
/// The helper owns guest polling so output remains live even while the local
/// terminal has no input available.
enum PommePublicPTYRelay {
    static let maximumTimeout: TimeInterval = 300
    static let pollInterval: TimeInterval = 0.025

    typealias Perform = @Sendable (String, JSONValue) async throws -> PommeAgentCorrelatedResult
    typealias SendStream = @Sendable (UUID, PommeAgentProtocol.Stream, Data?, (columns: Int, rows: Int)?, Int32?) async throws -> [PommeAgentJobStreamFrame]
    typealias ReceiveControl = @Sendable (TimeInterval) throws -> PommeControlStreamFrame?
    typealias FrameHandler = @Sendable ([PommeAgentJobStreamFrame]) throws -> Void

    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidPayload, invalidTimeout, invalidControlFrame, invalidCompletion, unrelatedJobFrame, publicEchoUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidPayload: "Invalid public PTY process payload."
            case .invalidTimeout: "Public PTY timeout must be finite and between zero and 300 seconds."
            case .invalidControlFrame: "Invalid public PTY control frame."
            case .invalidCompletion: "Public PTY process completion is invalid."
            case .unrelatedJobFrame: "Public PTY output belongs to another job."
            case .publicEchoUnavailable: "Public PTY execution requires a current Pomme agent with terminal echo enabled."
            }
        }
    }

    /// A public PTY is enabled only by the persistent agent's explicit
    /// capability receipt. Older agents therefore fail before process.start.
    static func supportsPublicEcho(_ description: JSONValue) -> Bool {
        description.objectValue?["publicPTYEchoVersion"] == .integer(1)
    }

    static func run(
        payload: JSONValue,
        timeout: TimeInterval,
        perform: @escaping Perform,
        sendStream: @escaping SendStream,
        receiveControl: @escaping ReceiveControl,
        onFrames: @escaping FrameHandler
    ) async throws -> PommeAgentCorrelatedResult {
        guard timeout.isFinite, timeout > 0, timeout <= maximumTimeout
        else { throw Error.invalidTimeout }
        guard let values = payload.objectValue,
              values["pty"] == .bool(true),
              values["detached"] != .bool(true)
        else { throw Error.invalidPayload }

        let started = try await perform("process.start", payload)
        guard let initial = started.result.objectValue,
              let rawJobID = initial["jobID"]?.stringValue,
              let jobID = UUID(uuidString: rawJobID),
              initial["exited"] == .bool(false)
        else { throw Error.invalidCompletion }
        guard initial["ptyEchoDisabled"] == .bool(false) else {
            _ = try? await sendStream(jobID, .signal, nil, nil, SIGTERM)
            throw Error.publicEchoUnavailable
        }

        var state = OutputState(jobID: jobID)
        var terminal = initial
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        do {
            try state.accept(started.streamFrames, onFrames: onFrames)
            while true {
                try Task.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 {
                    let frames = try await sendStream(jobID, .signal, nil, nil, SIGTERM)
                    try state.accept(frames, onFrames: onFrames)
                    terminal["timedOut"] = .bool(true)
                    terminal["terminationRequested"] = .bool(true)
                    return state.result(requestID: started.requestID, terminal: terminal)
                }

                if let frame = try receiveControl(max(0.001, min(pollInterval, remaining))) {
                    let frames = try await forward(frame, jobID: jobID, sendStream: sendStream)
                    try state.accept(frames, onFrames: onFrames)
                    if frame.stream == .cancellation {
                        terminal["cancelled"] = .bool(true)
                        terminal["terminationRequested"] = .bool(true)
                        return state.result(requestID: started.requestID, terminal: terminal)
                    }
                }

                let status = try await perform(
                    "process.status",
                    .object(["jobID": .string(jobID.uuidString.lowercased())])
                )
                guard let values = status.result.objectValue,
                      values["jobID"]?.stringValue.flatMap(UUID.init(uuidString:)) == jobID,
                      case .bool = values["exited"]
                else { throw Error.invalidCompletion }
                terminal.merge(values) { _, current in current }
                try state.accept(status.streamFrames, onFrames: onFrames)
                if terminal["exited"] == .bool(true), state.receivedExit {
                    try validateTerminal(terminal)
                    return state.result(requestID: started.requestID, terminal: terminal)
                }
            }
        } catch is CancellationError {
            let signalled: Bool
            do {
                let frames = try await sendStream(jobID, .signal, nil, nil, SIGTERM)
                try state.accept(frames, onFrames: onFrames)
                signalled = true
            } catch { signalled = false }
            terminal["cancelled"] = .bool(true)
            terminal["terminationRequested"] = .bool(signalled)
            return state.result(requestID: started.requestID, terminal: terminal)
        } catch {
            _ = try? await sendStream(jobID, .signal, nil, nil, SIGTERM)
            throw error
        }
    }

    private static func forward(
        _ frame: PommeControlStreamFrame,
        jobID: UUID,
        sendStream: SendStream
    ) async throws -> [PommeAgentJobStreamFrame] {
        switch frame.stream {
        case .stdin:
            if frame.eof == true {
                return try await sendStream(jobID, .eof, nil, nil, nil)
            }
            guard let data = try frame.decodedData(), !data.isEmpty else {
                throw Error.invalidControlFrame
            }
            return try await sendStream(jobID, .stdin, data, nil, nil)
        case .resize:
            guard let dimensions = dimensions(from: frame.payload) else {
                throw Error.invalidControlFrame
            }
            return try await sendStream(jobID, .resize, nil, dimensions, nil)
        case .signal:
            guard let signal = signal(from: frame.payload), signal > 0, signal < 128 else {
                throw Error.invalidControlFrame
            }
            return try await sendStream(jobID, .signal, nil, nil, signal)
        case .cancellation:
            return try await sendStream(jobID, .signal, nil, nil, SIGTERM)
        case .stdout, .stderr, .progress:
            throw Error.invalidControlFrame
        }
    }

    private static func dimensions(from payload: JSONValue?) -> (columns: Int, rows: Int)? {
        guard let object = payload?.objectValue,
              case .integer(let columns)? = object["columns"],
              case .integer(let rows)? = object["rows"],
              let columns = Int(exactly: columns), let rows = Int(exactly: rows),
              columns > 0, rows > 0
        else { return nil }
        return (columns, rows)
    }

    private static func signal(from payload: JSONValue?) -> Int32? {
        guard let object = payload?.objectValue,
              case .integer(let value)? = object["signal"]
        else { return nil }
        return Int32(exactly: value)
    }

    private static func validateTerminal(_ values: [String: JSONValue]) throws {
        if case .integer(let code)? = values["exitCode"], (0...255).contains(code), values["signal"] == nil { return }
        if case .integer(let signal)? = values["signal"], (1...127).contains(signal), values["exitCode"] == nil { return }
        throw Error.invalidCompletion
    }

    private struct OutputState {
        let jobID: UUID
        var receivedExit = false

        mutating func accept(_ frames: [PommeAgentJobStreamFrame], onFrames: FrameHandler) throws {
            guard frames.allSatisfy({ $0.jobID == jobID }) else { throw Error.unrelatedJobFrame }
            guard frames.allSatisfy({ [.stdout, .stderr, .exit].contains($0.frame.stream) }) else {
                throw Error.invalidCompletion
            }
            receivedExit = receivedExit || frames.contains(where: { $0.frame.stream == .exit })
            if !frames.isEmpty { try onFrames(frames) }
        }

        func result(requestID: UUID, terminal: [String: JSONValue]) -> PommeAgentCorrelatedResult {
            var values = terminal
            values["outputComplete"] = .bool(receivedExit)
            values["stdoutTruncated"] = .bool(false)
            values["stderrTruncated"] = .bool(false)
            return .init(requestID: requestID, result: .object(values), streamFrames: [])
        }
    }
}

/// Drives a public PTY from a real host terminal.  This type deliberately
/// keeps terminal mechanics at the host boundary; the guest never sees host
/// termios or escape-sequence state.
struct PommePublicPTYTerminalBridge {
    struct Transport {
        let send: (_ stream: PommeControlStreamFrame.Stream, _ data: Data?, _ payload: JSONValue?, _ eof: Bool?) throws -> Void
        let receive: (_ timeout: TimeInterval) throws -> PommeControlStreamEvent?
    }

    let transport: Transport
    let inputFD: Int32
    let outputFD: Int32
    let errorFD: Int32

    init(
        transport: Transport,
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO,
        errorFD: Int32 = STDERR_FILENO
    ) {
        self.transport = transport
        self.inputFD = inputFD
        self.outputFD = outputFD
        self.errorFD = errorFD
    }

    func run(timeout: TimeInterval) throws -> [String: Any] {
        guard timeout.isFinite, timeout > 0,
              isatty(inputFD) == 1, isatty(outputFD) == 1
        else { throw RunnerError.invalidGuestCommand("Public PTY requires an interactive terminal.") }

        let terminal = try TerminalMode(inputFD: inputFD)
        defer { terminal.restore() }
        try terminal.enable()
        var lastDimensions: (columns: Int, rows: Int)?

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var cancellationSent = false
        var timedOutCancellation = false
        var cancellationDeadline: TimeInterval?
        do {
            try sendResizeIfNeeded(lastDimensions: &lastDimensions)
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0, !cancellationSent {
                    try transport.send(.cancellation, nil, nil, nil)
                    cancellationSent = true
                    timedOutCancellation = true
                    cancellationDeadline = ProcessInfo.processInfo.systemUptime + 3
                }

                if let cancellationDeadline, ProcessInfo.processInfo.systemUptime >= cancellationDeadline {
                    throw RunnerError.invalidGuestCommand("Public PTY cancellation did not receive a terminal completion response.")
                }

                let receiveTimeout: TimeInterval
                if cancellationSent {
                    receiveTimeout = 0.025
                } else {
                    receiveTimeout = max(0.001, min(0.025, remaining))
                }
                if let event = try transport.receive(receiveTimeout) {
                    switch event {
                    case .stream(let frame): try write(frame)
                    case .response(let response): return try terminalResponse(response, localTimeout: timedOutCancellation)
                    }
                }

                try sendResizeIfNeeded(lastDimensions: &lastDimensions)
                guard !cancellationSent else { continue }
                switch try readInputIfAvailable() {
                case .none: break
                case .some(nil):
                    try transport.send(.cancellation, nil, nil, nil)
                    cancellationSent = true
                    cancellationDeadline = ProcessInfo.processInfo.systemUptime + 3
                case .some(.some(let data)):
                    try forwardInput(data)
                }
            }
        } catch {
            if !cancellationSent { try? transport.send(.cancellation, nil, nil, nil) }
            throw error
        }
    }

    private func terminalResponse(_ response: PommeControlResponse, localTimeout: Bool) throws -> [String: Any] {
        guard response.ok, let object = response.result?.objectValue else {
            let error = response.error
            throw RunnerError.controlCommandFailed(error.map { "\($0.code): \($0.message)" } ?? "Missing public PTY completion response.")
        }
        var payload = object.mapValues(\.publicValue)
        if localTimeout {
            if var result = payload["result"] as? [String: Any] {
                result["timedOut"] = true
                result["cancelled"] = false
                payload["result"] = result
            }
            payload["ok"] = false
            payload["hostExitCode"] = 124
            payload["error"] = "Foreground command timed out; inspect the returned job ID before taking further action."
        }
        payload["foreground"] = true
        payload["streamFrames"] = [[String: Any]]()
        return payload
    }

    private func write(_ frame: PommeControlStreamFrame) throws {
        switch frame.stream {
        case .stdout, .stderr:
            guard let data = try frame.decodedData() else {
                guard frame.eof == true else { throw RunnerError.invalidControlResponse("Invalid public PTY output frame.") }
                return
            }
            try write(data, to: frame.stream == .stdout ? outputFD : errorFD)
        case .progress: return
        case .stdin, .resize, .signal, .cancellation:
            throw RunnerError.invalidControlResponse("Unexpected public PTY control output.")
        }
    }

    private func forwardInput(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            if let controlC = data[offset...].firstIndex(of: 0x03) {
                if controlC > offset {
                    try transport.send(.stdin, Data(data[offset..<controlC]), nil, nil)
                }
                try transport.send(.signal, nil, .object(["signal": .integer(Int64(SIGINT))]), nil)
                offset = controlC + 1
            } else {
                try transport.send(.stdin, Data(data[offset...]), nil, nil)
                return
            }
        }
    }

    private func sendResizeIfNeeded(lastDimensions: inout (columns: Int, rows: Int)?) throws {
        guard let current = dimensions(), current.columns != lastDimensions?.columns || current.rows != lastDimensions?.rows else { return }
        try transport.send(.resize, nil, .object([
            "columns": .integer(Int64(current.columns)),
            "rows": .integer(Int64(current.rows)),
        ]), nil)
        lastDimensions = current
    }

    private func dimensions() -> (columns: Int, rows: Int)? {
        var size = winsize()
        guard ioctl(outputFD, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    private func readInputIfAvailable() throws -> Data?? {
        var descriptor = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, 0)
            if result == 0 { return nil }
            if result < 0 {
                if errno == EINTR { continue }
                try throwPOSIX("poll")
            }
            var bytes = [UInt8](repeating: 0, count: 32 * 1024)
            let count = Darwin.read(inputFD, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return .some(nil) }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            try throwPOSIX("read")
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { try throwPOSIX("public PTY output") }
            }
        }
    }

    private final class TerminalMode {
        private let inputFD: Int32
        private let original: termios

        init(inputFD: Int32) throws {
            self.inputFD = inputFD
            var value = termios()
            guard tcgetattr(inputFD, &value) == 0 else { try throwPOSIX("tcgetattr") }
            original = value
        }

        func enable() throws {
            var raw = original
            Darwin.cfmakeraw(&raw)
            raw.c_cc.16 = 1 // VMIN
            raw.c_cc.17 = 0 // VTIME
            guard tcsetattr(inputFD, TCSANOW, &raw) == 0 else { try throwPOSIX("tcsetattr") }
        }

        func restore() {
            var value = original
            _ = tcsetattr(inputFD, TCSANOW, &value)
        }
    }
}
