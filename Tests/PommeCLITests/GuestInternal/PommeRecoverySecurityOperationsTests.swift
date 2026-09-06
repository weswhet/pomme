import Foundation
import Testing

@Suite("Pomme Recovery guest security operations")
struct PommeRecoverySecurityOperationsTests {
    @Test("Security operations require the Recovery role and root")
    func roleAndRootGates() throws {
        let operations = PommeGuestRecoverySecurityOperations(
            effectiveUserID: { 0 }
        )
        do {
            _ = try operations.execute(
                role: .persistent,
                operation: "sip.status",
                payload: .object([:])
            )
            Issue.record("The persistent role reached the Recovery security surface.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .recoveryRoleRequired)
        }

        let nonRoot = PommeGuestRecoverySecurityOperations(
            effectiveUserID: { 501 }
        )
        do {
            _ = try nonRoot.execute(
                role: .recovery,
                operation: "sip.status",
                payload: .object([:])
            )
            Issue.record("A non-root process reached the Recovery security surface.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .rootRequired)
        }
    }

    @Test("SIP mutation uses the secret PTY seam and verifies csrutil status")
    func sipMutationIsAuthenticatedAndVerified() throws {
        let fixture = SIPFixture()
        let operations = PommeGuestRecoverySecurityOperations(
            process: { executable, arguments in
                try fixture.process(executable: executable, arguments: arguments)
            },
            secretProcess: { executable, arguments, credentials in
                try fixture.secretProcess(
                    executable: executable,
                    arguments: arguments,
                    credentials: credentials
                )
            },
            effectiveUserID: { 0 },
            nvramMutationVerified: { true }
        )
        let password = "guest-password-not-output"
        let result = try operations.execute(
            role: .recovery,
            operation: "sip.disable",
            payload: .object([
                "authorizedUser": .string("owner"),
                "password": .string(password)
            ])
        )
        #expect(result.objectValue?["sipDisabled"] == .bool(true))
        #expect(result.objectValue?["verified"] == .bool(true))
        #expect(fixture.secretArguments == [["disable"]])
        let expectedCredentials = try PommeGuestSecurityCredentials(username: "owner", password: password)
        #expect(fixture.secretCredentials == [expectedCredentials])
        let encoded = try JSONEncoder().encode(result)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(password))
    }

    @Test("SIP prompt responder accepts only native action-bound confirmation forms")
    func sipPromptResponderAcceptsNativeForms() throws {
        let credentials = try PommeGuestSecurityCredentials(
            username: "owner",
            password: "prompt-password"
        )
        let prompts = [
            (
                "disable",
                "Allow booting unsigned operating systems and any kernel extensions for OS \"macOS\"? [y/n]: "
            ),
            (
                "enable",
                "Raise security level to full boot security for OS \"macOS\"? [y/n]: "
            )
        ]
        for (action, confirmation) in prompts {
            var responder = PommeGuestSIPPromptResponder(
                action: action,
                expectedUsername: credentials.username
            )
            var transcript = confirmation
            #expect(try responder.nextInput(for: transcript, credentials: credentials) == "Y")
            transcript += "\nAuthorized user: "
            #expect(try responder.nextInput(for: transcript, credentials: credentials) == credentials.username)
            transcript += "\nEnter password for user owner: "
            #expect(try responder.nextInput(for: transcript, credentials: credentials) == credentials.password)
            #expect(responder.completed)
        }

        var bare = PommeGuestSIPPromptResponder(
            action: "disable",
            expectedUsername: credentials.username
        )
        #expect(try bare.nextInput(for: "[y/n]:", credentials: credentials) == "Y")
    }

    @Test("SIP and AMFI prompt responders reject unsafe or mismatched prompts")
    func promptRespondersRejectUnsafePrompts() throws {
        let credentials = try PommeGuestSecurityCredentials(
            username: "owner",
            password: "prompt-password"
        )
        let confirmation = "Allow booting unsigned operating systems and any kernel extensions for OS \"macOS\"? [y/n]: "

        var wrongUser = PommeGuestSIPPromptResponder(
            action: "disable",
            expectedUsername: credentials.username
        )
        _ = try wrongUser.nextInput(for: confirmation, credentials: credentials)
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try wrongUser.nextInput(
                for: confirmation + "\nEnter password for user intruder: ",
                credentials: credentials
            )
        }

        var repeated = PommeGuestSIPPromptResponder(
            action: "disable",
            expectedUsername: credentials.username
        )
        _ = try repeated.nextInput(for: confirmation, credentials: credentials)
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try repeated.nextInput(for: confirmation + "\n" + confirmation, credentials: credentials)
        }

