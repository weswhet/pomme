import Foundation
import Security
import Testing

@Suite("Temporary MDM helper host contract")
struct MDMTemporaryHelperTests {
    @Test("Cleanup signature verification uses inline requirements and rejects mismatches")
    func cleanupInlineRequirement() throws {
        for (requirement, succeeds) in [("anchor apple", true), ("identifier \"invalid.pomme.test\"", false)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = PommeMDMCleanupFailure.verificationArguments(path: "/usr/bin/true", requirement: requirement)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect((process.terminationStatus == 0) == succeeds)
        }
        #expect(PommeMDMCleanupFailure(stage: .verifyBootstrap).errorDescription?.contains("verifyBootstrap") == true)
    }

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

    @Test("Host cleans successful helpers and preserves every failed helper", arguments: [false, true])
    func hostTransactionOrderingAndCleanup(fail: Bool) async throws {
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
                if fail { throw PommeMDMEnrollmentError.enrollmentFailed }
                return .object([
                    "completed": .bool(true),
                    "profileIdentifier": .string("com.example.mdm")
                ])
            },
            cleanup: { _ in await recorder.append("cleanup") },
            now: { Date(timeIntervalSince1970: 1_000) }
        ), workspace: reservedWorkspace)

        do {
            let result = try await host.enroll(
                profile: profile, mode: .supervised, baseline: capturedBaseline, timeout: 60
            )
            #expect(!fail)
            #expect(result.profileIdentifier == "com.example.mdm")
        } catch {
            #expect(fail)
            #expect(error as? PommeMDMEnrollmentError == .enrollmentFailed)
        }
        let values = await recorder.values()
        #expect(values.count == (fail ? 6 : 7))
        #expect(values[0] == "prepare")
        #expect(values[1] == "file:\(reservedWorkspace.helperPath)")
        #expect(values[2] == "data:\(reservedWorkspace.entitlementsPath)")
        #expect(values[3] == "sign")
        #expect(values[4] == "data:\(reservedWorkspace.requestPath)")
        #expect(values[5].hasPrefix("launch:"))
        #expect(values[5].hasSuffix(":supervised"))
        if !fail { #expect(values[6] == "cleanup") }
        else { #expect(!values.contains("cleanup")) }
    }

    @Test("Keychain failure diagnostics contain stage, numeric status, and flags only")
    func keychainDiagnostics() throws {
        let collector = GuestMDMDiagnostics.Collector()
        GuestMDMDiagnostics.$current.withValue(collector) {
            #expect(throws: GuestInternalError.self) {
                _ = try GuestMDMIdentityKeychain.select(operations: .init(
                    open: { _ in (errSecSuccess, 1) },
                    status: { _ in (errSecSuccess, SecKeychainStatus(0)) },
                    unlockPrivate: { _ in errSecSuccess }
                ))
            }
        }
        #expect(collector.failureStage == "privateKeychainStatus")
        #expect(!collector.identityImportAttempted)
        let envelope: JSONValue = .object([
            "completed": .bool(false), "errorCode": .string("enrollment-failed"),
            "diagnostics": collector.value,
            "failureStage": .string("privateKeychainStatus"),
            "identityImportAttempted": .bool(false)
        ])
        #expect(try GuestMDMDiagnostics.validated(from: envelope) == collector.value)
        do {
            _ = try PommeMDMTemporaryHelperResult.decode(envelope, detailedFailure: true)
            Issue.record("Expected a completed helper failure")
        } catch let failure as PommeMDMHelperFailure {
            #expect(failure.error == .enrollmentFailed)
            #expect(failure.failureStage == .privateKeychainStatus)
            #expect(failure.beforeIdentityImport)
        }
        let encoded = String(decoding: try JSONEncoder().encode(collector.value), as: UTF8.self)
        #expect(!encoded.contains("MCXPrivate"))
        #expect(!encoded.contains("/Library/"))
    }

    @Test("Diagnostics reject arbitrary strings, surplus fields, and contradictory import proof")
    func diagnosticsRejectUnsafeData() throws {
        let safe: [String: JSONValue] = [
            "stage": .string("pkcs12Import"), "event": .string("begin"), "elapsedMillis": .integer(0)
        ]
        var unsafe = safe
        unsafe["message"] = .string("secret profile or native error")
        for record in [unsafe, safe.merging(["stage": .string("private profile bytes")]) { _, new in new }] {
            #expect(throws: PommeMDMEnrollmentError.self) {
                _ = try GuestMDMDiagnostics.validated(from: .object(["diagnostics": .array([.object(record)])]))
            }
        }
        #expect(throws: PommeMDMEnrollmentError.self) {
            _ = try GuestMDMDiagnostics.validated(from: .object([
                "diagnostics": .array([.object(safe)]), "identityImportAttempted": .bool(false)
            ]))
        }
    }

    @Test("Legacy and ambiguous helper failures cannot authorize another identity import")
    func retryProofRequiresCompletedPreImportFailure() throws {
        for code in ["enrollment-failed", "enrollment-outcome-unknown"] {
            do {
                _ = try PommeMDMTemporaryHelperResult.decode(.object([
                    "completed": .bool(false), "errorCode": .string(code)
                ]), detailedFailure: true)
                Issue.record("Expected helper failure")
            } catch let failure as PommeMDMHelperFailure {
                #expect(!failure.beforeIdentityImport)
                #expect(failure.error == (code == "enrollment-failed" ? .enrollmentFailed : .enrollmentOutcomeUnknown))
            }
        }
    }

    @Test("Post-import and XPC stages cannot prove a safe retry", arguments: ["xpcInstall", "identityAttachment", "privateKeyReference"])
    func postImportStageCannotAuthorizeRetry(stage: String) throws {
        do {
            _ = try PommeMDMTemporaryHelperResult.decode(.object([
                "completed": .bool(false), "errorCode": .string("enrollment-failed"),
                "identityImportAttempted": .bool(false), "failureStage": .string(stage),
                "diagnostics": .array([.object([
                    "stage": .string(stage), "event": .string("failed"), "elapsedMillis": .integer(0)
                ])])
            ]), detailedFailure: true)
            Issue.record("Expected helper failure")
        } catch let failure as PommeMDMHelperFailure {
            #expect(!failure.beforeIdentityImport)
            #expect(failure.error == .enrollmentFailed)
        }
    }

    @Test("XPC failure records its stage and retains unknown-outcome classification")
    func xpcDiagnostics() throws {
        let collector = GuestMDMDiagnostics.Collector()
        GuestMDMDiagnostics.$current.withValue(collector) {
            do {
                _ = try GuestMDMEnrollment(
                    request: { _, _ in throw GuestInternalError.mdm("private native reply") },
                    profileArchiveOverride: Data([1])
                ).enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/test.mobileconfig")
                Issue.record("Expected XPC failure")
            } catch GuestInternalError.mdmOutcomeUnknown {
                #expect(collector.failureStage == "xpcSetup")
            } catch { Issue.record("Unexpected error classification") }
        }
        let encoded = String(decoding: try JSONEncoder().encode(collector.value), as: UTF8.self)
        #expect(!encoded.contains("private native reply"))
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
