import ArgumentParser
import Foundation
import Darwin

/// Execution controls shared by `exec` and `shell`.
///
/// These options stay at the CLI boundary; PommeAgentProtocol owns their wire
/// representation and the authenticated guest agent owns execution.
struct GuestExecutionOptions: ParsableArguments {
    @Flag(name: [.customShort("i"), .customLong("stdin")], help: "Read binary standard input from the host.")
    var attachStdin = false

    @Flag(name: .customLong("pty"), help: "Attach the command to a pseudo-terminal.")
    var pty = false

    @Option(name: .customLong("cwd"), help: "Absolute guest working directory.")
    var cwd: String?

    @Option(name: [.customShort("e"), .customLong("env")], help: "Guest environment entry in KEY=VALUE form. Repeatable.")
    var environment: [String] = []

    @Option(name: .customLong("user"), help: "Guest user name.")
    var user: String?

    @Option(name: .customLong("uid"), parsing: .unconditional, help: "Guest numeric user ID.")
    var uid: UInt32?

    @Option(name: .customLong("group"), help: "Guest group name.")
    var group: String?

    @Option(name: .customLong("gid"), parsing: .unconditional, help: "Guest numeric group ID.")
    var gid: UInt32?

    @Option(name: .customLong("guest-stdin"), help: "Absolute guest file used as standard input.")
    var guestStdinPath: String?

    @Option(name: .customLong("guest-stdout"), help: "Absolute guest file used as standard output.")
    var guestStdoutPath: String?

    @Option(name: .customLong("guest-stderr"), help: "Absolute guest file used as standard error.")
    var guestStderrPath: String?

    func validate(detached: Bool, output: GlobalOptions, implicitPTY: Bool = false) throws {
        let usesPTY = pty || implicitPTY
        let guestRedirections = [guestStdinPath, guestStdoutPath, guestStderrPath]

        try validateAbsoluteGuestPath(cwd, option: "--cwd")
        try validateAbsoluteGuestPath(guestStdinPath, option: "--guest-stdin")
        try validateAbsoluteGuestPath(guestStdoutPath, option: "--guest-stdout")
        try validateAbsoluteGuestPath(guestStderrPath, option: "--guest-stderr")

        guard user == nil || uid == nil else {
            throw ValidationError("--user conflicts with --uid.")
        }
        guard group == nil || gid == nil else {
            throw ValidationError("--group conflicts with --gid.")
        }
        guard !attachStdin || guestStdinPath == nil else {
            throw ValidationError("--stdin conflicts with --guest-stdin.")
        }
        guard !attachStdin || !detached else {
            throw ValidationError("--stdin conflicts with --detach.")
        }
        guard !usesPTY || !attachStdin else {
            throw ValidationError("--stdin is implicit for an attached PTY; omit --stdin.")
        }
        guard !usesPTY || guestRedirections.allSatisfy({ $0 == nil }) else {
            throw ValidationError("--pty conflicts with --guest-stdin, --guest-stdout, and --guest-stderr.")
        }
        if usesPTY && !detached {
            switch try output.resolvedFormat() {
            case .json, .jsonl:
                throw ValidationError("--pty conflicts with JSON and JSONL output.")
            case .table:
                break
            }
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                throw ValidationError("--pty requires an interactive terminal for standard input and output.")
            }
        }

        for value in environment {
            let pieces = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty,
                  pieces[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  pieces[0].first?.isNumber != true,
                  !value.contains("\0")
            else {
                throw ValidationError("--env values must use KEY=VALUE with a valid environment key.")
            }
        }
    }

    func apply(to request: GuestCommandRequest, implicitPTY: Bool = false) throws -> GuestCommandRequest {
        let inputData: Data?
        if attachStdin {
            inputData = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            inputData = nil
        }
        var parsedEnvironment: [String: String] = [:]
        for value in environment {
            let separator = value.firstIndex(of: "=")!
            parsedEnvironment[String(value[..<separator])] = String(value[value.index(after: separator)...])
        }
        let requestPath: String = request.path
        let requestArguments: [String] = request.arguments
        let requestTimeout: TimeInterval = request.timeout
        let requestsPTY: Bool = pty || implicitPTY
        let requestCWD: String? = cwd
        let requestUser: String? = user
        let requestUID: UInt32? = uid
        let requestGroup: String? = group
        let requestGID: UInt32? = gid
        let requestGuestStdinPath: String? = guestStdinPath
        let requestGuestStdoutPath: String? = guestStdoutPath
        let requestGuestStderrPath: String? = guestStderrPath
        return GuestCommandRequest(
            path: requestPath,
            arguments: requestArguments,
            timeout: requestTimeout,
            inputData: inputData,
            attachStdin: attachStdin,
            pty: requestsPTY,
            cwd: requestCWD,
            environment: parsedEnvironment,
            user: requestUser,
            uid: requestUID,
            group: requestGroup,
            gid: requestGID,
            guestStdinPath: requestGuestStdinPath,
            guestStdoutPath: requestGuestStdoutPath,
            guestStderrPath: requestGuestStderrPath
        )
    }

