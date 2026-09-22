import Foundation
import Testing

@Suite("TUI guest-agent status rendering")
struct TUITransportRendererTests {
    @Test("Canonical VM states determine badges and counts independently of helper presence")
    func canonicalVMStates() throws {
        let states = ["running", "paused", "stopped", "unknown", "future-state"]
        let badges = ["[RUN]", "[PAUSE]", "[STOP]", "[?]", "[?]"]
        let entries = try states.map { state in
            try #require(TUIVMEntry(payload: [
                "name": state,
                "bundlePath": "/tmp/\(state).macvm",
                "vmState": state,
                "helperRunning": true
            ]))
        }
        let renderer = TUIRenderer(useColor: false)
        for (entry, badge) in zip(entries, badges) {
            #expect(renderer.vmSummary(entry).hasPrefix(badge))
            #expect(entry.running == (entry.vmState == "running"))
        }
        let output = renderer.renderDashboard(entries: entries, selectedIndex: nil, statusMessage: nil, width: 100)
        #expect(output.contains("running=1 paused=1 stopped=1 unknown=2"))
        for (state, badge) in zip(states, badges) {
            let row = try #require(output.split(separator: "\n").first { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count > 1 && fields[1] == state
            })
            #expect(row.trimmingCharacters(in: .whitespaces).hasPrefix(badge))
        }
        #expect(TUIVMEntry(payload: ["bundlePath": "/tmp/legacy", "running": true])?.running == false)
    }

    @Test("Canonical nullable integer protocol and executable digest render without legacy coercion")
    func canonicalAgentFields() {
        let agent = TUIGuestAgent(payload: ["protocolVersion": 1, "executableDigest": "actual-digest"])
        #expect(agent.protocolVersion == "1")
        #expect(agent.digest == "actual-digest")
        for value: Any in [NSNull(), true, "1", 1.5] {
            #expect(TUIGuestAgent(payload: ["protocolVersion": value]).protocolVersion == "-")
        }
        #expect(TUIGuestAgent(payload: ["digest": "legacy"]).digest == "-")
    }

    @Test("Dashboard renders the closed guest-agent status schema")
    func dashboardShowsGuestAgentSchema() throws {
        let normal = try #require(entry(name: "normal", connection: "connected", role: "normal"))
        let recovery = try #require(entry(name: "recovery", connection: "connected", role: "recovery"))
        let unavailable = try #require(entry(name: "offline", connection: "disconnected", role: "normal"))

        let output = TUIRenderer(useColor: false).renderDashboard(
            entries: [normal, recovery, unavailable],
            selectedIndex: 0,
            statusMessage: nil,
            width: 100
        )

        #expect(output.contains("guestAgentConnected=2 guestAgentDisconnected=1"))
        #expect(output.contains("GUEST AGENT"))
        #expect(output.contains("connection=connected"))
        #expect(output.contains("role=normal"))
        #expect(output.contains("protocol=3"))
        #expect(output.contains("digest=abc123"))
        #expect(output.contains("capabilities=files,jobs"))
        #expect(output.contains("update=current"))
    }

    @Test("Production guest-agent model projects its encoded fields", arguments: [true, false])
    func productionGuestAgentProjection(connected: Bool) throws {
        let status = connected ? GuestAgentStatusV1(
            connection: .connected,
            role: .normal,
            protocolVersion: PommeAgentProtocol.version,
            executableDigest: String(repeating: "a", count: 64),
            capabilities: ["process.status"],
            updateState: .current
        ) : .offline(role: .normal)
        let payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        )
        let projected = TUIGuestAgent(payload: payload)
        #expect(projected.protocolVersion == (connected ? String(PommeAgentProtocol.version) : "-"))
        #expect(projected.digest == (connected ? String(repeating: "a", count: 64) : "-"))
        #expect(projected.connection == (connected ? .connected : .disconnected))
    }

    @Test("Unknown guest-agent values remain closed")
    func modelAcceptsOnlyGuestAgentSchema() throws {
        let entry = try #require(TUIVMEntry(payload: [
            "bundlePath": "/tmp/fixture.macvm",
            "guestAgent": ["connection": "connected", "role": "other"]
        ]))

        #expect(entry.guestAgent.connection == .connected)
        #expect(entry.guestAgent.role == .unknown)
        #expect(TUIRenderer(useColor: false).vmSummary(entry).contains("guestAgent connection=connected role=unknown"))
    }

    @Test("Action detail does not advertise cancellation while an operation is active")
    func runningActionDetailExplainsCancellationBehavior() {
        let renderer = TUIRenderer(useColor: false)

        let running = renderer.renderDetail(
            title: "Restore Snapshot",
            vmName: "dev",
            phase: "running",
            elapsed: 1,
            statusLines: [],
            progress: nil,
            result: nil,
            errorMessage: nil,
            width: 80
        )
        let complete = renderer.renderDetail(
            title: "Restore Snapshot",
            vmName: "dev",
            phase: "complete",
            elapsed: 1,
            statusLines: [],
            progress: nil,
            result: .init(
                title: "Restore Snapshot",
                vmName: "dev",
                ok: true,
                hostExitCode: 0,
                text: "OK",
                payload: [:]
            ),
            errorMessage: nil,
            width: 80
        )

        #expect(running.contains("cancellation is unavailable"))
        #expect(running.contains("q/Esc Back") == false)
        #expect(complete.contains("r return and refresh"))
    }

    private func entry(name: String, connection: String, role: String) -> TUIVMEntry? {
        TUIVMEntry(payload: [
            "name": name,
            "bundlePath": "/tmp/\(name).macvm",
            "helperRunning": true,
            "vmState": "running",
            "bootMode": "normal",
            "guestAgent": [
                "connection": connection,
                "role": role,
                "protocolVersion": 3,
                "executableDigest": "abc123",
                "capabilities": ["jobs", "files"],
                "updateState": "current"
            ]
        ])
    }
}
