import Darwin
import Dispatch
import Foundation

final class RecoveryAgentEnsureResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<[String: Any], Error>?

    func store(_ result: Result<[String: Any], Error>) {
        lock.withLock { stored = result }
    }

    func result() -> Result<[String: Any], Error>? {
        lock.withLock { stored }
    }
}

final class RecoveryAgentProgressRenderer {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let vmName: String
    private let debug: Bool
    private let helperLogPath: String
    private let interactive: Bool
    private let write: (String) -> Void
    private let startedAt = Date()
    private let lock = NSLock()
    private var lastStage: RecoveryRuntimeAgentStage?
    private var frameIndex = 0
    private var cursorHidden = false
    private var finished = false
    private var interruptSource: DispatchSourceSignal?

    init(
        vmName: String,
        debug: Bool,
        helperLogPath: String,
        interactive: Bool = isatty(STDERR_FILENO) == 1,
        write: @escaping (String) -> Void = { fputs($0, stderr) }
    ) {
        self.vmName = Self.sanitized(vmName)
        self.debug = debug
        self.helperLogPath = helperLogPath
        self.interactive = interactive
        self.write = write
        if debug {
            write("[recovery-agent] \(self.vmName) helper-log=\(helperLogPath)\n")
        }
        if interactive {
            Darwin.signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: SIGINT,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.finish()
                Darwin.exit(130)
            }
            interruptSource = source
            source.resume()
        }
    }

    func update(stage: RecoveryRuntimeAgentStage) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if interactive {
            if !cursorHidden {
                write("\u{001B}[?25l")
                cursorHidden = true
            }
            let frame = Self.frames[frameIndex % Self.frames.count]
            frameIndex += 1
            write("\r\u{001B}[2K\(frame) \(vmName) \(stage.rawValue) \(elapsed)s")
            fflush(stderr)
        } else if stage != lastStage {
            write("[recovery-agent] \(vmName) stage=\(stage.rawValue) elapsed=\(elapsed)s\n")
        }
        if debug, stage != lastStage {
            write("[recovery-agent] \(vmName) transition=\(stage.rawValue) elapsed=\(elapsed)s\n")
        }
        lastStage = stage
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if interactive {
            write("\r\u{001B}[2K")
        }
        if cursorHidden {
            write("\u{001B}[?25h")
            cursorHidden = false
        }
        let interruptSource = interruptSource
        self.interruptSource = nil
        lock.unlock()
        interruptSource?.cancel()
        if interruptSource != nil {
            Darwin.signal(SIGINT, SIG_DFL)
        }
        fflush(stderr)
    }

    deinit {
        finish()
    }

    private static func sanitized(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        })
    }
}
