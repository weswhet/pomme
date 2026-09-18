import Darwin
import Foundation
import Synchronization

/// The host helper's bounded JSONL protocol. This is intentionally independent
/// of the guest agent protocol and has no compatibility decoder.
enum PommeControlProtocol {
    static let version = 1
    static let maximumFrameBytes = 256 * 1_024
    static let maximumStreamChunkBytes = 64 * 1_024
}

enum PommeControlFeature: String, Codable, CaseIterable, Sendable {
    case lifecycle
    case status
    case streaming
    case ui
    case terminalSessions
}

struct PommeControlHello: Codable, Equatable, Sendable {
    let type: String
    let protocolVersion: Int
    let features: [PommeControlFeature]

    init(features: [PommeControlFeature] = [.lifecycle, .status, .streaming, .ui]) {
        type = "hello"
        protocolVersion = PommeControlProtocol.version
        self.features = features
    }
}

struct PommeControlRequest: Codable, Equatable, Sendable {
    let type: String
    let protocolVersion: Int
    let id: UUID
    let command: String
    let payload: JSONValue?
    let streaming: Bool?

    init(id: UUID = UUID(), command: String, payload: JSONValue? = nil, streaming: Bool = false) {
        type = "request"
        protocolVersion = PommeControlProtocol.version
        self.id = id
        self.command = command
        self.payload = payload
        self.streaming = streaming ? true : nil
    }
}

struct PommeControlError: Codable, Equatable, Error, Sendable {
    let code: String
    let message: String
}

struct PommeControlResponse: Codable, Equatable, Sendable {
    let type: String
    let protocolVersion: Int
    let id: UUID
    let ok: Bool
    let result: JSONValue?
    let error: PommeControlError?

    static func success(id: UUID, result: JSONValue) -> Self {
        .init(type: "response", protocolVersion: PommeControlProtocol.version, id: id, ok: true, result: result, error: nil)
    }

    static func failure(id: UUID, code: String, message: String) -> Self {
        .init(type: "response", protocolVersion: PommeControlProtocol.version, id: id, ok: false, result: nil, error: .init(code: code, message: message))
    }
}

/// Every streaming frame is correlated with exactly one request. Binary data
/// remains base64 in JSONL so framing stays bounded and inspectable.
struct PommeControlStreamFrame: Codable, Equatable, Sendable {
    enum Stream: String, Codable, Sendable {
        case stdin, stdout, stderr, resize, signal, cancellation, progress
    }

    let type: String
    let protocolVersion: Int
    let id: UUID
    let sequence: UInt64
    let stream: Stream
    let dataBase64: String?
    let payload: JSONValue?
    let eof: Bool?

    init(id: UUID, sequence: UInt64, stream: Stream, data: Data? = nil, payload: JSONValue? = nil, eof: Bool? = nil) {
        type = "stream"
        protocolVersion = PommeControlProtocol.version
        self.id = id
        self.sequence = sequence
        self.stream = stream
        dataBase64 = data?.base64EncodedString()
        self.payload = payload
        self.eof = eof
    }

    func decodedData() throws -> Data? {
        guard let dataBase64 else { return nil }
        guard let data = Data(base64Encoded: dataBase64), data.count <= PommeControlProtocol.maximumStreamChunkBytes else {
            throw RunnerError.invalidControlResponse("Pomme stream data must be valid base64 and at most \(PommeControlProtocol.maximumStreamChunkBytes) bytes.")
        }
        return data
    }

    func validate() throws {
        guard type == "stream", protocolVersion == PommeControlProtocol.version else {
            throw RunnerError.invalidControlResponse("Expected a Pomme control v\(PommeControlProtocol.version) stream envelope.")
        }
        _ = try decodedData()
        switch stream {
        case .stdin, .stdout, .stderr:
            guard payload == nil, dataBase64 != nil || eof == true else { throw RunnerError.invalidControlResponse("Pomme stdio frames require data or EOF.") }
        case .resize, .signal, .progress:
            guard dataBase64 == nil, eof != true, payload?.objectValue != nil else { throw RunnerError.invalidControlResponse("Pomme \(stream.rawValue) frames require an object payload.") }
        case .cancellation:
            guard dataBase64 == nil, eof != true, payload == nil else { throw RunnerError.invalidControlResponse("Pomme cancellation frames carry no data or payload.") }
        }
    }
}

