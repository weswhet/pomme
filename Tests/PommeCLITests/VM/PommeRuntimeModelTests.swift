import Foundation
import Testing

@Suite("Pomme runtime model")
struct PommeRuntimeModelTests {
    @Test("Guest agent status has a closed Codable schema")
    func guestAgentStatusSchema() throws {
        let status = GuestAgentStatusV1(
            connection: .connected,
            role: .normal,
            protocolVersion: 1,
            executableDigest: "abc",
            capabilities: ["exec"],
            updateState: .current
        )
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(Set(object.keys) == ["connection", "role", "protocolVersion", "executableDigest", "capabilities", "updateState"])
        #expect(object["connection"] as? String == "connected")
        #expect(object["role"] as? String == "normal")
    }

    @Test("Only Pomme normal and Recovery ports are defined")
    func listenerPorts() {
        #expect(PommeAgentPort.persistentNormal == 505_051)
        #expect(PommeAgentPort.recoveryBootstrap == 505_052)
        #expect(PommeAgentPort.recoveryRuntime == 505_053)
        let immediatelyPrecedingPort = PommeAgentPort.persistentNormal - 1
        #expect(![PommeAgentPort.persistentNormal, PommeAgentPort.recoveryBootstrap, PommeAgentPort.recoveryRuntime].contains(immediatelyPrecedingPort))
    }

    @Test("Runtime identity cache keys include the helper lifetime")
    func runtimeIdentityIncludesLifetime() {
        let old = PommeRuntimeIdentity(socketPath: "/tmp/pomme-a.sock", pid: 42, startedAt: "first")
        let replacement = PommeRuntimeIdentity(socketPath: "/tmp/pomme-a.sock", pid: 42, startedAt: "second")
        #expect(old != replacement)
        #expect(Set([old, replacement]).count == 2)
    }

    @Test("Offline guest status is closed")
    func offlineGuestStatus() throws {
        let status = GuestAgentStatusV1.offline(role: .recovery)
        #expect(status.connection == .disconnected)
        #expect(status.role == .recovery)
        #expect(status.protocolVersion == nil)
        #expect(status.capabilities.isEmpty)
        #expect(status.updateState == .unavailable)
    }
}
