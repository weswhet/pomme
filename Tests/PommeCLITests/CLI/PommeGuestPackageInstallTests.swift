import Darwin
import Foundation
import Testing

/// Records each guest call and answers it from a script.
private final class FakeGuest: @unchecked Sendable {
    enum Call: Equatable {
        case execute(String, [String], UInt32?)
        case copy(source: String, destination: String)
        case start(String, [String], UInt32?, TimeInterval)
        case wait(String, TimeInterval)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let jobID = UUID().uuidString.lowercased()

    var mkdirStatus: Int32 = 0
    var rmStatus: Int32 = 0
    var copyFails = false
    var installerStatus: Int32 = 0
    var mkdirThrows = false
    var copyRefused = false
    var startFails = false
    /// The job ID the start reply carries; nil leaves it out.
    lazy var startJobID: String? = jobID
    var waitTimesOut = false
    var waitThrows = false
    /// The status poll answers with an error instead of the job's end.
    var waitRefused = false

    var calls: [Call] { lock.withLock { recorded } }

    private func record(_ call: Call) { lock.withLock { recorded.append(call) } }

    private static func frame(_ stream: String, _ text: String) -> [String: Any] {
        ["stream": stream, "dataBase64": Data(text.utf8).base64EncodedString()]
    }

    private func foreground(_ status: Int32, stderr: String = "") -> PommeOperationResult {
        PommeOperationResult(
            title: "Exec", vmName: "dev", ok: true, hostExitCode: status, text: "",
            payload: ["foreground": true, "hostExitCode": Int(status),
                      "streamFrames": stderr.isEmpty ? [] : [Self.frame("stderr", stderr)]]
        )
    }

    var operations: GuestOperations {
        GuestOperations(
            request: { [self] _, request, title in
                switch request {
                case .copy(let copy):
                    guard case .host(let source) = copy.source, case .guest(let destination) = copy.destination else {
                        throw RunnerError.unsupportedCopy("unexpected endpoints")
                    }
                    record(.copy(source: source.path, destination: destination))
                    if copyFails {
                        throw RunnerError.guestFileTransferFailed(primary: "disk full", transferredBytes: 2, cleanupErrors: [])
                    }
                    if copyRefused {
                        return PommeOperationResult(title: title, vmName: "dev", ok: false, hostExitCode: 1, text: "No space left on device",
                                                    payload: ["ok": false, "operation": "file.transfer", "hostExitCode": 1])
                    }
                    return PommeOperationResult(title: title, vmName: "dev", ok: true, hostExitCode: 0, text: "Copied 8 bytes.",
                                                payload: ["ok": true, "operation": "file.transfer", "bytes": 8, "sha256": "ab12", "hostExitCode": 0])
                case .startBackground(let command):
                    record(.start(command.path, command.arguments, command.uid, command.timeout))
                    if startFails {
                        return PommeOperationResult(title: title, vmName: "dev", ok: false, hostExitCode: 1,
                                                    text: "The identity helper refused uid 0.",
                                                    payload: ["ok": false, "hostExitCode": 1])
                    }
                    var result: [String: Any] = ["detached": true]
                    result["jobID"] = startJobID
                    return PommeOperationResult(title: title, vmName: "dev", ok: true, hostExitCode: 0, text: "",
                                                payload: ["ok": true, "result": result])
                case .jobWait(let id, let timeout):
                    record(.wait(id, timeout))
                    if waitThrows { throw RunnerError.guestAgentDisconnected }
                    if waitRefused {
                        return PommeOperationResult(title: title, vmName: "dev", ok: false, hostExitCode: 0,
                                                    text: "Unknown process job.",
                                                    payload: ["ok": false, "operation": "process.status", "hostExitCode": 0,
                                                              "result": ["jobID": id]])
                    }
                    if waitTimesOut {
                        return PommeOperationResult(title: title, vmName: "dev", ok: false, hostExitCode: 124,
                                                    text: "Timed out waiting for the background job.",
                                                    payload: ["ok": false, "operation": "process.wait", "hostExitCode": 124,
                                                              "result": ["jobID": id, "timedOut": true], "streamFrames": [[String: Any]]()])
                    }
                    let frames: [[String: Any]] = [
                        Self.frame("stdout", "installer: Package name is Tool\n"),
                        Self.frame("stderr", installerStatus == 0 ? "" : "installer: Error - the package is damaged.\n"),
                        ["stream": "exit"]
                    ]
                    return PommeOperationResult(title: title, vmName: "dev", ok: true, hostExitCode: installerStatus, text: "",
                                                payload: ["ok": true, "operation": "process.wait", "hostExitCode": Int(installerStatus),
                                                          "result": ["jobID": id, "exited": true, "exitCode": Int(installerStatus),
                                                                     "timedOut": false, "outputComplete": true],
                                                          "streamFrames": frames])
                default:
                    Issue.record("pomme install sent an unexpected guest request.")
                    throw RunnerError.guestAgentError("unexpected")
                }
            },
            execute: { [self] _, command in
                record(.execute(command.path, command.arguments, command.uid))
                switch command.path {
                case "/bin/mkdir":
                    if mkdirThrows { throw RunnerError.guestAgentDisconnected }
                    return foreground(mkdirStatus, stderr: mkdirStatus == 0 ? "" : "mkdir: File exists")
                case "/bin/rm": return foreground(rmStatus, stderr: rmStatus == 0 ? "" : "rm: Operation not permitted")
                default:
                    Issue.record("pomme install ran an unexpected foreground command.")
                    return foreground(1)
                }
            },
            ui: { _, _ in throw RunnerError.guestAgentError("unexpected") }
        )
    }
}

@Suite("Install request composition")
struct PommeGuestPackageInstallTests {
    private let requestID = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
    private let staging = "/private/var/tmp/pomme-install-0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

