import ArgumentParser
import Foundation
import Testing

/// `shell` opens a durable `/bin/sh` session. A one-shot expression is
/// `exec VM -- /bin/sh -c '...'`, so the VM is the only positional value.
@Suite("Shell command grammar")
struct ShellCommandTests {
    @Test("A detached shell takes an optional VM name")
    func detachedShell() throws {
        let named = try ShellCommand.parse(["dev", "-d", "--user", "alice", "--cwd", "/Users/alice", "-e", "A=1", "--gid", "20"])
        let fromEnvironment = try ShellCommand.parse(["--detach"])

        #expect(named.name == "dev")
        #expect(named.detach)
        #expect(named.process.user == "alice")
        #expect(named.process.cwd == "/Users/alice")
        #expect(named.process.environmentEntries == ["A": "1"])
        #expect(named.process.gid == 20)
        #expect(fromEnvironment.name == nil)
        #expect(fromEnvironment.detach)
    }

    @Test("A shell expression is an unexpected argument")
    func expressionIsRejected() {
        do {
            _ = try ShellCommand.parse(["dev", "ls -l /Users", "-d"])
            Issue.record("shell accepted an expression.")
        } catch {
            #expect(ShellCommand.fullMessage(for: error).contains("Unexpected argument 'ls -l /Users'"))
        }
    }

    @Test("Shell has no --timeout")
    func timeoutIsRejected() {
        do {
            _ = try ShellCommand.parse(["dev", "-d", "--timeout", "5"])
            Issue.record("shell accepted --timeout.")
        } catch {
            #expect(ShellCommand.fullMessage(for: error).contains("Unknown option '--timeout'"))
        }
    }

    @Test("Shell has none of exec's standard-stream flags", arguments: [
        ["-i"], ["--stdin"], ["--pty"],
        ["--guest-stdin", "/tmp/in"], ["--guest-stdout", "/tmp/out"], ["--guest-stderr", "/tmp/err"]
    ])
    func streamFlagsAreUnknown(_ flag: [String]) {
        do {
            _ = try ShellCommand.parse(["dev", "-d"] + flag)
            Issue.record("shell accepted \(flag[0]).")
        } catch {
            #expect(ShellCommand.fullMessage(for: error).contains("Unknown option '\(flag[0])'"))
        }
    }

    @Test("Shell and exec check the process options the same way", arguments: [
        (["--user", "alice", "--uid", "501"], "--user conflicts with --uid."),
        (["--group", "staff", "--gid", "20"], "--group conflicts with --gid."),
        (["--cwd", "relative"], "--cwd must be an absolute guest path."),
        (["-e", "1A=x"], "--env values must use KEY=VALUE with a valid environment key.")
    ])
    func processOptionChecks(arguments: [String], message: String) {
        func failure<Command: ParsableCommand>(_ type: Command.Type, _ arguments: [String]) -> String {
            do {
                _ = try type.parse(arguments)
                return "no error"
            } catch {
                return type.fullMessage(for: error)
            }
        }
        #expect(failure(ShellCommand.self, ["dev", "-d"] + arguments).contains(message))
        #expect(failure(ExecCommand.self, ["dev", "-d"] + arguments + ["--", "/usr/bin/true"]).contains(message))
    }

    @Test("Help describes a session, not an expression")
    func help() {
        let help = ShellCommand.helpMessage(columns: 400)
        #expect(help.contains("Open a durable guest shell session."))
        #expect(help.contains("print its session ID"))
        #expect(!help.lowercased().contains("expression"))
        #expect(!help.contains("--timeout"))
        for flag in ["--stdin", "--pty", "--guest-stdin", "--guest-stdout", "--guest-stderr"] {
            #expect(!help.contains(flag), "\(flag)")
        }
        for flag in ["--cwd", "--env", "--user", "--uid", "--group", "--gid"] {
            #expect(help.contains(flag), "\(flag)")
        }
    }
}
