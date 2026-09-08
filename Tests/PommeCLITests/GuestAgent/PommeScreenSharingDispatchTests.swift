import Foundation
import Testing

@Suite("Screen Sharing dispatch preflight")
struct PommeScreenSharingDispatchTests {
    @Test("Unsupported guests receive no Screen Sharing operation", arguments: ScreenSharingAction.allCases)
    func unavailableDoesNotDispatch(action: ScreenSharingAction) {
        var calls: [String] = []
        #expect(throws: RunnerError.self) {
            try ScreenSharingAgentCapabilityGate.perform(
                describe: {
                    calls.append("agent.describe")
                    return describe(capabilities: ["process.start"])
                },
                dispatch: {
                    calls.append("ui.screenSharing.\(action.rawValue)")
                    return "unexpected"
                }
            )
        }
        #expect(calls == ["agent.describe"])
    }

    @Test("A capable guest receives the requested operation after preflight", arguments: ScreenSharingAction.allCases)
    func availableDispatches(action: ScreenSharingAction) throws {
        var calls: [String] = []
        let request = ScreenSharingRequest(action: action)
        let response = try ScreenSharingAgentCapabilityGate.perform(
            describe: {
                calls.append("agent.describe")
                return describe(capabilities: ["ui.screenSharing"])
            },
            dispatch: {
                calls.append("ui.screenSharing")
                return request.agentPayload
            }
        )
        #expect(calls == ["agent.describe", "ui.screenSharing"])
        #expect(response["action"] as? String == action.rawValue)
    }

    @Test("A failed authenticated query never falls through to dispatch")
    func describeFailureDoesNotDispatch() {
        enum QueryFailure: Error { case unavailable }
        var dispatched = false
        #expect(throws: QueryFailure.self) {
            try ScreenSharingAgentCapabilityGate.perform(
                describe: { throw QueryFailure.unavailable },
                dispatch: { dispatched = true }
            )
        }
        #expect(!dispatched)
    }

    private func describe(capabilities: [String]) -> JSONValue {
        .object([
            "role": .string("persistent"),
            "protocol": .string(PommeAgentProtocol.name),
            "version": .integer(Int64(PommeAgentProtocol.version)),
            "executableSHA256": .string(String(repeating: "a", count: 64)),
            "capabilities": .array(capabilities.map(JSONValue.string)),
        ])
    }
}
