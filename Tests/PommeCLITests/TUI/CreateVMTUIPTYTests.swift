import Darwin
import Foundation
import Testing

@Suite("Pomme create VM TUI PTY")
@MainActor
struct CreateVMTUIPTYTests {
    @Test("Create form validates input and forwards the durable creation request")
    func forwardsValidatedCreateRequest() async throws {
        let recorder = CreateActionRecorder()
        let session = try TUITestPTYSession()
        defer { session.close() }

        try session.write("cnot valid!\ncreate-vm\nl60GB\n8GB\nnrq")
        try await run(session: session, recorder: recorder)

        #expect(await recorder.requests == [
            .init(
                name: "create-vm",
                restoreArgs: ["--version", "latest"],
                diskSize: "60GB",
                memory: "8GB",
                startMode: .normal
            )
        ])

        let transcript = session.readTranscript()
        #expect(transcript.contains("Invalid VM name not valid!"))
        #expect(transcript.contains("Create VM complete"))
        #expect(transcript.contains("return and refresh"))
        #expect(session.termiosMatchesOriginal)
    }

    @Test("Create restore-source cancellation does not invoke creation and restores the terminal")
    func cancellationRestoresTerminal() async throws {
        let recorder = CreateActionRecorder()
        let session = try TUITestPTYSession()
        defer { session.close() }

        try session.write("ccancel-vm\n")
        let quit = TUITestPTYDriver(session: session) {
            try session.waitForTranscript("Restore source")
            try session.write("\u{1B}")
            try session.waitForTranscript("pomme VM dashboard", occurrences: 2)
            try session.write("q")
        }
        do { try await run(session: session, recorder: recorder) }
        catch {
            session.abortInput()
            try quit.join()
            throw error
        }
        try quit.join()

        #expect(await recorder.requests.isEmpty)
        #expect(session.readTranscript().contains("Restore source"))
        #expect(session.termiosMatchesOriginal)
    }

    @Test("Driver failure unblocks a live create menu and is reported", arguments: [false, true])
    func driverFailureUnblocksRead(timeout: Bool) async throws {
        let recorder = CreateActionRecorder()
        let session = try TUITestPTYSession()
        defer { session.close() }
        try session.write("ccancel-vm\n")
        let driver = TUITestPTYDriver(session: session) {
            try session.waitForTranscript("Restore source")
            if timeout { try session.waitForTranscript("never-rendered-driver-sentinel", timeout: 0) }
            throw TUITestPTYDriver.Failure.injected
        }
        // Closing the master can make terminal output fail as well as returning
        // EOF to input. The driver error, not that secondary hangup, is asserted.
        do { try await run(session: session, recorder: recorder) }
        catch { session.abortInput() }
        #expect(throws: timeout ? TUITestPTYDriver.Failure.transcriptTimeout("never-rendered-driver-sentinel") : .injected) {
            try driver.join()
        }
        #expect(await recorder.requests.isEmpty)
        #expect(session.readTranscript().contains("Restore source"))
    }

    private func run(session: TUITestPTYSession, recorder: CreateActionRecorder) async throws {
        var tui = PommeTUI(
            initialVMName: nil,
            terminal: session.terminal,
            createAction: { name, restoreArgs, diskSize, memory, startMode in
                try await recorder.perform(
                    name: name,
                    restoreArgs: restoreArgs,
                    diskSize: diskSize,
                    memory: memory,
                    startMode: startMode
                )
            }
        )
        try await tui.run()
    }
}

/// The TUI intentionally performs blocking reads on MainActor. Its input
/// driver must therefore not depend on a spare Swift cooperative worker.
private final class TUITestPTYDriver: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case transcriptTimeout(String), injected, missingResult
    }
    private let finished = TUITestCompletion()
    private let lock = NSLock()
    private var result: Result<Void, any Error>?

    init(session: TUITestPTYSession, operation: @escaping @Sendable () throws -> Void) {
        Thread.detachNewThread { [self] in
            let outcome = Result { try operation() }
            if case .failure = outcome { session.abortInput() }
            lock.withLock { result = outcome }
            finished.complete()
        }
    }

    func join() throws {
        // Transcript waits have finite deadlines, but joining is ownership
        // synchronization, not an absolute OS scheduling deadline. Never let a
        // timeout release descriptors while this thread can still use them.
        finished.wait()
        guard let outcome = lock.withLock({ result }) else { throw Failure.missingResult }
        try outcome.get()
    }
}

private final class TUITestCompletion: @unchecked Sendable {
    private let condition = NSCondition()
    private var completed = false

    func complete() {
        condition.lock()
        completed = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while !completed { condition.wait() }
        condition.unlock()
    }
}

