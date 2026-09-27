import Darwin
import Foundation
import Testing

@Suite("Guest MDM enrollment")
struct GuestMDMEnrollmentTests {
    @Test("Private authentication rejection selects only the explicit readable System store before import")
    func privateAuthenticationFallback() throws {
        for readable in [false, true] {
            var opened: [String] = []
            let collector = GuestMDMDiagnostics.Collector()
            try GuestMDMDiagnostics.$current.withValue(collector) { () throws -> Void in
                let operations = GuestMDMIdentityKeychainOperations<String>(
                    open: { path in opened.append(path); return (errSecSuccess, path) },
                    status: { path in (errSecSuccess, path == GuestMDMIdentityKeychain.privatePath || readable ? kSecReadPermStatus : 0) },
                    unlockPrivate: { _ in errSecAuthFailed })
                if readable {
                    #expect(try GuestMDMIdentityKeychain.select(operations: operations) == GuestMDMIdentityKeychain.systemPath)
                } else {
                    #expect(throws: GuestInternalError.self) { _ = try GuestMDMIdentityKeychain.select(operations: operations) }
                }
            }
            #expect(opened == [GuestMDMIdentityKeychain.privatePath, GuestMDMIdentityKeychain.systemPath])
            #expect(!collector.identityImportAttempted)
            #expect(collector.failureStage == "systemKeychainStatus")
        }
    }

