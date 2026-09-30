import Foundation
import Testing

private final class HandoffOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var elapsed = 0.0
    var time: Double {
        get { lock.lock(); defer { lock.unlock() }; return elapsed }
        set { lock.lock(); defer { lock.unlock() }; elapsed = newValue }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
    func write(_ text: String) { lock.lock(); defer { lock.unlock() }; buffer += text }
    func clear() { lock.lock(); defer { lock.unlock() }; buffer = "" }
}

@Suite("Foreground progress handoff")
struct PommeProgressHandoffTests {
    @Test("First guest bytes clear animation and preserve binary output and exit status")
    func binaryHandoff() throws {
        let output = HandoffOutput()
        let session = PommeProgressSession(mode: .auto, structuredOutput: false, debug: false,
            environment: ["LANG": "en_US.UTF-8", "NO_COLOR": "1"], clock: { output.time },
            write: { output.write($0) }, terminalWidth: { 80 }, isTerminal: true,
            startTimer: false, signalCleanup: false)
        session.sink.step(vm: "sample", "Running whoami")
        output.time = 1
        session.tick()
        #expect(output.text.contains("Running whoami"))
        output.clear()
        let id = UUID()
        let stdout = Data([0, 255, 27, 91, 65, 10])
        let stderr = Data([128, 0, 13, 10])
        let events: [PommeControlStreamEvent] = [
            .stream(.init(id: id, sequence: 0, stream: .stdout, data: Data())),
            .stream(.init(id: id, sequence: 1, stream: .stdout, data: stdout)),
            .stream(.init(id: id, sequence: 2, stream: .stderr, data: stderr)),
            .response(.success(id: id, result: .object([
                "ok": .bool(false), "hostExitCode": .integer(7),
                "result": .object(["exited": .bool(true), "exitCode": .integer(7)])
            ])))
        ]
        var index = 0
        let result = try PommeProgressContext.$sink.withValue(session.sink) {
            try PommeCore.collectForegroundResponse {
                if index == 1 { #expect(output.text.isEmpty) }
                if index == 2 {
                    #expect(output.text == "\r\u{001B}[2K")
                    output.clear()
                    session.tick()
                    #expect(output.text.isEmpty)
                }
                defer { index += 1 }
                return events[index]
            }
        }
        let frames = try CLIOutputWriter.foregroundOutput(result)
        #expect(frames.count == 2)
        #expect(frames[0].descriptor == STDOUT_FILENO)
        #expect(frames[0].data == stdout)
        #expect(frames[1].descriptor == STDERR_FILENO)
        #expect(frames[1].data == stderr)
        #expect(PommeCore.hostExitCode(from: result) == 7)
        session.sink.step(vm: "sample", "Hidden after handoff")
        session.tick()
        #expect(output.text.isEmpty)
    }
}