    private func install(_ fixture: InstallPackageFixture, timeout: TimeInterval = 1_800) throws -> PommeGuestPackageInstall {
        PommeGuestPackageInstall(package: try PommeHostPackage.validated(path: fixture.flat.path),
                                 timeout: timeout, requestID: requestID)
    }

    @Test("Each step runs as root in a staging folder unique to the request")
    func requestShapes() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let install = try install(fixture, timeout: 900)

        #expect(install.stagingDirectory == staging)
        #expect(install.stagedPath == staging + "/Tool.pkg")
        #expect(PommeGuestPackageInstall.isStagingDirectory(install.stagingDirectory))

        let mkdir = install.createStagingRequest
        #expect(mkdir.path == "/bin/mkdir" && mkdir.arguments == ["-m", "0700", staging] && mkdir.uid == 0)

        let installer = install.installerRequest
        #expect(installer.path == "/usr/sbin/installer")
        #expect(installer.arguments == ["-pkg", staging + "/Tool.pkg", "-target", "/"])
        #expect(installer.uid == 0 && installer.user == nil && installer.timeout == 900)
        #expect(!installer.pty && !installer.attachStdin)
        try GuestCLIRequest.startBackground(installer).validate()

        let rm = install.removeStagingRequest
        #expect(rm.path == "/bin/rm" && rm.arguments == ["-rf", staging] && rm.uid == 0)

        let copy = install.copyRequest
        try copy.validate()
        guard case .host(let source) = copy.source, case .guest(let destination) = copy.destination else {
            Issue.record("The copy must go from the host to the guest.")
            return
        }
        #expect(source.lastPathComponent == "Tool.pkg")
        #expect(destination == staging + "/Tool.pkg")
    }

    @Test("Only the exact staging shape can be removed", arguments: [
        "/private/var/tmp", "/private/var/tmp/", "/private/var/tmp/pomme-install-",
        "/private/var/tmp/pomme-install-not-a-uuid",
        "/private/var/tmp/pomme-install-0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0",
        "/private/var/tmp/pomme-install-0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0/..",
        "/tmp/pomme-install-0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
    ])
    func refusesOtherRemovalPaths(_ path: String) {
        #expect(!PommeGuestPackageInstall.isStagingDirectory(path))
    }

    @Test("A successful install stages, installs, removes the copy, and confirms")
    func success() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        let install = try install(fixture)
        let result = try install.run(vmName: "dev", guest: guest.operations)