/// A server-side stream produces zero or more correlated output frames and
/// exactly one terminal response.  Both envelopes are read from the same
/// JSONL reader so a response coalesced with the final output frame cannot be
/// mistaken for another stream frame or stranded in a second reader.
enum PommeControlStreamEvent: Equatable, Sendable {
    case stream(PommeControlStreamFrame)
    case response(PommeControlResponse)
}

struct PommeControlStreamSequenceValidator: Sendable {
    private let id: UUID
    private var nextSequence: UInt64 = 0

    init(id: UUID) { self.id = id }

    mutating func accept(_ frame: PommeControlStreamFrame) throws {
        try frame.validate()
        guard frame.id == id, frame.sequence == nextSequence, nextSequence < UInt64.max else {
            throw RunnerError.invalidControlResponse("Pomme stream correlation or ordering failed.")
        }
        nextSequence += 1
    }

    var nextExpectedSequence: UInt64 { nextSequence }
}

final class PommeControlStreamSession: @unchecked Sendable {
    private struct ReceiveState: Sendable {
        var finalResponse: PommeControlResponse?

        init() {
            finalResponse = nil
        }
    }

    private struct OutboundState: Sendable {
        var validator: PommeControlStreamSequenceValidator
        var inputClosed: Bool

        init(id: UUID) {
            validator = .init(id: id)
            inputClosed = false
        }
    }

    let id: UUID
    private let fileDescriptor: Int32
    private let reader: Mutex<ControlWireCodec.FrameReader>
    private let receiveLock: Mutex<ReceiveState>
    private let inbound: Mutex<PommeControlStreamSequenceValidator>
    private let outbound: Mutex<OutboundState>

    init(id: UUID, fileDescriptor: Int32, reader: ControlWireCodec.FrameReader = .init()) {
        self.id = id
        self.fileDescriptor = fileDescriptor
        self.reader = .init(reader)
        receiveLock = .init(.init())
        inbound = .init(.init(id: id))
        outbound = .init(.init(id: id))
    }

    func receive() throws -> PommeControlStreamFrame {
        switch try receiveEvent() {
        case .stream(let frame):
            return frame
        case .response:
            throw RunnerError.invalidControlResponse("Pomme control stream reached its terminal response.")
        }
    }

    /// Reads one inbound stream frame with a bounded wait. A security PTY
    /// uses this after forwarding a password prompt so a silent control client
    /// cannot hold the guest process beyond the runner's cleanup deadline.
    func receive(timeout: TimeInterval) throws -> PommeControlStreamFrame {
        guard let event = try receiveEventIfAvailable(timeout: timeout) else {
            throw RunnerError.invalidControlResponse("Pomme control stream receive timed out.")
        }
        switch event {
        case .stream(let frame): return frame
        case .response:
            throw RunnerError.invalidControlResponse("Pomme control stream reached its terminal response.")
        }
    }

    /// Returns no frame when the bounded wait elapsed.  Long-lived terminal
    /// relays use this to continue draining their guest process while the
    /// caller has not typed another byte.
    func receiveIfAvailable(timeout: TimeInterval) throws -> PommeControlStreamFrame? {
        guard let event = try receiveEventIfAvailable(timeout: timeout) else { return nil }
        switch event {
        case .stream(let frame): return frame
        case .response:
            throw RunnerError.invalidControlResponse("Pomme control stream reached its terminal response.")
        }
    }

