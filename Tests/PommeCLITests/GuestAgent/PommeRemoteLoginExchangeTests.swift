import Foundation
import Testing

@Suite("Remote Login authenticated exchanges")
struct PommeRemoteLoginExchangeTests {
    @Test("Verified Remote Login state survives the authenticated exchange", arguments: [false, true])
    func verifiedState(enabled: Bool) async throws {
        let session = try await session(transaction: { requested in
            try PommeRemoteLogin.apply(enabled: requested) { arguments in
                if arguments == ["-getremotelogin"] {
                    return .init(stdout: "Remote Login: \(requested ? "On" : "Off")\n", stderr: "")
                }
                #expect(arguments == ["-f", "-setremotelogin", requested ? "on" : "off"])
                return .init(stdout: "", stderr: "")
            }
        })
        let result = try await session.request(
            operation: "remoteLogin.set",
            payload: .object(["enabled": .bool(enabled)])
        )
        #expect(result == .object(["enabled": .bool(enabled)]))
    }

    @Test("An unclassified transaction failure cannot become a success receipt")
    func transactionFailure() async throws {
        let session = try await session(transaction: { _ in throw PommeAgentOperationError.io })
        do {
            _ = try await session.request(
                operation: "remoteLogin.set",
                payload: .object(["enabled": .bool(true)])
            )
            Issue.record("A failed transaction returned a success receipt")
        } catch let failure as PommeAgentSessionError {
            #expect(failure.code == "operation-failed")
        }
    }

    @Test("Remote Login diagnostics survive real agent and host protocol boundaries")
    func actionableFailures() async throws {
        let cases: [(PommeAgentOperationError, String, String)] = [
            (.remoteLoginFullDiskAccessRequired, "remote-login-full-disk-access-required", "Full Disk Access"),
            (.remoteLoginVerificationFailed, "remote-login-verification-failed", "verif"),
        ]
        for (error, code, diagnostic) in cases {
            let session = try await session(transaction: { _ in throw error })
            do {
                _ = try await session.requestCorrelated(
                    operation: "remoteLogin.set",
                    payload: .object(["enabled": .bool(true)])
                )
                Issue.record("A failed Remote Login transaction returned a success receipt")
            } catch let failure as PommeAgentSessionError {
                #expect(failure.code == code)
                #expect(failure.message.localizedCaseInsensitiveContains(diagnostic))
            }
        }
    }

    private func session(
        transaction: @escaping @Sendable (Bool) throws -> Bool
    ) async throws -> PommeAgentSession {
        let token = String(repeating: "a", count: 64)
        let agent = try PommeAgent(
            role: .persistent,
            executableSHA256: String(repeating: "b", count: 64),
            remoteLoginTransaction: transaction
        )
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        let session = PommeAgentSession(exchange: { data in
            await connection.receive(Data(data.dropLast())) { request in
                try await agent.perform(request)
            }
        })
        try await session.authenticate(token: token)
        return session
    }
}