    private func validateAbsoluteGuestPath(_ path: String?, option: String) throws {
        guard let path else { return }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ValidationError("\(option) must be an absolute guest path.")
        }
    }
}

/// Executes a program directly in a running VM.
struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Execute a program in a running VM.")

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted before --.")
    var name: String?

    @Flag(name: [.customShort("d"), .customLong("detach")], help: "Create the PTY session without attaching and print its session ID.")
    var detach = false

    @OptionGroup var execution: GuestExecutionOptions
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    // Only tokens after `--` form the command, so the optional name can never
    // swallow the executable when POMME_VM_NAME supplies the VM.
    @Argument(parsing: .postTerminator, help: "Executable and arguments after --.")
    var command: [String] = []

    mutating func validate() throws {
        try execution.validate(detached: detach, output: output)
        if execution.pty, timeout.isExplicitlySet {
            throw ValidationError("--timeout is unavailable for interactive PTY sessions.")
        }
    }

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let directRequest = try GuestCommandRequest.direct(
            command,
            timeout: timeout.value(),
            flagName: "exec"
        )
        let request = try execution.apply(to: directRequest)
        let result: PommeOperationResult
        if request.pty {
            result = try PommeApplication.terminalSessionCreate(
                name: target,
                payload: request.terminalPayload(),
                title: "Exec",
                attach: !detach
            )
        } else {
            result = detach
                ? try PommeEnvironment.live().guest.request(target, .startBackground(request), "Exec")
                : try PommeEnvironment.live().guest.execute(target, request)
        }
        try CLIOutputWriter.write(result, options: output)
    }
}

/// Executes a shell expression in a running VM.
struct ShellCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shell", abstract: "Run a guest shell command or session.")

    @Argument(help: "[VM name] [quoted shell expression]. Uses POMME_VM_NAME when the VM name is omitted.")
    var arguments: [String] = []

    @Flag(name: [.customShort("d"), .customLong("detach")], help: "Detach a bare shell as a durable session; expressions remain background jobs.")
    var detach = false

    @OptionGroup var execution: GuestExecutionOptions
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        let resolution = try resolveTargetAndExpression()
        if resolution.expression != nil && execution.pty {
            throw ValidationError("--pty is available for a bare durable shell; shell expressions remain one-shot /bin/sh -c commands.")
        }
        try execution.validate(detached: detach, output: output, implicitPTY: resolution.expression == nil)
        if resolution.expression == nil, timeout.isExplicitlySet {
            throw ValidationError("--timeout is unavailable for interactive PTY sessions.")
        }
    }

    mutating func run() throws {
        let resolution = try resolveTargetAndExpression()
        let bareShell = resolution.expression == nil
        let directRequest: GuestCommandRequest
        if let expression = resolution.expression {
            directRequest = GuestCommandRequest.shell(expression, timeout: try timeout.value())
        } else {
            directRequest = GuestCommandRequest(path: "/bin/sh", arguments: [], timeout: try timeout.value())
        }
        let request = try execution.apply(to: directRequest, implicitPTY: bareShell)
        let result: PommeOperationResult
        if bareShell {
            result = try PommeApplication.terminalSessionCreate(
                name: resolution.target,
                payload: request.terminalPayload(shell: true),
                title: "Shell",
                attach: !detach
            )
        } else {
            result = detach
                ? try PommeEnvironment.live().guest.request(resolution.target, .startBackground(request), "Shell")
                : try PommeEnvironment.live().guest.execute(resolution.target, request)
        }
        try CLIOutputWriter.write(result, options: output)
    }

    private func resolveTargetAndExpression() throws -> (target: String, expression: String?) {
        let configuredTarget = ProcessInfo.processInfo.environment["POMME_VM_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        switch (configuredTarget, arguments.count) {
        case (_, 2):
            return (try validateVMName(arguments[0]), arguments[1])
        case let (.some(target), 1):
            return (try validateVMName(target), arguments[0])
        case let (.some(target), 0):
            return (try validateVMName(target), nil)
        case (.none, 1):
            return (try validateVMName(arguments[0]), nil)
        default:
            throw ValidationError("Usage: pomme shell [<vm>] ['<expression>'] (or set POMME_VM_NAME).")
        }
    }
}