    @Test("Credential diagnostics preserve only allowlisted reader errors")
    func credentialFailureDiagnostics() throws {
        for failure in PommeGuestOwnerCredentialError.allCases {
            let collector = GuestMDMDiagnostics.Collector()
            GuestMDMDiagnostics.$current.withValue(collector) {
                #expect(throws: GuestInternalError.self) {
                    _ = try GuestMDMIdentityKeychain.unlockWithGuestPassword(
                        readPassword: { throw failure },
                        unlock: { _ in Issue.record("Unexpected unlock"); return errSecSuccess })
                }
            }
            #expect(collector.failureStage == "privateKeychainCredential")
            let data = try JSONEncoder().encode(collector.value)
            #expect(String(decoding: data, as: UTF8.self).contains(failure.code))
            #expect(try GuestMDMDiagnostics.validated(from: .object(["diagnostics": collector.value])) != nil)
        }
        #expect(throws: PommeMDMEnrollmentError.self) {
            _ = try GuestMDMDiagnostics.validated(from: .object(["diagnostics": .array([.object([
                "stage": .string("privateKeychainCredential"), "event": .string("failed"),
                "elapsedMillis": .integer(0), "credentialError": .string("arbitrary-secret")])])]))
        }
    }

    @Test("Guest unlock passes exact UTF-8 password bytes and preserves authentication failure")
    func guestPasswordUnlock() throws {
        let result = try GuestMDMIdentityKeychain.unlockWithGuestPassword(
            readPassword: { "test-秘密-password" },
            unlock: { bytes in
                #expect(bytes == Data("test-秘密-password".utf8))
                return errSecAuthFailed
            })
        #expect(result == errSecAuthFailed)
    }

    @Test("Unavailable guest password never invokes unlock or exposes reader errors")
    func unavailableGuestPassword() {
        for missing in [false, true] {
            do {
                _ = try GuestMDMIdentityKeychain.unlockWithGuestPassword(
                    readPassword: {
                        if missing { throw NSError(domain: "sensitive-reader-details", code: 1) }
                        return ""
                    }, unlock: { _ in Issue.record("Unexpected unlock"); return errSecSuccess })
                Issue.record("Expected credential failure")
            } catch {
                #expect(!error.localizedDescription.contains("sensitive-reader-details"))
            }
        }
    }

    @Test("Missing private keychain uses the explicit guest System keychain")
    func missingPrivateKeychainSelectsSystem() throws {
        var paths: [String] = []
        let selected = try GuestMDMIdentityKeychain.select(operations: GuestMDMIdentityKeychainOperations<String>(
            open: { path in
                paths.append(path)
                return path == GuestMDMIdentityKeychain.privatePath ? (errSecNoSuchKeychain, nil) : (errSecSuccess, "system")
            },
            status: { _ in (errSecSuccess, kSecUnlockStateStatus | kSecReadPermStatus) }
        ))
        #expect(selected == "system")
        #expect(paths == [GuestMDMIdentityKeychain.privatePath, GuestMDMIdentityKeychain.systemPath])
    }

    @Test("Sequoia reports missing private keychain during status and defers System access to securityd")
    func deferredMissingKeychain() throws {
        var paths: [String] = []
        let selected = try GuestMDMIdentityKeychain.select(operations: GuestMDMIdentityKeychainOperations<String>(
            open: { path in paths.append(path); return (errSecSuccess, path) },
            status: { path in path == GuestMDMIdentityKeychain.privatePath
                ? (errSecNoSuchKeychain, 0) : (errSecSuccess, kSecReadPermStatus) }
        ))
        #expect(selected == GuestMDMIdentityKeychain.systemPath)
        #expect(paths == [GuestMDMIdentityKeychain.privatePath, GuestMDMIdentityKeychain.systemPath])
    }

    @Test("Existing private keychain errors never fall back and locked keychains are rejected")
    func privateKeychainFailsClosed() {
        for failure in [errSecAuthFailed, errSecInteractionNotAllowed] {
            var paths: [String] = []
            #expect(throws: GuestInternalError.self) {
                _ = try GuestMDMIdentityKeychain.select(operations: GuestMDMIdentityKeychainOperations<String>(
                    open: { path in paths.append(path); return (failure, nil) },
                    status: { _ in (errSecSuccess, kSecUnlockStateStatus) }
                ))
            }
            #expect(paths == [GuestMDMIdentityKeychain.privatePath])
        }
        #expect(throws: GuestInternalError.self) {
            _ = try GuestMDMIdentityKeychain.select(operations: GuestMDMIdentityKeychainOperations<String>(
                open: { _ in (errSecSuccess, "private") },
                status: { _ in (errSecSuccess, 0) }
            ))
        }
    }

    @Test("Private MDM keychain unlock is conditional and its resulting status is verified")
    func privateUnlock() throws {
        for initiallyUnlocked in [false, true] {
            var unlocked = initiallyUnlocked
            var unlockCalls = 0
            let selected = try GuestMDMIdentityKeychain.select(operations: GuestMDMIdentityKeychainOperations<String>(
                open: { _ in (errSecSuccess, "private") },
                status: { _ in (errSecSuccess, unlocked ? kSecUnlockStateStatus : kSecReadPermStatus) },
                unlockPrivate: { _ in unlockCalls += 1; unlocked = true; return errSecSuccess }
            ))
            #expect(selected == "private")
            #expect(unlockCalls == (initiallyUnlocked ? 0 : 1))
        }
    }

    @Test("Failed unlock or still-locked readback stops before identity import")
    func privateUnlockFailure() {
        for unlockStatus in [errSecAuthFailed, errSecSuccess] {
            let collector = GuestMDMDiagnostics.Collector()
            GuestMDMDiagnostics.$current.withValue(collector) {
                #expect(throws: GuestInternalError.self) {
                    _ = try GuestMDMIdentityKeychain.select(operations: GuestMDMIdentityKeychainOperations<String>(
                        open: { _ in (errSecSuccess, "private") },
                        status: { _ in (errSecSuccess, SecKeychainStatus(0)) },
                        unlockPrivate: { _ in unlockStatus }
                    ))
                }
            }
            #expect(!collector.identityImportAttempted)
            #expect(collector.failureStage == (unlockStatus == errSecSuccess ? "privateKeychainStatus" : "privateKeychainUnlock"))
        }
    }

    @Test("Two-phase XPC success extracts response fields")
    func success() throws {
        var commands: [String] = []
        let enrollment = GuestMDMEnrollment(requestTimeout: 1, request: { request, _ in
            commands.append(request["Command"] as? String ?? "")
            if request["Command"] as? String == "InstallMDMv1Profile" {
                return ["__Success__": true, "Response": ["UpdatedMDMProfileArchive": Data([4, 5, 6])]]
            }
            return [
                "__Success__": true,
                "Response": ["ProfileIdentifier": "com.example.mdm", "ServerSupportsPerUserConnections": true]
            ]
        }, profileArchiveOverride: Data([1, 2, 3]))
        let result = try enrollment.enroll(
            profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
            mode: .unapproved
        )
        #expect(result.exitCode == 0)
        #expect(commands == ["InstallMDMv1Profile", "InstallProfile"])
        #expect(result.payload["profileIdentifier"] as? String == "com.example.mdm")
    }

    @Test("Supervised enrollment approves the installed profile after the install reply")
    func supervisedEnrollmentApprovesAfterInstall() throws {
        var commands: [String] = []
        let enrollment = GuestMDMEnrollment(
            requestTimeout: 1,
            request: { request, _ in
                let command = request["Command"] as? String ?? ""
                commands.append(command)
                switch command {
                case "InstallMDMv1Profile":
                    return ["__Success__": true, "Response": ["UpdatedMDMProfileArchive": Data([4, 5, 6])]]
                case "InstallProfile":
                    return ["__Success__": true, "Response": ["ProfileIdentifier": "com.example.mdm"]]
                case "FlagAsUserIntended":
                    return ["__Success__": true]
                default:
                    return ["__Success__": false]
                }
            },
            profileArchiveOverride: Data([1, 2, 3])
        )

        let result = try enrollment.enroll(
            profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
            mode: .supervised
        )
        #expect(result.exitCode == 0)
        #expect(commands == ["InstallMDMv1Profile", "InstallProfile", "FlagAsUserIntended"])
        #expect(result.payload["approvalCommand"] as? String == "FlagAsUserIntended")
        #expect(result.payload["technicalUserApproval"] as? Bool == true)
    }

    @Test("Fresh supervised install observes the exact profile before approval")
    func freshSupervisedInstallObservesBeforeApproval() throws {
        let expected = Self.profileIdentity()
        var commands: [String] = []
        var observations = 0
        let enrollment = GuestMDMEnrollment(
            request: { request, _ in
                let command = request["Command"] as? String ?? ""
                commands.append(command)
                switch command {
                case "InstallMDMv1Profile":
                    return ["__Success__": true, "Response": ["UpdatedMDMProfileArchive": Data([4, 5, 6])]]
                case "InstallProfile":
                    return ["__Success__": true, "Response": ["ProfileIdentifier": expected.identifier]]
                case "FlagAsUserIntended":
                    #expect(observations == 2)
                    return ["__Success__": true]
                default:
                    return ["__Success__": false]
                }
            },
            profileArchiveOverride: Data([1, 2, 3]),
            profileIdentityOverride: expected,
            installedProfileObservation: { identity, _ in
                observations += 1
                #expect(identity == expected)
                return observations == 1 ? nil : Self.installedIdentity(matching: expected)
            }
        )

        let result = try enrollment.enroll(
            profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
            mode: .supervised
        )
        #expect(commands == ["InstallMDMv1Profile", "InstallProfile", "FlagAsUserIntended"])
        #expect(observations == 2)
        #expect(result.payload["approvalCommand"] as? String == "FlagAsUserIntended")
    }

    @Test("Matching unapproved enrollment reuses the installed profile without XPC")
    func matchingUnapprovedEnrollmentReusesInstalledProfile() throws {
        let expected = Self.profileIdentity()
        var requestCount = 0
        var observations = 0
        let enrollment = GuestMDMEnrollment(
            request: { _, _ in
                requestCount += 1
                return ["__Success__": false]
            },
            profileArchiveOverride: Data([1, 2, 3]),
            profileIdentityOverride: expected,
            installedProfileObservation: { identity, _ in
                observations += 1
                #expect(identity == expected)
                return Self.installedIdentity(matching: expected)
            }
        )

        let result = try enrollment.enroll(
            profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
            mode: .unapproved
        )
        #expect(requestCount == 0)
        #expect(observations == 1)
        #expect(result.payload["reused"] as? Bool == true)
        #expect(result.payload["profileIdentifier"] as? String == expected.identifier)
    }

    @Test("Matching supervised upgrade emits only FlagAsUserIntended")
    func matchingSupervisedUpgradeOnlyApprovesInstalledProfile() throws {
        let expected = Self.profileIdentity()
        var commands: [String] = []
        var observations = 0
        let enrollment = GuestMDMEnrollment(
            request: { request, _ in
                let command = request["Command"] as? String ?? ""
                commands.append(command)
                return ["__Success__": command == "FlagAsUserIntended"]
            },
            profileArchiveOverride: Data([1, 2, 3]),
            profileIdentityOverride: expected,
            installedProfileObservation: { identity, _ in
                observations += 1
                #expect(identity == expected)
                return Self.installedIdentity(matching: expected)
            }
        )

        let result = try enrollment.enroll(
            profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
            mode: .supervised
        )
        #expect(commands == ["FlagAsUserIntended"])
        #expect(observations == 1)
        #expect(result.payload["reused"] as? Bool == true)
        #expect(result.payload["approvalCommand"] as? String == "FlagAsUserIntended")
    }

    @Test("Conflicting installed identity rejects before XPC or identity import")
    func conflictingInstalledIdentityHasNoSideEffects() {
        let expected = Self.profileIdentity()
        var requestCount = 0
        var importAttempts = 0
        let enrollment = GuestMDMEnrollment(
            request: { _, _ in
                requestCount += 1
                return ["__Success__": true]
            },
            profileArchiveOverride: Data([1, 2, 3]),
            profileIdentityOverride: expected,
            installedProfileObservation: { _, _ in
                Self.installedIdentity(
                    identifier: "org.example.conflict",
                    uuid: expected.uuid,
                    serverURL: expected.serverURL
                )
            },
            identityImportObserver: {
                importAttempts += 1
            }
        )

        #expect(throws: GuestInternalError.self) {
            try enrollment.enroll(
                profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig",
                mode: .unapproved
            )
        }
        #expect(requestCount == 0)
        #expect(importAttempts == 0)
    }

    @Test("Setup rejection never advances to final install")
    func setupRejectionDoesNotInstall() {
        var commands: [String] = []
        let enrollment = GuestMDMEnrollment(request: { request, _ in
            commands.append(request["Command"] as? String ?? "")
            return ["__Success__": false, "Response": ["UpdatedMDMProfileArchive": Data([4])]]
        }, profileArchiveOverride: Data([1]))
        #expect(throws: GuestInternalError.self) {
            try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
        }
        #expect(commands == ["InstallMDMv1Profile"])
    }

    @Test("Lost final install reply reports unknown outcome without retrying")
    func lostFinalReplyRetainsIdentity() {
        let enrollment = GuestMDMEnrollment(request: { request, _ in
            if request["Command"] as? String == "InstallMDMv1Profile" {
                return ["__Success__": true, "Response": ["UpdatedMDMProfileArchive": Data([4])]]
            }
            throw GuestInternalError.timedOut
        }, profileArchiveOverride: Data([1]))
        do {
            _ = try enrollment.enroll(profilePath: "\(GuestMDMEnrollment.stagingDirectory)/profile.mobileconfig")
            Issue.record("Expected unknown enrollment outcome")
        } catch GuestInternalError.mdmOutcomeUnknown {
            // Expected: daemon state is not safe to undo or retry.
        } catch {
            Issue.record("Expected the closed unknown-outcome error")
        }
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

    private static func profileIdentity() -> MDMEnrollmentProfileIdentity {
        MDMEnrollmentProfileIdentity(
            identifier: "org.example.mdm",
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            serverURL: "https://mdm.example.test/server",
            digest: String(repeating: "a", count: 64)
        )
    }

    private static func installedIdentity(
        matching expected: MDMEnrollmentProfileIdentity
    ) -> MDMInstalledProfileIdentity {
        installedIdentity(
            identifier: expected.identifier,
            uuid: expected.uuid,
            serverURL: expected.serverURL
        )
    }

    private static func installedIdentity(
        identifier: String,
        uuid: UUID,
        serverURL: String
    ) -> MDMInstalledProfileIdentity {
        MDMInstalledProfileIdentity(identifier: identifier, uuid: uuid, serverURL: serverURL)
    }

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
