import Foundation
import ArgumentParser
@preconcurrency import AppKit
import Security
// Virtualization reference types are confined to their documented serial VM queue below.
// Remove this when the SDK models these queue-confined APIs with Sendable-aware annotations.
@preconcurrency import Virtualization
import Darwin

enum GuestUIOperation: String, Sendable {
    case type
    case key
    case keySequence = "key-sequence"
    case click
    case screenshot
}

struct GuestUIRequest: @unchecked Sendable {
    let operation: GuestUIOperation
    var agentPayload: [String: Any]
    var timeout: TimeInterval
    var hostOutputPath: String?
    var agentBinaryPath: String?

    var controlPayload: [String: Any] {
        var payload: [String: Any] = [
            "command": "guest-ui",
            "operation": operation.rawValue,
            "agentPayload": agentPayload,
            "timeout": timeout
        ]
        if let hostOutputPath {
            payload["hostOutputPath"] = hostOutputPath
        }
        if let agentBinaryPath {
            payload["agentBinaryPath"] = agentBinaryPath
        }
        return payload
    }

    static func parse(from object: [String: Any]) throws -> GuestUIRequest {
        guard let operationName = object["operation"] as? String,
              let operation = GuestUIOperation(rawValue: operationName)
        else {
            throw RunnerError.invalidControlResponse("guest-ui requires a valid operation.")
        }
        let agentPayload = object["agentPayload"] as? [String: Any] ?? ["operation": operation.rawValue]
        return GuestUIRequest(
            operation: operation,
            agentPayload: agentPayload,
            timeout: timeoutValue(from: object),
            hostOutputPath: object["hostOutputPath"] as? String,
            agentBinaryPath: object["agentBinaryPath"] as? String
        )
    }

    private static func timeoutValue(from object: [String: Any]) -> TimeInterval {
        if let value = object["timeout"] as? Double {
            return value
        }
        if let value = object["timeout"] as? Int {
            return TimeInterval(value)
        }
        if let value = object["timeout"] as? String, let parsed = TimeInterval(value) {
            return parsed
        }
        return Constants.defaultGuestCommandTimeout
    }
}
