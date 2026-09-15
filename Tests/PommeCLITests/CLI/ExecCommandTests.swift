import Foundation
import Testing

@Suite("Exec command grammar")
struct ExecCommandTests {
    @Test("The command comes only from tokens after the terminator")
    func commandFollowsTerminator() throws {
        let fromEnvironment = try ExecCommand.parse(["--", "/bin/echo", "hi"])
        #expect(fromEnvironment.name == nil)
        #expect(fromEnvironment.command == ["/bin/echo", "hi"])

        let named = try ExecCommand.parse(["t1", "--", "/bin/echo", "hi"])
        #expect(named.name == "t1")
        #expect(named.command == ["/bin/echo", "hi"])

        let detached = try ExecCommand.parse(["t1", "-d", "--pty", "--", "/bin/sh"])
        #expect(detached.detach && detached.execution.pty)
        #expect(detached.command == ["/bin/sh"])

        let timed = try ExecCommand.parse(["t1", "--timeout", "5", "--", "/bin/echo"])
        #expect(timed.timeout.timeout == 5)
        #expect(timed.command == ["/bin/echo"])
    }

    @Test("Options after the terminator belong to the guest command")
    func optionsAfterTerminatorBelongToCommand() throws {
        let command = try ExecCommand.parse(["t1", "--", "ls", "-la", "--json"])
        #expect(command.command == ["ls", "-la", "--json"])
        #expect(!command.output.json)
    }

    @Test("A command without the terminator is an unexpected argument")
    func commandWithoutTerminatorIsRejected() {
        #expect(throws: Error.self) {
            _ = try ExecCommand.parse(["t1", "/bin/echo", "hi"])
        }
    }
}
