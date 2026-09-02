import ArgumentParser
import Darwin
import Foundation

/// Output representations supported by public CLI commands.
enum CLIOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case table
    case json
    case jsonl
    case raw

}

/// Common presentation and diagnostic options.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Print JSON output. Equivalent to --format json.")
    var json = false

    @Option(name: .customLong("format"), help: "Output format: table, json, jsonl, or raw.")
    var format: CLIOutputFormat?

    @Flag(name: .customLong("debug"), help: "Print verbose diagnostic logging.")
    var debug = false

    /// Returns the selected output format after validating shorthand combinations.
    func resolvedFormat() throws -> CLIOutputFormat {
        if json, let format, format != .json {
            throw ValidationError("--json conflicts with --format \(format.rawValue).")
        }
        return json ? .json : (format ?? .table)
    }
}

/// Common time limit used by guest operations.
struct TimeoutOptions: ParsableArguments {
    @Option(name: .customLong("timeout"), help: "Time limit in seconds.")
    var timeout: Double = Constants.defaultGuestCommandTimeout

    /// Validates and returns the configured timeout.
    func value() throws -> TimeInterval {
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }
        return timeout
    }
}

/// Resolves explicit VM arguments or the configured environment default.
enum VMTargetResolver {
    /// Returns validated VM names, falling back to `POMME_VM_NAME` when no names were supplied.
    static func names(from arguments: [String], allowMultiple: Bool = true) throws -> [String] {
        let candidates: [String]
        if arguments.isEmpty {
            guard let configured = ProcessInfo.processInfo.environment["POMME_VM_NAME"], !configured.isEmpty else {
                throw ValidationError("Specify a VM name or set POMME_VM_NAME.")
            }
            candidates = [configured]
        } else {
            candidates = arguments
        }

        if !allowMultiple, candidates.count != 1 {
            throw ValidationError("Specify exactly one VM name.")
        }
        return try candidates.map(validateVMName)
    }

    /// Returns the single VM name encoded in a `name:/absolute/path` endpoint.
    static func endpointName(_ endpoint: String) throws -> String? {
        guard let separator = endpoint.firstIndex(of: ":") else {
            return nil
        }
        let name = String(endpoint[..<separator])
        let path = String(endpoint[endpoint.index(after: separator)...])
        guard !name.isEmpty, path.hasPrefix("/") else {
            return nil
        }
        return try validateVMName(name)
    }
}

/// Writes command results in a consistent human-readable or structured form.
enum CLIOutputWriter {
    /// Writes one operation result and throws its exit code when it failed.
    static func write(_ result: PommeOperationResult, options: GlobalOptions) throws {
        try write([result], options: options)
    }

    /// Writes multiple operation results and reports a nonzero aggregate exit status.
    static func write(_ results: [PommeOperationResult], options: GlobalOptions) throws {
        let format = try options.resolvedFormat()
        switch format {
        case .json:
            let payloads = results.map { resultPayload($0) }
            if payloads.count == 1 {
                print(try jsonLine(payloads[0]), terminator: "")
            } else {
                print(try jsonLine([
                    "ok": results.allSatisfy(\.ok),
                    "results": payloads
                ]), terminator: "")
            }
        case .jsonl:
            for result in results {
                print(try jsonLine(resultPayload(result)), terminator: "")
            }
        case .table, .raw:
            for (index, result) in results.enumerated() {
                if results.count > 1 {
                    let name = result.vmName ?? "unknown"
                    print("\(name):")
                }
                print(result.text)
                if results.count > 1, index != results.indices.last {
                    print("")
                }
            }
        }

        if let failed = results.first(where: { !$0.ok || $0.hostExitCode != 0 }) {
            throw ExitCode(failed.hostExitCode)
        }
    }

    /// Writes an arbitrary payload using the selected representation.
    static func write(payload: [String: Any], text: String, options: GlobalOptions) throws {
        switch try options.resolvedFormat() {
        case .json, .jsonl:
            print(try jsonLine(payload), terminator: "")
        case .table, .raw:
            print(text)
        }
        if payload["ok"] as? Bool == false {
            throw ExitCode(PommeCore.hostExitCode(from: payload, default: 1))
        }
    }

    private static func resultPayload(_ result: PommeOperationResult) -> [String: Any] {
        var payload = result.payload
        payload["ok"] = result.ok
        payload["hostExitCode"] = Int(result.hostExitCode)
        if let vmName = result.vmName {
            payload["name"] = vmName
        }
        return payload
    }
}

/// Prompts before irreversible command-line actions.
enum CLIConfirmation {
    /// Requires confirmation for deleting the named VMs unless `force` is true.
    static func confirmDeletion(of names: [String], force: Bool) throws {
        guard !force else {
            return
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw ValidationError("Deletion requires an interactive terminal. Pass --force to delete without prompting.")
        }

        let quotedNames = names.map { "'\($0)'" }.joined(separator: ", ")
        fputs("Delete \(quotedNames)? This removes the VM data and cannot be undone. [y/N] ", stderr)
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes"
        else {
            throw CleanExit.message("Deletion cancelled.")
        }
    }
}
