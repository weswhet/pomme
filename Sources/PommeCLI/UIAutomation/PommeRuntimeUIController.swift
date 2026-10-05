import Foundation
import Darwin

/// The narrow backend contract used by the helper's normal and Recovery UI
/// routes. Implementations must deliver through the VM's private Virtualization
/// resources; this boundary has no host-event or guest-agent fallback.
protocol PommeDirectUIBackend: Sendable {
    func screenshot(to outputURL: URL, timeout: TimeInterval) async throws -> [String: JSONValue]
    func click(x: Double, y: Double, timeout: TimeInterval) async throws -> [String: JSONValue]
    func sendKey(name: String, timeout: TimeInterval) async throws -> [String: JSONValue]
    func sendKeySequence(names: [String], timeout: TimeInterval) async throws -> [String: JSONValue]
    func typeText(_ text: String, replace: Bool, timeout: TimeInterval) async throws -> [String: JSONValue]
}

extension VirtualizationPrivateHeadlessBackend: PommeDirectUIBackend {}

/// Serializes helper UI requests and validates every payload before asking the
/// private Virtualization backend to construct or deliver an input event.
/// Serialization is required because the backend owns queue-confined VM
/// resources and a framebuffer observer with one outstanding capture slot.
actor PommeRuntimeUIController {
    private let backend: any PommeDirectUIBackend
    private var operationInFlight = false

    init(backend: any PommeDirectUIBackend) {
        self.backend = backend
    }

    func perform(_ request: PommeUIControlRequest) async throws -> [String: JSONValue] {
        guard !operationInFlight else {
            throw RunnerError.invalidUICommand("A direct VM UI operation is already in progress.")
        }
        operationInFlight = true
        defer { operationInFlight = false }

        switch request.operation {
        case .key:
            let key = try validatedKey(from: request.agentPayload)
            return try await backend.sendKey(name: key, timeout: request.timeout)

        case .keySequence:
            let keys = try validatedKeySequence(from: request.agentPayload)
            return try await backend.sendKeySequence(names: keys, timeout: request.timeout)

        case .type:
            guard let text = request.agentPayload["text"]?.stringValue else {
                throw RunnerError.invalidUICommand("guest-ui type requires text.")
            }
            let replace = boolValue(request.agentPayload["replace"]) ?? false
            return try await backend.typeText(text, replace: replace, timeout: request.timeout)

        case .click:
            guard let x = numberValue(request.agentPayload["x"]),
                  let y = numberValue(request.agentPayload["y"]),
                  x.isFinite,
                  y.isFinite
            else { throw RunnerError.invalidUICommand("guest-ui click requires finite x and y coordinates.") }
            return try await backend.click(x: x, y: y, timeout: request.timeout)

        case .screenshot:
            guard let path = request.hostOutputPath else {
                throw RunnerError.invalidUICommand("guest-ui screenshot requires hostOutputPath.")
            }
            let outputURL = try validatedScreenshotURL(path)
            return try await backend.screenshot(to: outputURL, timeout: request.timeout)
        }
    }

    private func validatedKey(from payload: [String: JSONValue]) throws -> String {
        guard let key = payload["key"]?.stringValue else {
            throw RunnerError.invalidUICommand("guest-ui key requires a key name.")
        }
        guard HostDisplayKey.lookup(key) != nil else {
            throw RunnerError.invalidUICommand(Self.unsupportedKeyMessage(key))
        }
        return key
    }

    static func unsupportedKeyMessage(_ key: String, index: Int? = nil) -> String {
        let position = index.map { " at index \($0) of the key sequence" } ?? ""
        return "Unsupported key '\(key)'\(position). Run `pomme ui keys` for the supported names."
    }

    private func validatedKeySequence(from payload: [String: JSONValue]) throws -> [String] {
        guard let values = payload["keys"]?.arrayValue,
              !values.isEmpty,
              values.count <= PommeUIControlRequest.maximumKeyCount
        else { throw RunnerError.invalidUICommand("guest-ui key-sequence requires 1-\(PommeUIControlRequest.maximumKeyCount) keys.") }
        return try values.enumerated().map { index, value in
            guard let key = value.stringValue else {
                throw RunnerError.invalidUICommand("guest-ui key-sequence requires key names.")
            }
            guard HostDisplayKey.lookup(key) != nil else {
                throw RunnerError.invalidUICommand(Self.unsupportedKeyMessage(key, index: index))
            }
            return key
        }
    }

    private func numberValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    private func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }

    private func validatedScreenshotURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL,
              url.path == path,
              path.hasPrefix("/"),
              path.utf8.count <= PommeUIControlRequest.maximumPathLength,
              !path.contains("\0")
        else { throw RunnerError.invalidUICommand("guest-ui screenshot path must be an absolute local path.") }

        var info = stat()
        if Darwin.lstat(path, &info) == 0,
           (info.st_mode & S_IFMT) == S_IFLNK
        {
            throw RunnerError.invalidUICommand("guest-ui screenshot refuses a symbolic-link output path.")
        }
        return url
    }
}
