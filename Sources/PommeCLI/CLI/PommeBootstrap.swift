import ArgumentParser
import Foundation
import os

/// Process entrypoint for the public Pomme command and the one guest-side
/// daemon invocation used by a provisioned VM. The daemon grammar is kept
/// separate from ArgumentParser so a guest launchd job cannot accidentally
/// enter the host command tree.
enum PommeBootstrap {
    static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async {
        // Internal entry points name only their flag; their arguments can
        // carry guest paths and commands.
        if let flag = arguments.first, flag.hasPrefix("--pomme-") {
            PommeUnifiedLog.helper.info(
                "Internal entry \(flag, privacy: .public) pid=\(getpid(), privacy: .public)"
            )
        }
        if ProcessInfo.processInfo.environment["POMME_INTERNAL_ASKPASS"] == "1" {
            Foundation.exit(PommeBootstrapAskpass.run())
        }
        if arguments.first == PommeNormalBootstrapInstaller.flag {
            Foundation.exit(PommeNormalBootstrapInstaller.run(arguments: arguments))
        }
        if arguments.first == PommeAgentUpdateApply.flag {
            Foundation.exit(PommeAgentUpdateApply.run(arguments: arguments))
        }
        if arguments.first == "--pomme-agent" {
            let exitCode = PommeAgentDaemon.run(arguments: arguments)
            Foundation.exit(exitCode)
        }

        if arguments.first == "--pomme-exec-helper" {
            Foundation.exit(PommeProcess.runIdentityHelper(arguments: arguments))
        }

        if arguments.first == "--pomme-mdm-staging-helper" {
            Foundation.exit(PommeMDMStagingHelper.run(arguments: arguments))
        }

        if arguments.first == PommeMDMPrivateHelper.flag {
            let exitCode = PommeMDMPrivateHelper.run(arguments: arguments)
            Foundation.exit(exitCode)
        }

        if arguments.first == PommeUpdateNotifier.flag {
            Foundation.exit(await PommeUpdateNotifier.runBackgroundCheck())
        }

        if arguments.first == "--pomme-runtime" {
            let exitCode = await PommeCore.runInternalHelper(arguments: arguments)
            Foundation.exit(exitCode)
        }

        PommeApplication.installDefaultProvisioningServices()
        PommeApplication.installRecoveryIntegrationFactory(
            PommeCore.makeLiveRecoveryIntegrationFactory()
        )

        if arguments == [errorCatalogFlag] {
            Foundation.exit(printErrorCatalog())
        }

        if arguments == ["--version"] {
            print(PommeBuildInfo.current.versionLine)
            Foundation.exit(0)
        }

        let publicArguments = PommeCore.normalizedPublicArguments(arguments)
        PommeErrorOutput.setInvocation(publicArguments)
        await run(publicArguments)
    }

    /// Prints the error catalog as JSON for the documentation generator.
    /// It isn't part of the public command tree.
    static let errorCatalogFlag = "--pomme-error-catalog"

