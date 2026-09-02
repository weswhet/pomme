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
