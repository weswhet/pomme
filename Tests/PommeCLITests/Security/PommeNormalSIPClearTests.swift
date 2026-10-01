import Foundation
import Testing

@Suite("Normal-boot SIP clear")
struct PommeNormalSIPClearTests {
    private static let groupUUID = UUID(uuidString: "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF")!
    private static let password = "clear-password-not-output"
    private static let success = "Successfully cleared system integrity configuration.\n"
        + "Restart the machine for the changes to take effect.\n"

    private static var payload: JSONValue {
        .object([
            "authorizedUser": .string("pomme"),
            "password": .string(password),
            "volumeGroupUUID": .string(groupUUID.uuidString.lowercased())
        ])
    }

    private static func credentials(_ username: String = "pomme") throws -> PommeGuestSecurityCredentials {
        try .init(username: username, password: password)
    }

    // MARK: Prompt responder

    @Test("The responder answers the native normal-boot clear dialog")
    func responderAnswersNativeDialog() throws {
        let credentials = try Self.credentials()
        var responder = PommeGuestSIPClearPromptResponder(expectedUsername: "pomme")
        var transcript = "Authorized us"
        #expect(try responder.nextInput(for: transcript, credentials: credentials) == nil)
        transcript += "er: "
        #expect(try responder.nextInput(for: transcript, credentials: credentials) == "pomme")
        // The username is echoed; getpass does not echo the password.
        transcript += "pomme\n\nPassword       : "
        #expect(try responder.nextInput(for: transcript, credentials: credentials) == Self.password)
        #expect(!responder.completed)
        transcript += "\nSuccessfully cleared system integ"
        #expect(try responder.nextInput(for: transcript, credentials: credentials) == nil)
        #expect(!responder.completed)
        transcript += "rity configuration.\nRestart the machine for the changes to take effect.\n"
        #expect(try responder.nextInput(for: transcript, credentials: credentials) == nil)
        #expect(responder.completed)
    }

    @Test("A password prompt naming the expected owner is accepted")
    func responderAcceptsNamedOwnerPrompt() throws {
        let credentials = try Self.credentials()
        var responder = PommeGuestSIPClearPromptResponder(expectedUsername: "pomme")
        var transcript = "Authorized user: "
        _ = try responder.nextInput(for: transcript, credentials: credentials)
        transcript += "pomme\nEnter password for user pomme: "
        #expect(try responder.nextInput(for: transcript, credentials: credentials) == Self.password)
        transcript += "\n" + Self.success
        _ = try responder.nextInput(for: transcript, credentials: credentials)
        #expect(responder.completed)
    }

