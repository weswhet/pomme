import Foundation
import Testing

@Suite("Pomme agent protocol v1")
struct PommeAgentProtocolTests {
    @Test("The envelope is strict, bounded, correlated, and newline-delimited")
    func envelope() throws {
        let request = PommeAgentProtocol.Envelope.request(operation: "agent.describe")
        let line = try PommeAgentProtocol.encode(request)
        #expect(line.last == 0x0A)
        #expect(try PommeAgentProtocol.decode(Data(line.dropLast())) == request)
        #expect(throws: PommeAgentProtocol.Error.invalidEnvelope) {
            try PommeAgentProtocol.decode(Data(#"{"protocol":"PommeAgentProtocol","version":1,"kind":"request","requestID":"00000000-0000-0000-0000-000000000000","operation":"agent.describe","payload":{},"extra":true}"#.utf8))
        }
        #expect(throws: PommeAgentProtocol.Error.duplicateKey) {
            try PommeAgentProtocol.decode(Data(#"{"protocol":"PommeAgentProtocol","protocol":"PommeAgentProtocol","version":1,"kind":"request","requestID":"00000000-0000-0000-0000-000000000000","operation":"agent.describe","payload":{}}"#.utf8))
        }
        #expect(throws: PommeAgentProtocol.Error.frameTooLarge) {
            try PommeAgentProtocol.decode(Data(repeating: 0x20, count: PommeAgentProtocol.maximumFrameBytes))
        }
    }

    @Test("Authentication is first, HMAC-based, and replay-safe")
    func authentication() async throws {
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .oneShot)
        let ordinary = PommeAgentProtocol.Envelope.request(operation: "agent.health")
        let blocked = try #require(PommeAgentProtocol.decode(Data((await connection.receive(try PommeAgentProtocol.encode(ordinary).dropLast()) { _ in .object([:]) }).dropLast())))
        #expect(blocked.error?.code == "authentication-required")
        let auth = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(["challenge": .string(String(repeating: "b", count: 64))]))
        let accepted = try PommeAgentProtocol.decode(Data((await connection.receive(try PommeAgentProtocol.encode(auth).dropLast()) { _ in .object([:]) }).dropLast()))
        #expect(accepted.ok == true)
        let replay = try PommeAgentProtocol.decode(Data((await connection.receive(try PommeAgentProtocol.encode(auth).dropLast()) { _ in .object([:]) }).dropLast()))
        #expect(replay.error?.code == "replayed-request")
        connection.resetForReconnect()
        let second = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: auth.payload)
        let rejected = try PommeAgentProtocol.decode(Data((await connection.receive(try PommeAgentProtocol.encode(second).dropLast()) { _ in .object([:]) }).dropLast()))
        #expect(rejected.error?.code == "authentication-rejected")
    }

    @Test("Stream chunks and file chunks have independent hard limits")
    func limits() throws {
        #expect(throws: PommeAgentProtocol.Error.invalidStream) {
            try PommeAgentStreamFrame(requestID: UUID(), stream: .stdout, data: Data(repeating: 1, count: PommeAgentProtocol.maximumStreamChunkBytes + 1))
        }
        #expect(PommeAgentProtocol.maximumFileChunkBytes == 32 * 1024)
    }

    @Test("Operation names and authentication tokens remain ASCII strict")
    func asciiValidation() {
        let operation = PommeAgentProtocol.Envelope.request(operation: "agent.café")
        #expect(throws: PommeAgentProtocol.Error.invalidOperation) {
            try operation.validate()
        }

        // Two-byte `é` keeps this input at the exact 64-byte token length, so
        // the rejection verifies the ASCII hex check rather than only length.
        let nonASCIIHex = String(repeating: "a", count: 62) + "é"
        #expect(throws: PommeAgentProtocol.Error.invalidRequest) {
            try PommeAgentAuthentication.normalized(nonASCIIHex)
        }
    }

    @Test("Recovery credentials expire and honor VM/session binding")
    func recoveryBinding() async throws {
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .oneShot, expiresAt: Date(timeIntervalSinceNow: 60), vmBinding: "vm-a", sessionBinding: "session-a")
        let wrong = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(["challenge": .string(String(repeating: "b", count: 64)), "vmID": .string("vm-b"), "sessionID": .string("session-a")]))
        let rejected = try PommeAgentProtocol.decode(Data((await connection.receive(try PommeAgentProtocol.encode(wrong).dropLast()) { _ in .object([:]) }).dropLast()))
        #expect(rejected.error?.code == "authentication-rejected")
        let expired = try PommeAgentConnection(token: token, lifetime: .oneShot, expiresAt: Date(timeIntervalSinceNow: -1))
        let request = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(["challenge": .string(String(repeating: "b", count: 64))]))
        let expiredReply = try PommeAgentProtocol.decode(Data((await expired.receive(try PommeAgentProtocol.encode(request).dropLast()) { _ in .object([:]) }).dropLast()))
        #expect(expiredReply.error?.code == "authentication-rejected")
    }

    @Test("Recovery host sessions send their VM and request bindings at authentication")
    func recoverySessionSendsBindings() async throws {
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(
            token: token,
            lifetime: .oneShot,
            expiresAt: Date(timeIntervalSinceNow: 60),
            vmBinding: "vm-a",
            sessionBinding: "session-a"
        )
        let session = PommeAgentSession(
            exchange: { request in
                await connection.receive(Data(request.dropLast())) { _ in .object([:]) }
            },
            role: .recovery,
            vmBinding: "vm-a",
            sessionBinding: "session-a"
        )
        try await session.authenticate(token: token)
        #expect(await session.status()?.role == .recovery)
    }

    @Test("Recovery operation preserves the immutable request correlation ID")
    func recoveryOperationPreservesRequestID() async throws {
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(
            token: token,
            lifetime: .oneShot,
            expiresAt: Date(timeIntervalSinceNow: 60),
            vmBinding: "vm-a",
            sessionBinding: "session-a"
        )
        let recorder = AgentRequestIDRecorder()
        let session = PommeAgentSession(
            exchange: { bytes in
                let request = try PommeAgentProtocol.decode(Data(bytes.dropLast()))
                if request.operation != "authenticate" {
                    await recorder.append(request.requestID)
                }
                return await connection.receive(Data(bytes.dropLast())) { _ in
                    .object(["accepted": .bool(true)])
                }
            },
            role: .recovery,
            vmBinding: "vm-a",
            sessionBinding: "session-a"
        )
        try await session.authenticate(token: token)
        let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let protocolSession: any PommeAgentSessionProtocol = session

        let result = try await protocolSession.perform(
            operation: "agent.install",
            payload: .object([:]),
            requestID: requestID
        )

        #expect(result.objectValue?["accepted"] == .bool(true))
        #expect(await recorder.values == [requestID])
    }

    @Test("Authenticated handler errors remain correlated and redacted")
    func correlatedOperationFailure() async throws {
        let connection = try PommeAgentConnection(token: String(repeating: "a", count: 64), lifetime: .persistent)
        let auth = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(["challenge": .string(String(repeating: "b", count: 64))]))
        _ = await connection.receive(try PommeAgentProtocol.encode(auth).dropLast()) { _ in .object([:]) }
        let request = PommeAgentProtocol.Envelope.request(operation: "file.open")
        let line = await connection.receive(try PommeAgentProtocol.encode(request).dropLast()) { _ in throw PommeAgentOperationError.notFound }
        let response = try PommeAgentProtocol.decode(Data(line.dropLast()))
        #expect(response.requestID == request.requestID)
        #expect(response.ok == false)
        #expect(response.error?.code == "not-found")
        #expect(response.result == nil)
    }

    @Test("Remote Login failures expose only closed, actionable codes and messages")
    func remoteLoginFailureIsClosedAndActionable() async throws {
        let connection = try PommeAgentConnection(token: String(repeating: "a", count: 64), lifetime: .persistent)
        let auth = PommeAgentProtocol.Envelope.request(
            operation: "authenticate",
            payload: .object(["challenge": .string(String(repeating: "b", count: 64))])
        )
        _ = await connection.receive(try PommeAgentProtocol.encode(auth).dropLast()) { _ in .object([:]) }

        let expected: [(PommeAgentOperationError, String, String)] = [
            (.remoteLoginFullDiskAccessRequired,
             "remote-login-full-disk-access-required",
             "Full Disk Access is required to change Remote Login."),
            (.remoteLoginVerificationFailed,
             "remote-login-verification-failed",
             "Remote Login could not be verified after the requested change.")
        ]
        for (error, code, message) in expected {
            let request = PommeAgentProtocol.Envelope.request(operation: "remoteLogin.set")
            let line = await connection.receive(try PommeAgentProtocol.encode(request).dropLast()) { _ in throw error }
            let response = try PommeAgentProtocol.decode(Data(line.dropLast()))
            #expect(response.error?.code == code)
            #expect(response.error?.message == message)
            #expect(response.error?.message.contains("Full Disk Access") == (code == "remote-login-full-disk-access-required"))
        }
    }

    @Test("Recovery security errors use a closed code and fixed protocol message")
    func recoverySecurityFailureIsClosed() async throws {
        let connection = try PommeAgentConnection(
            token: String(repeating: "a", count: 64), lifetime: .persistent)
        let auth = PommeAgentProtocol.Envelope.request(
            operation: "authenticate",
            payload: .object(["challenge": .string(String(repeating: "b", count: 64))])
        )
        _ = await connection.receive(try PommeAgentProtocol.encode(auth).dropLast()) { _ in .object([:]) }
        let request = PommeAgentProtocol.Envelope.request(operation: "amfi.disable")
        let line = await connection.receive(try PommeAgentProtocol.encode(request).dropLast()) { _ in
            throw PommeGuestRecoverySecurityError.rollbackFailed
        }
        let response = try PommeAgentProtocol.decode(Data(line.dropLast()))
        #expect(response.error?.code == PommeRecoveryGuestFailureCode.rollbackFailed.rawValue)
        #expect(response.error?.message == "The requested operation could not be completed.")
        #expect(response.error?.message.contains("rollback") == false)
    }
}

private actor AgentRequestIDRecorder {
    private(set) var values: [UUID] = []

    func append(_ value: UUID) { values.append(value) }
}