    func send(stream: PommeControlStreamFrame.Stream, data: Data? = nil, payload: JSONValue? = nil, eof: Bool? = nil) throws {
        try outbound.withLock { state in
            guard !state.inputClosed else {
                throw RunnerError.invalidControlResponse("Pomme control stream input is already closed.")
            }
            let frame = PommeControlStreamFrame(id: id, sequence: state.validator.nextExpectedSequence, stream: stream, data: data, payload: payload, eof: eof)
            try state.validator.accept(frame)
            try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(frame), to: fileDescriptor)
        }
    }

    func send(_ frame: PommeControlStreamFrame) throws {
        try outbound.withLock { state in
            guard !state.inputClosed else {
                throw RunnerError.invalidControlResponse("Pomme control stream input is already closed.")
            }
            try state.validator.accept(frame)
            try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(frame), to: fileDescriptor)
        }
    }

    /// Half-closes the client-to-helper direction while keeping the helper's
    /// output direction available for stream events and the terminal response.
    /// It is idempotent so callers may close input before collecting output or
    /// use `finish()` as the one-shot convenience operation.
    func closeInput() throws {
        try outbound.withLock { state in
            guard !state.inputClosed else { return }
            let result = Darwin.shutdown(fileDescriptor, SHUT_WR)
            guard result == 0 || errno == ENOTCONN else { try throwPOSIX("shutdown") }
            state.inputClosed = true
        }
    }

    /// Reads the next validated correlated server event.  The final response
    /// is terminal: no subsequent read is permitted, even if another JSONL
    /// envelope is already buffered on the socket.
    func receiveEvent() throws -> PommeControlStreamEvent {
        try receiveLock.withLock { state in
            guard state.finalResponse == nil else {
                throw RunnerError.invalidControlResponse("Pomme control stream was already terminated.")
            }
            let data = try reader.withLock { try $0.readFrame(from: fileDescriptor) }
            switch ControlWireCodec.envelopeType(in: data) {
            case "stream":
                let frame = try ControlWireCodec.decodeStreamFrame(data)
                try inbound.withLock { try $0.accept(frame) }
                return .stream(frame)
            case "response":
                let response = try ControlWireCodec.decodeResponse(data, matching: id)
                state.finalResponse = response
                return .response(response)
            default:
                throw RunnerError.invalidControlResponse("Expected a Pomme control stream or response envelope.")
            }
        }
    }

    func receiveEvent(timeout: TimeInterval) throws -> PommeControlStreamEvent {
        guard let event = try receiveEventIfAvailable(timeout: timeout) else {
            throw RunnerError.invalidControlResponse("Pomme control stream receive timed out.")
        }
        return event
    }

    /// Returns no event when the bounded wait elapsed without changing stream
    /// state.  This keeps a PTY bidirectional: host input can be idle while
    /// guest output and status continue to make progress.
    func receiveEventIfAvailable(timeout: TimeInterval) throws -> PommeControlStreamEvent? {
        guard timeout.isFinite, timeout > 0 else {
            throw RunnerError.invalidControlResponse("Pomme control stream timeout is invalid.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return try receiveLock.withLock { state in
            guard state.finalResponse == nil else {
                throw RunnerError.invalidControlResponse("Pomme control stream was already terminated.")
            }
            let data: Data?
            do {
                data = try reader.withLock { reader in
                    if reader.hasCompleteFrame {
                        return try reader.readFrame(from: fileDescriptor)
                    }
                    return try reader.readFrame(from: fileDescriptor, deadline: deadline)
                }
            } catch let error as POSIXError where error.code == .ETIMEDOUT {
                // A partial JSONL frame stays buffered inside FrameReader and
                // remains subject to the caller's next bounded deadline.
                return nil
            }
            guard let data else { return nil }
            switch ControlWireCodec.envelopeType(in: data) {
            case "stream":
                let frame = try ControlWireCodec.decodeStreamFrame(data)
                try inbound.withLock { try $0.accept(frame) }
                return .stream(frame)
            case "response":
                let response = try ControlWireCodec.decodeResponse(data, matching: id)
                state.finalResponse = response
                return .response(response)
            default:
                throw RunnerError.invalidControlResponse("Expected a Pomme control stream or response envelope.")
            }
        }
    }

    func receiveResponse() throws -> PommeControlResponse {
        switch try receiveEvent() {
        case .response(let response):
            return response
        case .stream:
            throw RunnerError.invalidControlResponse("Expected the Pomme control stream's terminal response.")
        }
    }
}

