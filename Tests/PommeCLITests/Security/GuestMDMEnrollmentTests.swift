import Darwin
import Foundation
import Testing

@Suite("Guest MDM enrollment")
struct GuestMDMEnrollmentTests {
    @Test("Two-phase XPC success extracts response fields")
    func success() throws {
        var commands: [String] = []
        var cleanupCount = 0
        let enrollment = GuestMDMEnrollment(requestTimeout: 1, request: { request, _ in
            commands.append(request["Command"] as? String ?? "")
            if request["Command"] as? String == "InstallMDMv1Profile" {
                return ["__Success__": true, "Response": ["UpdatedMDMProfileArchive": Data([4, 5, 6])]]
            }
            return [
                "__Success__": true,
                "Response": ["ProfileIdentifier": "com.example.mdm", "ServerSupportsPerUserConnections": true]
            ]
        }, profileArchiveOverride: Data([1, 2, 3]), cleanupImportedIdentityOverride: {
            cleanupCount += 1
        })
        let result = try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
        #expect(result.exitCode == 0)
        #expect(commands == ["InstallMDMv1Profile", "InstallProfile"])
        #expect(result.payload["profileIdentifier"] as? String == "com.example.mdm")
        #expect(cleanupCount == 0)
    }

    @Test("User-intent approval sends the private daemon command explicitly")
    func userIntentApproval() throws {
        var captured: [String: Any] = [:]
        let enrollment = GuestMDMEnrollment(
            requestTimeout: 1,
            request: { request, _ in
                captured = request
                return ["__Success__": true]
            }
        )
        let result = try enrollment.markUserApproved(profileIdentifier: "org.example.mdm")
        #expect(captured["Command"] as? String == "FlagAsUserIntended")
        #expect(captured["ProfileIdentifier"] as? String == "org.example.mdm")
        #expect(result.payload["approvalCommand"] as? String == "FlagAsUserIntended")
        #expect(result.payload["technicalUserApproval"] as? Bool == true)
    }

