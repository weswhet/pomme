import ArgumentParser
import Darwin
import Foundation

/// Output representations supported by public CLI commands.
enum CLIOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case table
    case json
    case jsonl
}

/// Common presentation and diagnostic options.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Print JSON output. Equivalent to --format json.")
    var json = false

    @Option(name: .customLong("format"), help: "Output format: table, json, or jsonl.")
    var format: CLIOutputFormat?

    @Flag(
        name: .customLong("debug"),
        help: "Print verbose diagnostics and retain Recovery navigation screenshots in a private temporary directory."
    )
    var debug = false

    @Option(name: .customLong("progress"), help: "Progress display: auto, plain, or off.")
    var progress: CLIProgressMode = .auto

    /// Returns the selected output format after validating shorthand combinations.
    func resolvedFormat() throws -> CLIOutputFormat {
        if json, let format, format != .json {
            throw ValidationError("--json conflicts with --format \(format.rawValue).")
        }
        return json ? .json : (format ?? .table)
    }
}

/// Invocation-scoped diagnostics for automatic Recovery navigation.  This is
/// deliberately task-local: Recovery workflows launch nested tasks, while
/// parallel creates must get independent recorder instances rather than share
/// an invocation-global mutable object.
enum PommeRecoveryDebugContext {
    @TaskLocal static var screenshotsEnabled = false
}

/// Internal helper metadata is useful to a person running `--debug`, but is
/// not part of Pomme's public JSON contract.  Consume it at the CLI boundary
/// before table, JSON, or JSONL rendering.
enum PommeRecoveryDebugScreenshotOutput {
    static let directoryKey = "recoveryDebugScreenshotDirectory"
    static let filesKey = "recoveryDebugScreenshotFiles"
    static let warningsKey = "recoveryDebugScreenshotWarnings"

    static func renderAndRemove(from payload: inout [String: Any]) {
        let directory = payload.removeValue(forKey: directoryKey) as? String
        let files = payload.removeValue(forKey: filesKey) as? [String] ?? []
        let warnings = payload.removeValue(forKey: warningsKey) as? [String] ?? []
        guard directory?.isEmpty == false || !warnings.isEmpty else { return }
        var lines: [String] = []
        if let directory, !directory.isEmpty {
            lines.append("Recovery debug screenshots: \(directory)")
            lines.append(contentsOf: files.map { "  \($0)" })
        }
        lines.append(contentsOf: warnings.map { "Warning: Recovery debug screenshot \($0)." })
        PommeProgressContext.sink?.suspend()
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

/// Common time limit used by guest operations.
struct TimeoutOptions: ParsableArguments {
    @Option(name: .customLong("timeout"), parsing: .unconditional, help: "Time limit in seconds.")
    var timeout: Double?

    var isExplicitlySet: Bool { timeout != nil }

    /// A negative value is captured rather than mistaken for a missing one,
    /// so the range check runs at parse time and names the real problem.
    mutating func validate() throws {
        if timeout != nil { _ = try value() }
    }

    /// Validates and returns the configured timeout.
    func value() throws -> TimeInterval {
        let value = timeout ?? Constants.defaultGuestCommandTimeout
        guard value.isFinite, value > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }
        return value
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
        PommeProgressContext.sink?.suspend()
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
                let payload = resultPayload(result)
                let objects = result.jsonlCollectionKeyPath.map { jsonlLines(payload: payload, keyPath: $0) } ?? [payload]
                for object in objects {
                    print(try jsonLine(object), terminator: "")
                }
            }
        case .table:
            for (index, result) in results.enumerated() {
                let label = results.count > 1 ? (result.vmName ?? "unknown") : nil
                let rendering = tableRendering(for: result, label: label)
                if let label, !rendering.isFailureText {
                    print("\(label):")
                }
                switch rendering {
                case .text(let descriptor, let text):
                    if descriptor == STDOUT_FILENO {
                        print(text)
                    } else {
                        try writeBytes(Data((text + "\n").utf8), to: descriptor)
                    }
                case .fileBytes:
                    try writeBytes(fileOutput(result.payload), to: STDOUT_FILENO)
                case .jobFrames:
                    for output in try backgroundJobOutput(result.payload) {
                        try writeBytes(output.data, to: output.descriptor)
                    }
                    if let metadata = result.payload["result"] as? [String: Any] {
                        for channel in ["stdout", "stderr"] where metadata[channel + "Truncated"] as? Bool == true {
                            try writeBytes(Data("Earlier \(channel) output was discarded; showing the last 64 KiB.\n".utf8), to: STDERR_FILENO)
                        }
                    }
                    try writeFailure(result.payload)
                case .foregroundFrames:
                    for output in try foregroundOutput(result.payload) {
                        try writeBytes(output.data, to: output.descriptor)
                    }
                    try writeFailure(result.payload)
                case .terminalBytes:
                    try writeBytes(terminalOutput(result.payload), to: STDOUT_FILENO)
                case .attachment:
                    break
                }
                if results.count > 1, index != results.indices.last {
                    print("")
                }
            }
        }

