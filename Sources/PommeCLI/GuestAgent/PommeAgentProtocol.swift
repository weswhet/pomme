import CryptoKit
import Foundation

/// The only wire contract spoken by Pomme guest agents.  It is deliberately
/// closed: unknown envelope keys and omitted required keys are protocol errors.
enum PommeAgentProtocol {
    static let name = "PommeAgentProtocol"
    static let version = 1
    static let maximumFrameBytes = 256 * 1024
    static let maximumStreamChunkBytes = 64 * 1024
    static let maximumFileChunkBytes = 32 * 1024

    enum Kind: String, Codable, Sendable { case request, response, stream }

    enum Stream: String, Codable, Sendable {
        case stdin, stdout, stderr, eof, resize, signal, exit
    }

    struct Failure: Codable, Equatable, Sendable {
        let code: String
        let message: String

        init(code: String, message: String) {
            self.code = code
            self.message = Self.redacted(message)
        }

        private static func redacted(_ message: String) -> String {
            let lowered = message.lowercased()
            if lowered.contains("token") || lowered.contains("password") || lowered.contains("secret") {
                return "The agent rejected the request."
            }
            return String(message.prefix(512))
        }
    }

    struct Envelope: Codable, Equatable, Sendable {
        let protocolName: String
        let version: Int
        let kind: Kind
        let requestID: UUID
        let operation: String
        let payload: JSONValue
        let ok: Bool?
        let result: JSONValue?
        let error: Failure?

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol", version, kind, requestID, operation, payload, ok, result, error
        }

        init(
            kind: Kind,
            requestID: UUID = UUID(),
            operation: String,
            payload: JSONValue = .object([:]),
            ok: Bool? = nil,
            result: JSONValue? = nil,
            error: Failure? = nil
        ) {
            protocolName = PommeAgentProtocol.name
            version = PommeAgentProtocol.version
            self.kind = kind
            self.requestID = requestID
            self.operation = operation
            self.payload = payload
            self.ok = ok
            self.result = result
            self.error = error
        }

        static func request(
            operation: String,
            payload: JSONValue = .object([:]),
            requestID: UUID = UUID()
        ) -> Self {
            .init(kind: .request, requestID: requestID, operation: operation, payload: payload)
        }

        static func response(
            to request: Envelope,
            result: JSONValue
        ) -> Self {
            .init(kind: .response, requestID: request.requestID, operation: request.operation,
                  payload: .object([:]), ok: true, result: result)
        }

        static func failure(to request: Envelope, code: String, message: String) -> Self {
            .init(kind: .response, requestID: request.requestID, operation: request.operation,
                  payload: .object([:]), ok: false, error: .init(code: code, message: message))
        }

        func validate() throws {
            guard protocolName == PommeAgentProtocol.name, version == PommeAgentProtocol.version else {
                throw Error.incompatibleVersion
            }
            guard !operation.isEmpty, operation.count <= 128,
                  operation.unicodeScalars.allSatisfy({
                      let value = $0.value
                      return (value >= 48 && value <= 57)
                          || (value >= 65 && value <= 90)
                          || (value >= 97 && value <= 122)
                          || value == 46
                          || value == 45
                  })
            else { throw Error.invalidOperation }
            switch kind {
            case .request:
                guard ok == nil, result == nil, error == nil else { throw Error.invalidRequest }
            case .response:
                guard let ok else { throw Error.invalidResponse }
                if ok {
                    guard result != nil, error == nil else { throw Error.invalidResponse }
                } else {
                    guard result == nil, error != nil else { throw Error.invalidResponse }
                }
            case .stream:
                guard ok == nil, result == nil, error == nil else { throw Error.invalidStream }
                try validateStreamPayload()
            }
        }

