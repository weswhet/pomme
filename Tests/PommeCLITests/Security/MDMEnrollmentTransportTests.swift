import Foundation
import Testing

@Suite("MDM enrollment PommeAgent gate")
struct MDMEnrollmentAgentGateTests {
    @Test("A verified normal PommeAgent with protocol v1 and required capabilities is accepted")
    func acceptsVerifiedAgent() throws {
        let payload = try MDMEnrollmentAgentGate.verify(agent())

        #expect(payload["agent"] as? String == "PommeAgent")
        #expect(payload["role"] as? String == MDMEnrollmentAgentDescription.normalRole)
        #expect(payload["version"] as? Int == 1)
        #expect((payload["capabilities"] as? [String]) == ["maintenance", "mdm.enrollment"])
    }

    @Test("Disconnected, non-normal, and incompatible agents fail before staging")
    func rejectsConnectionRoleAndProtocol() {
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(connected: false))
        }
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(role: "recovery"))
        }
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(protocolVersion: 2))
        }
    }

    @Test("Missing authentication or digest rejects the agent attestation")
    func rejectsMissingAuthenticationAndDigest() {
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(authenticated: false))
        }
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(executableDigest: nil))
        }
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(executableDigest: "not-a-digest"))
        }
    }

    @Test("Missing enrollment or maintenance capability fails closed")
    func rejectsMissingCapabilities() {
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(capabilities: ["maintenance"]))
        }
        #expect(throws: RunnerError.self) {
            try MDMEnrollmentAgentGate.verify(agent(capabilities: ["mdm.enrollment"]))
        }
    }

    @Test("The PommeAgent contract has no legacy selection fields")
    func noLegacySelectionFields() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("Sources/PommeCLI/Security/MDMEnrollment.swift"),
            encoding: .utf8
        ).lowercased()

        for forbidden in [
            "apple" + "q" + "ga",
            "guestcontrol" + "transport",
            "fall" + "back" + "agentconnected"
        ] {
            #expect(!source.contains(forbidden))
        }
    }

    private func agent(
        connected: Bool = true,
        authenticated: Bool = true,
        role: String = MDMEnrollmentAgentDescription.normalRole,
        protocolVersion: Int = MDMEnrollmentAgentDescription.protocolVersion,
        executableDigest: String? = String(repeating: "a", count: 64),
        capabilities: Set<String> = MDMEnrollmentAgentDescription.requiredCapabilities
    ) -> MDMEnrollmentAgentDescription {
        .init(
            connected: connected,
            authenticated: authenticated,
            role: role,
            protocolName: MDMEnrollmentAgentDescription.protocolName,
            protocolVersion: protocolVersion,
            executableDigest: executableDigest,
            capabilities: capabilities
        )
    }
}
