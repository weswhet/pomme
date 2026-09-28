import Darwin
import Foundation
import OpenDirectory
import OSLog

struct PommeBuddyPreferencesOwner: Codable, Sendable, Equatable {
    var account: String
    var uid: UInt32
    var generatedUID: String
    var homeDirectory: String

    func validate() throws {
        guard account == "pomme", uid >= 501, uid < UInt32.max,
              UUID(uuidString: generatedUID) != nil,
              homeDirectory == "/Users/pomme" else {
            throw PommeBuddyPreferencesFailure(code: "invalid-owner", numericCode: nil)
        }
    }
}

struct PommeBuddyPreferencesFailure: Error, Codable, Sendable, Equatable {
    var code: String
    var numericCode: Int?
}

struct PommeBuddyPreferencesStatus: Codable, Sendable, Equatable {
    var bootSessionUUID: String
    var productVersion: String?
    var buildVersion: String?
    var owner: PommeBuddyPreferencesOwner?
    var stage: String
    var outcome: String
    var error: PommeBuddyPreferencesFailure?
}

/// Only fixed labels, validated identities, and numeric metadata enter public logs.
struct PommeBuddyPreferencesDiagnostic: Sendable {
    var event: String
    var fields: [String: String] = [:]
    var isError = false

    var message: String {
        (["event=\(event)"] + fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }).joined(separator: " ")
    }

    static func log(_ diagnostic: Self) {
        let logger = Logger(subsystem: "com.github.weswhet.pomme", category: "buddy-preferences")
        if diagnostic.isError { logger.error("\(diagnostic.message, privacy: .public)") }
        else { logger.notice("\(diagnostic.message, privacy: .public)") }
    }

    static func stderrClassification(_ output: String, domain: String, key: String) -> String {
        guard output.utf8.count <= 4096 else { return "unknown-redacted" }
        var lines = output.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if lines.isEmpty { return "empty" }
        let header = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ defaults\[\d+:\d+\]"#
        if let prefix = lines[0].range(of: header + "(?: |$)", options: .regularExpression) {
            lines[0] = String(lines[0][prefix.upperBound...])
            if lines[0].isEmpty { lines.removeFirst() }
        }
        guard lines.count == 1 else { return "unknown-redacted" }
        switch lines[0] {
        case "sudo: a password is required": return "sudo-password-required"
        case "sudo: unknown user pomme": return "sudo-unknown-user"
        case "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper": return "sudo-terminal-required"
        case "Could not write domain \(domain); exiting", "Failed to write domain \(domain)": return "defaults-write-domain-failed"
        case "Domain \(domain) does not exist", "Domain \(domain) does not exist.": return "defaults-missing-domain"
        case "The domain/default pair of (\(domain), \(key)) does not exist", "The domain/default pair of (\(domain), \(key)) does not exist.": return "defaults-missing-pair"
        default: return "unknown-redacted"
        }
    }
}

struct PommeBuddyPreferencesCommandResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum PommeBuddyPreferencesBudget {
    static let command: TimeInterval = 15
    static let initialRead: TimeInterval = 60
    // Each of two keys can require type/value reads, a write, and type/value readback.
    static let receipt: TimeInterval = initialRead + 9 * command + 15
    static let receiptPollCount = Int(receipt / 2) + 1
}

struct PommeBuddyPreferencesDependencies: Sendable {
    var bootSessionUUID: @Sendable () throws -> String
    var owner: @Sendable () throws -> PommeBuddyPreferencesOwner?
    var homeExists: @Sendable (PommeBuddyPreferencesOwner) throws -> Bool
    var consoleIsOwner: @Sendable (PommeBuddyPreferencesOwner) throws -> Bool
    var command: @Sendable (String, [String]) async throws -> PommeBuddyPreferencesCommandResult
    var load: @Sendable () throws -> PommeBuddyPreferencesStatus?
    var save: @Sendable (PommeBuddyPreferencesStatus) throws -> Void
    var sleep: @Sendable () async throws -> Void
    var diagnostic: @Sendable (PommeBuddyPreferencesDiagnostic) -> Void = PommeBuddyPreferencesDiagnostic.log
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var instrumentedCommand: (@Sendable (String, [String], TimeInterval, @escaping @Sendable (PommeBuddyPreferencesDiagnostic) -> Void) async throws -> PommeBuddyPreferencesCommandResult)? = nil

