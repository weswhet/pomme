import Foundation
import Testing

@Suite("Pomme agent session failures")
struct PommeAgentSessionFailureTests {
    @Test("request exposes a redacted, typed guest failure")
    func requestSurfacesRedactedGuestFailure() async throws {
        let harness = try SessionHarness { request in
            try encodedFailure(
                for: request,
                code: "not-found",
                message: "token=super-secret-value"
            )
        }
        try await harness.authenticate()

        let failure = try await captureGuestFailure {
            _ = try await harness.session.request(operation: "file.open")
        }

        #expect(failure.code == "not-found")
        #expect(failure.message == "The agent rejected the request.")
        #expect(failure.localizedDescription.contains(failure.message))
        #expect(!failure.localizedDescription.contains("super-secret-value"))
    }

    @Test("requestCorrelated exposes a typed guest failure and preserves safe text")
    func requestCorrelatedSurfacesGuestFailure() async throws {
        let harness = try SessionHarness { request in
            try encodedFailure(
                for: request,
                code: "unsupported-operation",
                message: "The requested operation is not available."
            )
        }
        try await harness.authenticate()

        let failure = try await captureGuestFailure {
            _ = try await harness.session.requestCorrelated(operation: "agent.health")
        }

        #expect(failure.code == "unsupported-operation")
        #expect(failure.message == "The requested operation is not available.")
        #expect(failure.localizedDescription.contains(failure.message))
        #expect(failure == failure)
    }

    @Test("A described operation failure keeps the inner code and carries its message")
    func describedFailureCarriesMessage() {
        let failure = PommeAgentConnection.operationFailure(
            PommeAgentOperationError.described(.notFound, message: "No such executable: /nonexistent/bin")
        )
        let plain = PommeAgentConnection.operationFailure(PommeAgentOperationError.notFound)
        let rendered = PommeAgentSessionError(code: failure.code, message: failure.message)

        #expect(failure.code == "not-found")
        #expect(failure.message == "No such executable: /nonexistent/bin")
        #expect(plain.message == "The requested operation could not be completed.")
        #expect(rendered.localizedDescription == "Pomme agent request failed (not-found): No such executable: /nonexistent/bin")
    }

