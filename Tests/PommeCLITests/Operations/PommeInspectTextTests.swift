import Testing

@Suite("Inspect text")
struct PommeInspectTextTests {
    private let agent: [String: Any] = [
        "connection": "connected", "role": "normal", "protocolVersion": 1,
        "executableDigest": "abc", "updateState": "current", "capabilities": ["exec", "file"]
    ]

    @Test("Detailed inspect text prints each field once")
    func detailedInspectPrintsEachFieldOnce() {
        let inspect: [String: Any] = [
            "bundlePath": "/vms/t1.bundle", "pommeSocket": "/tmp/pomme-1.sock", "helperRunning": true,
            "vmState": "running", "bootMode": "normal", "guestAgent": agent
        ]
        let health: [String: Any] = [
            "healthy": true, "guestAgent": agent,
            "checks": [["name": "helper", "ok": true], ["name": "guestAgent", "ok": true]]
        ]
        let capabilities: [String: Any] = ["ok": true, "guestAgent": agent]

        let text = [
            PommeApplication.formatInspect(inspect),
            PommeApplication.formatHealth(health, includeGuestAgent: false),
            PommeApplication.formatCapabilities(capabilities, includeGuestAgent: false)
        ].joined(separator: "\n")
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.filter { $0.hasPrefix("guestAgent ") }.count == 1)
        #expect(lines.contains("pommeSocket: /tmp/pomme-1.sock"))
        #expect(!lines.contains { $0.hasPrefix("controlSocket:") })
        #expect(lines.filter { $0.hasPrefix("vmState:") } == ["vmState: running"])
        #expect(lines.filter { $0.hasPrefix("bootMode:") } == ["bootMode: normal"])
        #expect(lines.contains("check.helper: ok"))
        #expect(lines.contains("check.guestAgent: ok"))
        #expect(lines.contains("capabilities: exec, file"))
    }

    @Test("Standalone health and capabilities keep their guest agent line")
    func standaloneViewsKeepGuestAgent() {
        #expect(PommeApplication.formatHealth(["healthy": false, "guestAgent": agent]).contains("guestAgent connection=connected"))
        #expect(PommeApplication.formatCapabilities(["ok": true, "guestAgent": agent]).contains("guestAgent connection=connected"))
    }
}
