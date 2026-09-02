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
        let quit = Task.detached { () -> Bool in
            guard await session.waitForTranscript("Restore source") else {
                return false
            }
            do {
                try session.write("\u{1B}")
                guard await session.waitForTranscript("pomme VM dashboard", occurrences: 2) else {
                    return false
                }
                try session.write("q")
                return true
            } catch {
                return false
            }
        }
        try await run(session: session, recorder: recorder)
        #expect(await quit.value)

        #expect(await recorder.requests.isEmpty)
        #expect(session.readTranscript().contains("Restore source"))
        #expect(session.termiosMatchesOriginal)
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
            Darwin.close(master)
            Darwin.close(slave)
            try throwPOSIX("fcntl")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: drainQueue)
        source.setEventHandler { [weak self] in self?.drainAvailableBytes() }
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
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(master, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            try throwPOSIX("write")
        }
    }

    func readTranscript() -> String {
        drainQueue.sync { drainAvailableBytes() }
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return String(decoding: transcriptBytes, as: UTF8.self)
    }

    func waitForTranscript(_ text: String, occurrences: Int = 1) async -> Bool {
        for _ in 0..<200 {
            let transcript = readTranscript()
            if transcript.components(separatedBy: text).count - 1 >= occurrences {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
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

    func close() {
        drainSource?.cancel()
        drainSource = nil
        if master >= 0 {
            Darwin.close(master)
            master = -1
        }
        if slave >= 0 {
            Darwin.close(slave)
            slave = -1
        }
    }

    deinit {
        close()
    }
}