    @Test("correlation failures remain protocol errors")
    func wrongCorrelationRemainsProtocolFailure() async throws {
        let harness = try SessionHarness { request in
            try encodedFailure(
                for: request,
                requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                code: "not-found",
                message: "safe message"
            )
        }
        try await harness.authenticate()

        await #expect(throws: PommeAgentProtocol.Error.invalidResponse) {
            _ = try await harness.session.request(operation: "file.open")
        }
    }

    @Test("malformed response envelopes remain protocol errors")
    func malformedResponseRemainsProtocolFailure() async throws {
        let harness = try SessionHarness { _ in
            Data(#"{"protocol":"PommeAgentProtocol"}"#.utf8)
        }
        try await harness.authenticate()

        await #expect(throws: PommeAgentProtocol.Error.invalidEnvelope) {
            _ = try await harness.session.requestCorrelated(operation: "agent.health")
        }
    }

    @Test("authentication failures remain protocol errors")
    func authenticationFailureRemainsProtocolFailure() async throws {
        let session = PommeAgentSession(exchange: { data in
            let request = try PommeAgentProtocol.decode(Data(data.dropLast()))
            return try encodedFailure(
                for: request,
                code: "authentication-rejected",
                message: "Authentication was rejected."
            )
        })

        await #expect(throws: PommeAgentProtocol.Error.invalidResponse) {
            try await session.authenticate(token: String(repeating: "a", count: 64))
        }
    }

    @Test("sendStream accepts an acknowledgement with no output frames")
    func sendStreamAcceptsZeroOutputAcknowledgement() async throws {
        let jobID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let harness = try SessionHarness { request in
            try PommeAgentProtocol.encode(.response(
                to: request,
                result: .object(["jobID": .string(jobID.uuidString.lowercased())])
            ))
        }
        try await harness.authenticate()

        let frames = try await harness.session.sendStream(
            jobID: jobID,
            stream: .stdin,
            requestID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            data: Data("input".utf8)
        )

        #expect(frames.isEmpty)
    }

    @Test("sendStream retains output before its acknowledgement")
    func sendStreamRetainsOutputBeforeAcknowledgement() async throws {
        let jobID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let harness = try SessionHarness { request in
            let output = try PommeAgentJobStreamFrame(
                jobID: jobID,
                frame: .init(requestID: request.requestID, stream: .stdout, data: Data("output".utf8))
            )
            var response = try PommeAgentProtocol.encode(output.envelope())
            response.append(contentsOf: try PommeAgentProtocol.encode(.response(
                to: request,
                result: .object(["jobID": .string(jobID.uuidString.lowercased())])
            )))
            return response
        }
        try await harness.authenticate()

        let frames = try await harness.session.sendStream(
            jobID: jobID,
            stream: .stdin,
            requestID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            data: Data("input".utf8)
        )

        #expect(frames.count == 1)
        #expect(frames.first?.jobID == jobID)
        #expect(frames.first?.frame.stream == .stdout)
        #expect(frames.first?.frame.data == Data("output".utf8))
    }

    @Test("sendStream exposes a valid failure as a typed guest error")
    func sendStreamSurfacesGuestFailure() async throws {
        let harness = try SessionHarness { request in
            try encodedFailure(
                for: request,
                code: "operation-failed",
                message: "secret token must not escape"
            )
        }
        try await harness.authenticate()

        let failure = try await captureGuestFailure {
            _ = try await harness.session.sendStream(
                jobID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
                stream: .eof,
                requestID: UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000000")!
            )
        }

        #expect(failure.code == "operation-failed")
        #expect(failure.message == "The agent rejected the request.")
        #expect(!failure.localizedDescription.contains("secret token"))
    }

    @Test("A closed Recovery failure code survives session redaction")
    func recoveryFailureCodeSurvivesRedaction() async throws {
        let wireCode = PommeRecoveryGuestFailureCode.rollbackFailed.rawValue
        let harness = try SessionHarness { request in
            try encodedFailure(
                for: request,
                code: wireCode,
                message: "password=must-never-escape"
            )
        }
        try await harness.authenticate()

        let failure = try await captureGuestFailure {
            _ = try await harness.session.request(operation: "amfi.disable")
        }

        #expect(failure.code == wireCode)
        #expect(PommeRecoveryGuestFailureCode(rawValue: failure.code) == .rollbackFailed)
        #expect(!failure.localizedDescription.contains("must-never-escape"))
    }

    @Test("Closed Remote Login failures retain actionable, redacted messages")
    func remoteLoginFailureCodeSurvivesRedaction() async throws {
        let expected = [
            ("remote-login-full-disk-access-required", "Full Disk Access is required to change Remote Login."),
            ("remote-login-verification-failed", "Remote Login could not be verified after the requested change.")
        ]
        for (code, message) in expected {
            let harness = try SessionHarness { request in
                try encodedFailure(for: request, code: code, message: message)
            }
            try await harness.authenticate()
            let failure = try await captureGuestFailure {
                _ = try await harness.session.request(operation: "remoteLogin.set")
            }
            #expect(failure.code == code)
            #expect(failure.message == message)
        }
    }

    @Test("Unknown Recovery failure codes retain the generic compatibility path")
    func unknownRecoveryFailureCodeIsGeneric() async throws {
        let harness = try SessionHarness { request in
            try encodedFailure(
                for: request,
                code: "recovery-not-allowlisted",
                message: "secret=must-never-escape"
            )
        }
        try await harness.authenticate()

        let failure = try await captureGuestFailure {
            _ = try await harness.session.request(operation: "amfi.disable")
        }

        #expect(failure.code == "guest-failure")
        #expect(!failure.localizedDescription.contains("must-never-escape"))
    }
}

private struct SessionHarness {
    let token: String
    let session: PommeAgentSession

    init(
        response: @escaping @Sendable (PommeAgentProtocol.Envelope) throws -> Data
    ) throws {
        let token = String(repeating: "a", count: 64)
        self.token = token
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        session = PommeAgentSession(exchange: { data in
            let request = try PommeAgentProtocol.decode(Data(data.dropLast()))
            if request.operation == "authenticate" {
                return await connection.receive(Data(data.dropLast())) { _ in .object([:]) }
            }
            return try response(request)
        })
    }

    func authenticate() async throws {
        try await session.authenticate(token: token)
    }
}

private enum SessionFailureTestError: Error {
    case didNotThrow
    case unexpected(Error)
}

private func captureGuestFailure(
    _ operation: () async throws -> Void
) async throws -> PommeAgentSessionError {
    do {
        try await operation()
        throw SessionFailureTestError.didNotThrow
    } catch let failure as PommeAgentSessionError {
        return failure
    } catch {
        throw SessionFailureTestError.unexpected(error)
    }
}

private func encodedFailure(
    for request: PommeAgentProtocol.Envelope,
    requestID: UUID? = nil,
    code: String,
    message: String
) throws -> Data {
    let object: [String: Any] = [
        "protocol": PommeAgentProtocol.name,
        "version": PommeAgentProtocol.version,
        "kind": "response",
        "requestID": (requestID ?? request.requestID).uuidString.lowercased(),
        "operation": request.operation,
        "payload": [String: Any](),
        "ok": false,
        // JSONSerialization deliberately bypasses PommeAgentProtocol.Failure's
        // redacting initializer so the session must re-wrap decoded failures.
        "error": ["code": code, "message": message]
    ]
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    return data
}
