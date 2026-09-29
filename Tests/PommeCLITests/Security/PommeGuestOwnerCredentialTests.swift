import Foundation
import Testing

@Suite("Guest owner-credential recovery")
struct PommeGuestOwnerCredentialTests {
    private static let password = "s3cret-owner-passphrase"

    /// Builds a reader whose guest looks the way a Pomme-provisioned template
    /// does, then lets each test spoil exactly one property.
    private func makeReader(
        euid: uid_t = 0,
        autoLoginUser: (any Sendable)? = "pomme",
        artifact: PommeGuestOwnerCredentialArtifact? = .init(
            isRegularFile: true, userID: 0, groupID: 0, mode: 0o600, linkCount: 1),
        bytes: Data? = nil
    ) -> PommeGuestOwnerCredentialReader {
        let payload = bytes ?? kcpasswordData(for: Self.password)
        return .init(
            effectiveUserID: { euid },
            readAutoLoginUser: { autoLoginUser },
            readArtifact: { path in
                #expect(path == "/etc/kcpassword")
                return artifact
            },
            readBytes: { _ in payload }
        )
    }

    private func receipt(_ value: JSONValue) -> (account: String, password: String)? {
        guard let object = value.objectValue,
              object["verified"] == .bool(true),
              object["operation"] == .string("owner.credential.read"),
              let account = object["account"]?.stringValue,
              let password = object["password"]?.stringValue
        else { return nil }
        return (account, password)
    }

    @Test("Apple autologin padding after the NUL terminator is not password data")
    func nonzeroAutologinPadding() throws {
        for padding: [UInt8] in [[0xff, 0xfe, 0x80], [0x61, 0x62, 0x63], [0, 0, 0]] {
            let clear = Array("padded-✓".utf8) + [0] + padding
            let encoded = Data(clear.enumerated().map { index, byte in byte ^ kcpasswordKeyBytes[index % kcpasswordKeyBytes.count] })
            let result = try makeReader(bytes: encoded).read(payload: .object([:]))
            #expect(receipt(result)?.password == "padded-✓")
        }
        let invalid: [UInt8] = [0xff, 0, 0x61]
        let encoded = Data(invalid.enumerated().map { index, byte in byte ^ kcpasswordKeyBytes[index % kcpasswordKeyBytes.count] })
        #expect(kcpasswordString(from: encoded) == nil)
    }

    @Test("Recovers the automatic-login account and its password from the guest artifact")
    func recoversCredential() throws {
        let result = try makeReader().read(payload: .object([:]))
        let parsed = try #require(receipt(result))
        #expect(parsed.account == "pomme")
        #expect(parsed.password == Self.password)
    }

