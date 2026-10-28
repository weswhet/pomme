import ArgumentParser
import Darwin
import Foundation

/// A flat installer package on the host, checked before any guest traffic.
struct PommeHostPackage: Equatable, Sendable {
    /// The file the transfer reads: the given path with every symbolic link
    /// resolved, because the transfer refuses a final symbolic link.
    let url: URL
    /// The name the guest copy keeps: the last component of the given path.
    let name: String

    /// The first bytes of every flat package, which is a xar archive.
    static let xarMagic = Data("xar!".utf8)

    /// Checks that `path` names a readable, regular flat `.pkg` file. A
    /// bundle package is a folder, which the file transfer can't copy, so it
    /// is refused here rather than partway through the install.
    static func validated(
        path: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> Self {
        guard !path.isEmpty, !path.contains("\0") else {
            throw ValidationError("--pkg needs the path of a .pkg file.")
        }
        let given = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: currentDirectory).appendingPathComponent(path)
        let name = given.lastPathComponent
        guard given.pathExtension.lowercased() == "pkg", name.count > ".pkg".count else {
            throw ValidationError("--pkg must name a flat installer package ending in .pkg: \(path)")
        }
        // realpath(3), not URL.resolvingSymlinksInPath, which turns
        // /private/var into the /var symbolic link.
        guard let resolved = realpath(given.path, nil) else {
            if errno == ENOENT || errno == ENOTDIR {
                throw ValidationError("No such package: \(path)")
            }
            throw ValidationError("\(path) can't be read: \(String(cString: strerror(errno))).")
        }
        let url = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ValidationError("\(path) can't be read: \(String(cString: strerror(errno))).")
        }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            throw ValidationError("\(path) is a folder. pomme install accepts only flat .pkg files, not bundle packages.")
        case S_IFREG:
            break
        default:
            throw ValidationError("\(path) isn't a regular file.")
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw ValidationError("\(path) can't be read.")
        }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: xarMagic.count)) == xarMagic else {
            throw ValidationError("\(path) isn't a flat installer package; it doesn't start with a xar header.")
        }
        return .init(url: url, name: name)
    }
}

/// Installs a host package in a running VM through the guest agent.
///
/// Every step uses an operation the agent already offers: `process.start`
/// for `mkdir`, `installer`, and `rm`, and the file transfer for the copy.
/// The installer runs as a background job that the host waits on, because a
/// foreground command is limited to 300 seconds and large packages take
/// longer.
struct PommeGuestPackageInstall: Sendable {
    static let installerPath = "/usr/sbin/installer"
    static let stagingRoot = "/private/var/tmp"
    static let stagingPrefix = "pomme-install-"
    /// The installer's default time limit. Most packages install in a few
    /// minutes, and an operating system component can take much longer.
    static let defaultTimeout: TimeInterval = 30 * 60
    /// The longest wait `--timeout` accepts: one day.
    static let maximumTimeout: TimeInterval = 24 * 60 * 60
    /// The time limit of the `mkdir` and `rm` steps around the install.
    static let housekeepingTimeout: TimeInterval = 60

    let package: PommeHostPackage
    let requestID: UUID
    let timeout: TimeInterval

    init(package: PommeHostPackage, timeout: TimeInterval, requestID: UUID = UUID()) {
        self.package = package
        self.timeout = timeout
        self.requestID = requestID
    }

    /// A folder only this request uses. `mkdir` fails if it already exists,
    /// so Pomme never adopts or removes a folder that it didn't create.
    var stagingDirectory: String {
        "\(Self.stagingRoot)/\(Self.stagingPrefix)\(requestID.uuidString.lowercased())"
    }

    var stagedPath: String { "\(stagingDirectory)/\(package.name)" }

    /// Every guest step runs as root: `installer -target /` requires it, and
    /// the staging folder is readable only by root.
    private func rootCommand(_ path: String, _ arguments: [String], timeout: TimeInterval) -> GuestCommandRequest {
        GuestCommandRequest(path: path, arguments: arguments, timeout: timeout, uid: 0)
    }

    var createStagingRequest: GuestCommandRequest {
        rootCommand("/bin/mkdir", ["-m", "0700", stagingDirectory], timeout: Self.housekeepingTimeout)
    }

    var copyRequest: CopyRequest {
        CopyRequest(source: .host(package.url), destination: .guest(stagedPath))
    }

    var installerRequest: GuestCommandRequest {
        rootCommand(Self.installerPath, ["-pkg", stagedPath, "-target", "/"], timeout: timeout)
    }

