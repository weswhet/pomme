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
        defer { fixture.remove() }
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

    @Test("Fractional Recovery expiry stays POSIX-formatted and daemon-parseable")
    func fractionalExpiryPreservesLauncherArgumentAndDaemonIdentity() throws {
        // This is a timestamp shape observed in live Recovery qualification;
        // unlike the old 10_060 fixture it exercises the decimal separator
        // and the full-width epoch used by current Tahoe builds.
        let expectedEpoch = 1_788_575_600.179787
        let request = try makeFractionalExpiryRequest(epoch: expectedEpoch)
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: request)

        // Arrange/Act: read the token from the generated daemon invocation,
        // rather than reconstructing it from request.expiresAt.
        let expiryToken = try #require(
            launcherArgumentValue(named: "--one-shot-expiry", in: plan.launcherScript)
        )
        let parsedEpoch = try #require(TimeInterval(expiryToken))

        // Assert: the emitted token is a plain POSIX decimal with no locale
        // grouping or comma separator, and retains microsecond precision.
        #expect(expiryToken == "1788575600.179787")
        #expect(!expiryToken.contains(","))
        #expect(expiryToken.unicodeScalars.filter { $0.value == 0x2e }.count == 1)
        #expect(expiryToken.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value) || scalar.value == 0x2e
        })
        #expect(abs(parsedEpoch - expectedEpoch) <= 0.000001)

        // PommeAgentDaemon.parse rejects expired wall-clock values. Use a
        // separate, far-future fractional value to verify the generated
        // request identities through the real Recovery grammar as well.
        let parseEpoch = 9_999_999_000.179787
        let parseRequest = try makeFractionalExpiryRequest(epoch: parseEpoch)
        let parsePlan = try PommeRecoveryVirtioFSTerminalPlan(request: parseRequest)
        let parseScript = parsePlan.launcherScript
        let daemonPort = try #require(launcherArgumentValue(named: "--pomme-agent", in: parseScript))
        let daemonDigest = try #require(launcherArgumentValue(named: "--expected-sha256", in: parseScript))
        let daemonRole = try #require(launcherArgumentValue(named: "--role", in: parseScript))
        let daemonExpiry = try #require(launcherArgumentValue(named: "--one-shot-expiry", in: parseScript))
        let daemonVMID = try #require(launcherArgumentValue(named: "--vm-id", in: parseScript))
        let daemonSessionID = try #require(launcherArgumentValue(named: "--session-id", in: parseScript))
        let daemonOperation = try #require(launcherArgumentValue(named: "--operation", in: parseScript))
        let options = try PommeAgentDaemon.parse(arguments: [
            "--pomme-agent", daemonPort,
            "--token-file", "\(parsePlan.guestWorkspacePath)/session.credential",
            "--expected-sha256", daemonDigest,
            "--role", daemonRole,
            "--one-shot-expiry", daemonExpiry,
            "--vm-id", daemonVMID,
            "--session-id", daemonSessionID,
            "--operation", daemonOperation,
            "--request-file", "\(parsePlan.guestWorkspacePath)/request.json"
        ])
        let daemonParsedExpiry = try #require(options.oneShotExpiry)
        #expect(options.port == parseRequest.listenerPort)
        #expect(options.role == .recovery)
        #expect(options.expectedSHA256 == parseRequest.executableSHA256)
        #expect(options.vmBinding == parseRequest.vmUUID.uuidString.lowercased())
        #expect(options.sessionBinding == parseRequest.requestID.uuidString.lowercased())
        #expect(options.allowedOperation == parseRequest.operation)
        #expect(abs(daemonParsedExpiry.timeIntervalSince1970 - parseEpoch) <= 0.000001)
    }

    @Test("Capability probe proves the Recovery SHA-256 command before mutation")
    func capabilityProbeProvesRecoverySHA256BeforeMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)
        let probe = try #require(plan.capabilityProbes.first)

        #expect(plan.capabilityProbes.count == 1)
        #expect(probe.command.utf8.count <= PommeRecoveryVirtioFSTerminalPlan.maximumCommandLength)
        let knownVector = PommeRecoveryCrypto.sha256(Data("abc".utf8))
        #expect(knownVector == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(knownVector.utf8.count == 64)
        #expect(probe.command.hasPrefix("p=/sbin;u=/usr/bin;"))
        #expect(probe.command.contains("test -x $p/mount_virtiofs&&test -x $p/umount&&test -x $u/codesign&&test -x $p/sha256&&test"))
        #expect(probe.command.contains("$u/printf abc|$p/sha256 -q"))
        #expect(probe.command.contains(knownVector))
        #expect(probe.command.contains("printf '\(probe.marker)\\n'"))
        #expect(!probe.command.contains("/usr/bin/shasum"))
        #expect(!probe.command.contains("/usr/bin/openssl"))
        #expect(plan.launcherScript.contains("/sbin/sha256 -q \"$g/pomme-agent\""))
        #expect(plan.launcherScript.contains("/sbin/sha256 -q \"$g/request.json\""))
        #expect(!plan.launcherScript.contains("/usr/bin/shasum"))
        #expect(!plan.launcherScript.contains("/usr/bin/openssl"))
    }

    @Test("Generated capability probe emits only its marker when host tools exist")
    func generatedCapabilityProbeExecutesReadOnlyWhenHostToolsExist() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)
        let probe = try #require(plan.capabilityProbes.first)
        let requiredPaths = [
            "/sbin/mount_virtiofs",
            "/sbin/umount",
            "/usr/bin/codesign",
            "/sbin/sha256",
            "/usr/bin/printf"
        ]
        try #require(requiredPaths.allSatisfy { path in
            FileManager.default.isExecutableFile(atPath: path)
        })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", probe.command, "pomme-recovery-vfs-capability-probe"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        #expect(errorOutput.isEmpty)
        #expect(output == "\(probe.marker)\n")
    }

    @Test("Compact launcher keeps workspace confinement and stops at failed guards", arguments: ["success", "existing", "mountFailure", "copyFailure"])
    func compactLauncherPreservesGuardOrdering(scenario: String) throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let plan = try PommeRecoveryVirtioFSTerminalPlan(request: fixture.request)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-compact-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let workspace = parent.appendingPathComponent("workspace with spaces")
        let arguments = parent.appendingPathComponent("mount-arguments")
        let mount = parent.appendingPathComponent("mount-stub")
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var mountScript = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(quote(arguments.path))\n"
        if scenario == "mountFailure" {
            mountScript += "exit 9\n"
        } else if scenario != "copyFailure" {
            let launcher = "#!/bin/sh\nprintf '%s\\n' \"$PWD\"\n"
            mountScript += "printf '%s' \(quote(launcher)) > \(quote("m/" + PommeRecoveryArtifactNames.launcher))\n"
        }
        try mountScript.write(to: mount, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mount.path)
        if scenario == "existing" {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        }
        let command = plan.command
            .replacingOccurrences(of: "d=\(plan.mountWorkspacePath)", with: "d=\(quote(workspace.path))")
            .replacingOccurrences(of: "/sbin/mount_virtiofs", with: quote(mount.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if scenario == "success" {
            #expect(process.terminationStatus == 0)
            #expect(text == workspace.path + "\n")
            let attributes = try FileManager.default.attributesOfItem(atPath: workspace.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        } else {
            #expect(process.terminationStatus != 0)
            #expect(text.isEmpty)
        }
        if scenario == "existing" {
            #expect(!FileManager.default.fileExists(atPath: arguments.path))
        } else {
            #expect(try String(contentsOf: arguments, encoding: .utf8) == "-r\n\(plan.tag)\nm\n")
        }
    }

    @Test("Recovery SHA-256 command agrees with CryptoKit for a private fixture")
    func recoverySHA256CommandAgreesWithCryptoKit() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pomme-recovery-sha-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let bytes = Data("Pomme Recovery digest fixture\n".utf8)
        let input = parent.appendingPathComponent("digest-input")
        try bytes.write(to: input, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let expected = PommeRecoveryCrypto.sha256(bytes)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/sha256")
        process.arguments = ["-q", input.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let actual = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        #expect(errorOutput.isEmpty)
        #expect(actual == expected)
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
        let stagedRequest = try Data(
            contentsOf: prepared.rootURL.appendingPathComponent(PommeRecoveryArtifactNames.request)
        )
        #expect(prepared.terminalPlan.launcherScript == stagedLauncher)
        #expect(PommeRecoveryCrypto.sha256(stagedRequest) == prepared.terminalPlan.requestSHA256)
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

private func launcherArgumentValue(named name: String, in script: String) -> String? {
    guard let range = script.range(of: "\(name) ") else { return nil }
    return String(script[range.upperBound...].prefix { !$0.isWhitespace })
}

private func makeFractionalExpiryRequest(epoch: TimeInterval) throws -> PommeRecoverySessionRequest {
    let expiresAt = Date(timeIntervalSince1970: epoch)
    let credential = try PommeRecoveryCredential(
        id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        secret: Data(repeating: 0x42, count: 32),
        expiresAt: expiresAt
    )
    return try PommeRecoverySessionRequest(
        requestID: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!,
        vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        operation: .installAgent,
        issuedAt: expiresAt.addingTimeInterval(-60),
        expiresAt: expiresAt,
        executableSHA256: String(repeating: "a", count: 64),
        credential: credential
    )
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