        // The copy reads the resolved path; /var in the temporary folder is
        // itself a link to /private/var.
        #expect(guest.calls == [
            .execute("/bin/mkdir", ["-m", "0700", staging], 0),
            .copy(source: install.package.url.path, destination: staging + "/Tool.pkg"),
            .start("/usr/sbin/installer", ["-pkg", staging + "/Tool.pkg", "-target", "/"], 0, 1_800),
            .wait(guest.jobID, 1_800),
            .execute("/bin/rm", ["-rf", staging], 0)
        ])
        #expect(result.ok && result.hostExitCode == 0)
        #expect(result.text == "Installed Tool.pkg in dev.")
        #expect(result.payload["package"] as? String == "Tool.pkg")
        #expect(result.payload["stagingRemoved"] as? Bool == true)
        #expect(result.payload["stdout"] as? String == "installer: Package name is Tool\n")
        #expect((result.payload["bytes"] as? NSNumber)?.intValue == 8)
        #expect(CLIOutputWriter.tableRendering(for: result) == .text(descriptor: STDOUT_FILENO, text: "Installed Tool.pkg in dev."))
    }

    @Test("A failed installer exits nonzero, shows its output, and still removes the copy")
    func installerFailure() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.installerStatus = 1
        let result = try install(fixture).run(vmName: "dev", guest: guest.operations)

        #expect(guest.calls.last == .execute("/bin/rm", ["-rf", staging], 0))
        #expect(!result.ok && result.hostExitCode == 1)
        #expect(PommeErrorOutput.failureReport(result.payload).code == .guestPackageInstallFailed)
        #expect(result.text.contains("Tool.pkg"))
        #expect(CLIOutputWriter.tableRendering(for: result) == .foregroundFrames)
        let output = try CLIOutputWriter.foregroundOutput(result.payload)
        #expect(output.contains { $0.descriptor == STDERR_FILENO && String(decoding: $0.data, as: UTF8.self).contains("damaged") })
        #expect(result.payload["stagingRemoved"] as? Bool == true)
    }

    @Test("A failed copy removes the staging folder and reports the copy's error")
    func copyFailureCleansUp() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.copyFails = true
        #expect(throws: RunnerError.self) { _ = try install(fixture).run(vmName: "dev", guest: guest.operations) }
        #expect(guest.calls.count == 3)
        #expect(guest.calls.last == .execute("/bin/rm", ["-rf", staging], 0))
    }

    @Test("A lost mkdir reply still removes the folder it may have made, without a warning")
    func mkdirThrowCleansUpQuietly() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.mkdirThrows = true
        #expect(throws: RunnerError.self) { _ = try install(fixture).run(vmName: "dev", guest: guest.operations) }
        #expect(guest.calls == [
            .execute("/bin/mkdir", ["-m", "0700", staging], 0),
            .execute("/bin/rm", ["-rf", staging], 0)
        ])
        // The speculative removal reports its failure only to the log.
        guest.rmStatus = 1
        #expect(try install(fixture).cleanUp(vmName: "dev", guest: guest.operations, speculative: true)
                    == .failed("rm: Operation not permitted"))
    }

    @Test("A copy the guest refuses removes the staging folder")
    func copyRefusalCleansUp() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.copyRefused = true
        do {
            _ = try install(fixture).run(vmName: "dev", guest: guest.operations)
            Issue.record("A refused copy was ignored.")
        } catch let error as PommeGuestPackageInstallError {
            #expect(error.code == .guestOperationFailed)
            #expect(error.localizedDescription.contains("No space left on device"))
        }
        #expect(guest.calls.last == .execute("/bin/rm", ["-rf", staging], 0))
        #expect(!guest.calls.contains { if case .start = $0 { true } else { false } })
    }

    @Test("An installer the agent won't start leaves no package behind")
    func startFailureCleansUp() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.startFails = true
        do {
            _ = try install(fixture).run(vmName: "dev", guest: guest.operations)
            Issue.record("A refused start was ignored.")
        } catch let error as PommeGuestPackageInstallError {
            #expect(error.code == .guestOperationFailed)
            #expect(error.localizedDescription.contains("uid 0"))
        }
        #expect(guest.calls.last == .execute("/bin/rm", ["-rf", staging], 0))
        #expect(!guest.calls.contains { if case .wait = $0 { true } else { false } })
    }

    @Test("A start reply without a valid job ID is a protocol error and cleans up", arguments: [nil, "job-1"] as [String?])
    func invalidJobIDCleansUp(_ jobID: String?) throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.startJobID = jobID
        do {
            _ = try install(fixture).run(vmName: "dev", guest: guest.operations)
            Issue.record("A start reply without a job ID was accepted.")
        } catch let error as PommeGuestPackageInstallError {
            #expect(error.code == .guestAgentProtocolError)
        }
        #expect(guest.calls.last == .execute("/bin/rm", ["-rf", staging], 0))
        #expect(!guest.calls.contains { if case .wait = $0 { true } else { false } })
    }

    @Test("A cleanup failure doesn't hide a successful install")
    func cleanupFailureKeepsResult() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.rmStatus = 1
        let result = try install(fixture).run(vmName: "dev", guest: guest.operations)

        #expect(result.ok && result.hostExitCode == 0)
        #expect(result.payload["stagingRemoved"] as? Bool == false)
        #expect((result.payload["stagingCleanupError"] as? String)?.contains("Operation not permitted") == true)
    }

    @Test("A cleanup failure doesn't replace the installer's failure")
    func cleanupFailureKeepsInstallerFailure() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.installerStatus = 3
        guest.rmStatus = 1
        let result = try install(fixture).run(vmName: "dev", guest: guest.operations)
        #expect(result.hostExitCode == 3)
        #expect(PommeErrorOutput.failureReport(result.payload).code == .guestPackageInstallFailed)
    }

    @Test("A timeout leaves the package for the installer that may still be running")
    func timeoutKeepsPackage() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.waitTimesOut = true
        let result = try install(fixture, timeout: 5).run(vmName: "dev", guest: guest.operations)

        #expect(!guest.calls.contains(.execute("/bin/rm", ["-rf", staging], 0)))
        #expect(!result.ok && result.hostExitCode == 124)
        #expect(PommeErrorOutput.failureReport(result.payload).code == .timedOut)
        #expect(result.text.contains(guest.jobID) && result.text.contains(staging))
        #expect(result.payload["stagingRemoved"] as? Bool == false)
    }

    @Test("A wait that ends in an error keeps the package and never exits 0")
    func refusedWaitKeepsPackage() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.waitRefused = true
        let result = try install(fixture).run(vmName: "dev", guest: guest.operations)

        #expect(!guest.calls.contains(.execute("/bin/rm", ["-rf", staging], 0)))
        #expect(!result.ok && result.hostExitCode == 1)
        #expect(PommeErrorOutput.failureReport(result.payload).code == .guestOperationFailed)
        #expect(result.text.contains("Unknown process job."))
        #expect(result.text.contains(guest.jobID) && result.text.contains(staging))
        #expect(result.payload["stagingRemoved"] as? Bool == false)
    }

    @Test("A lost wait leaves the package and names the job")
    func lostWaitKeepsPackage() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.waitThrows = true
        do {
            _ = try install(fixture).run(vmName: "dev", guest: guest.operations)
            Issue.record("A lost wait was reported as a result.")
        } catch let error as PommeGuestPackageInstallError {
            #expect(error.code == .guestOperationFailed)
            #expect(error.localizedDescription.contains(guest.jobID))
        }
        #expect(!guest.calls.contains(.execute("/bin/rm", ["-rf", staging], 0)))
    }

    @Test("A staging folder that mkdir didn't create is never removed")
    func mkdirFailureStops() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let guest = FakeGuest()
        guest.mkdirStatus = 1
        do {
            _ = try install(fixture).run(vmName: "dev", guest: guest.operations)
            Issue.record("A failed mkdir was ignored.")
        } catch let error as PommeGuestPackageInstallError {
            #expect(error.localizedDescription.contains("File exists"))
        }
        #expect(guest.calls == [.execute("/bin/mkdir", ["-m", "0700", staging], 0)])
    }
}
