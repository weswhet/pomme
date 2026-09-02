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
            effectiveUserID: { 0 }
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
        #expect(try !store.isPresent())
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
    let vuid = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let dataRoot: URL
    let snapshotURL: URL
    private(set) var securityMode: String
    private(set) var customBootArguments: Bool
    private(set) var bootArguments: String
    private(set) var secretOperationCount = 0
    private var failNextNVRAMMutation: Bool

    init(failNextNVRAMMutation: Bool = false) throws {
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
        securityMode = "reduced"
        customBootArguments = false
        bootArguments = "keep=1"
        self.failNextNVRAMMutation = failNextNVRAMMutation
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
        nvramMutationVerified: Bool = true
    ) -> PommeGuestRecoverySecurityOperations {
        .init(
            process: { [self] executable, arguments in
                try process(executable: executable, arguments: arguments)
            },
            secretProcess: { [self] executable, arguments, credentials in
                try secretProcess(
                    executable: executable,
                    arguments: arguments,
                    credentials: credentials
                )
            },
            effectiveUserID: { 0 },
            snapshotStore: store,
            nvramMutationVerified: { nvramMutationVerified }
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
            return .init(status: 0, stdout: policyJSON)
        case ("/usr/bin/bputil", ["--json", "--display-all-policies"]):
            return .init(status: 0, stdout: policyJSON)
        case ("/usr/sbin/nvram", ["boot-args"]):
            return .init(status: 0, stdout: Data("boot-args\t\(bootArguments)\n".utf8))
        case ("/usr/sbin/nvram", let values)
            where values.count == 1 && values[0].hasPrefix("boot-args="):
            if failNextNVRAMMutation {
                failNextNVRAMMutation = false
                return .init(status: 1)
            }
            if let value = arguments[0].split(separator: "=", maxSplits: 1).last {
                bootArguments = String(value)
            }
            return .init(status: 0)
        case ("/usr/sbin/nvram", ["-d", "boot-args"]):
            bootArguments = ""
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
        secretOperationCount += 1
        guard arguments == ["-a", "-v", groupUUID.uuidString.lowercased()]
            || arguments.first.map({ ["-f", "-g", "-n"].contains($0) }) == true else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        if arguments.first == "-a" {
            securityMode = "permissive"
            customBootArguments = true
        } else {
            securityMode = arguments[0] == "-g" ? "reduced" : arguments[0] == "-n" ? "permissive" : "full"
            customBootArguments = arguments.contains("-a")
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

    private var policyJSON: Data {
        let permissive = securityMode == "permissive"
        let policy: [String: Any] = [
            "vuid": vuid.uuidString,
            "security_mode": securityMode,
            "smb0": true,
            "smb1": permissive,
            "smb2": false,
            "smb3": true,
            "smb4": false,
            "sip0": 0,
            "sip1": false,
            "sip2": false,
            "sip3": customBootArguments,
            "properly_paired": true,
            "os_paired_to_current": true,
            "os_type": "macOS"
        ]
        return try! JSONSerialization.data(
            withJSONObject: [vuid.uuidString: policy],
            options: [.sortedKeys]
        )
    }
}
