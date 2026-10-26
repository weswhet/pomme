import Foundation
import os

/// Pomme's unified logging facility. Read it back after a failure with
/// `log show --predicate 'subsystem == "com.github.weswhet.pomme"' --info --debug`.
///
/// Never pass a password, agent token, credential, Keychain item, SSH key, or
/// request body here, not even as private data. Free-form text goes through
/// `scrubbed(_:)`, which withholds anything that mentions a secret.
///
/// The system keeps `.info` messages only in memory until an error is
/// logged, and never stores `.debug` messages without a logging
/// configuration change, so failures are logged with `.error`.
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

    /// Words that withhold a log message in addition to those that
    /// `PommeErrorRedaction` checks. The unified log keeps text longer than
    /// the CLI's output, so it's stricter without changing that output.
    private static let extraSecretMarkers = [
        "credential", "passphrase", "private key", "-----begin", "authorization:",
        "bearer ", "proof", "kcpassword",
    ]

    /// One line of free-form text that is safe to log as public data: text
    /// that mentions a secret is withheld, and newlines are flattened.
    static func scrubbed(_ text: String) -> String {
        let lowered = text.lowercased()
        if PommeErrorRedaction.mentionsSecret(text) || extraSecretMarkers.contains(where: { lowered.contains($0) }) {
            return PommeErrorRedaction.withheldMessage
        }
        return String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(1024))
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
    /// `PommeErrorRedaction`, so a message that mentions a secret is withheld.
    static func error(
        _ error: any Error,
        context: String,
        vmName: String? = nil,
        logger: Logger = cli
    ) {
        let report = PommeErrorReport(error, redaction: .secrets)
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