    var removeStagingRequest: GuestCommandRequest {
        rootCommand("/bin/rm", ["-rf", stagingDirectory], timeout: Self.housekeepingTimeout)
    }

    /// Whether `path` has the exact shape of a staging folder, so that the
    /// recursive removal can't reach anything else.
    static func isStagingDirectory(_ path: String) -> Bool {
        let prefix = "\(stagingRoot)/\(stagingPrefix)"
        guard path.hasPrefix(prefix) else { return false }
        let rawID = String(path.dropFirst(prefix.count))
        guard let id = UUID(uuidString: rawID) else { return false }
        return rawID == id.uuidString.lowercased()
    }

    /// What became of the staging folder after the install.
    enum StagingCleanup: Equatable {
        case removed
        /// The installer might still be reading the package.
        case kept
        case failed(String)
    }

    /// The installer's end, when Pomme saw it.
    private enum Completion {
        case exited(PommeOperationResult)
        /// The wait ended first or failed, so the job may still be running.
        case unknown(jobID: String, waited: PommeOperationResult, timedOut: Bool)
    }

    func run(vmName: String, guest: GuestOperations) throws -> PommeOperationResult {
        let progress = PommeProgressContext.sink
        PommeUnifiedLog.notice(
            "installing \(package.name) through \(stagingDirectory) with a \(Self.seconds(timeout))s limit",
            vmName: vmName, logger: PommeUnifiedLog.install
        )
        progress?.step(vm: vmName, "Preparing the guest staging folder")
        let created: PommeOperationResult
        do {
            created = try guest.execute(vmName, createStagingRequest)
        } catch {
            // The folder may exist even though the reply was lost. Its name
            // is unique to this request, so removing it is safe. The error
            // may also have come before any guest traffic, for example from
            // a stopped VM, so a failed removal here isn't reported.
            _ = cleanUp(vmName: vmName, guest: guest, speculative: true)
            throw error
        }
        guard created.ok, created.hostExitCode == 0 else {
            throw PommeGuestPackageInstallError.stagingFailed(
                directory: stagingDirectory, detail: Self.outputText(created.payload)
            )
        }

        var receipt: [String: Any] = [:]
        let completion: Completion
        do {
            progress?.step(vm: vmName, "Copying \(package.name)")
            let copied = try guest.request(vmName, .copy(copyRequest), "Copy")
            guard copied.ok else {
                throw PommeGuestPackageInstallError.stagingFailed(directory: stagingDirectory, detail: copied.text)
            }
            receipt = copied.payload.filter { ["bytes", "sha256"].contains($0.key) }

            progress?.step(vm: vmName, "Running installer")
            let started = try guest.request(vmName, .startBackground(installerRequest), "Install")
            guard started.ok else {
                throw PommeGuestPackageInstallError.installerNotStarted(detail: started.text)
            }
            guard let jobID = (started.payload["result"] as? [String: Any])?["jobID"] as? String,
                  UUID(uuidString: jobID) != nil else {
                throw PommeGuestPackageInstallError.invalidJobResponse
            }
            PommeUnifiedLog.notice("installer started as job \(jobID)", vmName: vmName, logger: PommeUnifiedLog.install)
            do {
                let waited = try guest.request(vmName, .jobWait(jobID: jobID, timeout: timeout), "Install")
                let status = waited.payload["result"] as? [String: Any]
                let timedOut = status?["timedOut"] as? Bool == true
                if waited.ok, !timedOut, status?["exited"] as? Bool == true {
                    completion = .exited(waited)
                } else {
                    completion = .unknown(jobID: jobID, waited: waited, timedOut: timedOut)
                }
            } catch {
                PommeUnifiedLog.error(error, context: "waiting for installer job \(jobID)",
                                      vmName: vmName, logger: PommeUnifiedLog.install)
                throw PommeGuestPackageInstallError.installerOutcomeUnknown(
                    package: package.name, jobID: jobID, directory: stagingDirectory, underlying: error
                )
            }
        } catch let error as PommeGuestPackageInstallError {
            if case .installerOutcomeUnknown = error {
                // The package stays for the installer that may still run.
                PommeCore.warning("kept \(stagingDirectory) in the guest because the installer may still be running.", vmName: vmName)
            } else {
                _ = cleanUp(vmName: vmName, guest: guest)
            }
            throw error
        } catch {
            _ = cleanUp(vmName: vmName, guest: guest)
            throw error
        }

        switch completion {
        case .exited(let waited):
            let cleanup = cleanUp(vmName: vmName, guest: guest)
            return installedResult(vmName: vmName, waited: waited, receipt: receipt, cleanup: cleanup)
        case .unknown(let jobID, let waited, let timedOut):
            PommeUnifiedLog.notice("installer job \(jobID) didn't report its end (timedOut=\(timedOut)); kept \(stagingDirectory)",
                                   vmName: vmName, logger: PommeUnifiedLog.install)
            let detail = waited.text.isEmpty ? "the guest agent didn't report the job's end." : waited.text
            let error = PommeGuestPackageInstallError.installerStillRunning(
                package: package.name, jobID: jobID, directory: stagingDirectory,
                timeout: timeout, detail: timedOut ? nil : detail
            )
            var payload = basePayload(vmName: vmName, receipt: receipt, cleanup: .kept)
            payload["jobID"] = jobID
            return failure(error, payload: payload, vmName: vmName,
                           hostExitCode: timedOut ? 124 : (waited.hostExitCode == 0 ? 1 : waited.hostExitCode))
        }
    }

