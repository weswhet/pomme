import CryptoKit
import Darwin
import Foundation
import Testing
@preconcurrency import Virtualization

@Suite("Pomme Recovery VirtioFS terminal bootstrap")
struct PommeRecoveryVirtioFSBootstrapTests {
    @Test("Terminal plan is bounded, OCR-safe, and request-bound")
    func terminalPlanIsBoundedAndRequestBound() throws {
        let fixture = try makeFixture()
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)

        #expect(plan.tag == "pomme-0123456789abcdef01234567")
        #expect(plan.mountWorkspacePath == "/private/var/run/.pomme-vfs-0123456789abcdef01234567")
        #expect(plan.guestWorkspacePath == "/private/var/tmp/pomme-recovery-01234567-89ab-cdef-0123-456789abcdef")
        #expect(plan.runScriptPath == "\(plan.mountWorkspacePath)/run")
        #expect(plan.capabilityProbes.count == 1)
        #expect(plan.capabilityProbes[0].marker == plan.completionMarker)
        #expect(plan.capabilityProbes[0].command.contains("POMME"))
        #expect(plan.commands.count == 1)

        for command in plan.capabilityProbes.map(\.command) + plan.commands {
            #expect(command.utf8.count <= PommeRecoveryVirtioFSTerminalPlan.maximumCommandLength)
            #expect(command.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e })
            #expect(command.allSatisfy { HostDisplayKey.lookup(character: $0) != nil })
        }
        #expect(plan.commands[0].contains("/sbin/mount_virtiofs -r pomme-"))
        #expect(!plan.commands[0].contains("/usr/bin/nc"))
        #expect(!plan.commands[0].contains("mkdir -p"))
        #expect(plan.launcherScript.contains("--pomme-agent 505052"))
        #expect(plan.launcherScript.contains("--role recovery"))
        #expect(plan.launcherScript.contains("--vm-id 11111111-2222-3333-4444-555555555555"))
        #expect(plan.launcherScript.contains("--session-id 01234567-89ab-cdef-0123-456789abcdef"))
        #expect(plan.launcherScript.contains("--operation agent.install"))
        #expect(plan.launcherScript.contains("--request-file \"$g/request.json\""))
        #expect(plan.launcherScript.contains("--expected-sha256 \(fixture.digest)"))
        #expect(plan.launcherScript.contains(plan.requestSHA256))
        #expect(!plan.launcherScript.contains("agent.token"))
        #expect(!plan.launcherScript.contains("persistentToken"))
        #expect(!plan.launcherScript.contains(fixture.credentialText))
    }

    @Test("Bootstrap stages exactly the fixed read-only artifact set")
    func stagingIsPrivateReadOnlyAndAllowListed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let rootName = "pomme-recovery-vfs-unit"
        let builder = PommeRecoveryVirtioFSBootstrapBuilder(dependencies: .init(
            verifyCodeSignature: { _ in },
            rootName: { rootName }
        ))
        let prepared = try builder.build(.init(
            request: fixture.request,
            signedExecutableURL: fixture.executableURL,
            credential: fixture.credential,
            temporaryParentURL: fixture.parentURL
        ))
        defer { try? prepared.staging.removeHostArtifacts() }

        let names = try Set(FileManager.default.contentsOfDirectory(atPath: prepared.rootURL.path))
        #expect(names == PommeRecoveryArtifactNames.all)
        #expect(prepared.deviceConfiguration.share is VZSingleDirectoryShare)
        #expect(prepared.staging.proof.readOnly)
        #expect(prepared.staging.proof.isComplete)
        let stagedLauncher = try String(
            contentsOf: prepared.rootURL.appendingPathComponent(PommeRecoveryArtifactNames.launcher),
            encoding: .utf8
        )
        #expect(prepared.terminalPlan.launcherScript == stagedLauncher)
        #expect(mode(of: prepared.rootURL) == 0o700)
        for (name, expectedMode) in PommeRecoveryArtifactNames.modes {
            #expect(mode(of: prepared.rootURL.appendingPathComponent(name)) == expectedMode)
        }
    }

    @Test("Signature and exact executable digest are both required")
    func signatureAndDigestAreRequired() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let signatureChecks = LockedBootstrapCounter()
        let rejecting = PommeRecoveryVirtioFSBootstrapBuilder(dependencies: .init(
            verifyCodeSignature: { _ in
                signatureChecks.increment()
                throw PommeRecoveryVirtioFSBootstrapError.signatureRejected
            },
            rootName: { "pomme-recovery-vfs-signature" }
        ))
        #expect(throws: PommeRecoveryVirtioFSBootstrapError.signatureRejected) {
            _ = try rejecting.build(.init(
                request: fixture.request,
                signedExecutableURL: fixture.executableURL,
                credential: fixture.credential,
                temporaryParentURL: fixture.parentURL
            ))
        }
        #expect(signatureChecks.value == 1)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.parentURL.appendingPathComponent("pomme-recovery-vfs-signature").path
        ))

        let wrongDigest = try makeFixture(digest: String(repeating: "a", count: 64))
        defer { wrongDigest.remove() }
        let digestBuilder = PommeRecoveryVirtioFSBootstrapBuilder(dependencies: .init(
            verifyCodeSignature: { _ in },
            rootName: { "pomme-recovery-vfs-digest" }
        ))
        #expect(throws: PommeRecoveryVirtioFSBootstrapError.digestRejected) {
            _ = try digestBuilder.build(.init(
                request: wrongDigest.request,
                signedExecutableURL: wrongDigest.executableURL,
                credential: wrongDigest.credential,
                temporaryParentURL: wrongDigest.parentURL
            ))
        }
        #expect(!FileManager.default.fileExists(
            atPath: wrongDigest.parentURL.appendingPathComponent("pomme-recovery-vfs-digest").path
        ))
    }

    @Test("Symlink sources and unapproved staging names fail closed")
    func symlinksAndNamesFailClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let link = fixture.parentURL.appendingPathComponent("pomme-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.executableURL)
        let checks = LockedBootstrapCounter()
        let builder = PommeRecoveryVirtioFSBootstrapBuilder(dependencies: .init(
            verifyCodeSignature: { _ in checks.increment() },
            rootName: { "pomme-recovery-vfs-symlink" }
        ))
        #expect(throws: PommeRecoveryVirtioFSBootstrapError.sourceRejected) {
            _ = try builder.build(.init(
                request: fixture.request,
                signedExecutableURL: link,
                credential: fixture.credential,
                temporaryParentURL: fixture.parentURL
            ))
        }
        #expect(checks.value == 0)

        let badNameBuilder = PommeRecoveryVirtioFSBootstrapBuilder(dependencies: .init(
            verifyCodeSignature: { _ in },
            rootName: { "unexpected-root" }
        ))
        #expect(throws: PommeRecoveryVirtioFSBootstrapError.invalidInput) {
            _ = try badNameBuilder.build(.init(
                request: fixture.request,
                signedExecutableURL: fixture.executableURL,
                credential: fixture.credential,
                temporaryParentURL: fixture.parentURL
            ))
        }
    }

    @Test("SIP and AMFI plans never carry a durable normal-agent token")
    func securityPlansHaveNoDurableToken() throws {
        let fixture = try makeFixture(operation: .sip(.disable))
        defer { fixture.remove() }
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)
        #expect(plan.launcherScript.contains("--operation sip.disable"))
        #expect(plan.launcherScript.contains("--role recovery"))
        #expect(!plan.launcherScript.contains("agent.token"))
        #expect(!plan.launcherScript.contains("persistentToken"))
        #expect(!plan.launcherScript.contains("com.github.weswhet.pomme.agent"))
        #expect(!plan.launcherScript.contains("/usr/local/libexec/pomme"))
        #expect(plan.launcherScript.contains("session.credential"))
    }

    @Test("Unmount and share removal precede the Recovery daemon exec")
    func unmountPrecedesExec() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let script = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request).launcherScript
        let unmount = try #require(script.range(of: "/sbin/umount"))
        let launch = try #require(script.range(of: "\"$g/pomme-agent\" --pomme-agent"))
        #expect(unmount.lowerBound < launch.lowerBound)
        #expect(script.contains("/bin/rmdir \"$m\""))
        #expect(script.contains("test ! -e \"$m\" && test ! -L \"$m\""))
        #expect(script.contains("/bin/rmdir \"$d\""))
    }

    @Test("Launcher installs closed failure cleanup before mutation and runs daemon in foreground")
    func launcherFailureCleanupIsActiveAndBounded() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let script = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request).launcherScript
        let trap = try #require(script.range(of: "trap cleanup_on_exit EXIT"))
        let guestCreate = try #require(script.range(of: "/bin/mkdir -m 700 \"$g\""))
        let launch = try #require(script.range(of: "\"$g/pomme-agent\" --pomme-agent"))
        let marker = try #require(script.range(of: "/usr/bin/printf '%s\\n'"))

        #expect(trap.lowerBound < guestCreate.lowerBound)
        #expect(guestCreate.lowerBound < launch.lowerBound)
        #expect(launch.lowerBound < marker.lowerBound)
        #expect(script.contains("cleanup_known_mount_workspace"))
        #expect(script.contains("cleanup_known_guest_workspace"))
        #expect(script.contains("\"$g/pomme-agent\"|\"$g/request.json\"|\"$g/session.credential\""))
        #expect(!script.contains("rm -rf"))
        #expect(!script.contains("request-file \"$g/request.json\" </dev/null >/dev/null 2>&1 &"))
    }

    @Test("Cleanup command is closed to the two request workspaces")
    func cleanupCommandIsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)
        let removal = PommeRecoveryVirtioFSBootstrapGuestCleanup.request(
            terminalPlan: plan,
            timeout: 7
        )
        #expect(removal.path == "/bin/sh")
        #expect(removal.arguments.count == 5)
        #expect(removal.arguments[0] == "-c")
        #expect(removal.arguments[3] == plan.guestWorkspacePath)
        #expect(removal.arguments[4] == plan.mountWorkspacePath)
        #expect(removal.arguments[1].contains("pomme-agent"))
        #expect(removal.arguments[1].contains("session.credential"))
        #expect(removal.arguments[1].contains("/bin/rmdir"))
        #expect(!removal.arguments[1].contains("rm -rf"))
        #expect(!removal.arguments[1].contains("find /"))
    }

    @Test("Cleanup requires bounded successful command and independent absence proof")
    func cleanupRunsAndVerifiesAbsence() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)
        let calls = LockedBootstrapRequests()
        try await PommeRecoveryVirtioFSBootstrapGuestCleanup.run(
            terminalPlan: plan,
            timeout: 7,
            execute: { request in
                calls.append(request)
                return GuestCommandResult(
                    exitCode: 0,
                    signal: nil,
                    stdout: Data(),
                    stderr: Data(),
                    stdoutTruncated: false,
                    stderrTruncated: false
                )
            }
        )
        #expect(calls.value.count == 2)
        #expect(calls.value[0].timeout == 7)
        #expect(calls.value[1].timeout == 7)
        #expect(calls.value[1].arguments[0] == "-c")
        #expect(calls.value[1].arguments[1].contains("test ! -e"))
    }

    @Test("Only Recovery boots can receive the prepared share")
    func bootConfigurationIsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let builder = PommeRecoveryVirtioFSBootstrapBuilder(dependencies: .init(
            verifyCodeSignature: { _ in },
            rootName: { "pomme-recovery-vfs-config" }
        ))
        let prepared = try builder.build(.init(
            request: fixture.request,
            signedExecutableURL: fixture.executableURL,
            credential: fixture.credential,
            temporaryParentURL: fixture.parentURL
        ))
        defer { try? prepared.staging.removeHostArtifacts() }

        #expect(try PommeRecoveryVirtioFSBootstrapConfiguration.directorySharingDevices(
            bootMode: .normal,
            recoveryAgentEnabled: true,
            preparedBootstrap: prepared
        ).isEmpty)
        #expect(try PommeRecoveryVirtioFSBootstrapConfiguration.directorySharingDevices(
            bootMode: .recovery,
            recoveryAgentEnabled: false,
            preparedBootstrap: prepared
        ).isEmpty)
        #expect(try PommeRecoveryVirtioFSBootstrapConfiguration.directorySharingDevices(
            bootMode: .recovery,
            recoveryAgentEnabled: true,
            preparedBootstrap: prepared
        ).count == 1)
        #expect(throws: PommeRecoveryVirtioFSBootstrapError.self) {
            _ = try PommeRecoveryVirtioFSBootstrapConfiguration.directorySharingDevices(
                bootMode: .recovery,
                recoveryAgentEnabled: true,
                preparedBootstrap: nil
            )
        }
    }

    private func makeFixture(
        operation: PommeRecoveryOperation = .installAgent,
        digest: String? = nil
    ) throws -> BootstrapFixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pomme-recovery-vfs-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let bytes = Data("signed pomme executable fixture".utf8)
        let executable = parent.appendingPathComponent("pomme")
        try bytes.write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: executable.path)
        let executableDigest = PommeRecoveryCrypto.sha256(bytes)
        let credential = try PommeRecoveryCredential(
            secret: Data(repeating: 7, count: 32),
            expiresAt: Date().addingTimeInterval(120)
        )
        let request = try PommeRecoverySessionRequest(
            requestID: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!,
            vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            operation: operation,
            issuedAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(60),
            executableSHA256: digest ?? executableDigest,
            credential: credential
        )
        return .init(
            parentURL: parent,
            executableURL: executable,
            request: request,
            credential: credential,
            digest: executableDigest,
            credentialText: PommeRecoveryCrypto.hex(Data(repeating: 7, count: 32))
        )
    }
}

private struct BootstrapFixture {
    let parentURL: URL
    let executableURL: URL
    let request: PommeRecoverySessionRequest
    let credential: PommeRecoveryCredential
    let digest: String
    let credentialText: String

    func remove() {
        try? FileManager.default.removeItem(at: parentURL)
    }
}

private func mode(of url: URL) -> mode_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return 0 }
    return value.st_mode & 0o777
}

private final class LockedBootstrapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

private final class LockedBootstrapRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GuestCommandRequest] = []

    var value: [GuestCommandRequest] { lock.withLock { stored } }

    func append(_ request: GuestCommandRequest) {
        lock.withLock { stored.append(request) }
    }
}
