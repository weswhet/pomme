import Foundation
import Testing

@Suite("Normal-agent security status payload")
struct PommeNormalAMFIStatusPayloadTests {
    private static let report = JSONValue.object([
        "operation": .string("amfi.normal.status"),
        "amfiBootArgActive": .bool(true),
        "amfiDisabled": .bool(true),
        "bootPolicyAllowsCustomBootArgs": .bool(true),
        "securityMode": .string("permissive"),
        "baselinePresent": .bool(false),
        "baselinePhase": .string("none"),
        "reconciliationRequired": .bool(false),
        "verified": .bool(true),
    ])

    @Test("the payload names its source and carries no Recovery evidence")
    func payloadShape() throws {
        let payload = PommeApplication.normalAgentStatusPayload(
            operation: "amfi.status", name: "devme", finalState: .previous, report: Self.report)
        #expect(payload["ok"] as? Bool == true)
        #expect(payload["operation"] as? String == "amfi.status")
        #expect(payload["name"] as? String == "devme")
        #expect(payload["source"] as? String == "normalAgent")
        #expect(payload["finalState"] as? String == "previous")
        #expect(payload["finalStateVerified"] as? Bool == true)
        #expect(payload["hostExitCode"] as? Int == 0)
        #expect(payload["recovery"] == nil)
        #expect(payload["cleanup"] == nil)
    }

    @Test("the output is the agent's report with the keys a Recovery status prints")
    func outputCarriesTheReport() throws {
        let payload = PommeApplication.normalAgentStatusPayload(
            operation: "amfi.status", name: "devme", finalState: .normal, report: Self.report)
        let output = try #require(payload["output"] as? String)
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(decoded["amfiDisabled"] as? Bool == true)
        #expect(decoded["amfiBootArgActive"] as? Bool == true)
        #expect(decoded["bootPolicyAllowsCustomBootArgs"] as? Bool == true)
        #expect(decoded["securityMode"] as? String == "permissive")
        #expect(decoded["verified"] as? Bool == true)
        #expect(decoded["baselinePhase"] as? String == "none")
        #expect(payload["finalState"] as? String == "normal")
    }

    @Test("a SIP read uses the same shape with the keys a Recovery status prints")
    func sipPayload() throws {
        let payload = PommeApplication.normalAgentStatusPayload(
            operation: "sip.status", name: "devme", finalState: .previous,
            report: .object([
                "operation": .string("sip.normal.status"),
                "sipEnabled": .bool(false),
                "sipDisabled": .bool(true),
                "verified": .bool(true),
            ]))
        #expect(payload["operation"] as? String == "sip.status")
        #expect(payload["source"] as? String == "normalAgent")
        #expect(payload["recovery"] == nil)
        #expect(payload["cleanup"] == nil)
        let output = try #require(payload["output"] as? String)
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(decoded["sipDisabled"] as? Bool == true)
        #expect(decoded["sipEnabled"] as? Bool == false)
        #expect(decoded["verified"] as? Bool == true)
    }
}