    /// Removes the staging folder, best effort. A failure is reported as a
    /// warning and never replaces the install's own result. A `speculative`
    /// removal, of a folder that may not exist, logs a failure only to the
    /// unified log.
    func cleanUp(vmName: String, guest: GuestOperations, speculative: Bool = false) -> StagingCleanup {
        guard Self.isStagingDirectory(stagingDirectory) else {
            return .failed("The staging path has an unexpected shape.")
        }
        let reason: String
        do {
            let removed = try guest.execute(vmName, removeStagingRequest)
            if removed.ok, removed.hostExitCode == 0 {
                PommeUnifiedLog.notice("removed \(stagingDirectory)", vmName: vmName, logger: PommeUnifiedLog.install)
                return .removed
            }
            let output = Self.outputText(removed.payload)
            reason = output.isEmpty ? "rm exited with status \(removed.hostExitCode)" : output
        } catch {
            reason = error.localizedDescription
        }
        guard !speculative else {
            PommeUnifiedLog.notice("didn't remove \(stagingDirectory), which may not exist: \(reason)",
                                   vmName: vmName, logger: PommeUnifiedLog.install)
            return .failed(reason)
        }
        PommeCore.warning(
            "couldn't remove \(stagingDirectory) in the guest: \(reason) "
                + "To remove it, run `pomme exec \(vmName) -- /bin/rm -rf \(stagingDirectory)`.",
            vmName: vmName
        )
        return .failed(reason)
    }

    private func installedResult(
        vmName: String,
        waited: PommeOperationResult,
        receipt: [String: Any],
        cleanup: StagingCleanup
    ) -> PommeOperationResult {
        var payload = basePayload(vmName: vmName, receipt: receipt, cleanup: cleanup)
        let status = waited.payload["result"] as? [String: Any] ?? [:]
        payload["jobID"] = status["jobID"]
        if let exitCode = status["exitCode"] { payload["exitCode"] = exitCode }
        if let signal = status["signal"] { payload["signal"] = signal }
        let frames = (try? CLIOutputWriter.backgroundJobOutput(waited.payload)) ?? []
        payload["stdout"] = String(decoding: frames.filter { $0.descriptor == STDOUT_FILENO }.flatMap(\.data), as: UTF8.self)
        payload["stderr"] = String(decoding: frames.filter { $0.descriptor == STDERR_FILENO }.flatMap(\.data), as: UTF8.self)

        guard waited.hostExitCode == 0 else {
            PommeUnifiedLog.notice("installer failed with status \(waited.hostExitCode)", vmName: vmName, logger: PommeUnifiedLog.install)
            // The installer's own output explains the failure, so the table
            // form prints it, exactly as `pomme exec` would, before the error.
            payload["foreground"] = true
            payload["streamFrames"] = frames.map { frame in
                ["stream": frame.descriptor == STDOUT_FILENO ? "stdout" : "stderr",
                 "dataBase64": frame.data.base64EncodedString()]
            }
            let error = PommeGuestPackageInstallError.installerFailed(package: package.name, status: waited.hostExitCode)
            return failure(error, payload: payload, vmName: vmName, hostExitCode: waited.hostExitCode)
        }
        PommeUnifiedLog.notice("installed \(package.name)", vmName: vmName, logger: PommeUnifiedLog.install)
        payload["ok"] = true
        payload["hostExitCode"] = 0
        return PommeOperationResult(
            title: "Install", vmName: vmName, ok: true, hostExitCode: 0,
            text: "Installed \(package.name) in \(vmName).", payload: payload
        )
    }

