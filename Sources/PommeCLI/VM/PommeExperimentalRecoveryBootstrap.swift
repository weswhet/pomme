import Foundation

/// Starts the existing request-bound launcher through the authenticated resident
/// terminal. The resident never receives installer or security authority.
enum PommeExperimentalRecoveryBootstrap {
    static func launch(
        coordinator: PommeAgentVSOCKCoordinator,
        executableSHA256: String,
        launcher: PommeLiveRecoveryIntegration.Launcher,
        timeout: TimeInterval
    ) async throws {
        let session = try await authenticate(coordinator: coordinator,
            executableSHA256: executableSHA256, timeout: timeout)
        guard launcher.expiresAt.timeIntervalSinceNow >= timeout
            + PommeLiveRecoveryIntegration.credentialAuthenticationReserve else {
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
            throw PommeAgentProtocol.Error.invalidResponse
        }
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
        while !coordinator.isAuthenticated(as: .recoveryResident) {
            guard Date() < deadline else { throw PommeRecoverySessionError.observationTimedOut }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try coordinator.captureAuthenticatedSession(as: .recoveryResident)
        let description = try await session.request(operation: "agent.describe")
        try validate(description: description, executableSHA256: executableSHA256)
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
