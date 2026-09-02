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
}

struct PommeControlHello: Codable, Equatable, Sendable {
    let type: String
    let protocolVersion: Int
    let features: [PommeControlFeature]

    init(features: [PommeControlFeature] = PommeControlFeature.allCases) {
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
    let id: UUID
    private let fileDescriptor: Int32
    private let reader: Mutex<ControlWireCodec.FrameReader>
    private let receiveLock = Mutex(false)
    private let inbound: Mutex<PommeControlStreamSequenceValidator>
    private let outbound: Mutex<PommeControlStreamSequenceValidator>

    init(id: UUID, fileDescriptor: Int32, reader: ControlWireCodec.FrameReader = .init()) {
        self.id = id
        self.fileDescriptor = fileDescriptor
        self.reader = .init(reader)
        inbound = .init(.init(id: id))
        outbound = .init(.init(id: id))
    }

    func receive() throws -> PommeControlStreamFrame {
        try receiveLock.withLock { _ in
            let data = try reader.withLock { try $0.readFrame(from: fileDescriptor) }
            let frame = try ControlWireCodec.decodeStreamFrame(data)
            try inbound.withLock { try $0.accept(frame) }
            return frame
        }
    }

    func send(stream: PommeControlStreamFrame.Stream, data: Data? = nil, payload: JSONValue? = nil, eof: Bool? = nil) throws {
        try outbound.withLock { validator in
            let frame = PommeControlStreamFrame(id: id, sequence: validator.nextExpectedSequence, stream: stream, data: data, payload: payload, eof: eof)
            try validator.accept(frame)
            try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(frame), to: fileDescriptor)
        }
    }

    func send(_ frame: PommeControlStreamFrame) throws {
        try outbound.withLock { validator in
            try validator.accept(frame)
            try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(frame), to: fileDescriptor)
        }
    }

    func receiveResponse() throws -> PommeControlResponse {
        let data = try reader.withLock { try $0.readFrame(from: fileDescriptor) }
        return try ControlWireCodec.decodeResponse(data, matching: id)
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
        let exact: Set<String> = ["agent.describe", "agent.health", "system.info", "network.interfaces"]
        let prefixes = ["process.", "file.", "job.", "maintenance.", "remoteLogin.", "mdm.", "ui."]
        return exact.contains(operation) || prefixes.contains(where: operation.hasPrefix)
    }
}

enum PommeVMControlRequest: Sendable {
    case lifecycle(PommeLifecycleCommand)
    case snapshotSave(PommeSnapshotSaveRequest)
    case status
    case inspect
    case agentPerform(PommeAgentPerformRequest, streaming: Bool)

    var requiredFeature: PommeControlFeature {
        switch self {
        case .lifecycle, .snapshotSave: .lifecycle
        case .status, .inspect: .status
        case .agentPerform(_, let streaming): streaming ? .streaming : .status
        }
    }
}