    @Test("MDM profile selection is independent of configuration-profile ordering")
    func profileSelectionUsesRequestedIdentifier() {
        let selection = PommeCore.mdmProfileIdentifierSelection(
            firstIdentifier: "com.example.unrelated",
            requestedFound: true,
            requested: "org.example.mdm"
        )
        #expect(selection.observed == "org.example.mdm")
        #expect(selection.matchesRequested)

        let missing = PommeCore.mdmProfileIdentifierSelection(
            firstIdentifier: "com.example.unrelated",
            requestedFound: false,
            requested: "org.example.mdm"
        )
        #expect(missing.observed == "com.example.unrelated")
        #expect(!missing.matchesRequested)

        #expect(!PommeCore.mdmApprovalVerificationSucceeded(
            [
                "ok": true,
                "mdmEnrolled": true,
                "userApproved": true,
                "profileIdentifierMatchesRequested": false
            ],
            expectedProfileIdentifier: "org.example.mdm"
        ))
        #expect(PommeCore.mdmApprovalVerificationSucceeded(
            [
                "ok": true,
                "mdmEnrolled": true,
                "userApproved": true,
                "profileIdentifierMatchesRequested": true
            ],
            expectedProfileIdentifier: "org.example.mdm"
        ))
        #expect(!PommeCore.mdmApprovalVerificationSucceeded(
            [
                "ok": false,
                "mdmEnrolled": true,
                "userApproved": true,
                "profileIdentifierMatchesRequested": true
            ],
            expectedProfileIdentifier: "org.example.mdm"
        ))
    }

    @Test("Malformed setup response is rejected")
    func malformedResponse() {
        let enrollment = GuestMDMEnrollment(
            requestTimeout: 1,
            request: { _, _ in ["__Success__": true, "Response": [:]] },
            profileArchiveOverride: Data([1])
        )
        #expect(throws: GuestInternalError.self) {
            try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
        }
    }

    @Test("Persistent MDM operation rejects undeclared fields and paths outside staging")
    func persistentOperationRejectsUnsafeInput() {
        #expect(throws: PommeAgentOperationError.self) {
            _ = try PersistentMDMEnrollmentOperation(payload: .object([
                "action": .string("enroll"),
                "profilePath": .string("/tmp/profile.mobileconfig"),
                "timeout": .integer(60)
            ]))
        }
        #expect(throws: PommeAgentOperationError.self) {
            _ = try PersistentMDMEnrollmentOperation(payload: .object([
                "action": .string("enroll"),
                "profilePath": .string("\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig"),
                "timeout": .integer(60),
                "password": .string("must-not-pass")
            ]))
        }
    }

    @Test("Persistent MDM operation accepts only bounded typed requests")
    func persistentOperationAcceptsTypedRequest() throws {
        let operation = try PersistentMDMEnrollmentOperation(payload: .object([
            "action": .string("enroll"),
            "profilePath": .string("\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig"),
            "timeout": .integer(60)
        ]))
        #expect(operation == .enroll(
            profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
            timeout: 60
        ))
    }

    @Test("Staging preparation creates an owner-private root and is idempotent")
    func stagingPreparation() throws {
        let temporary = try MDMStagingTemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appendingPathComponent("pomme-mdm-enrollment", isDirectory: true)
        let uid = geteuid()
        let gid = getegid()

        #expect(try GuestMDMStaging.prepare(
            at: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        ) == .object(["ready": .bool(true)]))
        #expect(try GuestMDMStaging.prepare(
            at: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        ) == .object(["ready": .bool(true)]))

        var info = stat()
        #expect(lstat(root.path, &info) == 0)
        #expect(info.st_uid == uid)
        #expect(info.st_gid == gid)
        #expect(info.st_mode & 0o7777 == 0o700)
    }

    @Test("An existing staging root with unsafe mode is never repaired or used")
    func stagingPreparationRejectsUnsafeRoot() throws {
        let temporary = try MDMStagingTemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appendingPathComponent("pomme-mdm-enrollment", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let uid = geteuid()
        let gid = getegid()

        #expect(throws: GuestMDMStagingError.unsafeRoot) {
            try GuestMDMStaging.prepare(
                at: root,
                effectiveOwner: uid,
                expectedOwner: uid,
                expectedGroup: gid
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test("Cleanup removes only a validated direct-child profile and proves absence")
    func stagingCleanup() throws {
        let temporary = try MDMStagingTemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appendingPathComponent("pomme-mdm-enrollment", isDirectory: true)
        let uid = geteuid()
        let gid = getegid()
        _ = try GuestMDMStaging.prepare(
            at: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        )
        let profile = root.appendingPathComponent("profile.mobileconfig")
        #expect(FileManager.default.createFile(atPath: profile.path, contents: Data([1, 2, 3])))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)

        #expect(try GuestMDMStaging.cleanup(
            profilePath: profile.path,
            rootURL: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        ) == .object(["removed": .bool(true)]))
        #expect(!FileManager.default.fileExists(atPath: profile.path))
        #expect(try GuestMDMStaging.cleanup(
            profilePath: profile.path,
            rootURL: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        ) == .object(["removed": .bool(true)]))
    }

    @Test("Cleanup rejects symlink profiles and leaves their targets untouched")
    func stagingCleanupRejectsSymlink() throws {
        let temporary = try MDMStagingTemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appendingPathComponent("pomme-mdm-enrollment", isDirectory: true)
        let target = temporary.url.appendingPathComponent("outside-profile")
        let profile = root.appendingPathComponent("profile.mobileconfig")
        let uid = geteuid()
        let gid = getegid()
        _ = try GuestMDMStaging.prepare(
            at: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        )
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data([7, 8, 9])))
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)

        #expect(throws: GuestMDMStagingError.unsafeProfile) {
            try GuestMDMStaging.cleanup(
                profilePath: profile.path,
                rootURL: root,
                effectiveOwner: uid,
                expectedOwner: uid,
                expectedGroup: gid
            )
        }
        #expect(FileManager.default.fileExists(atPath: profile.path))
        #expect(try Data(contentsOf: target) == Data([7, 8, 9]))
    }

    @Test("Cleanup rejects paths outside the fixed direct-child boundary")
    func stagingCleanupRejectsPathTraversal() throws {
        let temporary = try MDMStagingTemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appendingPathComponent("pomme-mdm-enrollment", isDirectory: true)
        let uid = geteuid()
        let gid = getegid()
        _ = try GuestMDMStaging.prepare(
            at: root,
            effectiveOwner: uid,
            expectedOwner: uid,
            expectedGroup: gid
        )

        for path in [
            root.appendingPathComponent("../profile.mobileconfig").path,
            root.appendingPathComponent("./profile.mobileconfig").path,
            "/tmp/profile.mobileconfig"
        ] {
            #expect(throws: GuestMDMStagingError.invalidProfile) {
                try GuestMDMStaging.cleanup(
                    profilePath: path,
                    rootURL: root,
                    effectiveOwner: uid,
                    expectedOwner: uid,
                    expectedGroup: gid
                )
            }
        }
    }

    @Test("Injected XPC timeout is preserved")
    func timeout() {
        let enrollment = GuestMDMEnrollment(
            requestTimeout: 0.01,
            request: { _, _ in throw GuestInternalError.timedOut },
            profileArchiveOverride: Data([1])
        )
        #expect(throws: GuestInternalError.self) {
            try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
        }
    }

    @Test("A failed enrollment removes only its newly imported identity")
    func failedEnrollmentCleanup() {
        var cleanupCount = 0
        let enrollment = GuestMDMEnrollment(
            requestTimeout: 1,
            request: { _, _ in throw GuestInternalError.mdm("injected install failure") },
            profileArchiveOverride: Data([1]),
            cleanupImportedIdentityOverride: { cleanupCount += 1 }
        )
        #expect(throws: GuestInternalError.self) {
            try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
        }
        #expect(cleanupCount == 1)
    }

    @Test("Identity cleanup failure is reported with the enrollment failure")
    func cleanupFailure() {
        let enrollment = GuestMDMEnrollment(
            requestTimeout: 1,
            request: { _, _ in throw GuestInternalError.mdm("injected install failure") },
            profileArchiveOverride: Data([1]),
            cleanupImportedIdentityOverride: { throw CleanupFailure() }
        )
        #expect(throws: GuestInternalError.self) {
            try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
        }
    }

    @Test("State restoration runs after successful enrollment work")
    func stateRestorationOnSuccess() throws {
        let restorer = RecordingRestorer()
        let result: String = try MDMEnrollmentStateTransaction.execute(using: restorer) {
            restorer.events.append("operation")
            return "enrolled"
        }

        #expect(result == "enrolled")
        #expect(restorer.events == ["prepare", "operation", "restore"])
    }

    @Test("State restoration runs after failed enrollment work")
    func stateRestorationOnFailure() {
        let restorer = RecordingRestorer()

        #expect(throws: EnrollmentFailure.self) {
            _ = try MDMEnrollmentStateTransaction.execute(using: restorer) {
                restorer.events.append("operation")
                throw EnrollmentFailure()
            } as String
        }
        #expect(restorer.events == ["prepare", "operation", "restore"])
    }

    @Test("Restoration failure does not disclose the primary enrollment error")
    func stateRestorationFailureIsRedacted() {
        let restorer = RecordingRestorer(restoreError: true)

        #expect(throws: MDMEnrollmentRestorationError.self) {
            _ = try MDMEnrollmentStateTransaction.execute(using: restorer) {
                throw EnrollmentFailure()
            } as String
        }
        #expect(restorer.events == ["prepare", "restore"])
    }

    @Test("Preparation failure still invokes restoration")
    func preparationFailureRestoresState() {
        let restorer = RecordingRestorer(prepareError: true)

        #expect(throws: EnrollmentFailure.self) {
            _ = try MDMEnrollmentStateTransaction.execute(using: restorer) {
                "unreachable"
            } as String
        }
        #expect(restorer.events == ["prepare", "restore"])
    }

    private struct CleanupFailure: Error {}
    private struct EnrollmentFailure: Error {}

    private final class RecordingRestorer: @unchecked Sendable, MDMEnrollmentStateRestoring {
        var events: [String] = []
        let prepareError: Bool
        let restoreError: Bool

        init(prepareError: Bool = false, restoreError: Bool = false) {
            self.prepareError = prepareError
            self.restoreError = restoreError
        }

        func prepareForMDMEnrollment() throws {
            events.append("prepare")
            if prepareError {
                throw EnrollmentFailure()
            }
        }

        func restoreAfterMDMEnrollment() throws {
            events.append("restore")
            if restoreError {
                throw CleanupFailure()
            }
        }
    }
}

private struct MDMStagingTemporaryDirectory {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appendingPathComponent("pomme-mdm-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
