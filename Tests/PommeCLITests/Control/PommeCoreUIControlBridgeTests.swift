import Foundation
import Testing

@Suite("Public UI control bridge")
struct PommeCoreUIControlBridgeTests {
    @Test("UI operations survive the real CLI-to-helper envelope", arguments: [
        GuestUIOperation.key, .keySequence, .type, .click, .screenshot,
    ])
    func preservesUIOperation(_ operation: GuestUIOperation) throws {
        // Arrange: use the same payload builder as the public UI commands.
        let request = GuestUIRequest(
            operation: operation,
            agentPayload: ["operation": operation.rawValue, "key": "cmd+shift+t"],
            timeout: 10,
            hostOutputPath: "/private/tmp/pomme-ui-test.png"
        )

        // Act: exercise the bridge used before every control socket send.
        let wire = try PommeCore.makeControlRequest(from: request.controlPayload)

        // Assert: the operation must not be discarded as an envelope field.
        #expect(wire.command == "guest-ui")
        #expect(wire.payload?.objectValue?["operation"] == .string(operation.rawValue))
        #expect(wire.payload?.objectValue?["hostOutputPath"] == .string("/private/tmp/pomme-ui-test.png"))
        #expect(wire.payload?.objectValue?["agentPayload"]?.objectValue?["key"] == .string("cmd+shift+t"))
    }

    @Test("agent operations keep their own operation unchanged")
    func preservesAgentOperation() throws {
        let request = try PommeCore.makeControlRequest(from: [
            "command": "agent.perform", "operation": "agent.health",
        ])
        #expect(request.payload?.objectValue?["operation"] == .string("agent.health"))
    }

    @Test("relative screenshots resolve in the invoking CLI directory")
    func resolvesScreenshotDestination() throws {
        let request = GuestUIRequest(
            operation: .screenshot, agentPayload: [:], timeout: 10,
            hostOutputPath: "pomme-screen.png"
        )
        let wire = try PommeCore.makeControlRequest(from: request.controlPayload)
        #expect(wire.payload?.objectValue?["hostOutputPath"] == .string(
            URL(fileURLWithPath: "pomme-screen.png").standardizedFileURL.path
        ))
    }

    @Test("unknown helper commands remain rejected")
    func rejectsUnknownCommand() {
        #expect(throws: RunnerError.self) {
            try PommeCore.makeControlRequest(from: ["command": "unrecognized"])
        }
    }
}
