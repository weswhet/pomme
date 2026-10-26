import Foundation
import os

/// recoveryOS never acts on the framework's stop request, so every stop from
/// Recovery ends in a forced power-off. Powering off right after a security
/// change can lose it: 40 ms after `csrutil disable`, a macOS 27 guest hung at
/// the Apple logo on its next boot (October 25, 2026). Without a flush the
/// stop waits out the graceful window first.
///
/// A connected Recovery agent that offers a terminal (the experimental
/// image's resident, or the agent that ordinary terminal admission started)
/// can run `sync` instead. The kernel's sync waits for each file system to
/// write its data, so once it exits the host can power off at once. Older
/// pinned agents already run `/bin/sh`, so this needs no new guest operation.
enum PommeRecoveryFileSystemFlush {
    static let timeout: TimeInterval = 20
    private static let roles: [PommeAgentVSOCKRole] = [.recoveryResident, .recoveryRuntime]

    /// Returns true only when `sync` exited with status 0 in the guest. Any
    /// other outcome leaves the caller's ordinary stop in place. `timeout`
    /// bounds the wait for the resident and the sync together.
    static func run(
        coordinator: PommeAgentVSOCKCoordinator?,
        vmName: String,
        timeout: TimeInterval = Self.timeout
    ) async -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        guard let coordinator else { return false }
        // The resident starts with Recovery, so a stop soon after boot waits
        // for it. Ordinary Recovery connects an agent only for a terminal.
        while !roles.contains(where: { coordinator.isAuthenticated(as: $0) }),
              coordinator.isListening(for: .recoveryResident), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let role = roles.first(where: { coordinator.isAuthenticated(as: $0) }),
              let session = try? coordinator.captureAuthenticatedSession(as: role)
        else {
            PommeUnifiedLog.recovery.info("[\(vmName, privacy: .public)] no Recovery terminal agent is connected; stopping without a guest flush")
            return false
        }
        let sessionID = UUID().uuidString.lowercased()
        let command: [String: JSONValue] = [
            "path": .string("/bin/sh"), "arguments": .array([.string("-c"), .string("/bin/sync")]),
            "shell": .bool(false), "columns": .integer(80), "rows": .integer(24)
        ]
        var payload = command
        payload["sessionID"] = .string(sessionID)
        payload["sequence"] = .integer(0)
        payload["mutationDigest"] = .string(PommeTerminalMutationDigest.make(operation: "terminal.create", payload: command))
        do {
            _ = try await session.request(operation: "terminal.create", payload: .object(payload))
        } catch {
            PommeUnifiedLog.error(error, context: "Recovery file system flush", vmName: vmName, logger: PommeUnifiedLog.recovery)
            return false
        }
        while Date() < deadline {
            do {
                let status = try await session.request(operation: "terminal.status", payload: .object(["sessionID": .string(sessionID)]))
                if status.objectValue?["exited"] == .bool(true) {
                    _ = try? await session.request(operation: "terminal.release", payload: .object(["sessionID": .string(sessionID)]))
                    let elapsed = Date().timeIntervalSince(started)
                    guard case .integer(let exitCode)? = status.objectValue?["exitCode"], exitCode == 0 else {
                        let ending: String = switch (status.objectValue?["exitCode"], status.objectValue?["signal"]) {
                        case (.integer(let code)?, _): "exit \(code)"
                        case (_, .integer(let signal)?): "signal \(signal)"
                        default: "no status"
                        }
                        PommeUnifiedLog.recovery.error("[\(vmName, privacy: .public)] Recovery sync ended without success: \(ending, privacy: .public)")
                        return false
                    }
                    PommeUnifiedLog.recovery.notice("[\(vmName, privacy: .public)] Recovery file systems flushed through the \(String(describing: role), privacy: .public) agent in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
                    return true
                }
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                PommeUnifiedLog.error(error, context: "Recovery file system flush", vmName: vmName, logger: PommeUnifiedLog.recovery)
                return false
            }
        }
        PommeUnifiedLog.recovery.error("[\(vmName, privacy: .public)] Recovery sync didn't finish within \(timeout, privacy: .public)s")
        return false
    }
}