    /// Each chunk is what one PTY poll adds. Every chunk before the last is
    /// accepted; the last one must be rejected.
    @Test("The responder rejects prompts and output outside the clear dialog", arguments: [
        ["Turn off SIP? [y/n]: "],
        ["Password: "],
        ["Enter password for user pomme: "],
        ["Authorized user: ", "pomme\nEnter password for user intruder: "],
        ["Authorized user: ", "pomme\nUnknown user - try again!\nAuthorized user: "],
        ["Authorized user: ", "pomme\nPassword       : ", "\nFailed to authenticate.\n"],
        ["Authorized user: ", "pomme\nPassword       : ", "\nAuthorized user: "],
        ["Authorized user: ", "pomme\nPassword       : ", "\nPassword       : "],
        ["Authorized user: ", "pomme\nPassword       : ", "\nProceed? [y/n]: "]
    ])
    func responderRejectsUnsafeDialog(_ chunks: [String]) throws {
        let credentials = try Self.credentials()
        var responder = PommeGuestSIPClearPromptResponder(expectedUsername: "pomme")
        var transcript = ""
        for chunk in chunks.dropLast() {
            transcript += chunk
            _ = try responder.nextInput(for: transcript, credentials: credentials)
        }
        transcript += chunks.last ?? ""
        #expect(throws: PommeGuestRecoverySecurityError.promptRejected) {
            _ = try responder.nextInput(for: transcript, credentials: credentials)
        }
    }

    @Test("A clear that never reports success is not complete")
    func responderRequiresSuccessLine() throws {
        let credentials = try Self.credentials()
        var responder = PommeGuestSIPClearPromptResponder(expectedUsername: "pomme")
        var transcript = "Authorized user: "
        _ = try responder.nextInput(for: transcript, credentials: credentials)
        transcript += "pomme\nPassword       : "
        _ = try responder.nextInput(for: transcript, credentials: credentials)
        transcript += "\nfailed to clear system integrity configuration: denied\n"
        _ = try responder.nextInput(for: transcript, credentials: credentials)
        #expect(!responder.completed)
    }

    @Test("Credentials for another user are rejected before any input")
    func responderBindsCredentials() throws {
        var responder = PommeGuestSIPClearPromptResponder(expectedUsername: "pomme")
        #expect(throws: PommeGuestRecoverySecurityError.promptRejected) {
            _ = try responder.nextInput(for: "Authorized user: ", credentials: try Self.credentials("intruder"))
        }
    }

    // MARK: Guest operation

    @Test("The guest clears SIP as the owner after proving the installed volume")
    func guestClearsAfterEnvironmentProof() throws {
        let fixture = ClearFixture()
        let result = try fixture.operations().executeNormalSIPClear(role: .persistent, payload: Self.payload)
        #expect(result == .object([
            "operation": .string("sip.normal.clear"),
            "sipConfigurationCleared": .bool(true),
            "verified": .bool(true)
        ]))
        #expect(fixture.verifiedGroups == [Self.groupUUID])
        #expect(fixture.secretCalls == [["clear"]])
        #expect(fixture.secretCredentials == [try Self.credentials()])
        let encoded = try JSONEncoder().encode(result)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(Self.password))
    }

    @Test("Only the root persistent agent may clear SIP")
    func guestRequiresRootPersistentRole() throws {
        let fixture = ClearFixture()
        #expect(throws: PommeGuestRecoverySecurityError.invalidOperation) {
            _ = try fixture.operations().executeNormalSIPClear(role: .recovery, payload: Self.payload)
        }
        #expect(throws: PommeGuestRecoverySecurityError.rootRequired) {
            _ = try fixture.operations(effectiveUserID: 501)
                .executeNormalSIPClear(role: .persistent, payload: Self.payload)
        }
        #expect(fixture.verifiedGroups.isEmpty)
        #expect(fixture.secretCalls.isEmpty)
    }

    @Test("The clear payload is closed", arguments: [
        JSONValue.object(["authorizedUser": .string("pomme"), "password": .string(password)]),
        .object([
            "authorizedUser": .string("pomme"), "password": .string(password),
            "volumeGroupUUID": .string(groupUUID.uuidString)
        ]),
        .object([
            "authorizedUser": .string("pomme"), "password": .string(password),
            "volumeGroupUUID": .string(groupUUID.uuidString.lowercased()), "stage": .string("policy")
        ]),
        .object([
            "authorizedUser": .string("pomme"), "password": .string(""),
            "volumeGroupUUID": .string(groupUUID.uuidString.lowercased())
        ])
    ])
    func guestRejectsOpenPayloads(_ payload: JSONValue) throws {
        let fixture = ClearFixture()
        #expect(throws: PommeGuestRecoverySecurityError.self) {
            _ = try fixture.operations().executeNormalSIPClear(role: .persistent, payload: payload)
        }
        #expect(fixture.verifiedGroups.isEmpty)
        #expect(fixture.secretCalls.isEmpty)
    }

    @Test("A failed environment proof stops before csrutil runs")
    func guestStopsOnEnvironmentFailure() throws {
        let fixture = ClearFixture(environmentError: .recoveryEnvironmentUnverified)
        #expect(throws: PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified) {
            _ = try fixture.operations().executeNormalSIPClear(role: .persistent, payload: Self.payload)
        }
        #expect(fixture.secretCalls.isEmpty)
    }

    @Test("A nonzero csrutil exit is a failed clear")
    func guestRejectsFailedExit() throws {
        let fixture = ClearFixture(exitStatus: 1)
        #expect(throws: PommeGuestRecoverySecurityError.commandFailed) {
            _ = try fixture.operations().executeNormalSIPClear(role: .persistent, payload: Self.payload)
        }
    }

    @Test("The persistent agent advertises the clear operation")
    func agentAdvertisesClear() {
        #expect(PommeGuestRecoverySecurityOperations.normalSIPClearOperation == "sip.normal.clear")
        #expect(PommeAgent.persistentCapabilities.contains("sip.normal.clear"))
        #expect(!PommeAgent.recoveryCapabilities.contains("sip.normal.clear"))
    }

    @Test("The clear request passes the real control wire parser and router")
    func clearRouting() throws {
        let request = PommeControlRequest(command: "agent.perform", payload: .object([
            "operation": .string("sip.normal.clear"), "payload": Self.payload
        ]))
        let decoded = try ControlWireCodec.decodeRequest(ControlWireCodec.encodeLine(request))
        guard case .agentPerform(let agent, streaming: false) = try PommeVMControlRouter.route(decoded) else {
            Issue.record("The SIP clear request was not routed")
            return
        }
        #expect(agent.operation == "sip.normal.clear")
        #expect(agent.payload == Self.payload)
        let prefixed = PommeControlRequest(command: "agent.perform", payload: .object([
            "operation": .string("sip.normal.clearAll"), "payload": .object([:])
        ]))
        let decodedPrefixed = try ControlWireCodec.decodeRequest(ControlWireCodec.encodeLine(prefixed))
        #expect(throws: RunnerError.self) { try PommeVMControlRouter.route(decodedPrefixed) }
    }

    @Test("Only the normal role gets the clear exchange window")
    func clearExchangeWindow() {
        let ordinary: TimeInterval = 5
        #expect(PommeAgentVSOCKCoordinator.normalSIPClearExchangeTimeout == 300)
        #expect(PommeAgentVSOCKCoordinator.exchangeTimeout(
            for: .normal, operation: "sip.normal.clear", defaultTimeout: ordinary)
            == PommeAgentVSOCKCoordinator.normalSIPClearExchangeTimeout)
        #expect(PommeAgentVSOCKCoordinator.exchangeTimeout(
            for: .recoveryRuntime, operation: "sip.normal.clear", defaultTimeout: ordinary) == ordinary)
    }

    // MARK: Host receipt

    @Test("The host accepts only the exact clear receipt")
    func hostReceiptIsExact() {
        let receipt: [String: Any] = [
            "operation": "sip.normal.clear", "sipConfigurationCleared": true, "verified": true
        ]
        #expect(PommeSecurityNormalAgent.isVerifiedSIPClearReceipt(["ok": true, "result": receipt]))
        #expect(!PommeSecurityNormalAgent.isVerifiedSIPClearReceipt(["ok": false, "result": receipt]))
        var unverified = receipt
        unverified["verified"] = false
        #expect(!PommeSecurityNormalAgent.isVerifiedSIPClearReceipt(["ok": true, "result": unverified]))
        var foreign = receipt
        foreign["operation"] = "sip.enable"
        #expect(!PommeSecurityNormalAgent.isVerifiedSIPClearReceipt(["ok": true, "result": foreign]))
        var extra = receipt
        extra["sipDisabled"] = false
        #expect(!PommeSecurityNormalAgent.isVerifiedSIPClearReceipt(["ok": true, "result": extra]))
        #expect(!PommeSecurityNormalAgent.isVerifiedSIPClearReceipt(["ok": true]))
    }

    @Test("Only a closed guest failure code is surfaced from a failed reply")
    func hostFailureCodeIsClosed() {
        #expect(PommeSecurityNormalAgent.guestFailureCode([
            "ok": false,
            "error": "Pomme agent request failed (recovery-prompt-rejected): The prompt was rejected."
        ]) == .promptRejected)
        #expect(PommeSecurityNormalAgent.guestFailureCode([
            "ok": false, "error": "Pomme agent request failed (guest-failure): anything"
        ]) == nil)
        #expect(PommeSecurityNormalAgent.guestFailureCode([
            "ok": false, "error": "Unrelated (recovery-prompt-rejected)"
        ]) == nil)
        #expect(PommeSecurityNormalAgent.guestFailureCode([
            "ok": true, "error": "Pomme agent request failed (recovery-prompt-rejected)"
        ]) == nil)
    }
}

