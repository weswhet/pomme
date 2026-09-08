import Foundation
import Testing

@Suite("Temporary MDM helper host contract")
struct MDMTemporaryHelperTests {
    @Test("Workspace paths are fixed UUID-derived direct children of MDM staging")
    func workspacePaths() throws {
        let identifier = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))
        let workspace = try PommeMDMTemporaryHelperWorkspace(requestID: identifier)

        #expect(workspace.helperPath == "\(MDMProfileStaging.guestDirectory)/helper-12345678-1234-1234-1234-123456789abc.bin")
        #expect(workspace.entitlementsPath == "\(MDMProfileStaging.guestDirectory)/helper-12345678-1234-1234-1234-123456789abc.entitlements.plist")
        #expect(workspace.requestPath == "\(MDMProfileStaging.guestDirectory)/helper-12345678-1234-1234-1234-123456789abc.request.json")
        #expect(workspace.owns(workspace.helperPath))
        #expect(!workspace.owns("/tmp/pomme-helper"))
        #expect(throws: PommeMDMEnrollmentError.self) {
            _ = try PommeMDMTemporaryHelperWorkspace(requestID: identifier, root: "/tmp")
        }
    }

    @Test("Request is bounded, canonical, and binds post-sign helper and profile digests")
    func requestEncoding() throws {
        let identifier = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))
        let receipt = try PommeMDMProfileTransferReceipt(
            destination: "\(MDMProfileStaging.guestDirectory)/profile.mobileconfig",
            bytes: 4,
            sha256: String(repeating: "a", count: 64)
        )
        let request = try PommeMDMTemporaryHelperRequest(
            requestID: identifier,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            helperSHA256: String(repeating: "b", count: 64),
            profile: receipt,
            mode: .supervised
        )
        let decoded = try JSONDecoder().decode(
            PommeMDMTemporaryHelperRequest.self,
            from: request.encoded()
        )

        #expect(decoded == request)
        #expect(decoded.action == "enroll")
        #expect(decoded.requestID == identifier.uuidString.lowercased())
        #expect(decoded.profilePath == receipt.destination)
        #expect(decoded.profileSHA256 == receipt.sha256)
        #expect(decoded.mode.rawValue == MDMEnrollmentMode.supervised.rawValue)
        #expect((try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])?["mode"] as? String == "supervised")

        var legacy = try #require(try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        legacy.removeValue(forKey: "mode")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyRequest = try JSONDecoder().decode(PommeMDMTemporaryHelperRequest.self, from: legacyData)
        #expect(legacyRequest.mode.rawValue == MDMEnrollmentMode.unapproved.rawValue)
    }

    @Test("Helper is gated on pre-existing SIP and AMFI disabled evidence")
    func securityGate() throws {
        let capturedBaseline = try makeBaseline(sipDisabled: true, amfiDisabled: true)
        try PommeMDMTemporaryHelperSecurityGate.requireSIPAndAMFIDisabled(capturedBaseline)

        #expect(throws: PommeMDMEnrollmentError.self) {
            try PommeMDMTemporaryHelperSecurityGate.requireSIPAndAMFIDisabled(
                try makeBaseline(sipDisabled: false, amfiDisabled: true)
            )
        }
        #expect(throws: PommeMDMEnrollmentError.self) {
            try PommeMDMTemporaryHelperSecurityGate.requireSIPAndAMFIDisabled(
                try makeBaseline(sipDisabled: true, amfiDisabled: false)
            )
        }
    }

    @Test("Only completed helpers publish a profile identifier; host owns cleanup proof")
    func resultValidation() throws {
        let result = try PommeMDMTemporaryHelperResult.decode(.object([
            "completed": .bool(true),
            "profileIdentifier": .string("com.example.mdm")
        ]))
        #expect(result.profileIdentifier == "com.example.mdm")

        #expect(throws: PommeMDMEnrollmentError.self) {
            _ = try PommeMDMTemporaryHelperResult.decode(.object([
                "completed": .bool(true),
                "profileIdentifier": .string("com.example.mdm"),
                "unexpected": .bool(true)
            ]))
        }
    }

    @Test("Host stages, signs, request-binds, launches, and independently cleans exact helper artifacts")
    func hostTransactionOrderingAndCleanup() async throws {
        let artifact = try PommeMDMTemporaryHelperArtifact(
            source: URL(fileURLWithPath: "/tmp/canonical-pomme"),
            sha256: String(repeating: "a", count: 64)
        )
        let profile = try PommeMDMProfileTransferReceipt(
            destination: "\(MDMProfileStaging.guestDirectory)/profile.mobileconfig",
            bytes: 4,
            sha256: String(repeating: "b", count: 64)
        )
        let reservedWorkspace = try PommeMDMTemporaryHelperWorkspace(
            requestID: try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        )
        let capturedBaseline = try makeBaseline(sipDisabled: true, amfiDisabled: true)
        let recorder = Recorder()
        let host = PommeMDMTemporaryHelperHost(dependencies: .init(
            canonicalArtifact: { artifact },
            prepare: { _ in await recorder.append("prepare") },
            transferFile: { _, path in
                await recorder.append("file:\(path)")
                return try PommeMDMAuthenticatedFileTransferReceipt(
                    destination: path,
                    bytes: 4,
                    sha256: String(repeating: "a", count: 64)
                )
            },
            transferData: { data, path in
                await recorder.append("data:\(path)")
                return try PommeMDMAuthenticatedFileTransferReceipt(
                    destination: path,
                    bytes: data.count,
                    sha256: PommeMDMTemporaryHelperRequest.digest(of: data)
                )
            },
            resignAndVerify: { _ in
                await recorder.append("sign")
                return String(repeating: "c", count: 64)
            },
            launch: { _, request, _, _ in
                await recorder.append("launch:\(request.helperSHA256):\(request.mode.rawValue)")
                return .object([
                    "completed": .bool(true),
                    "profileIdentifier": .string("com.example.mdm")
                ])
            },
            cleanup: { _ in await recorder.append("cleanup") },
            now: { Date(timeIntervalSince1970: 1_000) }
        ), workspace: reservedWorkspace)

        let result = try await host.enroll(
            profile: profile,
            mode: .supervised,
            baseline: capturedBaseline,
            timeout: 60
        )
        #expect(result.profileIdentifier == "com.example.mdm")
        let values = await recorder.values()
        #expect(values.count == 7)
        #expect(values[0] == "prepare")
        #expect(values[1] == "file:\(reservedWorkspace.helperPath)")
        #expect(values[2] == "data:\(reservedWorkspace.entitlementsPath)")
        #expect(values[3] == "sign")
        #expect(values[4] == "data:\(reservedWorkspace.requestPath)")
        #expect(values[5].hasPrefix("launch:"))
        #expect(values[5].hasSuffix(":supervised"))
        #expect(values[6] == "cleanup")
    }

    private func makeBaseline(
        sipDisabled: Bool,
        amfiDisabled: Bool
    ) throws -> PommeMDMEnrollmentStateBaseline {
        .init(
            sip: try PommeProvisioningCoding.encode(JSONValue.object([
                "operation": .string("sip.status"),
                "sipDisabled": .bool(sipDisabled)
            ])),
            amfi: try PommeProvisioningCoding.encode(JSONValue.object([
                "operation": .string("amfi.status"),
                "amfiDisabled": .bool(amfiDisabled)
            ])),
            runState: .running(.normal)
        )
    }

    private actor Recorder {
        private var recorded: [String] = []
        func append(_ value: String) { recorded.append(value) }
        func values() -> [String] { recorded }
    }
}
