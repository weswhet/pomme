import ArgumentParser
import Darwin
import Foundation

/// Collects what a maintainer needs to diagnose a failure into one redacted
/// Markdown file. It never uploads anything.
struct BugReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bug-report",
        abstract: "Collect diagnostics for a bug report into one redacted file.",
        discussion: """
        Writes a Markdown file with the Pomme version and install method, this \
        Mac's macOS version, model, memory, and free disk space, and the last \
        error that pomme reported. For a VM, named or taken from the last error, \
        it adds the `pomme inspect` output, the end of the current and previous \
        helper logs, and recent guest logs when the guest agent is connected. \
        Pomme replaces your home directory with ~ and withholds lines that \
        mention a token, password, or secret. Review the file before you share \
        it. Pomme never uploads it.
        """
    )

    @Argument(help: "VM name. Defaults to the VM in the last error, if any.")
    var name: String?

    @Option(name: .customLong("output"), help: "File to write. Defaults to pomme-bug-report-DATE.md in the current directory.")
    var outputPath: String?

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let now = Date()
        let destination = try PommeBugReport.destination(outputPath, now: now)
        let lastError = PommeErrorOutput.readLastError()
        let vmName = try name.map(validateVMName) ?? PommeBugReport.vmName(in: lastError)
        PommeProgressContext.sink?.step(vm: vmName, "Collecting diagnostics")
        let text = PommeBugReport.render(PommeBugReport.collect(vmName: vmName, lastError: lastError, now: now))
        try PommeBugReport.write(text, to: destination)
        let path = PommeErrorRedaction.abbreviatingHome(destination.path)
        try CLIOutputWriter.write(
            PommeOperationResult(
                title: "Bug report",
                vmName: nil,
                ok: true,
                hostExitCode: 0,
                text: "Wrote the bug report to \(path).\nReview it before you share it. Pomme doesn't upload it.",
                payload: ["operation": "bug-report", "path": destination.path, "vm": vmName.map { $0 as Any } ?? NSNull()]
            ),
            options: output
        )
    }
}

extension BugReportCommand: CLIProgressCommand { var progressOptions: GlobalOptions { output } }

/// The contents of a bug report, collected and rendered separately so tests
/// can check the redaction without running a VM.
enum PommeBugReport {
    struct Section: Equatable {
        let title: String
        let body: String
        /// Whether the body is shown as a fenced block.
        let preformatted: Bool
    }

    static let helperLogLines = 200
    static let guestLogWindow = "30m"

    // MARK: Destination

