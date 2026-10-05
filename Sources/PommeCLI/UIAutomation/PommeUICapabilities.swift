import Foundation

/// Build-level support of the direct UI bridge. This does not claim that a
/// particular VM is running or that its display is ready for input.
enum PommeUICapabilities {
    static var publicPayload: [String: Any] {
        [
            "bridge": "direct-virtualization",
            "implementedOperations": ["click", "key", "key-sequence", "type", "screenshot"]
        ]
    }
}
