import ArgumentParser
import Foundation

/// Views Pomme subsystem records from the guest unified log.
struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "View Pomme guest-agent unified logs."
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var name: String?

    @Option(name: .customLong("last"), help: "History window: a positive number followed by s, m, h, or d; or boot.")
    var last: String?

    @Flag(name: .customLong("follow"), help: "Stream new records until interrupted.")
    var follow = false

    @Option(name: .customLong("category"), help: "Include an exact Pomme log category. Repeat to combine categories.")
    var categories: [String] = []

    @Option(name: .customLong("level"), help: "Minimum log level: default, info, or debug.")
    var level: GuestLogLevel = .info

    @Option(name: .customLong("format"), help: "Output format: text, json, or jsonl.")
    var format: GuestLogFormat?

    @Flag(name: .customLong("json"), help: "Print JSON records. Equivalent to --format json.")
    var json = false

    @Flag(name: .customLong("debug"), help: "Print verbose CLI diagnostics.")
    var debug = false

    @Option(name: .customLong("progress"), help: "Progress display: auto, plain, or off.")
    var progress: CLIProgressMode = .auto

    @OptionGroup var timeout: TimeoutOptions

    mutating func validate() throws {
        let outputFormat = try resolvedFormat()

        if follow, last != nil {
            throw ValidationError("--last conflicts with --follow.")
        }
        if follow, timeout.isExplicitlySet {
            throw ValidationError("--timeout conflicts with --follow.")
        }
        if let last {
            try Self.validateLast(last)
        }
        if !follow {
            let value = try timeout.value()
            guard value <= 300 else {
                throw ValidationError("--timeout must be between 1 and 300 seconds.")
            }
        }
        if follow, outputFormat == .json {
            throw ValidationError("--format json conflicts with --follow.")
        }
    }

    mutating func run() throws {
        let target = try target()
        try PommeApplication.guestLogs(
            name: target,
            request: try payload(),
            follow: follow,
            debug: debug
        )
    }

    func target(
        environmentTarget: String? = ProcessInfo.processInfo.environment["POMME_VM_NAME"]
    ) throws -> String {
        let arguments = name.map { [$0] } ?? []
        if arguments.isEmpty {
            guard let environmentTarget, !environmentTarget.isEmpty else {
                throw ValidationError("Specify a VM name or set POMME_VM_NAME.")
            }
            return try VMTargetResolver.names(from: [environmentTarget], allowMultiple: false)[0]
        }
        return try VMTargetResolver.names(from: arguments, allowMultiple: false)[0]
    }

    func payload() throws -> [String: Any] {
        let resolvedFormat = try resolvedFormat()
        if follow {
            return [
                "categories": categories,
                "level": level.rawValue,
                "format": resolvedFormat.rawValue
            ]
        }
        return [
            "last": last ?? "10m",
            "categories": categories,
            "level": level.rawValue,
            "format": resolvedFormat.rawValue,
            "timeout": try timeout.value()
        ]
    }

    func resolvedFormat() throws -> GuestLogFormat {
        if json, let format, format != .json {
            throw ValidationError("--json conflicts with --format \(format.rawValue).")
        }
        return json ? .json : (format ?? .text)
    }

    static func validateLast(_ value: String) throws {
        if value == "boot" { return }
        guard let unit = value.last, "smhd".contains(unit) else {
            throw ValidationError("--last must be boot or a positive number followed by s, m, h, or d.")
        }
        let numeric = value.dropLast()
        guard !numeric.isEmpty,
              numeric.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              numeric.utf8.filter({ $0 == 46 }).count <= 1,
              let amount = Double(String(numeric)), amount.isFinite, amount > 0
        else {
            throw ValidationError("--last must be boot or a positive number followed by s, m, h, or d.")
        }
    }
}

enum GuestLogLevel: String, CaseIterable, ExpressibleByArgument {
    case `default`
    case info
    case debug
}

enum GuestLogFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
    case jsonl
}

extension LogCommand: CLIProgressCommand {
    var progressOptions: GlobalOptions {
        var options = GlobalOptions()
        options.progress = progress
        options.debug = debug
        options.json = json
        switch format {
        case .json: options.format = .json
        case .jsonl: options.format = .jsonl
        case .text, nil: options.format = .table
        }
        return options
    }
}
