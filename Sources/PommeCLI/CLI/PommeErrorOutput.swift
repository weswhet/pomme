import Darwin
import Foundation
import Synchronization

/// Renders failures the same way wherever they surface: an error thrown by a
/// command, or a failed result that a command prints. Each failure is also
/// recorded as the last error for `pomme bug-report`.
enum PommeErrorOutput {
    /// The public arguments of the running command, set once by the
    /// bootstrap so that a recorded failure can name its command.
    private static let invocation = Mutex<[String]>([])

    static func setInvocation(_ arguments: [String]) {
        invocation.withLock { $0 = arguments }
    }

    // MARK: Text

    /// The lines printed to standard error. The first line is the message
    /// that Pomme has always printed, so scripts that match it keep working.
    static func failureText(message: String, report: PommeErrorReport, label: String? = nil) -> String {
        var lines = ["Error: " + (label.map { "\($0): " } ?? "") + message]
        if let hint = report.hint, !hint.isEmpty, !message.contains(hint) {
            lines.append(hint)
        }
        lines.append(codeLine(for: report.code))
        return lines.joined(separator: "\n")
    }

    static func codeLine(for code: PommeErrorCode) -> String {
        var line = "Error code: \(code.rawValue). For help, see \(PommeErrorCatalog.documentationURL(for: code))"
        if PommeErrorCatalog.entry(for: code)?.reportable ?? true {
            line += ". To report it, run `pomme bug-report`."
        }
        return line
    }

    // MARK: JSON

    /// The JSON object printed for an error that a command threw.
    static func failurePayload(message: String, report: PommeErrorReport, hostExitCode: Int32 = 1) -> [String: Any] {
        var payload = report.publicFields
        payload["ok"] = false
        payload["error"] = message
        payload["hostExitCode"] = Int(hostExitCode)
        return payload
    }

    /// Adds `errorCode`, `hint`, and `causes` to a failed result's payload,
    /// using the helper's report when it sent one, and removes the private
    /// report key.
    static func decorateFailure(_ payload: inout [String: Any]) {
        let report = failureReport(payload)
        payload.removeValue(forKey: PommeErrorReport.payloadKey)
        guard payload["ok"] as? Bool == false else { return }
        for (key, value) in report.publicFields where payload[key] == nil || payload[key] is NSNull {
            payload[key] = value
        }
    }

    /// The report for a failed result: the helper's report when present,
    /// otherwise one built from the result's `error` text.
    static func failureReport(_ payload: [String: Any], fallback: PommeErrorCode = .operationFailed) -> PommeErrorReport {
        if let report = PommeErrorReport(payload: payload[PommeErrorReport.payloadKey]) {
            return report
        }
        let message = (payload["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The operation failed."
        return PommeErrorReport(code: fallback, message: message, hint: PommeErrorCatalog.entry(for: fallback)?.hint)
    }

    // MARK: Thrown errors

    /// Prints a thrown error as text on standard error and, for JSON output,
    /// as a failure object on standard output, then records it.
    static func reportThrown(_ error: any Error, structuredFormat: CLIOutputFormat?) {
        let report = PommeErrorReport(error, redaction: .none)
        let message = error.localizedDescription.isEmpty ? report.message : displayMessage(for: error, report: report)
        FileHandle.standardError.write(Data((failureText(message: message, report: report) + "\n").utf8))
        if let structuredFormat, structuredFormat != .table,
           let line = try? jsonLine(failurePayload(message: message, report: report)) {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        recordLastError(report: report, message: message)
    }

    /// The text that ArgumentParser would have printed for a described error,
    /// or the translated text for a framework error.
    static func displayMessage(for error: any Error, report: PommeErrorReport) -> String {
        if error is any PommeDescribedError { return error.localizedDescription }
        if let localized = error as? LocalizedError, let description = localized.errorDescription,
           SystemErrorDescription(error) == nil {
            return description
        }
        return report.message
    }

    // MARK: Last error

    struct LastError: Codable, Equatable, Sendable {
        let code: PommeErrorCode
        let message: String
        let hint: String?
        let causes: [PommeErrorReport.Cause]
        let arguments: [String]
        let time: Date
        let version: String
    }

    static func lastErrorURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.github.weswhet.pomme", isDirectory: true)
            .appendingPathComponent("last-error.json", isDirectory: false)
    }

    /// Writes the failure, redacted, for `pomme bug-report`. A failure to
    /// write is ignored: the command has already failed for its own reason.
    static func recordLastError(report: PommeErrorReport, message: String, url: URL? = lastErrorURL()) {
        guard let url else { return }
        let redacted = PommeErrorReport(code: report.code, message: message, hint: report.hint, causes: report.causes).redacted()
        let record = LastError(
            code: redacted.code,
            message: redacted.message,
            hint: redacted.hint,
            causes: redacted.causes,
            arguments: redactedArguments(invocation.withLock { $0 }),
            time: Date(),
            version: PommeBuildInfo.current.versionLine
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        _ = chmod(url.path, 0o600)
    }

    static func readLastError(url: URL? = lastErrorURL()) -> LastError? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastError.self, from: data)
    }

    /// Flags whose value can hold a secret or private text.
    private static let sensitiveValueFlags: Set<String> = [
        "--text", "--password", "--token", "--secret", "--env", "-e", "--profile", "--credential"
    ]

    /// Keeps the shape of a command line but not its private values: the
    /// value after a sensitive flag, any argument that mentions a secret, and
    /// a guest command's arguments after `--` (its executable is kept).
    static func redactedArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var redactNext = false
        var afterSeparator = false
        var keptExecutable = false
        for argument in arguments {
            if afterSeparator {
                if !keptExecutable {
                    result.append(PommeErrorRedaction.mentionsSecret(argument) ? "<redacted>" : argument)
                    keptExecutable = true
                } else {
                    result.append("<redacted>")
                }
                continue
            }
            if redactNext {
                result.append("<redacted>")
                redactNext = false
                continue
            }
            if argument == "--" {
                afterSeparator = true
                result.append(argument)
                continue
            }
            if let equals = argument.firstIndex(of: "="), sensitiveValueFlags.contains(String(argument[..<equals])) {
                result.append(String(argument[..<equals]) + "=<redacted>")
                continue
            }
            if sensitiveValueFlags.contains(argument) {
                result.append(argument)
                redactNext = true
                continue
            }
            result.append(PommeErrorRedaction.mentionsSecret(argument) ? "<redacted>" : argument)
        }
        return result
    }
}