enum PommeLifecycleCommand: String, Sendable {
    case pause
    case resume
    case stop
    case forceStop = "force-stop"
}

struct PommeSnapshotSaveRequest: Sendable {
    let stageName: String

    static func parse(from object: [String: Any]) throws -> Self {
        guard let stageName = object["stageName"] as? String, !stageName.isEmpty, stageName.count <= 256, !stageName.contains("/"), stageName != ".", stageName != ".." else {
            throw RunnerError.invalidControlCommand("snapshot-save")
        }
        return .init(stageName: stageName)
    }
}

/// A validated host-display request. UI is deliberately a helper capability,
/// not a guest-agent operation: the runtime delivers it through the private
/// Virtualization HID/framebuffer bridge.
struct PommeUIControlRequest: Sendable {
    static let maximumTimeout: TimeInterval = 300
    static let maximumKeyNameLength = 64
    static let maximumKeyCount = 256
    static let maximumTextBytes = 64 * 1024
    static let maximumPathLength = 4_096

    let operation: GuestUIOperation
    let agentPayload: [String: JSONValue]
    let timeout: TimeInterval
    let hostOutputPath: String?

    static func parse(from object: [String: JSONValue]) throws -> Self {
        let nestedPayload = object["agentPayload"]?.objectValue
        let operationName = object["operation"]?.stringValue
            ?? nestedPayload?["operation"]?.stringValue
        guard let operationName,
              let operation = GuestUIOperation(rawValue: operationName)
        else {
            throw RunnerError.invalidUICommand("guest-ui requires a valid operation.")
        }

        var payload = nestedPayload ?? object.filter {
            !["operation", "timeout", "hostOutputPath", "agentBinaryPath", "agentPayload"].contains($0.key)
        }
        if let payloadOperation = payload["operation"]?.stringValue,
           payloadOperation != operation.rawValue {
            throw RunnerError.invalidUICommand("guest-ui operation and payload operation disagree.")
        }
        payload["operation"] = .string(operation.rawValue)

        let timeout = timeoutValue(from: object)
        guard timeout.isFinite, timeout > 0, timeout <= maximumTimeout else {
            throw RunnerError.invalidUICommand("guest-ui timeout must be finite, greater than zero, and at most \(Int(maximumTimeout)) seconds.")
        }

        let hostOutputPath: String?
        if let value = object["hostOutputPath"] {
            guard case .string(let path) = value,
                  !path.isEmpty,
                  path.utf8.count <= maximumPathLength,
                  path.hasPrefix("/"),
                  !path.contains("\0")
            else {
                throw RunnerError.invalidUICommand("guest-ui hostOutputPath must be an absolute path of at most \(maximumPathLength) bytes.")
            }
            hostOutputPath = path
        } else {
            hostOutputPath = nil
        }

        switch operation {
        case .key:
            try validateKey(payload["key"]?.stringValue)
        case .keySequence:
            guard let values = payload["keys"]?.arrayValue,
                  !values.isEmpty,
                  values.count <= maximumKeyCount
            else { throw RunnerError.invalidUICommand("guest-ui key-sequence requires 1-\(maximumKeyCount) keys.") }
            for value in values { try validateKey(value.stringValue) }
        case .type:
            guard let text = payload["text"]?.stringValue,
                  text.utf8.count <= maximumTextBytes
            else { throw RunnerError.invalidUICommand("guest-ui text must be at most \(maximumTextBytes) UTF-8 bytes.") }
            if let replace = payload["replace"], case .bool = replace {
                // The optional flag has the expected JSON type.
            } else if payload["replace"] != nil {
                throw RunnerError.invalidUICommand("guest-ui type replace must be a Boolean.")
            }
        case .click:
            guard let x = numberValue(payload["x"]),
                  let y = numberValue(payload["y"]),
                  x.isFinite,
                  y.isFinite,
                  abs(x) <= 1_000_000,
                  abs(y) <= 1_000_000
            else { throw RunnerError.invalidUICommand("guest-ui click coordinates must be finite numbers within bounds.") }
        case .screenshot:
            guard hostOutputPath != nil else {
                throw RunnerError.invalidUICommand("guest-ui screenshot requires hostOutputPath.")
            }
        case .settingsAI:
            // The existing planner depends on a guest/host accessibility
            // bridge that is intentionally outside this direct HID boundary.
            throw RunnerError.invalidUICommand(PommeUICapabilities.settingsAIUnavailableReason)
        }

        return .init(
            operation: operation,
            agentPayload: payload,
            timeout: timeout,
            hostOutputPath: hostOutputPath
        )
    }

