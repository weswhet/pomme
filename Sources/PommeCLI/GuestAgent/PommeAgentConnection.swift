import Foundation

/// Connection state is deliberately independent of VSOCK so integration can
/// bind it to a persistent normal daemon or a bounded Recovery session.
final class PommeAgentConnection: @unchecked Sendable {
    enum CredentialLifetime: Sendable { case persistent, oneShot }

    private let token: String
    private let lifetime: CredentialLifetime
    private let expiresAt: Date?
    private let vmBinding: String?
    private let sessionBinding: String?
    private var authenticated = false
    private var consumed = false
    private var seenRequests: Set<UUID> = []
    var isAuthenticated: Bool { authenticated }
    var permitsStream: Bool { authenticated && !isExpired }
    private var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    /// Bind recovery credentials to the VM/session that minted them when that
    /// context is available.  Bindings are compared before the HMAC proof is
    /// emitted, so a valid secret is never an admission token for another VM.
    init(token: String, lifetime: CredentialLifetime, expiresAt: Date? = nil,
         vmBinding: String? = nil, sessionBinding: String? = nil) throws {
        self.token = try PommeAgentAuthentication.normalized(token)
        self.lifetime = lifetime
        self.expiresAt = expiresAt
        self.vmBinding = vmBinding
        self.sessionBinding = sessionBinding
    }

    func receive(
        _ line: Data,
        handler: (PommeAgentProtocol.Envelope) async throws -> JSONValue
    ) async -> Data {
        do {
            let request = try PommeAgentProtocol.decode(line)
            guard request.kind == .request else { throw PommeAgentProtocol.Error.invalidRequest }
            guard seenRequests.insert(request.requestID).inserted else {
                return try PommeAgentProtocol.encode(.failure(to: request, code: "replayed-request", message: "Request IDs are single use."))
            }
            let response: PommeAgentProtocol.Envelope
            if !authenticated {
                guard request.operation == "authenticate" else {
                    response = .failure(to: request, code: "authentication-required", message: "Authenticate before requesting an operation.")
                    return try PommeAgentProtocol.encode(response)
                }
                guard !isExpired,
                      !consumed,
                      let values = request.payload.objectValue,
                      let challenge = values["challenge"]?.stringValue,
                      (vmBinding == nil || values["vmID"]?.stringValue == vmBinding),
                      (sessionBinding == nil || values["sessionID"]?.stringValue == sessionBinding)
                else {
                    response = .failure(to: request, code: "authentication-rejected", message: "Authentication was rejected.")
                    return try PommeAgentProtocol.encode(response)
                }
                let proof = try PommeAgentAuthentication.proof(token: token, challenge: challenge)
                authenticated = true
                if lifetime == .oneShot { consumed = true }
                response = .response(to: request, result: .object(["proof": .string(proof)]))
            } else if request.operation == "authenticate" {
                response = .failure(to: request, code: "authentication-replayed", message: "Authentication has already completed.")
            } else if isExpired {
                response = .failure(to: request, code: "credential-expired", message: "The session credential has expired.")
            } else {
                do {
                    response = .response(to: request, result: try await handler(request))
                } catch {
                    response = .failure(to: request, code: operationCode(error), message: "The requested operation could not be completed.")
                }
            }
            return try PommeAgentProtocol.encode(response)
        } catch {
            // A malformed request has no reliable correlation value.  The
            // caller closes the connection rather than emitting an ambiguous
            // uncorrelated response.
            return Data()
        }
    }

    func resetForReconnect() {
        authenticated = false
        seenRequests.removeAll(keepingCapacity: true)
        // A Recovery credential cannot be replayed by a later connection.
        if lifetime == .oneShot { consumed = true }
    }

    private func operationCode(_ error: Error) -> String {
        if let recoveryError = error as? PommeGuestRecoverySecurityError {
            return recoveryError.recoveryFailureCode.rawValue
        }
        guard let operationError = error as? PommeAgentOperationError else { return "operation-failed" }
        switch operationError {
        case .unsupported: return "unsupported-operation"
        case .activationPending: return "activation-pending"
        case .invalid: return "invalid-operation"
        case .notFound: return "not-found"
        case .io: return "operation-failed"
        }
    }
}

