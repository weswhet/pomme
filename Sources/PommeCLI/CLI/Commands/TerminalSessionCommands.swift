import ArgumentParser
import Foundation
import Darwin

struct SessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Manage durable guest terminal sessions.",
        subcommands: [
            SessionsListCommand.self,
            SessionsInspectCommand.self,
            SessionsAttachCommand.self,
            SessionsLogsCommand.self,
            SessionsTerminateCommand.self,
            SessionsDeleteCommand.self
        ]
    )
}

struct SessionsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List terminal sessions.", aliases: ["ls"])
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(PommeApplication.terminalSessionList(name: target), options: output)
    }
}

struct SessionsInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect a terminal session.")
    @Argument var name: String?
    @Argument var sessionID: String
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeApplication.terminalSessionInspect(name: target, sessionID: try Self.sessionID(sessionID)),
            options: output
        )
    }
}

struct SessionsAttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attach", abstract: "Attach to a terminal session.")
    @Argument var name: String?
    @Argument var sessionID: String
    @Flag(name: .customLong("takeover"), help: "Replace the current attachment.")
    var takeover = false
    @Flag(name: .customLong("from-start"), help: "Replay the transcript from byte offset zero.")
    var fromStart = false
    @Option(name: .customLong("from-offset"), parsing: .unconditional, help: "Replay from this exact transcript byte offset.")
    var fromOffset: Int64?
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard !(fromStart && fromOffset != nil) else {
            throw ValidationError("--from-start conflicts with --from-offset.")
        }
        if let fromOffset, fromOffset < 0 {
            throw ValidationError("--from-offset must not be negative.")
        }
        switch try output.resolvedFormat() {
        case .json, .jsonl:
            throw ValidationError("Interactive terminal attachment conflicts with JSON and JSONL output.")
        case .table, .raw:
            break
        }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ValidationError("Terminal session attachment requires interactive stdin and stdout.")
        }
    }

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let offset: UInt64? = fromStart ? 0 : fromOffset.map(UInt64.init)
        try CLIOutputWriter.write(
            PommeApplication.terminalSessionAttach(
                name: target,
                sessionID: try Self.sessionID(sessionID),
                offset: offset,
                takeover: takeover
            ),
            options: output
        )
    }
}

struct SessionsLogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Read terminal session transcript bytes.")
    @Argument var name: String?
    @Argument var sessionID: String
    @Option(name: .customLong("from-offset"), parsing: .unconditional, help: "Starting transcript byte offset.")
    var fromOffset: Int64 = 0
    @Flag(name: .customLong("follow"), help: "Continue until the session exits or is lost.")
    var follow = false
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard fromOffset >= 0 else {
            throw ValidationError("--from-offset must not be negative.")
        }
    }

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let id = try Self.sessionID(sessionID)
        var offset = UInt64(fromOffset)
        var snapshotEnd: UInt64?
        while true {
            let result = try PommeApplication.terminalSessionLogs(name: target, sessionID: id, offset: offset)
            try CLIOutputWriter.write(result, options: output)
            offset = Self.uint64(result.payload["nextOffset"]) ?? offset
            if snapshotEnd == nil,
               let session = result.payload["session"] as? [String: Any] {
                snapshotEnd = Self.uint64(session["transcriptOffset"])
            }
            let complete = result.payload["complete"] as? Bool == true
            if follow {
                if complete { return }
            } else if offset >= (snapshotEnd ?? offset) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

struct SessionsTerminateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminate", abstract: "Terminate a terminal session.")
    @Argument var name: String?
    @Argument var sessionID: String
    @Flag(name: .customLong("force"), help: "Send SIGKILL instead of SIGHUP.")
    var force = false
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeApplication.terminalSessionTerminate(name: target, sessionID: try Self.sessionID(sessionID), force: force),
            options: output
        )
    }
}

struct SessionsDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an exited or lost terminal session.")
    @Argument var name: String?
    @Argument var sessionID: String
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeApplication.terminalSessionDelete(name: target, sessionID: try Self.sessionID(sessionID)),
            options: output
        )
    }
}

private extension SessionsInspectCommand {
    static func sessionID(_ value: String) throws -> String { try TerminalSessionCommandSupport.sessionID(value) }
}

private extension SessionsAttachCommand {
    static func sessionID(_ value: String) throws -> String { try TerminalSessionCommandSupport.sessionID(value) }
}

private extension SessionsLogsCommand {
    static func sessionID(_ value: String) throws -> String { try TerminalSessionCommandSupport.sessionID(value) }
    static func uint64(_ value: Any?) -> UInt64? { TerminalSessionCommandSupport.uint64(value) }
}

private extension SessionsTerminateCommand {
    static func sessionID(_ value: String) throws -> String { try TerminalSessionCommandSupport.sessionID(value) }
}

private extension SessionsDeleteCommand {
    static func sessionID(_ value: String) throws -> String { try TerminalSessionCommandSupport.sessionID(value) }
}

enum TerminalSessionCommandSupport {
    static func sessionID(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value.lowercased() else {
            throw ValidationError("Session ID must be a UUID.")
        }
        return id.uuidString.lowercased()
    }

    static func uint64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int64, value >= 0 { return UInt64(value) }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }
}
