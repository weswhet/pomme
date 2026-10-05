import Foundation
import Testing

@Suite("Direct UI capability discovery")
struct PommeUICapabilitiesTests {
    @Test("Discovery lists the implemented direct operations and nothing else")
    func discoveryMatchesImplementation() {
        let payload = PommeUICapabilities.publicPayload
        #expect(payload["bridge"] as? String == "direct-virtualization")
        #expect(payload["implementedOperations"] as? [String] == ["click", "key", "key-sequence", "type", "screenshot"])
        #expect(payload["settingsAI"] == nil)
        #expect(Set(payload.keys) == ["bridge", "implementedOperations"])
    }

    @Test("A settings-ai request is not a guest UI operation")
    func settingsAIIsNotAnOperation() {
        #expect(GuestUIOperation(rawValue: "settings-ai") == nil)
        #expect(throws: RunnerError.self) {
            _ = try GuestUIRequest.parse(from: ["operation": "settings-ai"])
        }
    }
}