    static var live: Self {
        .init(bootSessionUUID: PommeBuddyPreferencesSystem.bootSessionUUID,
              owner: PommeBuddyPreferencesSystem.owner,
              homeExists: PommeBuddyPreferencesSystem.homeExists,
              consoleIsOwner: PommeBuddyPreferencesSystem.consoleIsOwner,
              command: { path, args in
                  try await Task.detached { try PommeBuddyPreferencesSystem.command(path, args) }.value
              },
              load: PommeBuddyPreferencesSystem.load,
              save: PommeBuddyPreferencesSystem.save,
              sleep: { try await Task.sleep(for: .seconds(2)) },
              instrumentedCommand: { path, args, timeout, sink in
                  try await Task.detached { try PommeBuddyPreferencesSystem.command(path, args, timeout: timeout, diagnostic: sink) }.value
              })
    }
}

/// The daemon owns this task independently of any authenticated connection.
/// A durable running receipt precedes every preference effect.
actor PommeBuddyPreferencesMaintenance {
    private let dependencies: PommeBuddyPreferencesDependencies
    private var receipt: PommeBuddyPreferencesStatus?
    private var started = false
    private var initialPreferenceRead = true
    private var stageStarted = ContinuousClock.now
    private let runID = UUID().uuidString
    private var lastWaitingState: String?
    private var lastWaitingLog: TimeInterval = 0

    private func emit(_ event: String, _ fields: [String: String] = [:], error: Bool = false) {
        var fields = fields
        fields["boot"] = receipt.flatMap { UUID(uuidString: $0.bootSessionUUID)?.uuidString } ?? "unknown"
        fields["daemon_pid"] = String(getpid())
        fields["run_id"] = runID
        fields["stage"] = ["detectingOS", "waitingForOwner", "maintainingBuild", "maintainingMiniBuddy", "complete"].contains(receipt?.stage ?? "") ? receipt!.stage : "initializing"
        dependencies.diagnostic(.init(event: event, fields: fields, isError: error))
    }

    private func waiting(_ state: String) {
        let now = dependencies.uptime()
        if lastWaitingState != state || now - lastWaitingLog >= 60 {
            emit("owner-waiting", ["state": state])
            lastWaitingState = state
            lastWaitingLog = now
        }
    }

    private func lookupOwner() throws -> PommeBuddyPreferencesOwner? {
        let owner: PommeBuddyPreferencesOwner?
        do { owner = try dependencies.owner() }
        catch {
            let code = (error as? PommeBuddyPreferencesFailure)?.code ?? ""
            emit(["invalid-owner", "invalid-owner-attribute", "invalid-owner-uid", "ambiguous-owner"].contains(code) ? "owner-invalid" : "owner-query-failed", ["numeric": String((error as? PommeBuddyPreferencesFailure)?.numericCode ?? (error as NSError).code)], error: true)
            throw error
        }
        guard let owner else { return nil }
        do { try owner.validate() }
        catch { emit("owner-invalid", error: true); throw error }
        return owner
    }

    private func checkedHome(_ owner: PommeBuddyPreferencesOwner) throws -> Bool {
        do { return try dependencies.homeExists(owner) }
        catch {
            emit("owner-home-invalid-or-query-failed", ["uid": String(owner.uid), "numeric": String((error as? PommeBuddyPreferencesFailure)?.numericCode ?? (error as NSError).code)], error: true)
            throw error
        }
    }

    private func saveReceipt() throws {
        guard let receipt else { return }
        do { try dependencies.save(receipt) }
        catch { emit("receipt-save-failed", ["numeric": String((error as? PommeBuddyPreferencesFailure)?.numericCode ?? (error as NSError).code)], error: true); throw error }
    }

    init(dependencies: PommeBuddyPreferencesDependencies = .live) {
        self.dependencies = dependencies
    }

    func status() -> PommeBuddyPreferencesStatus? { receipt }

    func statusPayload() throws -> JSONValue {
        guard let receipt else { return .object(["initializing": .bool(true)]) }
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(receipt))
    }

    func run() async {
        guard !started else { return }
        started = true
        let start = ContinuousClock.now
        do {
            let boot = try dependencies.bootSessionUUID()
            guard UUID(uuidString: boot) != nil else { throw failure("invalid-boot-identity") }
            receipt = .init(bootSessionUUID: boot, stage: "detectingOS", outcome: "waiting")
            let previous: PommeBuddyPreferencesStatus?
            do { previous = try dependencies.load() }
            catch { emit("receipt-load-failed", ["numeric": String((error as? PommeBuddyPreferencesFailure)?.numericCode ?? (error as NSError).code)], error: true); throw error }
            if let previous, previous.bootSessionUUID == boot {
                receipt = previous
                try validateReceipt(previous)
                emit("receipt-reused", ["outcome": previous.outcome])
                switch previous.outcome {
                case "succeeded", "failed": emit("receipt-terminal-no-replay", ["outcome": previous.outcome]); return
                case "running": emit("attempt-interrupted", error: true); throw failure("interrupted-attempt")
                case "waiting": break
                default: throw failure("invalid-receipt")
                }
            }
            emit("maintenance-started")
            // Waiting is restartable: no preference effects have occurred yet.
            try transition("detectingOS", outcome: "waiting")
            // Finish each async read before opening a modifying access to the
            // receipt: command diagnostics also read the receipt for context.
            let productVersion = try await osValue("-productVersion")
            receipt?.productVersion = productVersion
            let buildVersion = try await osValue("-buildVersion")
            receipt?.buildVersion = buildVersion
            emit("os-detected", ["product_version": receipt!.productVersion!, "build": receipt!.buildVersion!])
            try transition("waitingForOwner", outcome: "waiting")
            while true {
                try Task.checkCancellation()
                if let owner = try lookupOwner() {
                    let homeReady = try checkedHome(owner)
                    if homeReady, try dependencies.consoleIsOwner(owner) {
                        emit("owner-found", ["uid": String(owner.uid), "generated_uid": UUID(uuidString: owner.generatedUID)!.uuidString, "home": "/Users/pomme", "home_valid": "true"])
                        receipt?.owner = owner
                        break
                    }
                    waiting(homeReady ? "console-owner-absent" : "home-absent")
                } else { waiting("account-absent") }
                try await dependencies.sleep()
            }
            try transition("maintainingBuild", outcome: "running")
            try await maintain(domain: "com.apple.SetupAssistant", key: "LastSeenBuddyBuildVersion",
                               type: "string", value: receipt!.buildVersion!)
            try transition("maintainingMiniBuddy", outcome: "running")
            try await maintain(domain: "com.apple.loginwindow", key: "MiniBuddyLaunch", type: "boolean", value: "0")
            try transition("complete", outcome: "succeeded")
        } catch {
            if error is CancellationError, receipt?.outcome == "waiting" {
                // No preference effects began; a later daemon can resume waiting.
                emit("maintenance-wait-cancelled")
                return
            }
            let issue = (error as? PommeBuddyPreferencesFailure)
                ?? .init(code: error is CancellationError ? "cancelled" : "maintenance-failed",
                         numericCode: (error as NSError).code)
            if receipt == nil { receipt = .init(bootSessionUUID: "", stage: "initializing", outcome: "failed") }
            receipt?.outcome = "failed"
            receipt?.error = issue
            try? saveReceipt()
            emit("maintenance-failed", ["numeric": String(issue.numericCode ?? 0), "failure": Self.failureCodes.contains(issue.code) ? issue.code : "unknown-redacted"], error: true)
        }
        emit("maintenance-finished", ["outcome": receipt?.outcome == "succeeded" ? "succeeded" : "failed", "duration": String(describing: start.duration(to: .now))])
    }

    private static let failureCodes: Set<String> = ["cancelled", "maintenance-failed", "invalid-owner", "ambiguous-owner", "boot-query", "command-encoding", "command-output-limit", "command-pipe", "command-read", "command-signal", "command-signal-setup", "command-spawn", "command-spawn-init", "command-spawn-setup", "command-timeout", "command-wait", "directory-result", "console-query", "home-query", "interrupted-attempt", "invalid-boot-identity", "invalid-owner-attribute", "invalid-owner-uid", "invalid-receipt", "os-detection-failed", "owner-changed", "preference-boolean-invalid", "preference-build-invalid", "preference-read-failed", "preference-read-type-failed", "preference-readback-mismatch", "preference-type-mismatch", "preference-write-failed", "receipt-commit", "receipt-create", "receipt-directory-open", "receipt-directory-sync", "receipt-open", "root-required", "unsafe-home", "unsafe-receipt", "unsafe-receipt-directory"]

    private func failure(_ code: String, _ numeric: Int? = nil) -> PommeBuddyPreferencesFailure {
        .init(code: code, numericCode: numeric)
    }

    private func transition(_ stage: String, outcome: String) throws {
        emit("stage-finished", ["duration": String(describing: stageStarted.duration(to: .now))])
        stageStarted = .now
        receipt?.stage = stage
        receipt?.outcome = outcome
        try saveReceipt()
        emit("stage-started", ["outcome": outcome])
    }

    private func osValue(_ argument: String) async throws -> String {
        let result = try await command("/usr/bin/sw_vers", [argument], operation: argument == "-buildVersion" ? "detect-build" : "detect-version")
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, result.stderr.isEmpty, !value.isEmpty, value.utf8.count <= 128,
              value.range(of: argument == "-buildVersion" ? "^[0-9]{2,3}[A-Z][0-9]+[a-z]?$" : "^[0-9]+(?:\\.[0-9]+){1,2}$", options: .regularExpression) != nil
        else { throw failure("os-detection-failed", Int(result.status)) }
        return value
    }

    private func defaults(_ arguments: [String]) async throws -> PommeBuddyPreferencesCommandResult {
        // Revalidate immediately before every read/write so account replacement
        // cannot silently redirect a username-based sudo command.
        guard let current = try lookupOwner(), current == receipt?.owner,
              try checkedHome(current), try dependencies.consoleIsOwner(current) else { emit("owner-revalidation-failed", error: true); throw failure("owner-changed") }
        emit("owner-revalidated", ["uid": String(current.uid), "home_valid": "true", "operation": arguments[0], "key": arguments[2]])
        return try await command("/usr/bin/sudo", ["-n", "-H", "-u", "pomme", "/usr/bin/defaults"] + arguments,
                                 operation: arguments[0], domain: arguments[1], key: arguments[2],
                                 timeout: consumePreferenceTimeout(operation: arguments[0]))
    }

    private func consumePreferenceTimeout(operation: String) -> TimeInterval {
        // Console ownership can precede cfprefsd readiness during first login.
        // Give only the first read-type extra time; never replay a failed attempt.
        guard initialPreferenceRead, operation == "read-type" else { return PommeBuddyPreferencesBudget.command }
        initialPreferenceRead = false
        return PommeBuddyPreferencesBudget.initialRead
    }

    private func command(_ path: String, _ args: [String], operation: String, domain: String = "none", key: String = "none", timeout: TimeInterval = PommeBuddyPreferencesBudget.command) async throws -> PommeBuddyPreferencesCommandResult {
        let start = ContinuousClock.now
        let context = ["operation": operation, "key": key, "launcher": path == "/usr/bin/sudo" ? "sudo" : "sw_vers",
                       "boot": receipt.flatMap { UUID(uuidString: $0.bootSessionUUID)?.uuidString } ?? "unknown",
                       "daemon_pid": String(getpid()), "run_id": runID, "stage": receipt?.stage ?? "initializing",
                       "requested_program": path == "/usr/bin/sudo" ? "defaults" : "sw_vers"]
        let sink = dependencies.diagnostic
        let commandSink: @Sendable (PommeBuddyPreferencesDiagnostic) -> Void = { event in
            var event = event
            event.fields.merge(context) { _, context in context }
            sink(event)
        }
        commandSink(.init(event: "command-launch", fields: ["timeout_seconds": String(timeout)]))
        do {
            let result: PommeBuddyPreferencesCommandResult
            if let instrumented = dependencies.instrumentedCommand { result = try await instrumented(path, args, timeout, commandSink) }
            else { result = try await dependencies.command(path, args) }
            commandSink(.init(event: "command-result", fields: ["exit_code": String(result.status), "stdout_bytes": String(result.stdout.utf8.count), "stderr_bytes": String(result.stderr.utf8.count), "stderr_class": PommeBuddyPreferencesDiagnostic.stderrClassification(result.stderr, domain: domain, key: key), "duration": String(describing: start.duration(to: .now))], isError: result.status != 0))
            return result
        } catch {
            let failure = error as? PommeBuddyPreferencesFailure
            commandSink(.init(event: "command-failed", fields: ["failure": Self.commandFailureLabel(failure?.code), "numeric": String(failure?.numericCode ?? (error as NSError).code), "duration": String(describing: start.duration(to: .now))], isError: true))
            throw error
        }
    }

    private static func commandFailureLabel(_ code: String?) -> String {
        let allowed = ["command-pipe", "command-spawn-init", "command-signal-setup", "command-spawn-setup", "command-spawn", "command-output-limit", "command-read", "command-wait", "command-timeout", "command-signal", "command-encoding"]
        return code.flatMap { allowed.contains($0) ? $0 : nil } ?? "unknown-redacted"
    }

    private func read(domain: String, key: String, type: String) async throws -> String? {
        let kind = try await defaults(["read-type", domain, key])
        if kind.status == 1, kind.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Self.isMissing(kind.stderr, domain: domain, key: key) { return nil }
        guard kind.status == 0 else { throw failure("preference-read-type-failed", Int(kind.status)) }
        guard kind.stderr.isEmpty,
              kind.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Type is \(type)"
        else { emit("preference-type-mismatch", ["key": key, "expected_type": type], error: true); throw failure("preference-type-mismatch") }
        let result = try await defaults(["read", domain, key])
        guard result.status == 0, result.stderr.isEmpty else {
            throw failure("preference-read-failed", Int(result.status))
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "boolean", value != "0", value != "1" { throw failure("preference-boolean-invalid") }
        if type == "string", value.range(of: "^[0-9]{2,3}[A-Z][0-9]+[a-z]?$", options: .regularExpression) == nil { throw failure("preference-build-invalid") }
        return value
    }

    private func validateReceipt(_ value: PommeBuddyPreferencesStatus) throws {
        let waitingStages = ["detectingOS", "waitingForOwner"]
        let runningStages = ["maintainingBuild", "maintainingMiniBuddy"]
        guard value.error == nil || value.outcome == "failed",
              value.error.map({ !$0.code.isEmpty && $0.code.utf8.count <= 128 }) ?? true else { throw failure("invalid-receipt") }
        switch value.outcome {
        case "waiting":
            guard waitingStages.contains(value.stage), value.owner == nil else { throw failure("invalid-receipt") }
        case "running", "succeeded":
            guard value.outcome == "running" ? runningStages.contains(value.stage) : value.stage == "complete",
                  let owner = value.owner, let version = value.productVersion, let build = value.buildVersion,
                  version.range(of: "^[0-9]+(?:\\.[0-9]+){1,2}$", options: .regularExpression) != nil,
                  build.range(of: "^[0-9]{2,3}[A-Z][0-9]+[a-z]?$", options: .regularExpression) != nil else { throw failure("invalid-receipt") }
            try owner.validate()
        case "failed":
            guard value.error != nil, (waitingStages + runningStages + ["complete", "initializing"]).contains(value.stage) else { throw failure("invalid-receipt") }
            if let owner = value.owner { try owner.validate() }
        default: throw failure("invalid-receipt")
        }
    }

    private static func isMissing(_ output: String, domain: String, key: String) -> Bool {
        guard output.utf8.count <= 4096 else { return false }
        let lines = output.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let message = lines.last,
              lines.count == 1 || (lines.count == 2 && lines[0].range(
                of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ defaults\[\d+:\d+\]$"#,
                options: .regularExpression) != nil) else { return false }
        let domainMessage = "Domain \(domain) does not exist"
        let pairMessage = "The domain/default pair of (\(domain), \(key)) does not exist"
        return [domainMessage, domainMessage + ".", pairMessage, pairMessage + "."].contains(message)
    }

    private func maintain(domain: String, key: String, type: String, value: String) async throws {
        if try await read(domain: domain, key: key, type: type) == value { emit("preference-matching-skipped", ["key": key]); return }
        let result = try await defaults(["write", domain, key, type == "boolean" ? "-bool" : "-string",
                                         type == "boolean" ? "false" : value])
        guard result.status == 0, result.stderr.isEmpty, result.stdout.isEmpty else {
            throw failure("preference-write-failed", Int(result.status))
        }
        guard try await read(domain: domain, key: key, type: type) == value else {
            emit("preference-readback-mismatch", ["key": key, "expected_type": type], error: true)
            throw failure("preference-readback-mismatch")
        }
        emit("preference-readback-verified", ["key": key, "expected_type": type])
    }
}

