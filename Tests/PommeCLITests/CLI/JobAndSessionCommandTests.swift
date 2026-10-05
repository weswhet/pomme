import ArgumentParser
import Foundation
import Testing

/// Job and session commands take the VM as their only positional value; the
/// job or session they act on is always named with an option.
@Suite("Job and session ID options")
struct JobAndSessionCommandTests {
    private static let sessionID = "00000000-0000-0000-0000-000000000000"

    @Test("Job commands read the job ID from --job")
    func jobOption() throws {
        let inspect = try JobsInspectCommand.parse(["dev", "--job", "3f2a"])
        let logs = try JobsLogsCommand.parse(["--job", "3f2a", "dev"])
        let wait = try JobsWaitCommand.parse(["dev", "--job", "3f2a", "--timeout", "5"])
        let kill = try JobsKillCommand.parse(["--job", "3f2a", "--signal", "KILL"])

        #expect(inspect.name == "dev" && inspect.jobID == "3f2a")
        #expect(logs.name == "dev" && logs.jobID == "3f2a")
        #expect(wait.name == "dev" && wait.jobID == "3f2a" && wait.timeout.timeout == 5)
        #expect(kill.name == nil && kill.jobID == "3f2a" && kill.signal == "KILL")
    }

    @Test("Session commands read the session ID from --session")
    func sessionOption() throws {
        let inspect = try SessionsInspectCommand.parse(["dev", "--session", Self.sessionID])
        let logs = try SessionsLogsCommand.parse(["--session", Self.sessionID, "--follow"])
        let terminate = try SessionsTerminateCommand.parse(["dev", "--session", Self.sessionID, "--force"])
        let delete = try SessionsDeleteCommand.parse(["dev", "--session", Self.sessionID])

        #expect(inspect.name == "dev" && inspect.sessionID == Self.sessionID)
        #expect(logs.name == nil && logs.sessionID == Self.sessionID && logs.follow)
        #expect(terminate.name == "dev" && terminate.sessionID == Self.sessionID && terminate.force)
        #expect(delete.name == "dev" && delete.sessionID == Self.sessionID)
    }

    private static let idCommands: [(command: ParsableCommand.Type, option: String, id: String)] = [
        (JobsInspectCommand.self, "--job", "3f2a"),
        (JobsLogsCommand.self, "--job", "3f2a"),
        (JobsWaitCommand.self, "--job", "3f2a"),
        (JobsKillCommand.self, "--job", "3f2a"),
        (SessionsInspectCommand.self, "--session", sessionID),
        (SessionsAttachCommand.self, "--session", sessionID),
        (SessionsLogsCommand.self, "--session", sessionID),
        (SessionsTerminateCommand.self, "--session", sessionID),
        (SessionsDeleteCommand.self, "--session", sessionID)
    ]

    @Test("The old positional ID form names the missing option", arguments: idCommands)
    func positionalIDNamesOption(command: ParsableCommand.Type, option: String, id: String) {
        do {
            _ = try command.parse(["dev", id])
            Issue.record("\(command._commandName) accepted a positional ID.")
        } catch {
            #expect(command.fullMessage(for: error).contains("Missing expected argument '\(option) <"))
        }
    }

    @Test("A positional ID beside the option is unexpected", arguments: idCommands)
    func positionalIDIsUnexpected(command: ParsableCommand.Type, option: String, id: String) {
        do {
            _ = try command.parse(["dev", id, option, id])
            Issue.record("\(command._commandName) accepted a second positional value.")
        } catch {
            #expect(command.fullMessage(for: error).contains("Unexpected argument '\(id)'"))
        }
    }

    @Test("Help describes the ID options")
    func helpDescribesOptions() {
        let jobs = JobsLogsCommand.helpMessage(columns: 400)
        let sessions = SessionsAttachCommand.helpMessage(columns: 400)

        #expect(jobs.contains("--job <id>"))
        #expect(jobs.contains("as printed by `pomme exec --detach` or `pomme jobs list`"))
        #expect(sessions.contains("--session <id>"))
        #expect(sessions.contains("as printed by `pomme sessions list`"))
    }
}
