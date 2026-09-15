import ArgumentParser
import Foundation
import Testing

@Suite("Numeric option parsing")
struct NumericOptionTests {
    /// Each numeric option captures a value that starts with `-` instead of
    /// reporting it missing, so the range check names the real problem.
    @Test("Negative values reach the range check of every numeric option", arguments: [
        ("ui click", ["dev", "--x", "-1", "--y", "5"], "--x must be a finite display coordinate of zero or more."),
        ("ui click", ["dev", "--x", "5", "--y", "-1"], "--y must be a finite display coordinate of zero or more."),
        ("ipsw list", ["--limit", "-1"], "--limit must be greater than zero."),
        ("start", ["dev", "--timeout", "-5"], "--timeout must be greater than zero."),
        ("restart", ["dev", "--timeout", "-5"], "--timeout must be greater than zero."),
        ("exec", ["dev", "--timeout", "-5", "--", "/bin/true"], "--timeout must be greater than zero."),
        ("cat", ["dev:/tmp/x", "--offset", "-1"], "--offset must not be negative."),
        ("cat", ["dev:/tmp/x", "--count", "-1"], "--count must not be negative."),
        ("sessions logs", ["dev", "00000000-0000-0000-0000-000000000000", "--from-offset", "-1"], "--from-offset must not be negative."),
        ("ui ai settings", ["dev", "Goal", "--max-steps", "-1"], "requires a positive integer"),
        ("ui ai settings", ["dev", "Goal", "--confidence", "-1"], "between 0 and 1"),
        ("ui ai settings", ["dev", "Goal", "--model-timeout", "-1"], "positive number of seconds"),
        ("exec", ["dev", "--uid", "-1", "--", "/bin/true"], "The value '-1' is invalid for '--uid <uid>'"),
    ])
    func negativeValuesReachRangeChecks(command: String, arguments: [String], expected: String) throws {
        let message = try Self.validationMessage(command: command, arguments: arguments)
        #expect(message.contains(expected), "\(command) \(arguments): \(message)")
        #expect(!message.contains("Missing value"), "\(command) \(arguments): \(message)")
    }

    @Test("Positive values still parse for the same options")
    func positiveValuesParse() throws {
        var click = try UIClickCommand.parse(["dev", "--x", "10", "--y", "20"])
        try click.validate()
        #expect(click.x == 10 && click.y == 20)

        var start = try StartCommand.parse(["dev", "--timeout", "30"])
        try start.validate()
        #expect(start.timeout == 30)

        var logs = try SessionsLogsCommand.parse(["dev", "00000000-0000-0000-0000-000000000000", "--from-offset", "12"])
        try logs.validate()
        #expect(logs.fromOffset == 12)
    }

    private static func validationMessage(command: String, arguments: [String]) throws -> String {
        func message<Command: ParsableCommand>(_ type: Command.Type) -> String {
            do {
                var parsed = try type.parse(arguments)
                try parsed.validate()
                return "no error"
            } catch {
                return type.fullMessage(for: error)
            }
        }
        switch command {
        case "ui click": return message(UIClickCommand.self)
        case "ipsw list": return message(IPSWListCommand.self)
        case "start": return message(StartCommand.self)
        case "restart": return message(RestartCommand.self)
        case "exec": return message(ExecCommand.self)
        case "cat": return message(CatCommand.self)
        case "sessions logs": return message(SessionsLogsCommand.self)
        case "ui ai settings": return message(UIAISettingsCommand.self)
        default: throw ValidationError("Unknown command \(command).")
        }
    }
}
