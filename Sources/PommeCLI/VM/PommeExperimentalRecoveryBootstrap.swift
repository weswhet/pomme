import Foundation
import os

/// Starts the existing request-bound launcher through the authenticated resident
/// terminal. The resident never receives installer or security authority.
enum PommeExperimentalRecoveryBootstrap {
    static func launch(
        coordinator: PommeAgentVSOCKCoordinator,
        executableSHA256: String,
        launcher: PommeLiveRecoveryIntegration.Launcher,
        timeout: TimeInterval
    ) async throws {
        PommeUnifiedLog.experimentalRecovery.notice("launching the request-bound Recovery launcher through the resident terminal")
        let session = try await authenticate(coordinator: coordinator,
            executableSHA256: executableSHA256, timeout: timeout)
        guard launcher.expiresAt.timeIntervalSinceNow >= timeout
            + PommeLiveRecoveryIntegration.credentialAuthenticationReserve else {
            PommeUnifiedLog.experimentalRecovery.error("Recovery launcher credential expires too soon to authenticate; refusing launch")
            throw PommeLiveRecoveryIntegration.Error.credentialRejected
        }
        let terminalID = UUID().uuidString.lowercased()
        let command: [String: JSONValue] = [
            "path": .string("/bin/sh"), "arguments": .array([.string("-c"), .string(launcher.command)]),
            "shell": .bool(false), "columns": .integer(120), "rows": .integer(40)
        ]
        var payload = command
        payload["sessionID"] = .string(terminalID)
        payload["sequence"] = .integer(0)
        payload["mutationDigest"] = .string(PommeTerminalMutationDigest.make(operation: "terminal.create", payload: command))
        let result = try await session.request(operation: "terminal.create", payload: .object(payload))
        guard let object = result.objectValue, object["sessionID"] == .string(terminalID),
              case .integer(let pid)? = object["pid"], pid > 0 else {
            PommeUnifiedLog.experimentalRecovery.error("resident terminal.create returned an invalid receipt for the Recovery launcher")
            throw PommeAgentProtocol.Error.invalidResponse
        }
        // The launcher command embeds a credential, so only the session and pid are logged.
        PommeUnifiedLog.experimentalRecovery.notice("Recovery launcher started: terminal=\(terminalID, privacy: .public) pid=\(pid, privacy: .public)")
        // The request-bound daemon remains the foreground child. The existing
        // Recovery root now authenticates that separate one-shot connection;
        // runtime teardown closes this terminal after its transaction finishes.
    }

    /// Shared by request bootstrap and ordinary Recovery terminal admission.
    /// No display observation, keyboard input, or temporary share is involved.
    static func authenticate(
        coordinator: PommeAgentVSOCKCoordinator,
        executableSHA256: String,
        timeout: TimeInterval
    ) async throws -> PommeAuthenticatedAgentSession {
        let deadline = Date().addingTimeInterval(timeout)
        PommeUnifiedLog.experimentalRecovery.info("waiting up to \(timeout, privacy: .public)s for the Recovery resident to authenticate")
        while !coordinator.isAuthenticated(as: .recoveryResident) {
            guard Date() < deadline else {
                PommeUnifiedLog.experimentalRecovery.error("Recovery resident did not authenticate within \(timeout, privacy: .public)s")
                throw PommeRecoverySessionError.observationTimedOut
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try coordinator.captureAuthenticatedSession(as: .recoveryResident)
        let description = try await session.request(operation: "agent.describe")
        do {
            try validate(description: description, executableSHA256: executableSHA256)
        } catch {
            let observed = description.objectValue?["executableSHA256"]?.stringValue ?? "none"
            PommeUnifiedLog.experimentalRecovery.error("""
                Recovery resident description mismatch: expectedSHA256=\(executableSHA256, privacy: .public) \
                observedSHA256=\(observed, privacy: .public) role=\(description.objectValue?["role"]?.stringValue ?? "none", privacy: .public)
                """)
            throw error
        }
        PommeUnifiedLog.experimentalRecovery.notice("Recovery resident authenticated and matched executableSHA256=\(executableSHA256, privacy: .public)")
        return session
    }

    static func validate(description: JSONValue, executableSHA256: String) throws {
        guard let value = description.objectValue,
              value["role"] == .string("recovery"),
              value["protocol"] == .string(PommeAgentProtocol.name),
              value["version"] == .integer(Int64(PommeAgentProtocol.version)),
              value["executableSHA256"] == .string(executableSHA256),
              value["terminalSessionVersion"] == .integer(Int64(PommeAgent.terminalSessionVersion)),
              case .array(let capabilities)? = value["capabilities"],
              capabilities.allSatisfy({ $0.stringValue != nil }),
              Set(capabilities.compactMap(\.stringValue)) == Set(PommeAgent.recoveryTerminalCapabilities) else {
            throw PommeLiveRecoveryIntegration.Error.executableMismatch
        }
    }
}
