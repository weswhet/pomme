import Darwin
import Foundation
import ArgumentParser

/// The local half of a durable terminal attachment.  It owns only the local
/// TTY mode and the control socket; closing either side detaches the client
/// and never sends a guest signal.
struct PommeDurableTerminalBridge {
    let stream: PommeControlSocketStream

    func run() throws -> [String: Any] {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ValidationError("Terminal session attachment requires interactive stdin and stdout.")
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { try throwPOSIX("tcgetattr") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { try throwPOSIX("tcsetattr") }
        defer { var restored = original; _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored) }

        var lastWindowSize: (columns: UInt16, rows: UInt16)?
        try sendResizeIfAvailable(lastWindowSize: &lastWindowSize)
        var lineStart = true
        var pendingTilde = false

        while true {
            if try pumpInput(lineStart: &lineStart, pendingTilde: &pendingTilde) {
                // Closing the local control socket is a detach. It must not
                // send EOF, HUP, or any other signal to the guest process;
                // this covers ~., local stdin closure, and client loss.
                return ["detached": true, "hostExitCode": 0]
            }

            if let event = try stream.receiveEventIfAvailable(timeout: 0.025) {
                switch event {
                case .stream(let frame):
                    try handleOutput(frame)
                case .response(let response):
                    guard response.ok else {
                        let error = response.error ?? .init(code: "control-error", message: "The terminal attachment failed.")
                        throw RunnerError.controlCommandFailed("\(error.code): \(error.message)")
                    }
                    return response.result?.objectValue?.mapValues(\.publicValue)
                        ?? ["hostExitCode": 0]
                }
            }
            try sendResizeIfAvailable(lastWindowSize: &lastWindowSize)
        }
    }

    private func pumpInput(lineStart: inout Bool, pendingTilde: inout Bool) throws -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        var ready: Int32
        repeat { ready = poll(&descriptor, 1, 0) } while ready < 0 && errno == EINTR
        guard ready >= 0 else { try throwPOSIX("poll") }
        guard ready > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR) != 0,
           descriptor.revents & Int16(POLLIN) == 0 {
            return true
        }

        var bytes = [UInt8](repeating: 0, count: PommeControlProtocol.maximumStreamChunkBytes)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 { return true }
        if count < 0 {
            if errno == EINTR { return false }
            try throwPOSIX("read terminal input")
        }

        var outgoing = Data()
        func flush() throws {
            guard !outgoing.isEmpty else { return }
            try stream.send(stream: .stdin, data: outgoing)
            outgoing.removeAll(keepingCapacity: true)
        }
        for byte in bytes.prefix(count) {
            if pendingTilde {
                pendingTilde = false
                if byte == 0x2E {
                    try flush()
                    return true
                }
                if byte == 0x7E {
                    outgoing.append(byte)
                    lineStart = false
                    continue
                }
                outgoing.append(0x7E)
                lineStart = false
            } else if lineStart && byte == 0x7E {
                pendingTilde = true
                continue
            }
            outgoing.append(byte)
            lineStart = byte == 0x0A || byte == 0x0D
        }
        try flush()
        return false
    }

    private func handleOutput(_ frame: PommeControlStreamFrame) throws {
        switch frame.stream {
        case .stdout, .stderr:
            guard let data = try frame.decodedData() else { return }
            try writeAll(data, to: frame.stream == .stdout ? STDOUT_FILENO : STDERR_FILENO)
        case .progress:
            break
        case .stdin, .resize, .signal, .cancellation:
            throw RunnerError.invalidControlResponse("Unexpected terminal attachment output stream.")
        }
    }

    private func sendResizeIfAvailable(lastWindowSize: inout (columns: UInt16, rows: UInt16)?) throws {
        var size = winsize()
        guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0,
              size.ws_col > 0, size.ws_row > 0
        else { return }
        let current = (columns: size.ws_col, rows: size.ws_row)
        guard lastWindowSize?.columns != current.columns || lastWindowSize?.rows != current.rows else { return }
        try stream.send(
            stream: .resize,
            payload: .object([
                "columns": .integer(Int64(size.ws_col)),
                "rows": .integer(Int64(size.ws_row))
            ])
        )
        lastWindowSize = current
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { try throwPOSIX("write terminal output") }
        }
    }
}