    static func printErrorCatalog() -> Int32 {
        guard let data = try? JSONSerialization.data(
            withJSONObject: PommeErrorCatalog.jsonObject(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return 1 }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return 0
    }

    /// Parses and runs the public command tree. ArgumentParser's `main`
    /// attaches usage only to errors raised while parsing; a `ValidationError`
    /// thrown from `run()` is reported here with the executing subcommand's
    /// usage, matching the parse-time shape.
    static func run(_ arguments: [String]) async {
        var command: ParsableCommand
        do {
            command = try PommeCLI.parseAsRoot(arguments)
        } catch {
            // ArgumentParser's text can echo a mistyped secret, so only the
            // exit code is recorded.
            PommeUnifiedLog.cli.notice(
                "Command line rejected exit=\(PommeCLI.exitCode(for: error).rawValue, privacy: .public)"
            )
            PommeCLI.exit(withError: error)
        }
        let commandName = commandPath(for: type(of: command)).joined(separator: " ")
        let startedAt = Date()
        logCommandStart(commandName, arguments: arguments)

        let options = (command as? CLIProgressCommand)?.progressOptions
        let session = PommeProgressSession(
            mode: options?.progress ?? .off,
            structuredOutput: options?.json == true || options?.format == .json || options?.format == .jsonl,
            debug: options?.debug ?? false
        )
        do {
            try await PommeProgressContext.$sink.withValue(options == nil ? nil : session.sink) {
                try await PommeProgressContext.$debugEnabled.withValue(options?.debug ?? false) {
                    if options?.debug == true {
                        session.sink.diagnostic("Debug logging enabled for public command \(type(of: command)._commandName).")
                    }
                    if var asyncCommand = command as? AsyncParsableCommand {
                        try await asyncCommand.run()
                    } else {
                        try command.run()
                    }
                }
            }
            session.finish()
            logCommandEnd(commandName, exitCode: 0, startedAt: startedAt)
            PommeUpdateNotifier.afterCommand(command)
        } catch let error as ValidationError {
            session.finish()
            // A validation message can quote an argument, so only the
            // command and exit code are recorded.
            logCommandEnd(commandName, exitCode: ExitCode.validationFailure.rawValue, startedAt: startedAt)
            let text = validationFailureText(error, command: type(of: command))
            FileHandle.standardError.write(Data((text + "\n").utf8))
            Foundation.exit(ExitCode.validationFailure.rawValue)
        } catch {
            session.finish()
            // An exit code means the command already printed its result, and
            // a clean exit prints help. ArgumentParser handles both, and its
            // own errors too, such as the internal one that `help` throws.
            if error is ExitCode || error is CleanExit
                || String(reflecting: type(of: error)).hasPrefix("ArgumentParser.") {
                logCommandEnd(commandName, exitCode: PommeCLI.exitCode(for: error).rawValue, startedAt: startedAt)
                PommeCLI.exit(withError: error)
            }
            PommeUnifiedLog.error(error, context: commandName)
            let structured: CLIOutputFormat? = options.flatMap { try? $0.resolvedFormat() }
            PommeErrorOutput.reportThrown(error, structuredFormat: structured)
            logCommandEnd(commandName, exitCode: ExitCode.failure.rawValue, startedAt: startedAt)
            Foundation.exit(ExitCode.failure.rawValue)
        }
    }

    /// Records the command, its redacted arguments (which name the VM), and
    /// the build in the unified log.
    static func logCommandStart(_ commandName: String, arguments: [String]) {
        let build = PommeBuildInfo.current
        let redacted = PommeErrorOutput.redactedArguments(arguments)
            .redactingLogOnlyValues()
            .joined(separator: " ")
        PommeUnifiedLog.cli.notice("""
            Command start: \(commandName, privacy: .public) \
            arguments=[\(PommeUnifiedLog.scrubbed(redacted), privacy: .public)] \
            version=\(build.version, privacy: .public) commit=\(build.commit, privacy: .public) \
            pid=\(getpid(), privacy: .public)
            """)
    }

    static func logCommandEnd(_ commandName: String, exitCode: Int32, startedAt: Date) {
        let seconds = Date().timeIntervalSince(startedAt)
        PommeUnifiedLog.cli.notice("""
            Command end: \(commandName, privacy: .public) exit=\(exitCode, privacy: .public) \
            duration=\(seconds, format: .fixed(precision: 3), privacy: .public)s
            """)
    }

    /// Renders a validation failure exactly as ArgumentParser renders one
    /// raised during parsing: the message, the subcommand usage, and the help
    /// pointer.
    static func validationFailureText(_ error: ValidationError, command: ParsableCommand.Type) -> String {
        var lines: [String] = []
        if !error.message.isEmpty {
            lines.append("Error: \(error.message)")
        }
        let usage = PommeCLI.usageString(for: command)
        if !usage.isEmpty {
            lines.append("Usage: " + usage.replacingOccurrences(of: "\n", with: "\n       "))
        }
        lines.append("  See '\(commandPath(for: command).joined(separator: " ")) --help' for more information.")
        return lines.joined(separator: "\n")
    }

    /// Returns the command words from the root to `command`, such as
    /// `["pomme", "config", "init"]`.
    static func commandPath(for command: ParsableCommand.Type) -> [String] {
        func search(_ node: ParsableCommand.Type, path: [String]) -> [String]? {
            let path = path + [node._commandName]
            if node == command {
                return path
            }
            for child in node.configuration.subcommands {
                if let found = search(child, path: path) {
                    return found
                }
            }
            return nil
        }
        return search(PommeCLI.self, path: []) ?? [PommeCLI._commandName]
    }
}

private extension Array where Element == String {
    /// Blanks the guest user name in a command line that's already redacted
    /// for output, because the unified log keeps it longer.
    func redactingLogOnlyValues() -> [String] {
        let flags: Set<String> = ["--user"]
        var result: [String] = []
        var redactNext = false
        for argument in self {
            if argument == "--" { return result + self[(result.count)...] }
            if redactNext {
                result.append("<redacted>")
                redactNext = false
            } else if let equals = argument.firstIndex(of: "="), flags.contains(String(argument[..<equals])) {
                result.append(String(argument[..<equals]) + "=<redacted>")
            } else {
                result.append(argument)
                redactNext = flags.contains(argument)
            }
        }
        return result
    }
}
