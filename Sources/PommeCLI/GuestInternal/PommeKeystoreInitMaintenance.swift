import Darwin
import Foundation
import os

/// One boot's record of the keystore initializer. `outcome` is `running`,
/// `succeeded`, `failed`, or `skipped`; `reason` names why a run was skipped
/// or failed.
struct PommeKeystoreInitStatus: Codable, Sendable, Equatable {
    var bootSessionUUID: String
    var outcome: String
    var reason: String?
    var exitStatus: Int32?

    static let outcomes: Set<String> = ["running", "succeeded", "failed", "skipped"]
}

struct PommeKeystoreInitDependencies: Sendable {
    var bootSessionUUID: @Sendable () throws -> String
    var majorVersion: @Sendable () -> Int
    /// `statfs("/")` flags.
    var rootMountFlags: @Sendable () throws -> UInt32
    /// `security.mac.amfi.launch_constraints_enforced`; nil when absent.
    var launchConstraintsEnforced: @Sendable () -> Int32?
    /// Runs the initializer and returns its exit status.
    var initialize: @Sendable () async throws -> Int32
    var load: @Sendable () throws -> PommeKeystoreInitStatus?
    var save: @Sendable (PommeKeystoreInitStatus) throws -> Void
    var log: @Sendable (String, Bool) -> Void = PommeKeystoreInitMaintenance.log

    static var live: Self {
        .init(bootSessionUUID: PommeBuddyPreferencesSystem.bootSessionUUID,
              majorVersion: { ProcessInfo.processInfo.operatingSystemVersion.majorVersion },
              rootMountFlags: {
                  var info = statfs()
                  guard statfs("/", &info) == 0 else { throw PommeBuddyPreferencesSystem.issue("root-statfs", errno) }
                  return info.f_flags
              },
              launchConstraintsEnforced: {
                  var value: Int32 = 0
                  var size = MemoryLayout<Int32>.size
                  guard sysctlbyname("security.mac.amfi.launch_constraints_enforced", &value, &size, nil, 0) == 0,
                        size == MemoryLayout<Int32>.size else { return nil }
                  return value
              },
              initialize: {
                  try await Task.detached {
                      try PommeBuddyPreferencesSystem.command(PommeKeystoreInitMaintenance.program,
                                                              PommeKeystoreInitMaintenance.arguments,
                                                              timeout: PommeKeystoreInitMaintenance.timeout).status
                  }.value
              },
              load: { try PommeBuddyPreferencesSystem.loadReceipt(PommeKeystoreInitStatus.self, at: PommeKeystoreInitMaintenance.receiptPath) },
              save: { try PommeBuddyPreferencesSystem.saveReceipt($0, at: PommeKeystoreInitMaintenance.receiptPath) })
    }
}