    private func basePayload(vmName: String, receipt: [String: Any], cleanup: StagingCleanup) -> [String: Any] {
        var payload: [String: Any] = [
            "operation": "package.install",
            "name": vmName,
            "package": package.name,
            "stagedPath": stagedPath,
            "stagingRemoved": cleanup == .removed
        ]
        payload.merge(receipt) { current, _ in current }
        if case .failed(let reason) = cleanup { payload["stagingCleanupError"] = reason }
        return payload
    }

    private func failure(
        _ error: PommeGuestPackageInstallError,
        payload: [String: Any],
        vmName: String,
        hostExitCode: Int32
    ) -> PommeOperationResult {
        var payload = payload
        let report = PommeErrorReport(error, redaction: .none)
        payload["ok"] = false
        payload["error"] = report.message
        payload["hostExitCode"] = Int(hostExitCode)
        payload[PommeErrorReport.payloadKey] = report.payloadObject
        return PommeOperationResult(
            title: "Install", vmName: vmName, ok: false, hostExitCode: hostExitCode,
            text: report.message, payload: payload
        )
    }

    /// Whole seconds for a message, without the trap of `Int(_:)` on a huge
    /// value.
    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.0f", interval)
    }

    /// The text of a foreground result's output, for a failure message.
    static func outputText(_ payload: [String: Any]) -> String {
        let frames = (try? CLIOutputWriter.foregroundOutput(payload)) ?? []
        return String(decoding: frames.flatMap(\.data), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PommeGuestPackageInstallError: PommeDescribedError {
    case stagingFailed(directory: String, detail: String)
    case installerNotStarted(detail: String)
    case invalidJobResponse
    case installerFailed(package: String, status: Int32)
    case installerStillRunning(package: String, jobID: String, directory: String, timeout: TimeInterval, detail: String?)
    case installerOutcomeUnknown(package: String, jobID: String, directory: String, underlying: any Error)

    var code: PommeErrorCode {
        switch self {
        case .stagingFailed, .installerNotStarted: .guestOperationFailed
        case .invalidJobResponse: .guestAgentProtocolError
        case .installerFailed: .guestPackageInstallFailed
        case .installerStillRunning(_, _, _, _, let detail): detail == nil ? .timedOut : .guestOperationFailed
        case .installerOutcomeUnknown: .guestOperationFailed
        }
    }

    var underlying: (any Error)? {
        if case .installerOutcomeUnknown(_, _, _, let error) = self { return error }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .stagingFailed(let directory, let detail):
            "Pomme couldn't stage the package in the guest folder \(directory)" + (detail.isEmpty ? "." : ": \(detail)")
        case .installerNotStarted(let detail):
            "Pomme couldn't start the installer in the guest" + (detail.isEmpty ? "." : ": \(detail)")
        case .invalidJobResponse:
            "The guest agent didn't return a job ID for the installer."
        case .installerFailed(let package, let status):
            "The installer couldn't install \(package) (exit status \(status))."
        case .installerStillRunning(let package, let jobID, let directory, let timeout, let detail):
            (detail.map { "Pomme stopped waiting for the installer of \(package): \($0) " }
                ?? "The installer of \(package) didn't finish within \(PommeGuestPackageInstall.seconds(timeout)) seconds. ")
                + "It may still be running in the guest as job \(jobID), so Pomme left the package in \(directory)."
        case .installerOutcomeUnknown(let package, let jobID, let directory, let error):
            "Pomme lost track of the installer of \(package): \(error.localizedDescription) "
                + "It may still be running in the guest as job \(jobID), so Pomme left the package in \(directory)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .stagingFailed, .installerNotStarted:
            "Check the guest's free disk space, then retry."
        case .invalidJobResponse:
            "Run `pomme agent update NAME` to update the guest agent."
        case .installerFailed:
            "Read the installer output above for the reason."
        case .installerStillRunning(_, let jobID, let directory, _, _),
             .installerOutcomeUnknown(_, let jobID, let directory, _):
            "Run `pomme jobs wait NAME --job \(jobID) --timeout 3600` to wait for it. "
                + "After the wait reports that the job exited, run `pomme exec NAME -- /bin/rm -rf \(directory)`."
        }
    }
}
