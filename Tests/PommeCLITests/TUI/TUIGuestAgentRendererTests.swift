import Testing

@Suite("TUI guest-agent status rendering")
struct TUITransportRendererTests {
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
            "running": true,
            "vmState": "running",
            "bootMode": "normal",
            "guestAgent": [
                "connection": connection,
                "role": role,
                "protocolVersion": "3",
                "digest": "abc123",
                "capabilities": ["jobs", "files"],
                "updateState": "current"
            ]
        ])
    }
}
