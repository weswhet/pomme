import Foundation
import os

/// Pomme's unified logging facility. Read it back after a failure with
/// `log show --predicate 'subsystem == "com.github.weswhet.pomme"' --info --debug`.
///
/// Never pass a password, agent token, credential, Keychain item, SSH key, or
/// request body here, not even as private data. Free-form text goes through
/// `scrubbed(_:)`, which redacts secret values that slip through anyway.
///
/// The system keeps `.info` messages only in memory until the same process
/// logs an error, and never stores `.debug` messages without a logging
/// configuration change. Diagnostics that must survive an interrupted run,
/// such as `PommeCore.log`, are notices, and failures are errors.
enum PommeUnifiedLog {
    static let subsystem = "com.github.weswhet.pomme"

    /// Command start and end, diagnostics, warnings, and reported errors.
    static let cli = Logger(subsystem: subsystem, category: "cli")
    /// Creation, provisioning phases, and the provisioning journal.
    static let provisioning = Logger(subsystem: subsystem, category: "provisioning")
    /// Recovery boot and Recovery sessions.
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
    /// `pomme create --experimental-recovery`.
    static let experimentalRecovery = Logger(subsystem: subsystem, category: "experimental-recovery")
    /// VM start, stop, pause, resume, and boot mode.
    static let runtime = Logger(subsystem: subsystem, category: "runtime")
    /// The `--pomme-runtime` and other internal helper processes.
    static let helper = Logger(subsystem: subsystem, category: "helper")
    /// SIP, AMFI, owner preparation, and MDM workflows.
    static let security = Logger(subsystem: subsystem, category: "security")
    /// The host's connection to the guest agent.
    static let guestAgent = Logger(subsystem: subsystem, category: "guest-agent")
    /// Guest agent bootstrap and installation.
    static let bootstrap = Logger(subsystem: subsystem, category: "bootstrap")
    /// External processes that Pomme launches.
    static let process = Logger(subsystem: subsystem, category: "process")
    /// Restore image download and verification.
    static let ipsw = Logger(subsystem: subsystem, category: "ipsw")
    /// Templates and clones.
    static let template = Logger(subsystem: subsystem, category: "template")
    /// `pomme firmware` and boot firmware repair.
    static let firmware = Logger(subsystem: subsystem, category: "firmware")
    /// UI automation in the guest.
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Keys whose values are redacted in `key=value` and `key: value` text.
    private static let secretKeyPattern =
        "password|passwd|passphrase|secret|token|credential|api[_-]?key|authorization|cookie|private[_-]?key|kcpassword"

    private static let pemBlock = try! NSRegularExpression(
        pattern: "-----BEGIN [^-]+-----.*?(-----END [^-]+-----|$)", options: [.dotMatchesLineSeparators])
    private static let bearer = try! NSRegularExpression(
        pattern: "\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}", options: [.caseInsensitive])
    private static let secretAssignment = try! NSRegularExpression(
        pattern: "\\b([A-Za-z_-]*(?:\(secretKeyPattern))[A-Za-z_-]*)(\"?\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;)\\]}]+)",
        options: [.caseInsensitive])
    private static let opaqueRun = try! NSRegularExpression(pattern: "[A-Za-z0-9+=]{32,}")
    /// Values of a secret-named key that say whether it exists, not what it is.
    private static let descriptiveValues: Set<String> = [
        "true", "false", "yes", "no", "nil", "null", "none", "present", "missing", "absent", "available",
        "unavailable", "required", "optional", "set", "unset", "valid", "invalid", "redacted", "<redacted>",
    ]

    /// One line of free-form text that is safe to log as public data. Pomme
    /// never logs a secret on purpose, so this removes secret values rather
    /// than whole messages, keeping the diagnostic: values of secret-named
    /// keys, bearer credentials, and PEM blocks are redacted, and a run of 32
    /// or more letters and digits, such as a digest or an agent credential,
    /// keeps only its first 8. Names with hyphens, dots, or slashes, such as
    /// UUIDs, VM names, and paths, are kept. Newlines are flattened.
    static func scrubbed(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        line = replacing(pemBlock, in: line) { _ in "<redacted key>" }
        line = replacing(bearer, in: line) { match in
            match.split(separator: " ", maxSplits: 1).first.map { "\($0) <redacted>" } ?? "<redacted>"
        }
        line = replacing(secretAssignment, in: line, groups: true) { groups in
            let value = groups[3].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if descriptiveValues.contains(value.lowercased()) || (value.count <= 4 && Int(value) != nil) {
                return groups[0]
            }
            return groups[1] + groups[2] + "<redacted>"
        }
        line = replacing(opaqueRun, in: line) { run in
            guard run.contains(where: \.isNumber), run.contains(where: \.isLetter) else { return run }
            return "\(run.prefix(8))…"
        }
        return String(line.prefix(1024))
    }

    private static func replacing(
        _ expression: NSRegularExpression, in text: String, transform: (String) -> String
    ) -> String {
        replacing(expression, in: text, groups: true) { transform($0[0]) }
    }

    /// Replaces each match, from the last to the first, with what `transform`
    /// returns for its capture groups; group 0 is the whole match.
    private static func replacing(
        _ expression: NSRegularExpression, in text: String, groups: Bool, transform: ([String]) -> String
    ) -> String {
        var result = text
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            let captured = (0..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: result).map { String(result[$0]) } ?? ""
            }
            result.replaceSubrange(whole, with: transform(captured))
        }
        return result
    }

    /// Records a diagnostic message, attributed to a VM when one is named.
    static func message(
        _ text: String,
        vmName: String? = nil,
        level: OSLogType = .info,
        logger: Logger = cli
    ) {
        let line = scrubbed(text)
        if let vmName {
            logger.log(level: level, "[\(vmName, privacy: .public)] \(line, privacy: .public)")
        } else {
            logger.log(level: level, "\(line, privacy: .public)")
        }
    }

    /// Records a major milestone, such as a progress step, as a notice.
    static func notice(_ text: String, vmName: String? = nil, logger: Logger = cli) {
        message(text, vmName: vmName, level: .default, logger: logger)
    }

    /// Records a warning that Pomme printed, as a notice so that it's kept.
    static func warning(_ text: String, vmName: String? = nil, logger: Logger = cli) {
        notice("warning: " + text, vmName: vmName, logger: logger)
    }

    /// Records an error with its catalog code, Swift type, description, and
    /// the domain and code of each underlying error. Text passes through
    /// `scrubbed(_:)`, which removes secret values but keeps the message.
    static func error(
        _ error: any Error,
        context: String,
        vmName: String? = nil,
        logger: Logger = cli
    ) {
        let report = PommeErrorReport(error, redaction: .none)
        let nsError = error as NSError
        let type = String(reflecting: Swift.type(of: error))
        let causes = report.causes
            .map { "\($0.domain) \($0.code): \(scrubbed($0.description))" }
            .joined(separator: "; ")
        let vm = vmName.map { " vm=\($0)" } ?? ""
        logger.error("""
            \(scrubbed(context), privacy: .public) failed\(vm, privacy: .public): \
            code=\(report.code.rawValue, privacy: .public) type=\(type, privacy: .public) \
            domain=\(nsError.domain, privacy: .public) domainCode=\(nsError.code, privacy: .public) \
            message=\(scrubbed(report.message), privacy: .public) \
            causes=[\(causes, privacy: .public)]
            """)
    }
}