        if let failed = results.first(where: { !$0.ok || $0.hostExitCode != 0 }) {
            throw ExitCode(failed.hostExitCode)
        }
    }

    /// How the table form presents one result: exact bytes for command
    /// output, or presentation text on the descriptor that matches its
    /// outcome.
    enum TableRendering: Equatable {
        case text(descriptor: Int32, text: String)
        case fileBytes
        case jobFrames
        case foregroundFrames
        case terminalBytes
        case attachment

        var isFailureText: Bool {
            if case .text(let descriptor, _) = self { return descriptor == STDERR_FILENO }
            return false
        }
    }

    /// Byte-carrying results keep their existing routes. Everything else is
    /// text, and a failed result reaches stderr with the same `Error:` prefix
    /// ArgumentParser gives a thrown error, so a failure reads the same whether
    /// the CLI threw it or the helper returned it.
    static func tableRendering(for result: PommeOperationResult, label: String? = nil) -> TableRendering {
        let operation = result.payload["operation"] as? String ?? ""
        if result.ok, operation == "file.read" {
            return .fileBytes
        }
        if ["process.output", "process.wait"].contains(operation), result.payload["streamFrames"] is [[String: Any]] {
            return .jobFrames
        }
        if result.payload["foreground"] as? Bool == true {
            return .foregroundFrames
        }
        if result.ok, operation == "terminal.logs" {
            return .terminalBytes
        }
        if result.payload["terminalAttachment"] as? Bool == true {
            return .attachment
        }
        if result.ok {
            return .text(descriptor: STDOUT_FILENO, text: result.text)
        }
        let message = result.text.isEmpty ? "The operation failed." : result.text
        return .text(descriptor: STDERR_FILENO, text: "Error: " + (label.map { "\($0): " } ?? "") + message)
    }

    private static func writeFailure(_ payload: [String: Any]) throws {
        if let error = payload["error"] as? String {
            try writeBytes(Data(("Error: " + error + "\n").utf8), to: STDERR_FILENO)
        }
    }

    /// Cat emits exact bytes, including binary data and files without a newline.
    static func fileOutput(_ payload: [String: Any]) throws -> Data {
        guard let encoded = payload["dataBase64"] as? String,
              let data = Data(base64Encoded: encoded),
              data.count <= PommeAgentProtocol.maximumFileChunkBytes else {
            throw RunnerError.invalidControlResponse("Invalid file output.")
        }
        return data
    }

    /// Durable terminal logs use the stream-sized control-channel limit rather
    /// than the smaller file-transfer chunk limit.
    static func terminalOutput(_ payload: [String: Any]) throws -> Data {
        guard let encoded = payload["dataBase64"] as? String,
              let data = Data(base64Encoded: encoded),
              data.count <= PommeControlProtocol.maximumStreamChunkBytes else {
            throw RunnerError.invalidControlResponse("Invalid terminal output.")
        }
        return data
    }

    /// Keep command bytes separate from presentation text: no replacement
    /// decoding, combined stderr, extra newline, or synthetic "OK" output.
    static func foregroundOutput(_ payload: [String: Any]) throws -> [(descriptor: Int32, data: Data)] {
        guard let frames = payload["streamFrames"] as? [[String: Any]] else {
            throw RunnerError.invalidControlResponse("Missing foreground output frames.")
        }
        return try frames.map { frame in
            guard let kind = frame["stream"] as? String,
                  kind == "stdout" || kind == "stderr",
                  let encoded = frame["dataBase64"] as? String,
                  let data = Data(base64Encoded: encoded),
                  data.count <= PommeControlProtocol.maximumStreamChunkBytes
            else { throw RunnerError.invalidControlResponse("Invalid foreground output frame.") }
            return (kind == "stdout" ? STDOUT_FILENO : STDERR_FILENO, data)
        }
    }

    /// Retained job logs include an exit frame after the two byte streams.
    /// Keep binary stdout/stderr exact rather than printing a synthetic OK.
    static func backgroundJobOutput(_ payload: [String: Any]) throws -> [(descriptor: Int32, data: Data)] {
        guard let frames = payload["streamFrames"] as? [[String: Any]] else {
            throw RunnerError.invalidControlResponse("Missing background job output frames.")
        }
        let bytes = try frames.filter { frame in
            guard let stream = frame["stream"] as? String,
                  ["stdout", "stderr", "exit"].contains(stream) else {
                throw RunnerError.invalidControlResponse("Invalid background job output frame.")
            }
            return stream != "exit"
        }
        return try foregroundOutput(["streamFrames": bytes])
    }

    private static func writeBytes(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { try throwPOSIX("foreground output") }
            }
        }
    }

    /// Writes an arbitrary payload using the selected representation. For a
    /// list-shaped payload, `jsonlCollection` names the array whose elements
    /// JSONL prints one per line; `jsonlElements` supplies those objects
    /// directly when they are not a single array in the payload.
    static func write(
        payload: [String: Any],
        text: String,
        options: GlobalOptions,
        jsonlCollection: String? = nil,
        jsonlElements: [[String: Any]]? = nil
    ) throws {
        PommeProgressContext.sink?.suspend()
        switch try options.resolvedFormat() {
        case .json:
            print(try jsonLine(payload), terminator: "")
        case .jsonl:
            let objects = payload["ok"] as? Bool == false
                ? [payload]
                : jsonlElements ?? jsonlCollection.map { jsonlLines(payload: payload, keyPath: [$0]) } ?? [payload]
            for object in objects {
                print(try jsonLine(object), terminator: "")
            }
        case .table:
            if payload["ok"] as? Bool == false {
                try writeBytes(Data(("Error: " + text + "\n").utf8), to: STDERR_FILENO)
            } else {
                print(text)
            }
        }
        if payload["ok"] as? Bool == false {
            throw ExitCode(PommeCore.hostExitCode(from: payload, default: 1))
        }
    }

    /// The objects JSONL prints for a list-shaped payload: one per element of
    /// the array at `keyPath`, none for an empty array, or the whole payload
    /// when the path does not lead to an array of objects (a failure envelope,
    /// for example).
    static func jsonlLines(payload: [String: Any], keyPath: [String]) -> [[String: Any]] {
        var node: Any = payload
        for key in keyPath {
            guard let object = node as? [String: Any], let next = object[key] else {
                return [payload]
            }
            node = next
        }
        return node as? [[String: Any]] ?? [payload]
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

        let progress = PommeProgressContext.sink
        progress?.pause()
        defer { progress?.resume() }
        let quotedNames = names.map { "'\($0)'" }.joined(separator: ", ")
        fputs("Delete \(quotedNames)? This removes the VM data and cannot be undone. [y/N] ", stderr)
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes"
        else {
            throw CleanExit.message("Deletion cancelled.")
        }
    }
}