        var selection = PommeGuestSIPPromptResponder(
            action: "disable",
            expectedUsername: credentials.username
        )
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try selection.nextInput(
                for: "Pick a macOS installation (1..2): ",
                credentials: credentials
            )
        }

        var refused = PommeGuestSIPPromptResponder(
            action: "disable",
            expectedUsername: credentials.username
        )
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try refused.nextInput(for: "aborted\n", credentials: credentials)
        }

        var unboundPassword = PommeGuestSIPPromptResponder(
            action: "disable",
            expectedUsername: credentials.username
        )
        _ = try unboundPassword.nextInput(for: confirmation, credentials: credentials)
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try unboundPassword.nextInput(
                for: confirmation + "\nPassword       : ",
                credentials: credentials
            )
        }

        var amfi = PommeGuestAMFIPromptResponder(expectedUsername: credentials.username)
        _ = try amfi.nextInput(for: "Authorized user: ", credentials: credentials)
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try amfi.nextInput(
                for: "Authorized user: \nPlease enter password for user intruder: ",
                credentials: credentials
            )
        }
    }

    @Test("Status and mutation payloads are closed")
    func payloadsAreClosed() throws {
        let operations = PommeGuestRecoverySecurityOperations(
            process: { _, _ in .init(status: 0, stdout: Data("System Integrity Protection status: enabled.\n".utf8)) },
            effectiveUserID: { 0 }
        )
        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "sip.status",
                payload: .object(["password": .string("secret")])
            )
            Issue.record("Status accepted credential fields.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPayload)
        }

        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "sip.disable",
                payload: .object([
                    "authorizedUser": .string("owner"),
                    "password": .string("secret"),
                    "extra": .bool(true)
                ])
            )
            Issue.record("Mutation accepted an unknown field.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPayload)
        }

        let amfiFixture = try AMFIFixture()
        let amfiOperations = amfiFixture.operations()
        do {
            _ = try amfiOperations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: .object([
                    "authorizedUser": .string("owner"),
                    "password": .string("secret")
                ])
            )
            Issue.record("AMFI mutation accepted a request without its bound volume group.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPayload)
        }
    }

    @Test("AMFI disable preserves an exact snapshot until enable restores it")
    func amfiDisableAndEnable() throws {
        let fixture = try AMFIFixture()
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)
        let payload = fixture.credentialsPayload

        let disabled = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: payload
        )
        #expect(disabled.objectValue?["amfiBootArgActive"] == .bool(true))
        #expect(disabled.objectValue?["bootPolicyAllowsCustomBootArgs"] == .bool(true))
        #expect(try store.isPresent())
        #expect(fixture.securityMode == "permissive")

        let enabled = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: payload
        )
        #expect(enabled.objectValue?["amfiBootArgActive"] == .bool(false))
        #expect(enabled.objectValue?["verified"] == .bool(true))
        #expect(try !store.isPresent())
        #expect(fixture.securityMode == "reduced")
        #expect(fixture.bootArguments == "keep=1")
    }

    @Test("AMFI preserves enabled MDM and kext policy options in the disable command")
    func amfiDisableRetainsKnownPolicyOptions() throws {
        let fixture = try AMFIFixture(initialSecurityMode: "reduced", initialKextsEnabled: true)
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        #expect(
            fixture.secretArguments.first
                == ["-a", "-m", "-k", "-v", fixture.groupUUID.uuidString.lowercased()]
        )
        #expect(fixture.mdmEnabled)
        #expect(fixture.kextsEnabled)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.credentialsPayload
        )
        #expect(fixture.mdmEnabled)
        #expect(fixture.kextsEnabled)
    }

    @Test("Non-UTF8 boot arguments fail before the first authenticated policy write")
    func nonUTF8BootArgumentsAreRejectedBeforeMutation() throws {
        let fixture = try AMFIFixture(
            initialBootArgumentBytes: Data([0x6b, 0x65, 0xff]),
            bootArgumentsAsData: true
        )
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("A non-restorable binary boot-args value was accepted.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidNVRAM)
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(try !store.isPresent())
    }

    @Test("An unexpected NVRAM read failure is rejected before policy mutation")
    func unexpectedNVRAMReadFailureIsRejectedBeforeMutation() throws {
        let fixture = try AMFIFixture(
            bootArgumentsReadStatus: 1,
            bootArgumentsReadStderr: "nvram: permission denied\n"
        )
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("An unverified NVRAM read failure was treated as absence.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidNVRAM)
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(try !store.isPresent())
    }

    @Test("AMFI preserves a real trailing carriage return in boot arguments")
    func trailingCarriageReturnIsPreserved() throws {
        let original = Data("keep=1\r".utf8)
        let fixture = try AMFIFixture(initialBootArgumentBytes: original)
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.credentialsPayload
        )
        #expect(Data(fixture.bootArguments.utf8) == original)
    }

    @Test("AMFI preserves literal percent bytes in boot arguments")
    func literalPercentBootArgumentsArePreserved() throws {
        let original = Data("foo=%20 keep=1".utf8)
        let fixture = try AMFIFixture(initialBootArgumentBytes: original)
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.credentialsPayload
        )

        #expect(Data(fixture.bootArguments.utf8) == original)
    }

    @Test("A partial AMFI mutation rolls LocalPolicy and NVRAM back")
    func amfiRollback() throws {
        let fixture = try AMFIFixture(failNextNVRAMMutation: true)
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("A failed NVRAM write was reported as success.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .commandFailed)
        }
        #expect(fixture.securityMode == "reduced")
        #expect(fixture.bootArguments == "keep=1")
        #expect(try store.isPresent())
        #expect(try store.loadRecord().phase == .rollbackVerified)
        let failure = try store.loadRecord().nvramFailure
        #expect(failure?.action == .disable)
        #expect(failure?.transactionPhase == .nvramApplying)
        #expect(failure?.stage == .completedExit)
        #expect(failure?.exitCode == 1)
        #expect(failure?.stderrCategory == .other)

        // A retry reconciles the retained baseline after the partial attempt;
        // the unresolved snapshot is not a blanket same-direction rejection.
        let retried = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        #expect(retried.objectValue?["verified"] == .bool(true))
        #expect(try store.loadRecord().phase == .disabledVerified)
    }

    @Test("NVRAM failure diagnostics are closed, redacted, and visible to bound status")
    func nvramFailureDiagnosticIsClosedAndRetained() throws {
        let fixture = try AMFIFixture(
            failNextNVRAMMutation: true,
            nvramFailureStderr: "nvram: Operation not permitted; password=fixture-password boot-args=secret\n"
        )
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.nvramWriteDenied) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
        }

        let record = try store.loadRecord()
        #expect(record.phase == .rollbackVerified)
        #expect(record.policyCheckpoint?.action == .rollback)
        #expect(record.nativeTransition?.action == .rollback)
        #expect(record.nativeTransition?.receipt == true)
        #expect(record.nvramCheckpoint?.action == .rollback)
        #expect(record.nvramCheckpoint?.receipt == true)
        #expect(record.nvramFailure?.stderrCategory == .notPermitted)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!encoded.contains("fixture-password"))
        #expect(!encoded.contains("boot-args=secret"))

        let status = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        let diagnostic = status.objectValue?["nvramFailure"]?.objectValue
        #expect(diagnostic?["action"] == .string("disable"))
        #expect(diagnostic?["phase"] == .string("nvramApplying"))
        #expect(diagnostic?["stage"] == .string("completedExit"))
        #expect(diagnostic?["stderrCategory"] == .string("notPermitted"))
        #expect(diagnostic?["exitCode"] == .integer(1))
    }

    @Test("NVRAM completion failures retain a closed diagnostic")
    func nvramCompletionFailureDiagnosticIsRetainedThroughRollback() throws {
        let fixture = try AMFIFixture(failNextNVRAMError: .timedOut)
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.timedOut) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
        }

        let failure = try store.loadRecord().nvramFailure
        #expect(failure?.action == .disable)
        #expect(failure?.transactionPhase == .nvramApplying)
        #expect(failure?.stage == .completionUnavailable)
        #expect(failure?.exitCode == nil)
        #expect(failure?.stderrCategory == .other)
        #expect(try store.loadRecord().phase == .rollbackVerified)
    }

    @Test("NVRAM stderr classification remains a closed vocabulary")
    func nvramFailureCategoriesAreClosed() {
        #expect(
            PommeGuestAMFINVRAMFailureCategory.classify(
                stderr: Data("permission denied\n".utf8)
            ) == .permissionDenied
        )
        #expect(
            PommeGuestAMFINVRAMFailureCategory.classify(
                stderr: Data("Operation not permitted\n".utf8)
            ) == .notPermitted
        )
        #expect(
            PommeGuestAMFINVRAMFailureCategory.classify(
                stderr: Data("Invalid argument\n".utf8)
            ) == .invalidArgument
        )
        #expect(
            PommeGuestAMFINVRAMFailureCategory.classify(
                stderr: Data("unknown native failure\n".utf8)
            ) == .other
        )
    }

    @Test("AMFI mutation stays unavailable until NVRAM write and readback are qualified")
    func amfiMutationRequiresNVRAMQualification() throws {
        let fixture = try AMFIFixture()
        let operations = fixture.operations(nvramMutationVerified: false)
        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("AMFI mutation was reported before NVRAM qualification.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .nvramMutationUnqualified)
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.securityMode == "reduced")
    }

    @Test("The default AMFI gate is a concrete Recovery and volume proof")
    func concreteRecoveryGate() throws {
        let fixture = try AMFIFixture()
        let operations = fixture.operations(
            nvramMutationVerified: nil,
            recoveryEnvironmentVerifier: { _ in
                throw PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified
            }
        )
        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("AMFI mutation passed an unverified Recovery gate.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .recoveryEnvironmentUnverified)
        }
        #expect(fixture.secretOperationCount == 0)
    }

    @Test("Production SIP mutations require a request-bound startup volume")
    func productionSIPMutationRequiresTargetVolume() throws {
        let operations = PommeGuestRecoverySecurityOperations(
            effectiveUserID: { 0 }
        )
        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "sip.disable",
                payload: .object([
                    "authorizedUser": .string("owner"),
                    "password": .string("secret")
                ])
            )
            Issue.record("Production SIP mutation accepted an unbound target.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPayload)
        }
    }

    @Test("A normal-macOS csrutil status success is insufficient for AMFI mutation")
    func normalCSRUtilShapeDoesNotPassRecoveryGate() throws {
        let group = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let operations = PommeGuestRecoverySecurityOperations(
            process: { executable, arguments in
                if executable == "/usr/bin/csrutil", arguments == ["status"] {
                    return .init(
                        status: 0,
                        stdout: Data("System Integrity Protection status: enabled.\n".utf8)
                    )
                }
                if executable == "/usr/bin/csrutil",
                   arguments == ["authenticated-root", "status"] {
                    // This also succeeds on normal macOS. It is not the
                    // Recovery proof by itself.
                    return .init(
                        status: 0,
                        stdout: Data("Authenticated Root status: enabled.\n".utf8)
                    )
                }
                if executable == "/usr/sbin/diskutil", arguments == ["info", "-plist", "/"] {
                    let normalRoot: [String: Any] = [
                        "DeviceIdentifier": "disk1s1s1",
                        "FilesystemType": "apfs",
                        "MountPoint": "/",
                        "VolumeName": "Macintosh HD",
                        "Writable": false,
                        "WritableVolume": false
                    ]
                    return .init(
                        status: 0,
                        stdout: try PropertyListSerialization.data(
                            fromPropertyList: normalRoot,
                            format: .xml,
                            options: 0
                        )
                    )
                }
                if executable == "/usr/sbin/diskutil",
                   arguments == ["apfs", "listVolumeGroups", "-plist"] {
                    let groups: [String: Any] = [
                        "Containers": [[
                            "VolumeGroups": [[
                                "APFSVolumeGroupUUID": group.uuidString,
                                "Volumes": [
                                    ["Role": "System", "DeviceIdentifier": "disk1s1"],
                                    ["Role": "Data", "DeviceIdentifier": "disk1s2"]
                                ]
                            ]]
                        ]]
                    ]
                    return .init(
                        status: 0,
                        stdout: try PropertyListSerialization.data(
                            fromPropertyList: groups,
                            format: .xml,
                            options: 0
                        )
                    )
                }
                throw PommeGuestRecoverySecurityError.invalidOperation
            },
            effectiveUserID: { 0 }
        )
        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: .object([
                    "authorizedUser": .string("owner"),
                    "password": .string("secret"),
                    "volumeGroupUUID": .string(group.uuidString.lowercased())
                ])
            )
            Issue.record("Normal-macOS csrutil output passed the Recovery gate.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .recoveryEnvironmentUnverified)
        }
    }

    @Test("Target-bound AMFI status exposes baseline reconciliation state without credentials")
    func targetBoundStatus() throws {
        let fixture = try AMFIFixture()
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)
        let before = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(before.objectValue?["baselinePresent"] == .bool(false))
        #expect(before.objectValue?["baselinePhase"] == .string("none"))
        #expect(before.objectValue?["reconciliationRequired"] == .bool(false))

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        let after = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(after.objectValue?["baselinePresent"] == .bool(true))
        #expect(after.objectValue?["baselinePhase"] == .string("disabledVerified"))
        #expect(after.objectValue?["reconciliationRequired"] == .bool(false))
        #expect(after.objectValue?["enforcementState"] == nil)
    }

    @Test("Legacy empty AMFI status remains the closed MDM response")
    func legacyStatusShapeRemainsClosed() throws {
        let fixture = try AMFIFixture()
        let status = try fixture.operations().execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([:])
        )
        let statusKeys = status.objectValue.map { Set($0.keys) } ?? Set<String>()
        #expect(statusKeys == Set([
            "operation", "amfiBootArgActive", "amfiDisabled",
            "bootPolicyAllowsCustomBootArgs", "securityMode", "verified"
        ]))
    }

    @Test("Unknown LocalPolicy fields allow status but stop before an authenticated write")
    func unknownPolicySchemaIsGuarded() throws {
        let fixture = try AMFIFixture(unknownPolicyKey: "future_policy_field")
        let operations = fixture.operations()
        let status = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([:])
        )
        #expect(status.objectValue?["verified"] == .bool(true))
        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("An unknown LocalPolicy schema was mutated.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPolicy)
        }
        #expect(fixture.secretOperationCount == 0)
    }

    @Test("A failed targeted policy read falls back to a successful all-policy read")
    func failedTargetedPolicyReadFallsBack() throws {
        let fixture = try AMFIFixture(targetedPolicyStatus: 1)
        let status = try fixture.operations().execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([:])
        )

        #expect(status.objectValue?["verified"] == .bool(true))
        #expect(fixture.targetedPolicyReadCount == 1)
        #expect(fixture.allPolicyReadCount == 1)
    }

    @Test("A failed all-policy read is rejected after targeted parsing fails")
    func failedAllPolicyReadIsRejected() throws {
        let fixture = try AMFIFixture(
            allPolicyStatus: 1,
            targetedPolicyMalformed: true
        )
        do {
            _ = try fixture.operations().execute(
                role: .recovery,
                operation: "amfi.status",
                payload: .object([:])
            )
            Issue.record("A nonzero bputil read was accepted as policy state.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .commandFailed)
        }
        #expect(fixture.targetedPolicyReadCount == 1)
        #expect(fixture.allPolicyReadCount == 1)
    }

    @Test("Native LocalPolicy metadata is retained while anti-replay nonces rotate")
    func nativePolicyProjectionRetainsBaseline() throws {
        let fixture = try AMFIFixture(
            rotatePolicyNonceOnWrite: true,
            initialSecurityMode: "full"
        )
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        let baseline = try store.loadRecord().snapshot
        let baselineJSON = String(decoding: baseline.localPolicy, as: UTF8.self)
        #expect(baselineJSON.contains(fixture.initialPolicyNonce))
        #expect(baselineJSON.contains("\"spih\""))
        #expect(fixture.localPolicyNonce != fixture.initialPolicyNonce)
        #expect(fixture.localPolicyGeneration == 2)
        #expect(fixture.localPolicySPih != String(repeating: "B", count: 96))
        #expect(fixture.localPolicyNSih != String(repeating: "F", count: 96))

        let enabled = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.credentialsPayload
        )
        #expect(enabled.objectValue?["verified"] == .bool(true))
        #expect(fixture.localPolicyGeneration == 3)
        #expect(try !store.isPresent())
    }

    @Test("Manifest drift after a policy receipt stays pending without rollback")
    func manifestDriftAfterPolicyReceiptIsNotAdopted() throws {
        let fixture = try AMFIFixture(driftOnNVRAMWrite: true)
        let store = try PommeGuestAMFISnapshotStore(
            dataRoot: fixture.dataRoot,
            volumeGroupUUID: fixture.groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil
        )
        let operations = fixture.operations(store: store)

        do {
            _ = try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("A manifest changed after the policy receipt was adopted.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .snapshotPending)
        }
        #expect(fixture.secretOperationCount == 1)
        #expect(try store.loadRecord().phase == .nvramApplied)
        #expect(try store.loadRecord().nativeTransition?.receipt == true)
    }

    @Test("Active auxiliary policy fields are rejected before authenticated write")
    func activeAuxiliaryPolicyIsGuarded() throws {
        let fixture = try AMFIFixture(activeAuxiliaryPolicy: true)
        do {
            _ = try fixture.operations().execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("An auxiliary LocalPolicy hash was mutated.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPolicy)
        }
        #expect(fixture.secretOperationCount == 0)
    }

    @Test("Custom SIP policy bits are rejected before authenticated write")
    func customSIPBitsAreGuarded() throws {
        let fixture = try AMFIFixture(customSIPBits: 1)
        do {
            _ = try fixture.operations().execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("Custom SIP bits were mutated through the AMFI path.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPolicy)
        }
        #expect(fixture.secretOperationCount == 0)
    }

    @Test("A policy for a different volume group is rejected before write")
    func foreignPolicyTargetIsGuarded() throws {
        let fixture = try AMFIFixture(
            policyVUID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        )
        do {
            _ = try fixture.operations().execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("A LocalPolicy for a different volume group was accepted.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPolicy)
        }
        #expect(fixture.secretOperationCount == 0)
    }

    @Test("A policy JSON prefix must identify the selected volume group")
    func foreignPolicyPrefixIsGuarded() throws {
        let fixture = try AMFIFixture(
            policyHeaderUUID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        )
        do {
            _ = try fixture.operations().execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
            Issue.record("A policy with a foreign bputil target prefix was accepted.")
        } catch let error as PommeGuestRecoverySecurityError {
            #expect(error == .invalidPolicy)
        }
        #expect(fixture.secretOperationCount == 0)
    }
}

private final class SIPFixture: @unchecked Sendable {
    private(set) var enabled = true
    private(set) var secretArguments: [[String]] = []
    private(set) var secretCredentials: [PommeGuestSecurityCredentials] = []

    func process(executable: String, arguments: [String]) throws -> PommeGuestProcessCapture {
        guard executable == "/usr/bin/csrutil", arguments == ["status"] else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        let state = enabled ? "enabled" : "disabled"
        return .init(
            status: 0,
            stdout: Data("System Integrity Protection status: \(state).\n".utf8)
        )
    }

    func secretProcess(
        executable: String,
        arguments: [String],
        credentials: PommeGuestSecurityCredentials
    ) throws -> PommeGuestProcessCapture {
        guard executable == "/usr/bin/csrutil", arguments == ["enable"] || arguments == ["disable"] else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        secretArguments.append(arguments)
        secretCredentials.append(credentials)
        enabled = arguments == ["enable"]
        return .init(status: 0)
    }
}

private final class AMFIFixture: @unchecked Sendable {
    let groupUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let dataRoot: URL
    let snapshotURL: URL
    let initialPolicyNonce = String(repeating: "C", count: 96)
    private(set) var securityMode: String
    private(set) var customBootArguments: Bool
    private(set) var bootArguments: String
    private(set) var localPolicyNonce: String
    private(set) var localPolicySPih: String
    private(set) var localPolicyNSih: String
    private(set) var localPolicyGeneration: UInt64
    private(set) var mdmEnabled: Bool
    private(set) var kextsEnabled: Bool
    private(set) var secretOperationCount = 0
    private(set) var secretArguments: [[String]] = []
    private(set) var targetedPolicyReadCount = 0
    private(set) var allPolicyReadCount = 0
    private var bootArgumentBytes: Data
    private var failNextNVRAMMutation: Bool
    private var failNextNVRAMError: PommeGuestRecoverySecurityError?
    private let nvramFailureStderr: Data
    private let unknownPolicyKey: String?
    private let targetedPolicyStatus: Int32
    private let allPolicyStatus: Int32
    private let targetedPolicyMalformed: Bool
    private let rotatePolicyNonceOnWrite: Bool
    private let regenerateManifestOnWrite: Bool
    private let driftOnNVRAMWrite: Bool
    private let activeAuxiliaryPolicy: Bool
    private let customSIPBits: UInt64
    private let policyVUID: UUID
    private let policyHeaderUUID: UUID
    private let bootArgumentsAsData: Bool
    private let bootArgumentsReadStatus: Int32
    private let bootArgumentsReadStderr: Data

    init(
        failNextNVRAMMutation: Bool = false,
        failNextNVRAMError: PommeGuestRecoverySecurityError? = nil,
        nvramFailureStderr: String = "",
        unknownPolicyKey: String? = nil,
        targetedPolicyStatus: Int32 = 0,
        allPolicyStatus: Int32 = 0,
        targetedPolicyMalformed: Bool = false,
        rotatePolicyNonceOnWrite: Bool = false,
        regenerateManifestOnWrite: Bool = true,
        driftOnNVRAMWrite: Bool = false,
        activeAuxiliaryPolicy: Bool = false,
        customSIPBits: UInt64 = 0,
        initialSecurityMode: String = "reduced",
        initialKextsEnabled: Bool = false,
        policyVUID: UUID? = nil,
        policyHeaderUUID: UUID? = nil,
        initialBootArgumentBytes: Data? = nil,
        bootArgumentsAsData: Bool = false,
        bootArgumentsReadStatus: Int32 = 0,
        bootArgumentsReadStderr: String = ""
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-guest-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        dataRoot = directory
        snapshotURL = directory.appendingPathComponent(PommeGuestAMFISnapshotStore.snapshotRelativePath)
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        securityMode = initialSecurityMode
        customBootArguments = false
        let initialBootArguments = initialBootArgumentBytes ?? Data("keep=1".utf8)
        bootArgumentBytes = initialBootArguments
        bootArguments = String(decoding: initialBootArguments, as: UTF8.self)
        localPolicyNonce = initialPolicyNonce
        localPolicySPih = String(repeating: "B", count: 96)
        localPolicyNSih = String(repeating: "F", count: 96)
        localPolicyGeneration = 1
        mdmEnabled = initialSecurityMode != "full"
        kextsEnabled = initialKextsEnabled
        self.failNextNVRAMMutation = failNextNVRAMMutation
        self.failNextNVRAMError = failNextNVRAMError
        self.nvramFailureStderr = Data(nvramFailureStderr.utf8)
        self.unknownPolicyKey = unknownPolicyKey
        self.targetedPolicyStatus = targetedPolicyStatus
        self.allPolicyStatus = allPolicyStatus
        self.targetedPolicyMalformed = targetedPolicyMalformed
        self.rotatePolicyNonceOnWrite = rotatePolicyNonceOnWrite
        self.regenerateManifestOnWrite = regenerateManifestOnWrite
        self.driftOnNVRAMWrite = driftOnNVRAMWrite
        self.activeAuxiliaryPolicy = activeAuxiliaryPolicy
        self.customSIPBits = customSIPBits
        self.policyVUID = policyVUID ?? groupUUID
        self.policyHeaderUUID = policyHeaderUUID ?? groupUUID
        self.bootArgumentsAsData = bootArgumentsAsData
        self.bootArgumentsReadStatus = bootArgumentsReadStatus
        self.bootArgumentsReadStderr = Data(bootArgumentsReadStderr.utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: dataRoot)
    }

    var credentialsPayload: JSONValue {
        .object([
            "authorizedUser": .string("owner"),
            "password": .string("fixture-password"),
            "volumeGroupUUID": .string(groupUUID.uuidString.lowercased())
        ])
    }

    func operations(
        store: PommeGuestAMFISnapshotStore? = nil,
        nvramMutationVerified: Bool? = true,
        recoveryEnvironmentVerifier: PommeGuestRecoverySecurityOperations.RecoveryEnvironmentVerifier? = nil
    ) -> PommeGuestRecoverySecurityOperations {
        let processRunner: PommeGuestRecoverySecurityOperations.ProcessRunner = {
            [self] executable, arguments in
            try process(executable: executable, arguments: arguments)
        }
        let secretProcessRunner: PommeGuestRecoverySecurityOperations.SecretProcessRunner = {
            [self] executable, arguments, credentials in
            try secretProcess(
                executable: executable,
                arguments: arguments,
                credentials: credentials
            )
        }
        let legacyGate: (@Sendable () -> Bool)?
        if let nvramMutationVerified {
            legacyGate = { nvramMutationVerified }
        } else {
            legacyGate = nil
        }
        return PommeGuestRecoverySecurityOperations(
            process: processRunner,
            secretProcess: secretProcessRunner,
            effectiveUserID: { 0 },
            snapshotStore: store,
            nvramMutationVerified: legacyGate,
            recoveryEnvironmentVerifier: recoveryEnvironmentVerifier
        )
    }

    func process(executable: String, arguments: [String]) throws -> PommeGuestProcessCapture {
        switch (executable, arguments) {
        case ("/usr/sbin/diskutil", ["apfs", "listVolumeGroups", "-plist"]):
            return .init(status: 0, stdout: volumeGroupsPropertyList)
        case ("/usr/bin/bputil", let values)
            where values.count == 4
                && values[0] == "--json"
                && values[1] == "--display-policy"
                && values[2] == "-v":
            targetedPolicyReadCount += 1
            let output = targetedPolicyMalformed ? Data("{".utf8) : policyJSON
            return .init(status: targetedPolicyStatus, stdout: output)
        case ("/usr/bin/bputil", ["--json", "--display-all-policies"]):
            allPolicyReadCount += 1
            return .init(status: allPolicyStatus, stdout: policyJSON)
        case ("/usr/sbin/nvram", ["-x", "boot-args"]):
            guard bootArgumentsReadStatus == 0 else {
                return .init(
                    status: bootArgumentsReadStatus,
                    stderr: bootArgumentsReadStderr
                )
            }
            let value: Any
            if bootArgumentsAsData {
                value = bootArgumentBytes
            } else {
                value = String(decoding: bootArgumentBytes, as: UTF8.self)
            }
            return .init(
                status: 0,
                stdout: try PropertyListSerialization.data(
                    fromPropertyList: ["boot-args": value],
                    format: .xml,
                    options: 0
                )
            )
        case ("/usr/sbin/nvram", ["boot-args"]):
            return .init(status: 0, stdout: Data("boot-args\t\(bootArguments)\n".utf8))
        case ("/usr/sbin/nvram", let values)
            where values.count == 1 && values[0].hasPrefix("boot-args="):
            if let failNextNVRAMError {
                self.failNextNVRAMError = nil
                throw failNextNVRAMError
            }
            if failNextNVRAMMutation {
                failNextNVRAMMutation = false
                return .init(status: 1, stderr: nvramFailureStderr)
            }
            if let value = arguments[0].split(separator: "=", maxSplits: 1).last {
                bootArguments = String(value)
                bootArgumentBytes = Data(value.utf8)
            }
            if driftOnNVRAMWrite {
                advanceNativeManifestGeneration(by: 2)
            }
            return .init(status: 0)
        case ("/usr/sbin/nvram", ["-d", "boot-args"]):
            bootArguments = ""
            bootArgumentBytes = Data()
            return .init(status: 0)
        default:
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
    }

    func secretProcess(
        executable: String,
        arguments: [String],
        credentials: PommeGuestSecurityCredentials
    ) throws -> PommeGuestProcessCapture {
        guard executable == "/usr/bin/bputil",
              !credentials.password.isEmpty else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        guard arguments.count >= 3,
              let mode = arguments.first,
              ["-a", "-f", "-g", "-n"].contains(mode),
              let volumeFlag = arguments.dropFirst().firstIndex(of: "-v"),
              volumeFlag + 1 < arguments.count,
              arguments[volumeFlag + 1] == groupUUID.uuidString.lowercased() else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        var flagsArguments = Array(arguments.dropFirst())
        let relativeVolumeFlag = flagsArguments.firstIndex(of: "-v")!
        flagsArguments.removeSubrange(relativeVolumeFlag...(relativeVolumeFlag + 1))
        let flags = Set(flagsArguments)
        guard flags.isSubset(of: ["-m", "-k", "-c", "-a", "-s"]) else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        secretOperationCount += 1
        secretArguments.append(arguments)
        mdmEnabled = flags.contains("-m")
        kextsEnabled = flags.contains("-k")
        if mode == "-a" {
            securityMode = "permissive"
            customBootArguments = true
        } else {
            securityMode = mode == "-g" ? "reduced" : mode == "-n" ? "permissive" : "full"
            customBootArguments = flags.contains("-a")
        }
        if rotatePolicyNonceOnWrite {
            localPolicyNonce = localPolicyNonce == initialPolicyNonce
                ? String(repeating: "D", count: 96)
                : String(repeating: "E", count: 96)
        }
        if regenerateManifestOnWrite {
            advanceNativeManifestGeneration()
        }
        return .init(status: 0)
    }

    private var volumeGroupsPropertyList: Data {
        let value: [String: Any] = [
            "Containers": [[
                "VolumeGroups": [[
                    "APFSVolumeGroupUUID": groupUUID.uuidString,
                    "Volumes": [
                        ["Role": "System", "DeviceIdentifier": "disk1s1"],
                        ["Role": "Data", "DeviceIdentifier": "disk1s2"]
                    ]
                ]]
            ]]
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func advanceNativeManifestGeneration(by amount: UInt64 = 1) {
        localPolicyGeneration += amount
        let alphabet = Array("0123456789ABCDEF")
        localPolicySPih = String(
            repeating: alphabet[Int(localPolicyGeneration % UInt64(alphabet.count))],
            count: 96
        )
        localPolicyNSih = String(
            repeating: alphabet[Int((localPolicyGeneration + 1) % UInt64(alphabet.count))],
            count: 96
        )
    }

    private var policyJSON: Data {
        let permissive = securityMode == "permissive"
        let reduced = securityMode != "full"
        let policy: [String: Any] = [
            "CSEC": true,
            "CEPO": 1,
            "SDOM": 1,
            "CHIP": 65024,
            "BORD": 32,
            "ECID": UInt64(16_328_928_024_640_429_816),
            "CRPO": true,
            "lobo": true,
            "spih": localPolicySPih,
            "spih_exists": true,
            "nsih": localPolicyNSih,
            "stng": localPolicyGeneration,
            "stng_exists": true,
            "lpnh": localPolicyNonce,
            "rpnh": String(repeating: "D", count: 96),
            "os_lpnh": localPolicyNonce,
            "os_ronh": String(repeating: "E", count: 96),
            "auxp_exists": false,
            "auxi_exists": false,
            "auxr_exists": false,
            "coih_exists": false,
            "vuid": policyVUID.uuidString,
            "kuid": "00000000-0000-0000-0000-000000000000",
            "love": "25.7.83.0.0,0",
            "bputil_version": "0.1.14",
            "security_mode": securityMode,
            "smb0": reduced,
            "smb1": permissive,
            "smb2": kextsEnabled,
            "smb3": mdmEnabled,
            "smb4": false,
            "sip0": customSIPBits,
            "sip0_exists": customSIPBits != 0,
            "sip1": false,
            "sip2": false,
            "sip3": customBootArguments,
            "properly_paired": true,
            "os_paired_to_current": true,
            "baa_certified": false,
            "os_type": "macOS",
            "os_type_overriden": true
        ]
        var value = policy
        if activeAuxiliaryPolicy {
            value["auxp_exists"] = true
            value["auxp"] = String(repeating: "A", count: 96)
        }
        if let unknownPolicyKey {
            value[unknownPolicyKey] = "future-value"
        }
        let json = try! JSONSerialization.data(
            withJSONObject: [policyVUID.uuidString: value],
            options: [.sortedKeys]
        )
        var output = Data("Operating on Volume Group UUID \(policyHeaderUUID.uuidString.uppercased())\n".utf8)
        output.append(json)
        return output
    }
}
