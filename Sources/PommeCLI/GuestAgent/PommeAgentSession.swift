import Darwin
import Foundation

/// Transport-neutral host session. Integration supplies exact VSOCK I/O; this
/// type enforces request correlation and never retries a mutating operation.
actor PommeAgentSession {
    typealias Exchange = @Sendable (Data) async throws -> Data
    private let exchange: Exchange
    private let role: GuestAgentStatusV1.Role
    private let vmBinding: String?
    private let sessionBinding: String?
    private var authenticated = false
    private var streamFrames: [UUID: [PommeAgentJobStreamFrame]] = [:]

    init(
        exchange: @escaping Exchange,
        role: GuestAgentStatusV1.Role = .normal,
        vmBinding: String? = nil,
        sessionBinding: String? = nil
    ) {
        self.exchange = exchange
        self.role = role
        self.vmBinding = vmBinding
        self.sessionBinding = sessionBinding
    }

    func authenticate(token: String) async throws {
        guard !authenticated else { throw PommeAgentProtocol.Error.invalidRequest }
        let challenge = PommeAgentAuthentication.challenge()
        var payload: [String: JSONValue] = ["challenge": .string(challenge)]
        if let vmBinding { payload["vmID"] = .string(vmBinding) }
        if let sessionBinding { payload["sessionID"] = .string(sessionBinding) }
        let request = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(payload))
        let response = try await send(request)
        guard response.ok == true, let proof = response.result?.objectValue?["proof"]?.stringValue,
              try PommeAgentAuthentication.verifies(proof: proof, token: token, challenge: challenge)
        else { throw PommeAgentProtocol.Error.invalidResponse }
        authenticated = true
    }

    func request(operation: String, payload: JSONValue = .object([:]), requestID: UUID = UUID()) async throws -> JSONValue {
        guard authenticated else { throw PommeAgentProtocol.Error.invalidRequest }
        let request = PommeAgentProtocol.Envelope.request(operation: operation, payload: payload, requestID: requestID)
        let response = try await send(request)
        guard response.ok == true, let result = response.result else { throw PommeAgentProtocol.Error.invalidResponse }
        return result
    }

    func requestCorrelated(operation: String, payload: JSONValue = .object([:])) async throws -> (requestID: UUID, result: JSONValue) {
        guard authenticated else { throw PommeAgentProtocol.Error.invalidRequest }
        let request = PommeAgentProtocol.Envelope.request(operation: operation, payload: payload)
        let response = try await send(request)
        guard response.ok == true, let result = response.result else { throw PommeAgentProtocol.Error.invalidResponse }
        return (request.requestID, result)
    }

    /// The VM transport feeds every JSONL frame through this session. Stream
    /// events are retained by correlation ID, never mistaken for a response.
    func drainStreams(requestID: UUID) -> [PommeAgentJobStreamFrame] {
        defer { streamFrames.removeValue(forKey: requestID) }
        return streamFrames[requestID] ?? []
    }

    /// Send stdin/EOF/resize/signal for one job. Returned packets are only
    /// packets sharing this stream request ID; unrelated responses are invalid.
    func sendStream(jobID: UUID, stream: PommeAgentProtocol.Stream, requestID: UUID = UUID(), data: Data? = nil, dimensions: (columns: Int, rows: Int)? = nil, signal: Int32? = nil) async throws -> [PommeAgentJobStreamFrame] {
        guard authenticated else { throw PommeAgentProtocol.Error.invalidRequest }
        let outgoing = try PommeAgentJobStreamFrame(jobID: jobID, frame: .init(requestID: requestID, stream: stream, data: data, dimensions: dimensions, signal: signal))
        _ = try await ingest(try await exchange(PommeAgentProtocol.encode(outgoing.envelope())), expectedResponse: nil)
        return drainStreams(requestID: requestID)
    }

    private func send(_ request: PommeAgentProtocol.Envelope) async throws -> PommeAgentProtocol.Envelope {
        let data = try await exchange(PommeAgentProtocol.encode(request))
        guard let response = try await ingest(data, expectedResponse: request) else { throw PommeAgentProtocol.Error.invalidResponse }
        return response
    }

    private func ingest(_ data: Data, expectedResponse request: PommeAgentProtocol.Envelope?) async throws -> PommeAgentProtocol.Envelope? {
        var matched: PommeAgentProtocol.Envelope?
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let frame = try PommeAgentProtocol.decode(Data(rawLine))
            switch frame.kind {
            case .stream: streamFrames[frame.requestID, default: []].append(try PommeAgentJobStreamFrame(envelope: frame))
            case .response:
                guard let request, frame.requestID == request.requestID, frame.operation == request.operation, matched == nil else { throw PommeAgentProtocol.Error.invalidResponse }
                matched = frame
            case .request: throw PommeAgentProtocol.Error.invalidResponse
            }
        }
        if request == nil { return nil }
        guard let response = matched else { throw PommeAgentProtocol.Error.invalidResponse }
        return response
    }
}

extension PommeAgentSession: PommeAgentSessionProtocol {
    func status() async -> GuestAgentStatusV1? {
        guard authenticated else { return nil }
        return .init(
            connection: .connected,
            role: role,
            protocolVersion: PommeAgentProtocol.version,
            executableDigest: nil,
            capabilities: ["process", "file", "stream", "maintenance"],
            updateState: .unknown
        )
    }

    func perform(operation: String, payload: JSONValue?) async throws -> JSONValue {
        try await request(operation: operation, payload: payload ?? .object([:]))
    }

    func perform(
        operation: String,
        payload: JSONValue?,
        requestID: UUID
    ) async throws -> JSONValue {
        try await request(
            operation: operation,
            payload: payload ?? .object([:]),
            requestID: requestID
        )
    }

    func close() async { authenticated = false }
}

enum PommeAgentCredential {
    static func load(path: String, consume: Bool) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, info.st_gid == 0, info.st_mode & 0o077 == 0
        else { throw PommeAgentProtocol.Error.invalidRequest }
        let token = try PommeAgentAuthentication.normalized(String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines))
        if consume, unlink(path) != 0 { throw PommeAgentProtocol.Error.invalidRequest }
        return token
    }
}