private final class ClearFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let environmentError: PommeGuestRecoverySecurityError?
    private let exitStatus: Int32
    private var groups: [UUID] = []
    private var calls: [[String]] = []
    private var credentials: [PommeGuestSecurityCredentials] = []

    init(environmentError: PommeGuestRecoverySecurityError? = nil, exitStatus: Int32 = 0) {
        self.environmentError = environmentError
        self.exitStatus = exitStatus
    }

    var verifiedGroups: [UUID] { lock.withLock { groups } }
    var secretCalls: [[String]] { lock.withLock { calls } }
    var secretCredentials: [PommeGuestSecurityCredentials] { lock.withLock { credentials } }

    func operations(effectiveUserID: uid_t = 0) -> PommeGuestRecoverySecurityOperations {
        .init(
            process: { _, _ in throw PommeGuestRecoverySecurityError.invalidOperation },
            secretProcess: { [self] executable, arguments, credentials in
                guard executable == "/usr/bin/csrutil" else {
                    throw PommeGuestRecoverySecurityError.invalidOperation
                }
                lock.withLock {
                    calls.append(arguments)
                    self.credentials.append(credentials)
                }
                return .init(status: exitStatus)
            },
            effectiveUserID: { effectiveUserID },
            normalEnvironmentVerifier: { [self] group in
                lock.withLock { groups.append(group) }
                if let environmentError { throw environmentError }
            }
        )
    }
}