    private static func timeoutValue(from object: [String: JSONValue]) -> TimeInterval {
        guard let value = object["timeout"] else { return Constants.defaultGuestCommandTimeout }
        switch value {
        case .integer(let value): return TimeInterval(value)
        case .number(let value): return value
        case .string(let value): return TimeInterval(value) ?? .nan
        default: return .nan
        }
    }

    private static func numberValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    private static func validateKey(_ value: String?) throws {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= maximumKeyNameLength,
              !value.contains("\0")
        else { throw RunnerError.invalidUICommand("guest-ui key names must be non-empty and at most \(maximumKeyNameLength) bytes.") }
    }
}

/// Closed forwarding boundary for public agent operations. The helper never
/// accepts an arbitrary shell/control operation over its local socket.
struct PommeAgentPerformRequest: Sendable {
    let operation: String
    let payload: JSONValue?

    static func parse(from object: [String: JSONValue]) throws -> Self {
        guard let operation = object["operation"]?.stringValue,
              operation.count <= 128,
              allowed(operation)
        else { throw RunnerError.invalidControlCommand("agent.perform") }
        let payload = object["payload"]
        if let payload, payload.objectValue == nil { throw RunnerError.invalidControlCommand("agent.perform") }
        return .init(operation: operation, payload: payload)
    }

    private static func allowed(_ operation: String) -> Bool {
        let exact: Set<String> = [
            "agent.describe", "agent.health", "system.info", "network.interfaces",
            "amfi.normal.disable", "amfi.normal.enable",
            "amfi.normal.verifyDisabled", "amfi.normal.verifyEnabled",
            // Read-only AMFI inspection from a normal boot, so a caller does
            // not spend a Recovery session to learn a state this reports.
            "amfi.normal.status",
            // Recovers the automatic-login owner credential Pomme configured,
            // for a VM cloned from a provisioned template. Root-only and
            // bounded inside the agent; it is named exactly, never by prefix.
            "owner.credential.read"
        ]
        let prefixes = ["process.", "file.", "job.", "maintenance.", "remoteLogin.", "mdm.", "ui."]
        return exact.contains(operation) || prefixes.contains(where: operation.hasPrefix)
    }
}

enum PommeVMControlRequest: Sendable {
    /// `guestShutdownRequested` is true when the host has already asked the
    /// guest to shut itself down, which is the only case where waiting out the
    /// long window can pay off.
    case lifecycle(PommeLifecycleCommand, guestShutdownRequested: Bool = false)
    case snapshotSave(PommeSnapshotSaveRequest)
    case status
    case inspect
    case agentPerform(PommeAgentPerformRequest, streaming: Bool)
    case guestUI(PommeUIControlRequest)
    case terminalSession(PommeTerminalSessionControlRequest, streaming: Bool)

    var requiredFeature: PommeControlFeature {
        switch self {
        case .lifecycle, .snapshotSave: .lifecycle
        case .status, .inspect: .status
        case .agentPerform(_, let streaming): streaming ? .streaming : .status
        case .guestUI: .ui
        // A streamed terminal attach needs both the streaming transport and
        // the terminal-session capability. The socket client checks the
        // transport feature separately.
        case .terminalSession: .terminalSessions
        }
    }
}