/// Runs the boot task that macOS 27 `launchd` skips in a VM.
///
/// macOS 27 gives the `keystore-init` boot task (`applekeystored --init`)
/// `LimitLoadToBootingExternalVolume`, and launchd skips it when the root
/// file system is local and not removable, which a virtio disk always is.
/// The guest's booted-volume keybag is then never mapped, `apsd` cannot
/// create its push identity, and an enrolled VM never sends `TokenUpdate`.
/// The persistent agent runs the same initializer once per boot under the
/// same condition launchd uses. It needs SIP disabled: otherwise the launch
/// constraints on `applekeystored` stop the process before it runs.
actor PommeKeystoreInitMaintenance {
    static let program = "/usr/libexec/applekeystored"
    static let arguments = ["--init"]
    static let timeout: TimeInterval = 30
    static let receiptPath = "/private/var/db/pomme/keystore-init.json"
    static let firstAffectedMajorVersion = 27

    private let dependencies: PommeKeystoreInitDependencies
    private var receipt: PommeKeystoreInitStatus?
    private var started = false

    init(dependencies: PommeKeystoreInitDependencies = .live) {
        self.dependencies = dependencies
    }

    func status() -> PommeKeystoreInitStatus? { receipt }

    func statusPayload() throws -> JSONValue {
        guard let receipt else { return .object(["initializing": .bool(true)]) }
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(receipt))
    }

    /// The reason launchd's own condition doesn't apply, or nil when the
    /// guest needs the initializer. This mirrors launchd's check: run only
    /// when `statfs("/")` reports `MNT_LOCAL` without `MNT_REMOVABLE`.
    static func skipReason(majorVersion: Int, rootMountFlags: UInt32, launchConstraintsEnforced: Int32?) -> String? {
        if majorVersion < firstAffectedMajorVersion { return "unaffected-os" }
        if rootMountFlags & UInt32(MNT_LOCAL | MNT_REMOVABLE) != UInt32(MNT_LOCAL) { return "boot-volume-external" }
        if let enforced = launchConstraintsEnforced, enforced != 0 { return "launch-constraints-enforced" }
        return nil
    }

    func run() async {
        guard !started else { return }
        started = true
        let boot: String
        do {
            boot = try dependencies.bootSessionUUID()
            guard UUID(uuidString: boot) != nil else { throw PommeBuddyPreferencesSystem.issue("invalid-boot-identity") }
        } catch {
            dependencies.log("event=keystore-init-failed reason=boot-query", true)
            return
        }
        do {
            if let previous = try dependencies.load(), previous.bootSessionUUID == boot,
               PommeKeystoreInitStatus.outcomes.contains(previous.outcome) {
                // Never run twice in one boot, even after an agent restart.
                // An interrupted run is reported rather than repeated.
                receipt = previous.outcome == "running"
                    ? .init(bootSessionUUID: boot, outcome: "failed", reason: "interrupted-attempt")
                    : previous
                if previous.outcome == "running" { try dependencies.save(receipt!) }
                dependencies.log("event=keystore-init-receipt-reused outcome=\(receipt!.outcome)", false)
                return
            }
        } catch {
            receipt = .init(bootSessionUUID: boot, outcome: "failed", reason: Self.failureCode(error, fallback: "receipt-load-failed"))
            dependencies.log("event=keystore-init-failed reason=\(receipt!.reason!)", true)
            return
        }
        let flags: UInt32
        do { flags = try dependencies.rootMountFlags() }
        catch {
            record(.init(bootSessionUUID: boot, outcome: "failed", reason: Self.failureCode(error, fallback: "root-statfs")))
            return
        }
        if let reason = Self.skipReason(majorVersion: dependencies.majorVersion(), rootMountFlags: flags,
                                        launchConstraintsEnforced: dependencies.launchConstraintsEnforced()) {
            record(.init(bootSessionUUID: boot, outcome: "skipped", reason: reason))
            return
        }
        // A durable running receipt precedes the initializer, so a restarted
        // agent in this boot can't start a second one.
        guard record(.init(bootSessionUUID: boot, outcome: "running")) else { return }
        do {
            let status = try await dependencies.initialize()
            record(status == 0
                ? .init(bootSessionUUID: boot, outcome: "succeeded", exitStatus: status)
                : .init(bootSessionUUID: boot, outcome: "failed", reason: "exit-status", exitStatus: status))
        } catch {
            record(.init(bootSessionUUID: boot, outcome: "failed", reason: Self.failureCode(error, fallback: "initializer-failed")))
        }
    }

    @discardableResult
    private func record(_ status: PommeKeystoreInitStatus) -> Bool {
        receipt = status
        var message = "event=keystore-init-\(status.outcome)"
        if let reason = status.reason { message += " reason=\(reason)" }
        if let exit = status.exitStatus { message += " exit_code=\(exit)" }
        do { try dependencies.save(status) }
        catch {
            receipt = .init(bootSessionUUID: status.bootSessionUUID, outcome: "failed",
                            reason: Self.failureCode(error, fallback: "receipt-save-failed"))
            dependencies.log("event=keystore-init-failed reason=\(receipt!.reason!)", true)
            return false
        }
        dependencies.log(message, status.outcome == "failed")
        return true
    }

    private static func failureCode(_ error: any Error, fallback: String) -> String {
        guard let code = (error as? PommeBuddyPreferencesFailure)?.failureCode, !code.isEmpty, code.utf8.count <= 64,
              code.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else { return fallback }
        return code
    }

    static func log(_ message: String, _ isError: Bool) {
        let logger = Logger(subsystem: PommeUnifiedLog.subsystem, category: "keystore-init")
        if isError { logger.error("\(message, privacy: .public)") }
        else { logger.notice("\(message, privacy: .public)") }
    }
}