/// Reads presentation settings from the parsed command, never from guest arguments.
protocol CLIProgressCommand {
    var progressOptions: GlobalOptions { get }
}

extension AgentStatusCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension AgentRepairCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension AgentUpdateCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ConfigValidateCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ConfigRenderCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension IPSWListCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension IPSWDownloadCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ExecCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ShellCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension JobsListCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension JobsInspectCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension JobsLogsCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension JobsWaitCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension JobsKillCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension CopyCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension CatCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension CreateCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ListCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension StartCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension StopCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension RestartCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension PauseCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ResumeCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension DeleteCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension StatusCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension InspectCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension MDMCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension RemoteLoginStatusCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension RemoteLoginEnableCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension RemoteLoginDisableCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ScreenSharingStatusCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ScreenSharingEnableCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension ScreenSharingDisableCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SnapshotCreateCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SnapshotListCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SnapshotRestoreCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SnapshotDeleteCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension TemplateCreateCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension TemplateListCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension TemplateDeleteCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SessionsListCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SessionsInspectCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SessionsAttachCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SessionsLogsCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SessionsTerminateCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension SessionsDeleteCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension UITypeCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension UIKeyCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension UIKeySequenceCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension UIKeysCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension UIClickCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension UIScreenshotCommand: CLIProgressCommand { var progressOptions: GlobalOptions { format } }
extension ToolsCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
extension AgentHelpCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }
