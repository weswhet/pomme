import Darwin
import Foundation

enum ControlWireCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    static func encodeLine<T: Encodable & Sendable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        try validateFrameSize(data)
        return data
    }

    static func decodeHello(_ data: Data) throws -> PommeControlHello {
        let hello = try decode(PommeControlHello.self, from: data, allowedEnvelopeFields: ["type", "protocolVersion", "features"])
        guard hello.type == "hello", hello.protocolVersion == PommeControlProtocol.version else {
            throw RunnerError.invalidControlResponse("Expected a Pomme control v\(PommeControlProtocol.version) hello envelope.")
        }
        return hello
    }

    static func decodeRequest(_ data: Data) throws -> PommeControlRequest {
        let request = try decode(PommeControlRequest.self, from: data, allowedEnvelopeFields: ["type", "protocolVersion", "id", "command", "payload", "streaming"])
        guard request.type == "request", request.protocolVersion == PommeControlProtocol.version else {
            throw RunnerError.invalidControlResponse("Expected a Pomme control v\(PommeControlProtocol.version) request envelope.")
        }
        return request
    }

    static func decodeResponse(_ data: Data, matching id: UUID) throws -> PommeControlResponse {
        let response = try decode(PommeControlResponse.self, from: data, allowedEnvelopeFields: ["type", "protocolVersion", "id", "ok", "result", "error"])
        guard response.type == "response", response.protocolVersion == PommeControlProtocol.version, response.id == id,
              response.ok ? (response.result != nil && response.error == nil) : (response.result == nil && response.error != nil)
        else { throw RunnerError.invalidControlResponse("Malformed or mismatched Pomme control response.") }
        return response
    }

    static func decodeStreamFrame(_ data: Data) throws -> PommeControlStreamFrame {
        let frame = try decode(PommeControlStreamFrame.self, from: data, allowedEnvelopeFields: ["type", "protocolVersion", "id", "sequence", "stream", "dataBase64", "payload", "eof"])
        try frame.validate()
        return frame
    }

    static func writeFrame(_ data: Data, to fileDescriptor: Int32, deadline: TimeInterval? = nil) throws {
        try validateFrameSize(data)
        var noSigPipe: Int32 = 1
        guard Darwin.setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            try throwPOSIX("setsockopt(SO_NOSIGPIPE)")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if let deadline { try waitForDescriptor(fileDescriptor, events: Int16(POLLOUT), deadline: deadline) }
                let written = Darwin.write(fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR { continue }
                else if written < 0, deadline != nil, errno == EAGAIN { continue }
                else { try throwPOSIX("write") }
            }
        }
    }

    struct FrameReader: Sendable {
        private var buffered = Data()

        mutating func readFrame(from fileDescriptor: Int32, deadline: TimeInterval? = nil) throws -> Data {
            while true {
                if let newline = buffered.firstIndex(of: 0x0A) {
                    let frame = Data(buffered[...newline])
                    buffered.removeSubrange(...newline)
                    try ControlWireCodec.validateFrameSize(frame)
                    return frame
                }
                guard buffered.count < PommeControlProtocol.maximumFrameBytes else {
                    throw RunnerError.invalidControlResponse("Pomme control frame exceeds \(PommeControlProtocol.maximumFrameBytes) bytes.")
                }
                let remaining = PommeControlProtocol.maximumFrameBytes - buffered.count
                var bytes = [UInt8](repeating: 0, count: min(4_096, remaining))
                if let deadline {
                    try ControlWireCodec.waitForDescriptor(fileDescriptor, events: Int16(POLLIN), deadline: deadline)
                }
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
                if count > 0 { buffered.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { throw RunnerError.invalidControlResponse("Pomme control socket closed before a complete JSONL frame.") }
                else if deadline != nil, errno == EAGAIN { continue }
                else if errno != EINTR { try throwPOSIX("read") }
            }
        }
    }

    /// One monotonic deadline applies to every partial read/write, rather than
    /// restarting the timeout whenever another byte becomes available.
    static func waitForDescriptor(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        guard deadline.isFinite else { throw POSIXError(.EINVAL) }
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
            let milliseconds = Int32(min(Double(Int32.max), max(1, (remaining * 1_000).rounded(.up))))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = Darwin.poll(&item, 1, milliseconds)
            if ready > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw POSIXError(.EBADF) }
                if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
            } else if ready == 0 {
                throw POSIXError(.ETIMEDOUT)
            } else if errno != EINTR {
                try throwPOSIX("poll")
            }
        }
    }

    static func protocolVersion(in data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: trimmingNewline(data)) as? [String: Any])?["protocolVersion"] as? Int
    }

    static func envelopeType(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: trimmingNewline(data)) as? [String: Any])?["type"] as? String
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, allowedEnvelopeFields: Set<String>) throws -> T {
        try validateFrameSize(data)
        let frame = try strictJSONLBody(data)
        do {
            try validateEnvelopeFields(frame, allowed: allowedEnvelopeFields)
            return try decoder.decode(type, from: frame)
        }
        catch { throw RunnerError.invalidControlResponse("Malformed Pomme control JSON: \(error.localizedDescription)") }
    }

    private static func validateFrameSize(_ data: Data) throws {
        guard data.count <= PommeControlProtocol.maximumFrameBytes else {
            throw RunnerError.invalidControlResponse("Pomme control frame exceeds \(PommeControlProtocol.maximumFrameBytes) bytes.")
        }
    }

    private static func trimmingNewline(_ data: Data) -> Data {
        var data = data
        while data.last == 0x0A || data.last == 0x0D { data.removeLast() }
        return data
    }

    private static func strictJSONLBody(_ data: Data) throws -> Data {
        let body = trimmingNewline(data)
        guard !body.isEmpty, !body.contains(0x0A), !body.contains(0x0D) else {
            throw RunnerError.invalidControlResponse("Pomme control envelopes must be one non-empty JSONL frame.")
        }
        return body
    }

    /// JSONDecoder intentionally ignores unknown keys and JSONSerialization
    /// accepts duplicate keys. Envelope framing is an authority boundary, so
    /// scan the root object before decoding and reject both cases.
    private static func validateEnvelopeFields(_ data: Data, allowed: Set<String>) throws {
        var index = data.startIndex
        consumeWhitespace(data, &index)
        guard consume(data, byte: 0x7B, &index) else { throw RunnerError.invalidControlResponse("Pomme control envelope must be a JSON object.") }
        consumeWhitespace(data, &index)
        var fields = Set<String>()
        if consume(data, byte: 0x7D, &index) {
            consumeWhitespace(data, &index)
            guard index == data.endIndex else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
            return
        }
        while true {
            let key = try consumeJSONString(data, &index)
            guard allowed.contains(key), fields.insert(key).inserted else {
                throw RunnerError.invalidControlResponse("Unknown or duplicate Pomme control envelope field.")
            }
            consumeWhitespace(data, &index)
            guard consume(data, byte: 0x3A, &index) else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
            try consumeJSONValue(data, &index)
            consumeWhitespace(data, &index)
            if consume(data, byte: 0x7D, &index) {
                consumeWhitespace(data, &index)
                guard index == data.endIndex else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
                return
            }
            guard consume(data, byte: 0x2C, &index) else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
            consumeWhitespace(data, &index)
        }
    }

    private static func consumeJSONValue(_ data: Data, _ index: inout Data.Index) throws {
        consumeWhitespace(data, &index)
        guard index < data.endIndex else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
        switch data[index] {
        case 0x22: _ = try consumeJSONString(data, &index)
        case 0x7B, 0x5B:
            let opening = data[index]; let closing: UInt8 = opening == 0x7B ? 0x7D : 0x5D
            var depth = 0
            repeat {
                guard index < data.endIndex else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
                if data[index] == 0x22 { _ = try consumeJSONString(data, &index); continue }
                if data[index] == opening { depth += 1 }
                if data[index] == closing { depth -= 1 }
                index = data.index(after: index)
            } while depth > 0
        default:
            let start = index
            while index < data.endIndex, ![0x20, 0x09, 0x7D, 0x2C, 0x5D].contains(data[index]) { index = data.index(after: index) }
            guard index > start else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
        }
    }

    private static func consumeJSONString(_ data: Data, _ index: inout Data.Index) throws -> String {
        consumeWhitespace(data, &index)
        guard index < data.endIndex, data[index] == 0x22 else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
        let start = index
        index = data.index(after: index)
        while index < data.endIndex {
            switch data[index] {
            case 0x22:
                index = data.index(after: index)
                let quoted = Data(data[start..<index])
                guard let value = try? decoder.decode(String.self, from: quoted) else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
                return value
            case 0x5C:
                index = data.index(after: index)
                guard index < data.endIndex else { throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.") }
                index = data.index(after: index)
            case 0x00...0x1F:
                throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.")
            default: index = data.index(after: index)
            }
        }
        throw RunnerError.invalidControlResponse("Malformed Pomme control envelope.")
    }

    private static func consumeWhitespace(_ data: Data, _ index: inout Data.Index) {
        while index < data.endIndex, data[index] == 0x20 || data[index] == 0x09 { index = data.index(after: index) }
    }

    private static func consume(_ data: Data, byte: UInt8, _ index: inout Data.Index) -> Bool {
        guard index < data.endIndex, data[index] == byte else { return false }
        index = data.index(after: index)
        return true
    }
}