/// Manages background guest jobs.
struct JobsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs",
        abstract: "Manage background guest jobs.",
        subcommands: [
            JobsListCommand.self,
            JobsInspectCommand.self,
            JobsLogsCommand.self,
            JobsWaitCommand.self,
            JobsKillCommand.self
        ]
    )
}

struct JobsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List background jobs.", aliases: ["ls"])
    @Argument var name: String?
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(target, .jobList, "Jobs"),
            options: output
        )
    }
}

struct JobsInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect a background job.")
    @Argument var name: String?
    @Argument var jobID: String
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(target, .jobStatus(jobID), "Job"),
            options: output
        )
    }
}

struct JobsLogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Print background job output.")
    @Argument var name: String?
    @Argument var jobID: String
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(target, .jobOutput(jobID), "Logs"),
            options: output
        )
    }
}

struct JobsWaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for a background job.")
    @Argument var name: String?
    @Argument var jobID: String
    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(
                target, .jobWait(jobID: jobID, timeout: timeout.value()), "Wait"
            ),
            options: output
        )
    }
}

struct JobsKillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Signal a background job.")
    @Argument var name: String?
    @Argument var jobID: String
    @Option(name: .customLong("signal"), help: "Signal: TERM, KILL, INT, or HUP.")
    var signal = "TERM"
    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(
                target, .jobKill(jobID: jobID, signal: GuestSignal.parse(signal)), "Kill"
            ),
            options: output
        )
    }
}

/// Copies files between the host and a VM through the guest agent.
struct CopyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cp", abstract: "Copy files between the host and a VM.")

    @Argument(help: "Host path or NAME:/absolute/path endpoint.")
    var source: String

    @Argument(help: "Host path or NAME:/absolute/path endpoint. A destination ending in / (or an existing host directory) receives the source's file name.")
    var destination: String

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let sourceName = try VMTargetResolver.endpointName(source)
        let destinationName = try VMTargetResolver.endpointName(destination)
        guard sourceName != nil || destinationName != nil, sourceName == nil || destinationName == nil else {
            throw ValidationError("cp requires exactly one VM endpoint and one host path.")
        }
        let target = sourceName ?? destinationName!
        let request = try CopyRequest.parse(
            source: normalize(source, vmName: target),
            destination: normalize(destination, vmName: target)
        )
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(target, .copy(request), "Copy"),
            options: output
        )
    }

    private func normalize(_ endpoint: String, vmName: String) -> String {
        let prefix = "\(vmName):"
        guard endpoint.hasPrefix(prefix) else {
            return endpoint
        }
        return "guest:" + endpoint.dropFirst(prefix.count)
    }
}

/// Reads a guest file through the file-transfer agent.
struct CatCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cat", abstract: "Read a guest file through the transfer agent.")

    @Argument(help: "NAME:/absolute/path endpoint.")
    var path: String

    @Option(name: .customLong("offset"), parsing: .unconditional, help: "Starting byte offset.")
    var offset = 0

    @Option(name: .customLong("count"), parsing: .unconditional, help: "Maximum bytes to read.")
    var count: Int?

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        guard offset >= 0 else {
            throw ValidationError("--offset must not be negative.")
        }
        if let count, count < 0 {
            throw ValidationError("--count must not be negative.")
        }
    }

    mutating func run() throws {
        guard let target = try VMTargetResolver.endpointName(path) else {
            throw ValidationError("cat requires a NAME:/absolute/path endpoint, for example dev:/tmp/output.txt.")
        }
        let prefix = "\(target):"
        let guestPath = "guest:" + path.dropFirst(prefix.count)
        let request = try CatRequest.parse(path: guestPath, offset: offset, count: count)
        try CLIOutputWriter.write(
            PommeEnvironment.live().guest.request(target, .cat(request), "Cat"),
            options: output
        )
    }
}