private struct CreateRequest: Equatable, Sendable {
    let name: String
    let restoreArgs: [String]
    let diskSize: String
    let memory: String
    let startMode: StartMode
}

private actor CreateActionRecorder {
    var requests: [CreateRequest] = []

    func perform(
        name: String,
        restoreArgs: [String],
        diskSize: String,
        memory: String,
        startMode: StartMode
    ) throws -> PommeOperationResult {
        requests.append(.init(
            name: name,
            restoreArgs: restoreArgs,
            diskSize: diskSize,
            memory: memory,
            startMode: startMode
        ))
        return PommeOperationResult(
            title: "Create VM",
            vmName: name,
            ok: true,
            hostExitCode: 0,
            text: "Create VM complete",
            payload: ["ok": true, "name": name]
        )
    }
}

final class TUITestPTYSession: @unchecked Sendable {
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private var originalTermios: termios
    private let transcriptLock = NSLock()
    private var transcriptBytes: [UInt8] = []
    private let drainQueue = DispatchQueue(label: "pomme.tests.tui-pty-drain")
    private var drainSource: DispatchSourceRead?
    private let drainCancelled = TUITestCompletion()
    let terminal: TUITerminal

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 32, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            try throwPOSIX("openpty")
        }
        self.master = master
        self.slave = slave

        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else {
            Darwin.close(master)
            Darwin.close(slave)
            try throwPOSIX("tcgetattr")
        }
        originalTermios = attributes
        terminal = TUITerminal(
            inputFD: slave,
            outputFD: slave,
            environment: ["TERM": "xterm-256color", "NO_COLOR": "1"]
        )

        let flags = fcntl(master, F_GETFL, 0)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let failure = errno
            Darwin.close(master)
            Darwin.close(slave)
            self.master = -1
            self.slave = -1
            // Initialization completed before this failure, but no drain
            // source exists to deliver a cancellation callback during deinit.
            drainCancelled.complete()
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: drainQueue)
        source.setEventHandler { [weak self] in self?.drainAvailableBytes() }
        let descriptor = master
        let cancelled = drainCancelled
        source.setCancelHandler { [weak self] in
            // Runs after the source's final drain event on this same queue.
            // No pending handler can read a descriptor reused by another test.
            Darwin.close(descriptor)
            self?.master = -1
            cancelled.complete()
        }
        drainSource = source
        source.resume()
    }

    var termiosMatchesOriginal: Bool {
        var current = termios()
        guard tcgetattr(slave, &current) == 0 else {
            return false
        }
        // The PTY kernel owns PENDIN and sets it when canonical input was queued
        // before the TUI temporarily entered raw mode. It is not a terminal mode
        // selected by Pomme, so compare the stable local-mode bits instead.
        let stableLocalFlags = ~tcflag_t(PENDIN)
        return current.c_iflag == originalTermios.c_iflag
            && current.c_oflag == originalTermios.c_oflag
            && current.c_cflag == originalTermios.c_cflag
            && (current.c_lflag & stableLocalFlags) == (originalTermios.c_lflag & stableLocalFlags)
            && current.c_ispeed == originalTermios.c_ispeed
            && current.c_ospeed == originalTermios.c_ospeed
    }

    func write(_ text: String) throws {
        try drainQueue.sync {
            let bytes = Array(text.utf8)
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(master, buffer.baseAddress, buffer.count)
            }
            guard written == bytes.count else { try throwPOSIX("write") }
        }
    }

    func readTranscript() -> String {
        drainQueue.sync { drainAvailableBytes() }
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return String(decoding: transcriptBytes, as: UTF8.self)
    }

    func waitForTranscript(_ text: String, occurrences: Int = 1, timeout: TimeInterval = 2) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            let transcript = readTranscript()
            if transcript.components(separatedBy: text).count - 1 >= occurrences {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while ContinuousClock.now < deadline
        throw TUITestPTYDriver.Failure.transcriptTimeout(text)
    }

    private func drainAvailableBytes() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                transcriptLock.lock()
                transcriptBytes.append(contentsOf: buffer.prefix(Int(count)))
                transcriptLock.unlock()
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
    }

    func abortInput() {
        drainQueue.sync {
            guard let source = drainSource else { return }
            source.cancel()
            drainSource = nil
        }
        // Every caller joins the same cancellation, including a parent racing
        // the failing input driver. Only the handler owns the master close.
        drainCancelled.wait()
    }

    func close() {
        abortInput()
        if slave >= 0 {
            Darwin.close(slave)
            slave = -1
        }
    }

    deinit {
        close()
    }
}