private enum PommeBuddyPreferencesSystem {
    static let receiptPath = "/private/var/db/pomme/buddy-preferences.json"

    static func bootSessionUUID() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 128 else { throw issue("boot-query", errno) }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw issue("boot-query", errno) }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func owner() throws -> PommeBuddyPreferencesOwner? {
        let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers,
                               attribute: kODAttributeTypeRecordName, matchType: ODMatchType(kODMatchEqualTo),
                               queryValues: "pomme", returnAttributes: [kODAttributeTypeRecordName, kODAttributeTypeUniqueID,
                                  kODAttributeTypeGUID, kODAttributeTypeNFSHomeDirectory], maximumResults: 2)
        guard let records = try query.resultsAllowingPartial(false) as? [ODRecord] else { throw issue("directory-result") }
        if records.isEmpty { return nil }
        guard records.count == 1 else { throw issue("ambiguous-owner") }
        func value(_ key: String) throws -> String {
            guard let values = try records[0].values(forAttribute: key) as? [String], values.count == 1 else {
                throw issue("invalid-owner-attribute")
            }
            return values[0]
        }
        let uidText = try value(kODAttributeTypeUniqueID)
        guard let uid = UInt32(uidText), String(uid) == uidText else { throw issue("invalid-owner-uid") }
        let identity = try PommeBuddyPreferencesOwner(account: value(kODAttributeTypeRecordName), uid: uid,
                                                     generatedUID: value(kODAttributeTypeGUID), homeDirectory: value(kODAttributeTypeNFSHomeDirectory))
        try identity.validate()
        return identity
    }

    static func consoleIsOwner(_ owner: PommeBuddyPreferencesOwner) throws -> Bool {
        // Account creation precedes the first login. User defaults become ready
        // only after that verified account owns the console session.
        var info = stat()
        guard lstat("/dev/console", &info) == 0, info.st_mode & S_IFMT == S_IFCHR else {
            throw issue("console-query", errno)
        }
        return info.st_uid == owner.uid
    }

    static func homeExists(_ owner: PommeBuddyPreferencesOwner) throws -> Bool {
        var info = stat()
        guard lstat(owner.homeDirectory, &info) == 0 else {
            if errno == ENOENT { return false }
            throw issue("home-query", errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner.uid,
              info.st_mode & 0o022 == 0 else { throw issue("unsafe-home") }
        return true
    }

    static func issue(_ code: String, _ numeric: Int32? = nil) -> PommeBuddyPreferencesFailure {
        .init(code: code, numericCode: numeric.map(Int.init))
    }

    static func validateDirectory() throws {
        guard geteuid() == 0 else { throw issue("root-required") }
        var info = stat()
        guard lstat("/private/var/db/pomme", &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0, info.st_mode & 0o077 == 0 else {
            throw issue("unsafe-receipt-directory", errno)
        }
    }

    static func load() throws -> PommeBuddyPreferencesStatus? {
        try validateDirectory()
        let fd = open(receiptPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw issue("receipt-open", errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 16_384 else { throw issue("unsafe-receipt") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 16_385) ?? Data()
        return try JSONDecoder().decode(PommeBuddyPreferencesStatus.self, from: data)
    }

    static func save(_ receipt: PommeBuddyPreferencesStatus) throws {
        try validateDirectory()
        let data = try JSONEncoder().encode(receipt)
        let temporary = receiptPath + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw issue("receipt-create", errno) }
        defer { close(fd); unlink(temporary) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, rename(temporary, receiptPath) == 0 else { throw issue("receipt-commit", errno) }
        let directory = open("/private/var/db/pomme", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw issue("receipt-directory-open", errno) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw issue("receipt-directory-sync", errno) }
    }

    static func command(_ path: String, _ arguments: [String], timeout: TimeInterval = PommeBuddyPreferencesBudget.command, diagnostic: @Sendable (PommeBuddyPreferencesDiagnostic) -> Void = { _ in }) throws -> PommeBuddyPreferencesCommandResult {
        var output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw issue("command-pipe", errno) }
        defer { close(output[0]); close(output[1]) }
        guard pipe(&errors) == 0 else { throw issue("command-pipe", errno) }
        defer { close(errors[0]); close(errors[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw issue("command-spawn-init") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        // launchd and the hosting thread may ignore or block signals. Give
        // each command ordinary signal behavior without changing the agent.
        var signalDefaults = sigset_t()
        var signalMask = sigset_t()
        guard sigfillset(&signalDefaults) == 0,
              sigdelset(&signalDefaults, SIGKILL) == 0,
              sigdelset(&signalDefaults, SIGSTOP) == 0,
              sigemptyset(&signalMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &signalDefaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0 else { throw issue("command-signal-setup") }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, output[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, errors[0]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw issue("command-spawn-setup") }
        let argv = ([path] + arguments).map { $0.withCString { strdup($0) } } + [nil]
        let environment: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C"]
        let env = environment.map { $0.withCString { strdup($0) } } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { env in
                posix_spawn(&pid, path, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw issue("command-spawn", result) }
        diagnostic(.init(event: "command-spawned", fields: ["launcher_pid": String(pid)]))
        close(output[1]); output[1] = -1
        close(errors[1]); errors[1] = -1
        let descriptors = [output[0], errors[0]]
        var buffers = [Data(), Data()], ended = [false, false]
        var status: Int32 = 0
        var reaped = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            for fd in descriptors {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw issue("command-pipe", errno) }
            }
            while !reaped || !ended.allSatisfy({ $0 }) {
                for index in descriptors.indices where !ended[index] {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(descriptors[index], &bytes, bytes.count)
                    if count > 0 {
                        buffers[index].append(contentsOf: bytes.prefix(count))
                        guard buffers[index].count <= 16_384 else { throw issue("command-output-limit") }
                    } else if count == 0 { ended[index] = true }
                    else if errno != EAGAIN && errno != EINTR { throw issue("command-read", errno) }
                }
                if !reaped {
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid { reaped = true }
                    else if waited < 0 && errno != EINTR { throw issue("command-wait", errno) }
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw issue("command-timeout") }
                usleep(10_000)
            }
        } catch {
            // The command has its own process group, including sudo's child.
            // A timeout cannot leave defaults running after the failed receipt.
            kill(-pid, SIGKILL)
            if !reaped {
                let reapDeadline = ProcessInfo.processInfo.systemUptime + 1
                while ProcessInfo.processInfo.systemUptime < reapDeadline {
                    if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                    usleep(10_000)
                }
            }
            diagnostic(.init(event: "command-aborted", fields: ["launcher_pid": String(pid), "timed_out": String((error as? PommeBuddyPreferencesFailure)?.code == "command-timeout"), "stdout_bytes": String(buffers[0].count), "stderr_bytes": String(buffers[1].count)], isError: true))
            throw error
        }
        var completion = ["launcher_pid": String(pid), "signal": String(status & 0x7f),
                          "stdout_bytes": String(buffers[0].count), "stderr_bytes": String(buffers[1].count), "timed_out": "false"]
        if status & 0x7f == 0 { completion["exit_code"] = String((status >> 8) & 0xff) }
        diagnostic(.init(event: "command-reaped", fields: completion, isError: status & 0x7f != 0))
        guard status & 0x7f == 0 else { throw issue("command-signal", status & 0x7f) }
        guard let stdout = String(data: buffers[0], encoding: .utf8), let stderr = String(data: buffers[1], encoding: .utf8) else { throw issue("command-encoding") }
        return .init(status: (status >> 8) & 0xff, stdout: stdout, stderr: stderr)
    }
}
