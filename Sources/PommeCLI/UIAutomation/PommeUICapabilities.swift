import Foundation

/// Build-level support of the direct UI bridge. This does not claim that a
/// particular VM is running or that its display is ready for input.
enum PommeUICapabilities {
    static let settingsAIUnavailableReason =
        "UI AI Settings automation is unavailable in this build. Use explicit ui click, key, key-sequence, type, or screenshot commands."

    static func require(operation: GuestUIOperation) throws {
        if operation == .settingsAI {
            throw RunnerError.invalidUICommand(settingsAIUnavailableReason)
        }
    }

    static var publicPayload: [String: Any] {
        [
            "bridge": "direct-virtualization",
            "implementedOperations": ["click", "key", "key-sequence", "type", "screenshot"],
            "settingsAI": ["available": false, "reason": settingsAIUnavailableReason]
        ]
    }
}
