import Foundation
import Testing

@Suite("Offline status serialization")
struct PommeStatusSerializationTests {
    @Test("offline status guest-agent optionals are JSON-safe")
    func offlineStatusPayloadConvertsToOperationResult() throws {
        let reference = offlineReference()
        let payload = try PommeCore.vmStatusPayload(reference: reference)

        #expect(payload["helperRunning"] as? Bool == false)
        let result = PommeOperationResult(
            title: "Status",
            vmName: reference.name,
            ok: payload["ok"] as? Bool ?? false,
            hostExitCode: 1,
            text: "offline",
            payload: payload
        )

        try assertJSONSafe(result.payload)
        let guestAgent = try #require(result.payload["guestAgent"] as? [String: Any])
        #expect(guestAgent["protocolVersion"] is NSNull)
        #expect(guestAgent["executableDigest"] is NSNull)
    }

    @Test("The status line does not claim a background job count")
    func statusLineOmitsJobs() {
        let running: [String: Any] = [
            "vmState": "running", "bootMode": "normal", "helperRunning": true,
            "guestAgent": ["connection": "connected", "role": "normal"]
        ]

        let text = PommeApplication.formatStatus(running)

        #expect(text.hasPrefix("VM running boot=normal helper=true"))
        // The agent's job table is read by `jobs list`; this payload never
        // carried it, so a count here could only ever be zero.
        #expect(!text.contains("jobs="))
        #expect(text.contains("guestAgent connection=connected"))
    }

    @Test("An offline status payload carries no jobs field")
    func offlineStatusOmitsJobs() throws {
        let payload = try PommeCore.vmStatusPayload(reference: offlineReference())

        #expect(payload["jobs"] == nil)
        #expect(!PommeApplication.formatStatus(payload).contains("jobs="))
    }

    @Test("offline inspect guest-agent optionals are JSON-safe")
    func offlineInspectPayloadConvertsToOperationResult() throws {
        let reference = offlineReference()
        let payload = try PommeCore.vmInspectPayload(reference: reference)

        #expect(payload["helperRunning"] as? Bool == false)
        let result = PommeOperationResult(
            title: "Inspect",
            vmName: reference.name,
            ok: payload["ok"] as? Bool ?? false,
            hostExitCode: 1,
            text: "offline",
            payload: payload
        )

        try assertJSONSafe(result.payload)
        let guestAgent = try #require(result.payload["guestAgent"] as? [String: Any])
        #expect(guestAgent["protocolVersion"] is NSNull)
        #expect(guestAgent["executableDigest"] is NSNull)
    }

    private func offlineReference() -> VMReference {
        let id = UUID().uuidString
        return VMReference(
            name: "offline-\(id)",
            bundle: BundleLayout(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pomme-offline-status-\(id)", isDirectory: true)
            )
        )
    }

    private func assertJSONSafe(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(!data.isEmpty)
    }
}