    @Test("A stated account binds the request and a different one is refused")
    func bindsRequestedAccount() throws {
        let reader = makeReader()
        let matched = try reader.read(payload: .object(["account": .string("pomme")]))
        #expect(receipt(matched)?.password == Self.password)

        #expect(throws: PommeGuestOwnerCredentialError.accountMismatch) {
            _ = try reader.read(payload: .object(["account": .string("someoneelse")]))
        }
    }

    @Test("Recovery is refused for a non-root agent")
    func requiresRoot() {
        #expect(throws: PommeGuestOwnerCredentialError.rootRequired) {
            _ = try makeReader(euid: 501).read(payload: .object([:]))
        }
    }

    @Test("Only an empty payload or a single safe account field is accepted")
    func validatesPayload() throws {
        #expect(try PommeGuestOwnerCredentialReader.requestedAccount(from: .object([:])) == nil)
        #expect(try PommeGuestOwnerCredentialReader.requestedAccount(
            from: .object(["account": .string("pomme")])) == "pomme")

        for rejected: JSONValue in [
            .string("pomme"),
            .object(["account": .string("pomme"), "path": .string("/etc/shadow")]),
            .object(["path": .string("/etc/kcpassword")]),
            .object(["account": .string("")]),
            .object(["account": .string("../../etc/passwd")]),
            .object(["account": .string("has space")]),
            .object(["account": .integer(1)]),
        ] {
            #expect(throws: PommeGuestOwnerCredentialError.invalidPayload) {
                _ = try PommeGuestOwnerCredentialReader.requestedAccount(from: rejected)
            }
        }
    }

    @Test("A guest with no configured automatic-login account yields no credential")
    func requiresAutoLoginAccount() {
        for reader in [
            makeReader(autoLoginUser: nil),
            makeReader(autoLoginUser: 501),
            makeReader(autoLoginUser: ["pomme"]),
            makeReader(autoLoginUser: "not a user name"),
        ] {
            #expect(throws: PommeGuestOwnerCredentialError.autoLoginUnavailable) {
                _ = try reader.read(payload: .object([:]))
            }
        }
    }

    @Test("Only the exact root-owned artifact macOS writes is trusted")
    func validatesArtifactOwnershipAndMode() {
        let safe = PommeGuestOwnerCredentialArtifact(
            isRegularFile: true, userID: 0, groupID: 0, mode: 0o600, linkCount: 1)
        #expect(safe.isSafe)
        // Apple has been observed to write the artifact 0400 as well.
        #expect(PommeGuestOwnerCredentialArtifact(
            isRegularFile: true, userID: 0, groupID: 0, mode: 0o400, linkCount: 1).isSafe)

        let unsafe = [
            PommeGuestOwnerCredentialArtifact(
                isRegularFile: false, userID: 0, groupID: 0, mode: 0o600, linkCount: 1),
            .init(isRegularFile: true, userID: 501, groupID: 0, mode: 0o600, linkCount: 1),
            .init(isRegularFile: true, userID: 0, groupID: 20, mode: 0o600, linkCount: 1),
            .init(isRegularFile: true, userID: 0, groupID: 0, mode: 0o644, linkCount: 1),
            .init(isRegularFile: true, userID: 0, groupID: 0, mode: 0o660, linkCount: 1),
            .init(isRegularFile: true, userID: 0, groupID: 0, mode: 0o604, linkCount: 1),
            .init(isRegularFile: true, userID: 0, groupID: 0, mode: 0o600, linkCount: 2),
        ]
        for artifact in unsafe { #expect(!artifact.isSafe) }

        #expect(throws: PommeGuestOwnerCredentialError.artifactUnsafe) {
            _ = try makeReader(artifact: unsafe[1]).read(payload: .object([:]))
        }
        #expect(throws: PommeGuestOwnerCredentialError.artifactMissing) {
            _ = try makeReader(artifact: nil).read(payload: .object([:]))
        }
    }

    @Test("An empty, oversized, or undecodable artifact is refused")
    func validatesArtifactContents() {
        let oversized = Data(repeating: 0x41, count: PommeGuestOwnerCredentialReader.maximumArtifactBytes + 1)
        for bytes in [Data(), oversized, kcpasswordData(for: "")] {
            #expect(throws: PommeGuestOwnerCredentialError.credentialUnreadable) {
                _ = try makeReader(bytes: bytes).read(payload: .object([:]))
            }
        }
    }

    @Test("Recovery round-trips a password containing multibyte and padding-length text")
    func roundTripsAwkwardPasswords() throws {
        // 11 bytes is exactly one kcpassword key length, which exercises the
        // padding branch of the codec in both directions.
        for password in ["12345678901", "pässwörd-✓", "a", String(repeating: "z", count: 64)] {
            let reader = makeReader(bytes: kcpasswordData(for: password))
            let result = try reader.read(payload: .object([:]))
            #expect(receipt(result)?.password == password)
        }
    }

    @Test("The host receipt check requires the pinned digest and the advertised contract")
    func hostReceiptCheckIsClosed() {
        let digest = String(repeating: "a", count: 64)
        let base: [String: Any] = [
            "role": "persistent",
            "protocol": PommeAgentProtocol.name,
            "version": Int64(PommeAgentProtocol.version),
            "executableSHA256": digest,
            "capabilities": ["owner.credential.read", "process.start"],
            "ownerCredentialVersion": Int64(PommeGuestOwnerCredentialReader.version),
        ]
        #expect(PommeSecurityNormalAgent.supportsOwnerCredentialRecovery(
            base, expectedExecutableDigest: digest))

        var olderPinnedAgent = base
        olderPinnedAgent.removeValue(forKey: "ownerCredentialVersion")
        #expect(!PommeSecurityNormalAgent.supportsOwnerCredentialRecovery(
            olderPinnedAgent, expectedExecutableDigest: digest))

        var missingCapability = base
        missingCapability["capabilities"] = ["process.start"]
        #expect(!PommeSecurityNormalAgent.supportsOwnerCredentialRecovery(
            missingCapability, expectedExecutableDigest: digest))

        var wrongDigest = base
        wrongDigest["executableSHA256"] = String(repeating: "b", count: 64)
        #expect(!PommeSecurityNormalAgent.supportsOwnerCredentialRecovery(
            wrongDigest, expectedExecutableDigest: digest))

        var recoveryRole = base
        recoveryRole["role"] = "recovery"
        #expect(!PommeSecurityNormalAgent.supportsOwnerCredentialRecovery(
            recoveryRole, expectedExecutableDigest: digest))

        var coercedVersion = base
        coercedVersion["ownerCredentialVersion"] = "1"
        #expect(!PommeSecurityNormalAgent.supportsOwnerCredentialRecovery(
            coercedVersion, expectedExecutableDigest: digest))
    }

    @Test("The recovery operation is a persistent-agent capability and not a Recovery one")
    func capabilityIsPersistentOnly() {
        #expect(PommeAgent.persistentCapabilities.contains(PommeGuestOwnerCredentialReader.operation))
        #expect(!PommeAgent.recoveryCapabilities.contains(PommeGuestOwnerCredentialReader.operation))
        #expect(!PommeAgent.recoveryTerminalCapabilities.contains(
            PommeGuestOwnerCredentialReader.operation))
    }
}

