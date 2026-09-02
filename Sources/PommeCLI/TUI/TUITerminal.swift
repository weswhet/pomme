import Foundation
import Darwin

final class TUITerminal {
    private var originalTermios: termios?
    private var alternateScreenActive = false
    private let environment: [String: String]
    private let inputFD: Int32
    private let outputFD: Int32

    init(
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.inputFD = inputFD
        self.outputFD = outputFD
        self.environment = environment
    }

    static var isInteractiveTerminal: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    var supportsANSI: Bool {
        guard isatty(outputFD) == 1 else {
            return false
        }
        let term = environment["TERM"] ?? ""
        return !term.isEmpty && term != "dumb"
    }

    var useColor: Bool {
        supportsANSI && environment["NO_COLOR"] == nil
    }

    var width: Int {
        var size = winsize()
        if ioctl(outputFD, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return 100
    }

    func enableRawMode() throws {
        if originalTermios == nil {
            var current = termios()
            guard tcgetattr(inputFD, &current) == 0 else {
                try throwPOSIX("tcgetattr")
            }
            originalTermios = current
        }

        guard var raw = originalTermios else {
            return
        }
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        raw.c_iflag &= ~tcflag_t(ICRNL | IXON)
        guard tcsetattr(inputFD, TCSANOW, &raw) == 0 else {
            try throwPOSIX("tcsetattr")
        }
    }

    func restore() {
        guard let originalTermios else {
            return
        }
        var restored = originalTermios
        _ = tcsetattr(inputFD, TCSANOW, &restored)
        self.originalTermios = nil
    }

    func enterAlternateScreen() {
        guard supportsANSI, !alternateScreenActive else {
            return
        }
        write("\u{1B}[?1049h")
        alternateScreenActive = true
    }

    func leaveAlternateScreen() {
        guard supportsANSI, alternateScreenActive else {
            return
        }
        write("\u{1B}[?1049l")
        alternateScreenActive = false
    }

    func clear() {
        if supportsANSI {
            write("\u{1B}[2J\u{1B}[H")
        } else {
            write(String(repeating: "\n", count: 30))
        }
    }

    func hideCursor() {
        guard supportsANSI else {
            return
        }
        write("\u{1B}[?25l")
    }

    func showCursor() {
        guard supportsANSI else {
            return
        }
        write("\u{1B}[?25h")
    }

    func write(_ string: String) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else {
                return
            }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(outputFD, address, remaining)
                if count > 0 {
                    remaining -= count
                    address = address.advanced(by: count)
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                return
            }
        }
    }

    func readLine() -> String? {
        var bytes: [UInt8] = []
        while let byte = readByteBlocking() {
            if byte == 10 || byte == 13 {
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
    }

    func readKey() throws -> TUIKey {
        guard let byte = readByteBlocking() else {
            return .escape
        }
        switch byte {
        case 10, 13:
            return .enter
        case 27:
            return readEscapeSequence()
        case 127, 8:
            return .backspace
        default:
            guard let scalar = UnicodeScalar(Int(byte)) else {
                return .escape
            }
            return .character(Character(scalar))
        }
    }

    private func readEscapeSequence() -> TUIKey {
        guard let second = readByteNonBlocking(), second == 91,
              let third = readByteNonBlocking()
        else {
            return .escape
        }

        switch third {
        case 65:
            return .up
        case 66:
            return .down
        default:
            return .escape
        }
    }

    private func readByteBlocking() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(inputFD, &byte, 1)
            if count == 1 {
                return byte
            }
            if count == 0 {
                return nil
            }
            if errno != EINTR {
                return nil
            }
        }
    }

    private func readByteNonBlocking() -> UInt8? {
        let flags = fcntl(inputFD, F_GETFL, 0)
        guard flags >= 0 else {
            return nil
        }
        _ = fcntl(inputFD, F_SETFL, flags | O_NONBLOCK)
        defer {
            _ = fcntl(inputFD, F_SETFL, flags)
        }

        for _ in 0..<20 {
            var byte: UInt8 = 0
            let count = Darwin.read(inputFD, &byte, 1)
            if count == 1 {
                return byte
            }
            if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                return nil
            }
            usleep(1_000)
        }
        return nil
    }
}
