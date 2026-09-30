import ArgumentParser
import Foundation
import Testing

@Suite("Command progress presentation")
struct PommeProgressCommandTests {
    @Test("Waiting commands accept progress controls", arguments: [
        ["create", "dev", "--resume"],
        ["start", "dev"], ["stop", "dev"], ["restart", "dev"],
        ["agent", "repair", "dev"], ["sip", "disable", "dev"],
        ["amfi", "enable", "dev"], ["remote-login", "enable", "dev"],
        ["screen-sharing", "disable", "dev"], ["jobs", "wait", "dev", "job-id"],
        ["log", "dev"], ["ipsw", "download", "latest"],
        ["template", "list"], ["status", "dev"]
    ])
    func modes(_ arguments: [String]) throws {
        for mode in ["auto", "plain", "off"] {
            let parsed = try PommeCLI.parseAsRoot(arguments + ["--progress", mode])
            let settings = try #require(parsed as? CLIProgressCommand).progressOptions
            #expect(settings.progress.rawValue == mode)
        }
    }

    @Test("Guest arguments cannot enable host diagnostics or change progress")
    func guestArguments() throws {
        let command = try ExecCommand.parse([
            "dev", "--progress", "off", "--", "/bin/echo", "--debug", "--progress", "plain"
        ])
        #expect(command.progressOptions.progress == .off)
        #expect(!command.progressOptions.debug)
        #expect(command.command == ["/bin/echo", "--debug", "--progress", "plain"])
    }

    @Test("Log presentation options stay outside the guest payload")
    func logPayload() throws {
        let original = try LogCommand.parse(["dev", "--format", "jsonl"])
        let progress = try LogCommand.parse(["dev", "--format", "jsonl", "--progress", "plain"])
        #expect(NSDictionary(dictionary: try original.payload()) == NSDictionary(dictionary: try progress.payload()))
        #expect(progress.progressOptions.format == .jsonl)
        #expect(progress.progressOptions.progress == .plain)
    }

    @Test("Invalid progress modes fail parsing")
    func invalidMode() {
        #expect(throws: (any Error).self) {
            _ = try StatusCommand.parse(["dev", "--progress", "animated"])
        }
    }

    @Test("Result output stops further progress writes")
    func outputHandoff() throws {
        let captured = ProgressCommandCapture()
        let session = PommeProgressSession(
            mode: .plain, structuredOutput: false, debug: false,
            write: { captured.append($0) }, isTerminal: false, startTimer: false
        )
        defer { session.finish() }
        try PommeProgressContext.$sink.withValue(session.sink) {
            session.sink.step(vm: "dev", "Preparing command")
            let before = captured.value
            #expect(!before.isEmpty)
            // An empty result list exercises the output boundary without writing stdout.
            try CLIOutputWriter.write([], options: GlobalOptions.parse([]))
            session.sink.step(vm: "dev", "Late callback")
            #expect(captured.value == before)
        }
    }

    @Test("TUI has no command progress session")
    func tui() throws {
        let parsed = try PommeCLI.parseAsRoot(["tui"])
        #expect(!(parsed is CLIProgressCommand))
    }
}

private final class ProgressCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; text += value }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