struct PommeAgentStreamFrame: Equatable, Sendable {
    let requestID: UUID
    let stream: PommeAgentProtocol.Stream
    let data: Data?
    let dimensions: (columns: Int, rows: Int)?
    let signal: Int32?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestID == rhs.requestID
            && lhs.stream == rhs.stream
            && lhs.data == rhs.data
            && lhs.dimensions?.columns == rhs.dimensions?.columns
            && lhs.dimensions?.rows == rhs.dimensions?.rows
            && lhs.signal == rhs.signal
    }

    init(requestID: UUID, stream: PommeAgentProtocol.Stream, data: Data? = nil,
         dimensions: (columns: Int, rows: Int)? = nil, signal: Int32? = nil) throws {
        guard data?.count ?? 0 <= PommeAgentProtocol.maximumStreamChunkBytes else {
            throw PommeAgentProtocol.Error.invalidStream
        }
        if stream == .resize {
            guard data == nil, let dimensions, dimensions.columns > 0, dimensions.rows > 0 else {
                throw PommeAgentProtocol.Error.invalidStream
            }
        }
        if stream == .signal, data != nil { throw PommeAgentProtocol.Error.invalidStream }
        self.requestID = requestID; self.stream = stream; self.data = data
        self.dimensions = dimensions; self.signal = signal
    }

    init(envelope: PommeAgentProtocol.Envelope) throws {
        guard envelope.kind == .stream, let values = envelope.payload.objectValue,
              let name = values["stream"]?.stringValue, let stream = PommeAgentProtocol.Stream(rawValue: name) else { throw PommeAgentProtocol.Error.invalidStream }
        let data: Data?
        if let encoded = values["dataBase64"]?.stringValue { guard let decoded = Data(base64Encoded: encoded) else { throw PommeAgentProtocol.Error.invalidStream }; data = decoded } else { data = nil }
        let dimensions: (columns: Int, rows: Int)?
        if case .integer(let columns)? = values["columns"], case .integer(let rows)? = values["rows"], let column = Int(exactly: columns), let row = Int(exactly: rows) { dimensions = (column, row) } else { dimensions = nil }
        let signal: Int32?
        if case .integer(let raw)? = values["signal"], let value = Int32(exactly: raw) { signal = value } else { signal = nil }
        try self.init(requestID: envelope.requestID, stream: stream, data: data, dimensions: dimensions, signal: signal)
    }

    func envelope() -> PommeAgentProtocol.Envelope {
        var payload: [String: JSONValue] = ["stream": .string(stream.rawValue)]
        if let data { payload["dataBase64"] = .string(data.base64EncodedString()) }
        if let dimensions { payload["columns"] = .integer(Int64(dimensions.columns)); payload["rows"] = .integer(Int64(dimensions.rows)) }
        if let signal { payload["signal"] = .integer(Int64(signal)) }
        return .init(kind: .stream, requestID: requestID, operation: "stream.\(stream.rawValue)", payload: .object(payload))
    }
}

/// Public transport seam: every stream packet carries both the process job and
/// the request correlation. Hosts may multiplex packets without consuming a
/// neighbouring operation response.
struct PommeAgentJobStreamFrame: Equatable, Sendable {
    let jobID: UUID
    let frame: PommeAgentStreamFrame

    init(jobID: UUID, frame: PommeAgentStreamFrame) { self.jobID = jobID; self.frame = frame }

    init(envelope: PommeAgentProtocol.Envelope) throws {
        guard let values = envelope.payload.objectValue,
              let rawJobID = values["jobID"]?.stringValue, let jobID = UUID(uuidString: rawJobID) else { throw PommeAgentProtocol.Error.invalidStream }
        self.jobID = jobID; self.frame = try .init(envelope: envelope)
    }

    func envelope() -> PommeAgentProtocol.Envelope {
        var envelope = frame.envelope()
        var payload = envelope.payload.objectValue ?? [:]
        payload["jobID"] = .string(jobID.uuidString.lowercased())
        envelope = .init(kind: .stream, requestID: frame.requestID, operation: envelope.operation, payload: .object(payload))
        return envelope
    }
}