@Suite("Normal-boot AMFI status contract")
struct PommeNormalAMFIStatusTests {
    private let digest = String(repeating: "a", count: 64)

    private func describe(
        version: Int64? = Int64(PommeGuestRecoverySecurityOperations.normalAMFIStatusVersion),
        capabilities: [Any] = [
            PommeGuestRecoverySecurityOperations.normalAMFIStatusOperation, "process.start",
        ],
        role: String = "persistent",
        executable: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "role": role,
            "protocol": PommeAgentProtocol.name,
            "version": Int64(PommeAgentProtocol.version),
            "executableSHA256": executable ?? digest,
            "capabilities": capabilities,
        ]
        if let version { value["normalAMFIStatusVersion"] = version }
        return value
    }

    @Test("The status receipt requires the advertised version, capability, role, and digest")
    func receiptIsClosed() {
        #expect(PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            describe(), expectedExecutableDigest: digest))

        // An agent pinned before this contract existed.
        #expect(!PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            describe(version: nil), expectedExecutableDigest: digest))
        #expect(!PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            describe(capabilities: ["process.start"]), expectedExecutableDigest: digest))
        #expect(!PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            describe(role: "recovery"), expectedExecutableDigest: digest))
        #expect(!PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            describe(executable: String(repeating: "b", count: 64)),
            expectedExecutableDigest: digest))
    }

    @Test("A coerced or mismatched version is not accepted")
    func rejectsCoercedVersion() {
        var coerced = describe()
        coerced["normalAMFIStatusVersion"] = "1"
        #expect(!PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            coerced, expectedExecutableDigest: digest))

        #expect(!PommeSecurityNormalAgent.supportsNormalAMFIStatus(
            describe(version: 99), expectedExecutableDigest: digest))
    }

    /// The status operation must stay out of the staging vocabulary, or an
    /// agent pinned before it would fail the superset check that gates AMFI
    /// disable and enable and would stop working entirely.
    @Test("Status is advertised separately from the four staging operations")
    func statusIsNotAStagingOperation() {
        let status = PommeGuestRecoverySecurityOperations.normalAMFIStatusOperation
        #expect(status == "amfi.normal.status")
        #expect(!PommeAgent.normalAMFIOperations.contains(status))
        #expect(!PommeSecurityNormalAgent.normalAMFIOperations.contains(status))
        #expect(PommeAgent.persistentCapabilities.contains(status))
        #expect(!PommeAgent.recoveryCapabilities.contains(status))
        #expect(PommeSecurityNormalAgent.normalAMFIOperations.count == 4)
    }
}

@Suite("Helper forwarding boundary")
struct PommeAgentPerformAllowlistTests {
    private func parses(_ operation: String) -> Bool {
        (try? PommeAgentPerformRequest.parse(from: [
            "operation": .string(operation), "payload": .object([:]),
        ])) != nil
    }

    /// The helper's allowlist is closed, so an operation the guest agent
    /// supports is still unreachable until it is named here. Both of these
    /// were added with their guest operations and must not drift apart.
    @Test("The new guest operations are reachable through the helper")
    func newOperationsAreForwarded() {
        #expect(parses(PommeGuestRecoverySecurityOperations.normalAMFIStatusOperation))
        #expect(parses(PommeGuestOwnerCredentialReader.operation))
        for staging in PommeSecurityNormalAgent.normalAMFIOperations { #expect(parses(staging)) }
        #expect(parses("agent.describe"))
    }

    @Test("The allowlist still refuses operations it does not name")
    func unrelatedOperationsAreRefused() {
        for refused in [
            "owner.credential.write", "owner.", "amfi.normal", "amfi.disable",
            "sip.disable", "agent.install", "terminal.create", "shell",
        ] {
            #expect(!parses(refused), "\(refused) must not be forwarded")
        }
    }
}
