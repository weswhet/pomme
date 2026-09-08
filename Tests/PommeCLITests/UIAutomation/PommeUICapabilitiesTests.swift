import Foundation
import Testing

@Suite("Direct UI capability discovery")
struct PommeUICapabilitiesTests {
    @Test("Discovery exposes the unavailable AI bridge without advertising it as implemented")
    func discoveryMatchesImplementation() throws {
        let payload = PommeUICapabilities.publicPayload
        let settings = try #require(payload["settingsAI"] as? [String: Any])
        #expect(settings["available"] as? Bool == false)
        #expect(settings["reason"] as? String == PommeUICapabilities.settingsAIUnavailableReason)
        #expect(payload["implementedOperations"] as? [String] == ["click", "key", "key-sequence", "type", "screenshot"])
        for operation: GuestUIOperation in [.click, .key, .keySequence, .type, .screenshot] {
            try PommeUICapabilities.require(operation: operation)
        }
    }

    @Test("Unavailable AI rejects before VM name validation or dispatch", arguments: ["suggest", "step", "loop"])
    func unavailableBeforeVMResolution(_ mode: String) throws {
        let request = GuestUIRequest(
            operation: .settingsAI,
            agentPayload: ["operation": "settings-ai", "goal": "Open Keyboard settings", "mode": mode],
            timeout: 1)
        do {
            // Invalid syntax prevents any real VM lookup even if this regresses.
            _ = try PommeApplication.ui(name: "invalid/vm", request: request)
            Issue.record("Unavailable AI unexpectedly dispatched")
        } catch {
            #expect(error.localizedDescription == PommeUICapabilities.settingsAIUnavailableReason)
        }
    }
}
