import Foundation
import Testing
@preconcurrency import Virtualization

@Suite("Pomme runtime model")
struct PommeRuntimeModelTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var snapshot: [String] { lock.withLock { values } }
    }

    @Test("Provisioning requires host availability and the exact guest major")
    func provisioningAvailability() {
        #expect(PommeMacGuestProvisioningIntent.isSupported(hostMajor: 27, guestMajor: 27))
        #expect(PommeMacGuestProvisioningIntent.isSupported(hostMajor: 28, guestMajor: 27))
        #expect(!PommeMacGuestProvisioningIntent.isSupported(hostMajor: 26, guestMajor: 27))
        #expect(!PommeMacGuestProvisioningIntent.isSupported(hostMajor: 27, guestMajor: 26))
        #expect(!PommeMacGuestProvisioningIntent.isSupported(hostMajor: 27, guestMajor: 28))
    }

    @Test("Ordinary start options have no provisioning and Recovery rejects injection")
    func provisioningOptionsAreExplicit() throws {
        if #available(macOS 27, *) {
            let options = VZMacOSVirtualMachineStartOptions()
            #expect(options.guestProvisioningOptions == nil)
            options.startUpFromMacOSRecovery = true
            let events = Events()
            let intent = PommeMacGuestProvisioningIntent(password: "private-test-password", guestMajor: 27) { events.append("marker") }
            #expect(throws: (any Error).self) { try intent.prepareDispatch(options: options) }
            #expect(options.guestProvisioningOptions == nil)
            #expect(events.snapshot.isEmpty)
        }
    }

    @Test("Provisioning rejects Recovery and every saved-state path before dispatch")
    func provisioningColdNormalOnly() throws {
        let events = Events()
        let intent = PommeMacGuestProvisioningIntent(password: "private-test-password", guestMajor: 27) { events.append("marker") }
        try intent.validate(bootMode: .normal, hasSavedState: false, requiresRestore: false, hostMajor: 27)
        for mode in [BootMode.normal, .recovery] {
            for saved in [false, true] {
                for required in [false, true] where mode != .normal || saved || required {
                    #expect(throws: (any Error).self) {
                        try intent.validate(bootMode: mode, hasSavedState: saved, requiresRestore: required, hostMajor: 27)
                    }
                }
            }
        }
        #expect(events.snapshot.isEmpty)
    }

    @Test("Provisioning setter precedes durable marker and dispatch cannot repeat")
    func provisioningOneShotOrdering() throws {
        let events = Events()
        let intent = PommeMacGuestProvisioningIntent(password: "private-test-password", guestMajor: 27) { events.append("marker") }
        try intent.prepareDispatch { events.append("setter") }
        events.append("framework-start")
        #expect(throws: (any Error).self) { try intent.prepareDispatch { events.append("repeated") } }
        #expect(events.snapshot == ["setter", "marker", "framework-start"])
    }

    @Test("Failed preparation never leaks secrets and cannot be replayed")
    func provisioningRedactionAndFailure() throws {
        let secret = "private-test-password"
        let events = Events()
        let intent = PommeMacGuestProvisioningIntent(password: secret, guestMajor: 27) { events.append("marker") }
        #expect(!String(describing: intent).contains(secret))
        #expect(!String(reflecting: intent).contains(secret))
        #expect(Mirror(reflecting: intent).children.isEmpty)
        do {
            try intent.prepareDispatch { throw NSError(domain: secret, code: 1) }
            Issue.record("Expected setter failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
        #expect(throws: (any Error).self) { try intent.prepareDispatch {} }
        #expect(events.snapshot.isEmpty)
        let markerFailure = PommeMacGuestProvisioningIntent(password: secret, guestMajor: 27) {
            throw NSError(domain: secret, code: 2)
        }
        do {
            try markerFailure.prepareDispatch {}
            Issue.record("Expected marker failure")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test("Guest agent status has a closed Codable schema")
    func guestAgentStatusSchema() throws {
        let status = GuestAgentStatusV1(
            connection: .connected,
            role: .normal,
            protocolVersion: 1,
            executableDigest: "abc",
            capabilities: ["exec"],
            updateState: .current
        )
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(Set(object.keys) == ["connection", "role", "protocolVersion", "executableDigest", "capabilities", "updateState"])
        #expect(object["connection"] as? String == "connected")
        #expect(object["role"] as? String == "normal")
    }

    @Test("Only Pomme normal and Recovery ports are defined")
    func listenerPorts() {
        #expect(PommeAgentPort.persistentNormal == 505_051)
        #expect(PommeAgentPort.recoveryBootstrap == 505_052)
        #expect(PommeAgentPort.recoveryRuntime == 505_053)
        let immediatelyPrecedingPort = PommeAgentPort.persistentNormal - 1
        #expect(![PommeAgentPort.persistentNormal, PommeAgentPort.recoveryBootstrap, PommeAgentPort.recoveryRuntime].contains(immediatelyPrecedingPort))
    }

    @Test("Runtime identity cache keys include the helper lifetime")
    func runtimeIdentityIncludesLifetime() {
        let old = PommeRuntimeIdentity(socketPath: "/tmp/pomme-a.sock", pid: 42, startedAt: "first")
        let replacement = PommeRuntimeIdentity(socketPath: "/tmp/pomme-a.sock", pid: 42, startedAt: "second")
        #expect(old != replacement)
        #expect(Set([old, replacement]).count == 2)
    }

    @Test("Offline guest status is closed")
    func offlineGuestStatus() throws {
        let status = GuestAgentStatusV1.offline(role: .recovery)
        #expect(status.connection == .disconnected)
        #expect(status.role == .recovery)
        #expect(status.protocolVersion == nil)
        #expect(status.capabilities.isEmpty)
        #expect(status.updateState == .unavailable)
    }
}