        private func validateStreamPayload() throws {
            guard let object = payload.objectValue,
                  let raw = object["stream"]?.stringValue,
                  let stream = Stream(rawValue: raw)
            else { throw Error.invalidStream }
            if let encoded = object["dataBase64"]?.stringValue {
                guard let data = Data(base64Encoded: encoded), data.count <= PommeAgentProtocol.maximumStreamChunkBytes else {
                    throw Error.invalidStream
                }
            }
            switch stream {
            case .resize:
                guard object["dataBase64"] == nil,
                      case .integer(let columns)? = object["columns"], columns > 0,
                      case .integer(let rows)? = object["rows"], rows > 0
                else { throw Error.invalidStream }
            case .signal:
                guard object["dataBase64"] == nil,
                      case .integer = object["signal"]
                else { throw Error.invalidStream }
            case .stdin, .stdout, .stderr, .eof, .exit:
                break
            }
        }
    }

    enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case frameTooLarge, malformedFrame, duplicateKey, incompatibleVersion
        case invalidEnvelope, invalidRequest, invalidResponse, invalidStream, invalidOperation

        var errorDescription: String? {
            switch self {
            case .frameTooLarge: "Pomme agent frame exceeded 256 KiB."
            case .malformedFrame: "Pomme agent frame is malformed."
            case .duplicateKey: "Pomme agent frame contains duplicate object keys."
            case .incompatibleVersion: "Pomme agent protocol version is unsupported."
            case .invalidEnvelope: "Pomme agent envelope has unknown or missing fields."
            case .invalidRequest: "Pomme agent request envelope is invalid."
            case .invalidResponse: "Pomme agent response envelope is invalid."
            case .invalidStream: "Pomme agent stream envelope is invalid."
            case .invalidOperation: "Pomme agent operation is invalid."
            }
        }
    }

    static func encode(_ envelope: Envelope) throws -> Data {
        try envelope.validate()
        var data = try JSONEncoder().encode(envelope)
        guard data.count < maximumFrameBytes else { throw Error.frameTooLarge }
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) throws -> Envelope {
        guard !line.isEmpty, line.count < maximumFrameBytes else { throw Error.frameTooLarge }
        guard !line.contains(0x0A), !line.contains(0x0D) else { throw Error.malformedFrame }
        try rejectDuplicateObjectKeys(line)
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
        } catch { throw Error.malformedFrame }
        let allowed: Set<String> = ["protocol", "version", "kind", "requestID", "operation", "payload", "ok", "result", "error"]
        guard Set(object.keys).isSubset(of: allowed) else { throw Error.invalidEnvelope }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: line)
            try envelope.validate()
            return envelope
        } catch let error as Error { throw error }
        catch { throw Error.invalidEnvelope }
    }

    /// A small JSON scanner is preferable to accepting ambiguous object input
    /// through JSONSerialization, whose duplicate-key behavior is unspecified.
    private static func rejectDuplicateObjectKeys(_ data: Data) throws {
        var stack: [Set<String>] = []
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x22 {
                index = data.index(after: index)
                var bytes: [UInt8] = []
                while index < data.endIndex, data[index] != 0x22 {
                    if data[index] == 0x5C { index = data.index(after: index) }
                    guard index < data.endIndex else { throw Error.malformedFrame }
                    bytes.append(data[index]); index = data.index(after: index)
                }
                guard index < data.endIndex else { throw Error.malformedFrame }
                let key = String(decoding: bytes, as: UTF8.self)
                let next = data.index(after: index)
                var cursor = next
                while cursor < data.endIndex, [0x20, 0x09].contains(data[cursor]) { cursor = data.index(after: cursor) }
                if cursor < data.endIndex, data[cursor] == 0x3A, !stack.isEmpty {
                    if !stack[stack.count - 1].insert(key).inserted { throw Error.duplicateKey }
                }
                index = next
            } else if byte == 0x7B {
                stack.append([]); index = data.index(after: index)
            } else if byte == 0x7D {
                guard !stack.isEmpty else { throw Error.malformedFrame }
                stack.removeLast(); index = data.index(after: index)
            } else { index = data.index(after: index) }
        }
        guard stack.isEmpty else { throw Error.malformedFrame }
    }
}

enum PommeAgentAuthentication {
    static func challenge() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    static func proof(token: String, challenge: String) throws -> String {
        let token = try normalized(token)
        let challenge = try normalized(challenge)
        let code = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: SymmetricKey(data: Data(token.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func verifies(proof: String, token: String, challenge: String) throws -> Bool {
        let expected = try self.proof(token: token, challenge: challenge)
        return constantTimeEqual(Array(proof.lowercased().utf8), Array(expected.utf8))
    }

    static func normalized(_ value: String) throws -> String {
        let value = value.lowercased()
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else {
            throw PommeAgentProtocol.Error.invalidRequest
        }
        return value
    }

    private static func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