    static func destination(_ path: String?, now: Date, directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> URL {
        let url: URL
        if let path {
            guard !path.isEmpty else { throw RunnerError.invalidRequest(field: "--output", reason: "the path is empty.") }
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            url = directory.appendingPathComponent("pomme-bug-report-\(formatter.string(from: now)).md")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RunnerError.invalidRequest(field: "--output", reason: "\(url.path) already exists. Choose another file.")
        }
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { try throwPOSIX("open \(url.path)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    // MARK: Collection

    /// The VM that the last error's command named, if it still exists.
    static func vmName(in lastError: PommeErrorOutput.LastError?, existing: () -> [String] = existingVMNames) -> String? {
        guard let arguments = lastError?.arguments, !arguments.isEmpty else { return nil }
        let names = Set(existing())
        return arguments.first { names.contains($0) }
    }

    static func existingVMNames() -> [String] {
        let entries = (try? PommeApplication.listVMsPayload())?["vms"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["name"] as? String }
    }

    static func collect(vmName: String?, lastError: PommeErrorOutput.LastError?, now: Date) -> [Section] {
        var sections = [pommeSection(), hostSection(), lastErrorSection(lastError)]
        if let vmName {
            sections.append(contentsOf: vmSections(vmName))
        }
        return sections
    }

    static func pommeSection(build: PommeBuildInfo = .current) -> Section {
        let executable = (try? PommeExecutableIdentity.currentExecutableURL()) ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "pomme")
        let method = PommeInstallMethod.detect(buildInfo: build, executable: executable)
        return Section(title: "Pomme", body: [
            "- Version: \(build.version)",
            "- Commit: \(build.commit)",
            "- Distribution: \(build.distribution)",
            "- Install method: \(method.name)",
            "- Executable: \(executable.path)"
        ].joined(separator: "\n"), preformatted: false)
    }

    static func hostSection() -> Section {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        var lines = [
            "- macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(PommeCore.hostOSBuild() ?? "unknown"))",
            "- Model: \(sysctlString("hw.model") ?? "unknown")",
            "- Memory: \(byteCountText(info.physicalMemory))",
            "- CPU cores: \(info.processorCount)"
        ]
        let volumes = [("VM store", try? vmStoreDirectory(create: false)), ("Home", URL(fileURLWithPath: NSHomeDirectory()))]
        for (label, url) in volumes {
            guard let url, let free = freeSpace(at: url) else { continue }
            lines.append("- Free space (\(label)): \(byteCountText(free))")
        }
        return Section(title: "Host", body: lines.joined(separator: "\n"), preformatted: false)
    }

    static func lastErrorSection(_ lastError: PommeErrorOutput.LastError?) -> Section {
        guard let lastError else {
            return Section(title: "Last error", body: "Pomme hasn't recorded an error.", preformatted: false)
        }
        let formatter = ISO8601DateFormatter()
        var lines = [
            "- Code: `\(lastError.code.rawValue)`",
            "- Message: \(lastError.message)",
            "- Command: `pomme \(lastError.arguments.joined(separator: " "))`",
            "- Time: \(formatter.string(from: lastError.time))",
            "- Version: \(lastError.version)"
        ]
        if let hint = lastError.hint { lines.insert("- Hint: \(hint)", at: 2) }
        for cause in lastError.causes {
            lines.append("- Caused by \(cause.domain) \(cause.code): \(cause.description)")
        }
        return Section(title: "Last error", body: lines.joined(separator: "\n"), preformatted: false)
    }

    static func vmSections(_ name: String) -> [Section] {
        var sections: [Section] = []
        let inspect = runSelf(["inspect", name, "--format", "json", "--progress", "off"], timeout: 60)
        sections.append(Section(title: "VM \(name): inspect", body: prettyJSON(inspect.output), preformatted: true))
        if let reference = try? namedVMReference(name, requireExists: true) {
            for (label, url) in [("helper log", reference.bundle.helperLogURL), ("previous helper log", reference.bundle.previousHelperLogURL)] {
                let body = tail(of: url, lines: helperLogLines) ?? "The file doesn't exist."
                sections.append(Section(title: "VM \(name): \(label) (last \(helperLogLines) lines)", body: body, preformatted: true))
            }
        }
        if guestAgentConnected(inspectJSON: inspect.output) {
            let logs = runSelf(["log", name, "--last", guestLogWindow, "--timeout", "60", "--progress", "off"], timeout: 90)
            sections.append(Section(title: "VM \(name): guest log (last \(guestLogWindow))", body: logs.output, preformatted: true))
        } else {
            sections.append(Section(title: "VM \(name): guest log", body: "The guest agent isn't connected, so guest logs weren't collected.", preformatted: false))
        }
        return sections
    }

    /// Puts each JSON value on its own line, so redaction withholds only
    /// the lines that need it instead of the whole document. Text that isn't
    /// JSON is returned unchanged.
    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: pretty, encoding: .utf8)
        else { return text }
        return result
    }

    static func guestAgentConnected(inspectJSON: String) -> Bool {
        guard let data = inspectJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let agent = object["guestAgent"] as? [String: Any]
        return agent?["connection"] as? String == "connected"
    }

    // MARK: Rendering

    /// Renders the sections as Markdown, redacting every section.
    static func render(_ sections: [Section], home: String = NSHomeDirectory()) -> String {
        var lines = [
            "# Pomme bug report",
            "",
            "Review this file before you share it. Pomme replaced your home directory with `~` and withheld lines that mention a token, password, or secret.",
            ""
        ]
        for section in sections {
            lines.append("## \(redact(section.title, home: home))")
            lines.append("")
            let body = redact(section.body.trimmingCharacters(in: .newlines), home: home)
            if section.preformatted {
                let fence = body.contains("```") ? "~~~~" : "```"
                lines.append(fence)
                lines.append(body.isEmpty ? "(empty)" : body)
                lines.append(fence)
            } else {
                lines.append(body)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static let withheldLine = "[Pomme withheld this line because it might contain a secret.]"

    static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            return PommeErrorRedaction.mentionsSecret(line) ? withheldLine : PommeErrorRedaction.abbreviatingHome(line, home: home)
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    static func tail(of url: URL, lines count: Int, maximumBytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    static func freeSpace(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.flatMap { UInt64(exactly: $0) }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Runs this pomme with `arguments` and returns its combined output, or a
    /// note that it failed or timed out.
    static func runSelf(_ arguments: [String], timeout: TimeInterval) -> (status: Int32?, output: String) {
        guard let executable = try? PommeExecutableIdentity.currentExecutableURL() else {
            return (nil, "Pomme couldn't find its own executable.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = PommeBugReportBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (nil, "`pomme \(arguments.joined(separator: " "))` didn't start: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        var output = String(decoding: buffer.data, as: UTF8.self)
        if timedOut { output += "\n[Pomme stopped this command after \(Int(timeout)) seconds.]" }
        return (process.terminationStatus, output)
    }
}

/// Collects a child process's output from the pipe's reader thread.
private final class PommeBugReportBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit = 1024 * 1024

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < limit else { return }
        storage.append(data.prefix(limit - storage.count))
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
