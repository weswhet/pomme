import ArgumentParser
import Foundation
import Testing

/// `shell` opens a durable `/bin/sh` session. A one-shot expression is
/// `exec VM -- /bin/sh -c '...'`, so the VM is the only positional value.
@Suite("Shell command grammar")
struct ShellCommandTests {
    @Test("A detached shell takes an optional VM name")
    func detachedShell() throws {
        let named = try ShellCommand.parse(["dev", "-d", "--user", "alice"])
        let fromEnvironment = try ShellCommand.parse(["--detach"])

        #expect(named.name == "dev")
        #expect(named.detach)
        #expect(named.execution.user == "alice")
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

    @Test("Shell rejects options that conflict with its terminal")
    func terminalConflictsAreRejected() {
        #expect(throws: (any Error).self) {
            _ = try ShellCommand.parse(["dev", "-d", "--guest-stdout", "/tmp/out"])
        }
    }

    @Test("Help describes a session, not an expression")
    func help() {
        let help = ShellCommand.helpMessage(columns: 400)
        #expect(help.contains("Open a durable guest shell session."))
        #expect(help.contains("print its session ID"))
        #expect(!help.lowercased().contains("expression"))
        #expect(!help.contains("--timeout"))
    }
}
