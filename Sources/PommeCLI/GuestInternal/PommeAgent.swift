import Darwin
import Foundation

enum PommeAgentRole: String, Sendable { case persistent, recovery }
enum PommeAgentAuthority: Sendable { case standard, recoveryTerminal }

/// A single long-lived normal-boot agent or a bounded Recovery session.
/// VSOCK integration owns framing I/O and delegates each authenticated request
/// to this actor; process and file state intentionally survive reconnects.
actor PommeAgent {
    /// Version of the credential-free normal-boot AMFI staging contract. The
    /// host asks for this version through the opt-in describe payload before
    /// it can submit any normal AMFI operation.
    static let normalAMFIWorkflowVersion = 1

    /// These operation names are deliberately closed. They only stage and
    /// verify the boot-argument half of the AMFI transaction; Recovery owns
    /// LocalPolicy writes and credentials.
    static let normalAMFIOperations = [
        "amfi.normal.disable",
        "amfi.normal.enable",
        "amfi.normal.verifyDisabled",
        "amfi.normal.verifyEnabled"
    ]

    /// Version of the private PTY input contract supported by this persistent
    /// agent.  Hosts require this additive describe field before starting a
    /// credential-bearing process so older pinned daemons cannot run it.
    static let privatePTYInputVersion = 1

    /// Version of the owner-credential recovery contract. A host preflights
    /// this additive describe field before asking the root agent to recover
    /// the automatic-login owner password, so an older pinned agent fails
    /// explicitly instead of looking like a guest with no owner.
    static let ownerCredentialVersion = PommeGuestOwnerCredentialReader.version

    /// Version of the public PTY echo contract. Hosts must preflight this
    /// additive describe receipt before requesting normal terminal echo.
    static let publicPTYEchoVersion = 1
    /// Version of the durable terminal-session contract. It is advertised
    /// independently so older pinned agents fail before a PTY is created.
    static let terminalSessionVersion = PommeTerminalService.protocolVersion
    static let terminalCapabilities = [
        "terminal.create", "terminal.status", "terminal.read", "terminal.ack",
        "terminal.input", "terminal.resize", "terminal.signal", "terminal.terminate",
        "terminal.release", "terminal.list"
    ]
    static let recoveryTerminalCapabilities = ["agent.describe", "agent.health"] + terminalCapabilities
    static let recoveryCapabilities = [
        "agent.install",
        "agent.describe", "agent.health",
        "sip.status", "sip.disable", "sip.enable",
        "amfi.status", "amfi.disable", "amfi.enable"
    ]
    static let persistentCapabilities = ["agent.describe", "agent.health", "process.start", "process.status", "process.signal", "process.list", "process.output", "process.wait", "file.open", "file.read", "file.write", "file.seek", "file.flush", "file.close", "file.commit", "file.abort", "system.info", "network.interfaces", "remoteLogin.set", "mdm.staging.prepare", "mdm.enrollment", "mdm.staging.cleanup", "maintenance", "maintenance.update.begin", "maintenance.update.commit", "maintenance.update.finalize", PommeGuestOwnerCredentialReader.operation] + terminalCapabilities + normalAMFIOperations
    /// Detached-job logs retain their trailing bytes so an already streamed
    /// status response never makes `process.output` destructive. The agent
    /// keeps this bounded per channel and tells callers when earlier bytes
    /// have fallen out of the retained tail.
    static let maximumRetainedJobLogBytes = 64 * 1024
    static let maximumListedJobs = 256
    /// A logs or wait request may catch up a writer, but no one request can
    /// monopolize the agent while a child continuously produces output.
    static let maximumJobCaptureBytes = 512 * 1024
    static let maximumJobCaptureDuration = Duration.milliseconds(50)
    struct Job: Sendable {
        let id: UUID
        let pid: Int32
        let startedAt: Date
        var exited: Bool
        var status: Int32?
        let ptyMaster: Int32?
        var stdin: Int32?
        let stdout: Int32?
        let stderr: Int32?
        /// Output descriptors are marked only after a read observes EOF
        /// (EIO for a PTY master). POLLHUP remains readable on Darwin even
        /// after the final bytes have been consumed, so readiness alone
        /// cannot establish completion.
        var outputEOF: Set<Int32>
        let detached: Bool
        var stdoutLog: Data
        var stderrLog: Data
        var stdoutLogTruncated: Bool
        var stderrLogTruncated: Bool
        var stdoutBytes: Int64
        var stderrBytes: Int64
    }

    private struct OpenFile {
        let descriptor: Int32
        let readable: Bool
        let writable: Bool
        let stage: URL?
        let destination: URL?
        var tainted: Bool
    }

    let role: PommeAgentRole
    let authority: PommeAgentAuthority
    let executableSHA256: String
    private var files: [UUID: OpenFile] = [:]
    private struct FileCleanup {
        let stage: URL
        let destination: URL
        let preservePriorEntry: Bool
    }
    private var pendingFileCleanup: [UUID: FileCleanup] = [:]
    private var completedFileCleanup: Set<UUID> = []
    private var jobs: [UUID: Job] = [:]
    private var activationPending = false
    private var update: PommeAgentUpdateJournal?
    private let journalPath: String
    private let executablePath: String
    private let remoteLoginTransaction: @Sendable (Bool) throws -> Bool
    private let writeChunk: @Sendable (Int32, Data, Int) -> Int
    private let recoveryInstaller: PommeAgentRecoveryInstaller?
    private let recoverySecurity: PommeGuestRecoverySecurityOperations
    private let ownerCredential: PommeGuestOwnerCredentialReader
    private let terminalService: PommeTerminalService

    init(role: PommeAgentRole, executableSHA256: String, journalPath: String = PommeAgentInstall.journal,
         executablePath: String = PommeAgentInstall.executable,
         remoteLoginTransaction: @escaping @Sendable (Bool) throws -> Bool = PommeRemoteLogin.apply,
         writeChunk: @escaping @Sendable (Int32, Data, Int) -> Int = PommeAgent.writeChunk,
         recoveryInstaller: PommeAgentRecoveryInstaller? = nil,
         recoverySecurity: PommeGuestRecoverySecurityOperations = .init(),
         ownerCredential: PommeGuestOwnerCredentialReader = .init(),
         recoveredJournal: PommeAgentUpdateJournal? = nil,
         authority: PommeAgentAuthority = .standard) throws {
        guard executableSHA256.count == 64, executableSHA256.allSatisfy(\.isHexDigit) else {
            throw PommeAgentProtocol.Error.invalidRequest
        }
        self.role = role; self.authority = authority; self.executableSHA256 = executableSHA256.lowercased(); self.journalPath = journalPath; self.executablePath = executablePath; self.remoteLoginTransaction = remoteLoginTransaction; self.writeChunk = writeChunk
        self.recoveryInstaller = role == .recovery ? (recoveryInstaller ?? PommeAgentRecoveryInstaller()) : nil
        self.recoverySecurity = recoverySecurity
        self.ownerCredential = ownerCredential
        let terminalSpoolRoot = URL(fileURLWithPath: journalPath)
            .deletingLastPathComponent()
            .appendingPathComponent("terminal-spool", isDirectory: true)
        self.terminalService = try PommeTerminalService(
            role: role,
            spoolRoot: role == .persistent ? terminalSpoolRoot : nil
        )
        if let recovered = recoveredJournal {
            if recovered.phase != .hostValidated && recovered.phase != .rolledBack { self.update = recovered; self.activationPending = true }
        } else if FileManager.default.fileExists(atPath: journalPath) {
            let recovered = try PommeAgentJournalStore.read(at: journalPath)
            if recovered.phase != .hostValidated && recovered.phase != .rolledBack { self.update = recovered; self.activationPending = true }
        }
    }

    deinit {
        for file in files.values { _ = Darwin.close(file.descriptor) }
        for job in jobs.values { [job.ptyMaster, job.stdin, job.stdout, job.stderr].compactMap { $0 }.forEach { _ = Darwin.close($0) } }
    }

    func perform(_ request: PommeAgentProtocol.Envelope) throws -> JSONValue {
        if authority == .recoveryTerminal {
            guard role == .recovery else { throw PommeAgentOperationError.invalid }
            switch request.operation {
            case "agent.describe":
                return .object([
                    "role": .string(role.rawValue), "protocol": .string(PommeAgentProtocol.name),
                    "version": .integer(Int64(PommeAgentProtocol.version)), "executableSHA256": .string(executableSHA256),
                    "capabilities": .array(Self.recoveryTerminalCapabilities.map(JSONValue.string)),
                    "terminalSessionVersion": .integer(Int64(Self.terminalSessionVersion))
                ])
            case "agent.health":
                return .object(["ok": .bool(true), "activationPending": .bool(false)])
            default:
                throw PommeAgentOperationError.unsupported
            }
        }
        if role == .recovery {
            switch request.operation {
            case "agent.describe":
                return .object([
                    "role": .string(role.rawValue), "protocol": .string(PommeAgentProtocol.name),
                    "version": .integer(Int64(PommeAgentProtocol.version)), "executableSHA256": .string(executableSHA256),
                    "capabilities": .array(Self.recoveryCapabilities.map(JSONValue.string)),
                    "terminalSessionVersion": .integer(Int64(Self.terminalSessionVersion))
                ])
            case "agent.health":
                return .object(["ok": .bool(true), "activationPending": .bool(false)])
            case "agent.install":
                guard let recoveryInstaller else { throw PommeAgentOperationError.invalid }
                return try recoveryInstaller.install(payload: request.payload, requestID: request.requestID)
            case "terminal.create", "terminal.status", "terminal.read", "terminal.ack",
                 "terminal.input", "terminal.resize", "terminal.signal", "terminal.terminate",
                 "terminal.release", "terminal.list":
                throw PommeAgentOperationError.unsupported
            case "sip.status", "sip.disable", "sip.enable",
                 "amfi.status", "amfi.disable", "amfi.enable":
                return try recoverySecurity.execute(
                    role: role,
                    operation: request.operation,
                    payload: request.payload
                )
            default:
                throw PommeAgentOperationError.unsupported
            }
        }
        if activationPending, !request.operation.hasPrefix("maintenance.update.") {
            throw PommeAgentOperationError.activationPending
        }
        switch request.operation {
        case "agent.describe":
            var description: [String: JSONValue] = [
                "role": .string(role.rawValue), "protocol": .string(PommeAgentProtocol.name),
                "version": .integer(Int64(PommeAgentProtocol.version)), "executableSHA256": .string(executableSHA256),
                "capabilities": .array(Self.persistentCapabilities.map(JSONValue.string))
            ]
            if request.payload.objectValue?["includePrivatePTYCapabilities"] == .bool(true) {
                description["privatePTYInputVersion"] = .integer(Int64(Self.privatePTYInputVersion))
            }
            if request.payload.objectValue?["includePublicPTYCapabilities"] == .bool(true) {
                description["publicPTYEchoVersion"] = .integer(Int64(Self.publicPTYEchoVersion))
            }
            description["terminalSessionVersion"] = .integer(Int64(Self.terminalSessionVersion))
            if request.payload.objectValue?["includeNormalAMFICapabilities"] == .bool(true) {
                description["normalAMFIWorkflowVersion"] = .integer(Int64(Self.normalAMFIWorkflowVersion))
            }
            if request.payload.objectValue?["includeOwnerCredentialCapabilities"] == .bool(true) {
                description["ownerCredentialVersion"] = .integer(Int64(Self.ownerCredentialVersion))
            }
            return .object(description)
        case "agent.health": return .object(["ok": .bool(true), "activationPending": .bool(activationPending)])
        case let operation where Self.normalAMFIOperations.contains(operation):
            return try recoverySecurity.executeNormalAMFI(
                role: role,
                operation: operation,
                payload: request.payload
            )
        case "system.info": return .object(["name": .string("macOS"), "hostName": .string(ProcessInfo.processInfo.hostName)])
        case "network.interfaces": return .array([])
        case "remoteLogin.set": return try remoteLogin(request.payload)
        // The response carries the owner password, so it is produced only for
        // the root persistent agent on this authenticated session and is
        // never written to a log, journal, or process argument.
        case PommeGuestOwnerCredentialReader.operation:
            guard role == .persistent else { throw PommeAgentOperationError.invalid }
            return try ownerCredential.read(payload: request.payload)
        case "process.start": return try start(request.payload)
        case "process.status": return try status(request.payload)
        case "process.signal": return try signal(request.payload)
        case "process.list": return try list(request.payload)
        case "process.output": return try output(request.payload)
        case "process.wait": throw PommeAgentOperationError.unsupported
        case "file.open": return try open(request.payload)
        case "file.read": return try read(request.payload)
        case "file.write": return try write(request.payload)
        case "file.seek": return try seek(request.payload)
        case "file.flush": return try flush(request.payload)
        case "file.close": return try close(request.payload)
        case "file.commit": return try commitFile(request.payload)
        case "file.abort": return try abortFile(request.payload)
        case "mdm.staging.prepare":
            guard try object(request.payload).isEmpty else { throw PommeAgentOperationError.invalid }
            return try GuestMDMEnrollment.prepareStagingDirectory()
        case "mdm.enrollment": return try mdmEnrollment(request.payload)
        case "mdm.staging.cleanup": return try mdmCleanup(request.payload)
        case "maintenance": return .object(["updatePending": .bool(activationPending)])
        case "maintenance.update.begin": return try beginUpdate(request.payload)
        case "maintenance.update.commit": return try commitUpdate(request.payload)
        case "maintenance.update.finalize": return try finalizeUpdate(request.payload)
        default: throw PommeAgentOperationError.unsupported
        }
    }

    /// `process.wait` yields while it drains bounded pipe chunks. The daemon
    /// uses this entry point so ordinary synchronous in-process operation
    /// seams remain usable for file and process tests.
    func performAsynchronously(_ request: PommeAgentProtocol.Envelope) async throws -> JSONValue {
        if authority == .recoveryTerminal {
            guard request.operation == "agent.describe"
                    || request.operation == "agent.health"
                    || Self.terminalCapabilities.contains(request.operation)
            else { throw PommeAgentOperationError.unsupported }
            if request.operation == "agent.describe" || request.operation == "agent.health" {
                return try perform(request)
            }
            return try await terminalService.perform(operation: request.operation, payload: request.payload)
        }
        if Self.terminalCapabilities.contains(request.operation) {
            guard role == .persistent || role == .recovery else { throw PommeAgentOperationError.unsupported }
            return try await terminalService.perform(operation: request.operation, payload: request.payload)
        }
        if role == .persistent, request.operation == "process.wait" {
            guard !activationPending else { throw PommeAgentOperationError.activationPending }
            return try await wait(request.payload)
        }
        return try perform(request)
    }

    private func start(_ payload: JSONValue) throws -> JSONValue {
        let object = try object(payload)
        let path = try string(object, "path")
        let arguments = try strings(object["arguments"])
        let identity = try PommePrivilege.resolve(object)
        let pty = try strictBoolean(object["pty"])
        let detached = try strictBoolean(object["detached"])
        guard !(pty && detached) else { throw PommeAgentOperationError.invalid }
        let options = try PommeProcess.Options(payload: object, pty: pty)
        let launched = try PommeProcess.spawn(
            path: path,
            arguments: arguments,
            identity: identity,
            pty: pty,
            options: options
        )
        let job = Job(id: UUID(), pid: launched.pid, startedAt: Date(), exited: false, status: nil, ptyMaster: launched.ptyMaster, stdin: launched.stdin, stdout: launched.stdout, stderr: launched.stderr, outputEOF: [], detached: detached, stdoutLog: Data(), stderrLog: Data(), stdoutLogTruncated: false, stderrLogTruncated: false, stdoutBytes: 0, stderrBytes: 0)
        jobs[job.id] = job
        var result: [String: JSONValue] = [
            "jobID": .string(job.id.uuidString.lowercased()),
            "pid": .integer(Int64(launched.pid)),
            "detached": .bool(detached),
            "exited": .bool(false)
        ]
        if pty { result["ptyEchoDisabled"] = .bool(launched.ptyEchoDisabled) }
        return .object(result)
    }

    private func status(_ payload: JSONValue) throws -> JSONValue {
        let id = try jobID(payload)
        let job = try refreshStatus(for: id)
        return .object(statusResult(for: job, id: id))
    }

    private func statusResult(for job: Job, id: UUID) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "jobID": .string(id.uuidString.lowercased()),
            "pid": .integer(Int64(job.pid)),
            "exited": .bool(job.exited),
            "outputPending": .bool(hasPendingOutput(job))
        ]
        if let rawStatus = job.status {
            let terminal = terminalStatus(rawStatus)
            if let exitCode = terminal.exitCode { result["exitCode"] = .integer(Int64(exitCode)) }
            if let signal = terminal.signal { result["signal"] = .integer(Int64(signal)) }
        }
        return result
    }

    private func list(_ payload: JSONValue) throws -> JSONValue {
        guard try object(payload).isEmpty else { throw PommeAgentOperationError.invalid }
        var listed: [(id: UUID, job: Job)] = []
        for id in Array(jobs.keys) {
            let job = try refreshStatus(for: id)
            if job.detached { listed.append((id, job)) }
        }
        listed.sort { $0.job.startedAt < $1.job.startedAt }
        let retained = listed.prefix(Self.maximumListedJobs)
        return .object([
            "jobs": .array(retained.map { entry in
                var result = statusResult(for: entry.job, id: entry.id)
                result["detached"] = .bool(true)
                return .object(result)
            }),
            "truncated": .bool(listed.count > Self.maximumListedJobs)
        ])
    }

    private func output(_ payload: JSONValue) throws -> JSONValue {
        let id = try detachedJobID(payload, keys: ["jobID"])
        _ = try refreshStatus(for: id)
        _ = try captureAvailableOutput(jobID: id)
        guard let job = jobs[id] else { throw PommeAgentOperationError.notFound }
        var result = statusResult(for: job, id: id)
        result["outputComplete"] = .bool(outputIsDrained(job))
        result["stdoutBytes"] = .integer(job.stdoutBytes)
        result["stderrBytes"] = .integer(job.stderrBytes)
        result["stdoutTruncated"] = .bool(job.stdoutLogTruncated)
        result["stderrTruncated"] = .bool(job.stderrLogTruncated)
        return .object(result)
    }

    private func wait(_ payload: JSONValue) async throws -> JSONValue {
        let values = try object(payload)
        guard Set(values.keys) == ["jobID", "timeout"] else { throw PommeAgentOperationError.invalid }
        let id = try detachedJobID(payload, keys: ["jobID", "timeout"])
        let deadline = ContinuousClock.now.advanced(by: .seconds(try timeout(values, "timeout")))
        while true {
            _ = try refreshStatus(for: id)
            _ = try captureAvailableOutput(jobID: id)
            guard let current = jobs[id] else { throw PommeAgentOperationError.notFound }
            if current.exited, outputIsDrained(current) {
                var result = statusResult(for: current, id: id)
                result["outputComplete"] = .bool(true)
                result["timedOut"] = .bool(false)
                result["stdoutBytes"] = .integer(current.stdoutBytes)
                result["stderrBytes"] = .integer(current.stderrBytes)
                result["stdoutTruncated"] = .bool(current.stdoutLogTruncated)
                result["stderrTruncated"] = .bool(current.stderrLogTruncated)
                return .object(result)
            }
            if ContinuousClock.now >= deadline {
                var result = statusResult(for: current, id: id)
                result["outputComplete"] = .bool(outputIsDrained(current))
                result["timedOut"] = .bool(true)
                result["stdoutBytes"] = .integer(current.stdoutBytes)
                result["stderrBytes"] = .integer(current.stderrBytes)
                result["stdoutTruncated"] = .bool(current.stdoutLogTruncated)
                result["stderrTruncated"] = .bool(current.stderrLogTruncated)
                return .object(result)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func refreshStatus(for id: UUID) throws -> Job {
        guard var job = jobs[id] else { throw PommeAgentOperationError.notFound }
        guard !job.exited else { return job }
        while true {
            var value: Int32 = 0
            let result = waitpid(job.pid, &value, WNOHANG)
            if result == job.pid {
                job.exited = true
                job.status = value
                jobs[id] = job
                return job
            }
            if result == 0 { return job }
            if result < 0, errno == EINTR { continue }
            return job
        }
    }

    private func terminalStatus(_ rawStatus: Int32) -> (exitCode: Int32?, signal: Int32?) {
        let termination = rawStatus & 0x7f
        if termination == 0 {
            return ((rawStatus >> 8) & 0xff, nil)
        }
        guard termination != 0x7f else { return (nil, nil) }
        return (nil, termination)
    }

    private func signal(_ payload: JSONValue) throws -> JSONValue {
        let id = try jobID(payload); guard let job = jobs[id] else { throw PommeAgentOperationError.notFound }
        let raw = try integer(try object(payload), "signal")
        guard [SIGHUP, SIGINT, SIGTERM, SIGKILL].contains(Int32(raw)) else { throw PommeAgentOperationError.invalid }
        let groupSignalled = kill(-job.pid, Int32(raw)) == 0
        let processSignalled = kill(job.pid, Int32(raw)) == 0
        guard groupSignalled || processSignalled else { throw PommeAgentOperationError.invalid }
        return .object(["jobID": .string(id.uuidString.lowercased()), "signalled": .bool(true)])
    }

    private func open(_ payload: JSONValue) throws -> JSONValue {
        let object = try object(payload); let path = try string(object, "path"); let mode = try string(object, "mode")
        guard path.hasPrefix("/"), !path.contains("\0") else { throw PommeAgentOperationError.invalid }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        if mode == "stageWrite" {
            return try mapFileTransactionError { try openStage(destination: destination) }
        }
        guard mode == "read" else { throw PommeAgentOperationError.invalid }
        let fd = try mapFileTransactionError { try PommeAgentFileTransaction.openRegular(destination, flags: O_RDONLY) }
        let id = UUID(); files[id] = .init(descriptor: fd, readable: true, writable: false, stage: nil, destination: nil, tainted: false)
        return .object(["fileID": .string(id.uuidString.lowercased())])
    }

    private func openStage(destination: URL) throws -> JSONValue {
        let staged = try PommeAgentFileTransaction.createAdjacentStage(for: destination)
        let id = UUID(); files[id] = .init(descriptor: staged.descriptor, readable: false, writable: true, stage: staged.url, destination: destination, tainted: false)
        return .object(["fileID": .string(id.uuidString.lowercased()), "staged": .bool(true)])
    }

    private func read(_ payload: JSONValue) throws -> JSONValue {
        let object = try object(payload); let file = try file(object); guard file.readable else { throw PommeAgentOperationError.invalid }
        let requested = min(try integer(object, "count"), PommeAgentProtocol.maximumFileChunkBytes)
        guard requested >= 0 else { throw PommeAgentOperationError.invalid }
        var bytes = [UInt8](repeating: 0, count: requested); let count = Darwin.read(file.descriptor, &bytes, requested)
        guard count >= 0 else { throw PommeAgentOperationError.io }
        return .object(["dataBase64": .string(Data(bytes.prefix(count)).base64EncodedString()), "eof": .bool(count < requested)])
    }

    private func write(_ payload: JSONValue) throws -> JSONValue {
        let object = try object(payload); let id = try uuid(object, "fileID"); guard var file = files[id], file.writable, !file.tainted,
              let encoded = object["dataBase64"]?.stringValue, let data = Data(base64Encoded: encoded), data.count <= PommeAgentProtocol.maximumFileChunkBytes
        else { throw PommeAgentOperationError.invalid }
        var completed = false
        defer { if !completed { file.tainted = true; files[id] = file } }
        var offset = 0
        while offset < data.count { let count = writeChunk(file.descriptor, data, offset); guard count > 0 else { throw PommeAgentOperationError.io }; offset += count }
        completed = true
        return .object(["count": .integer(Int64(offset))])
    }

    private func seek(_ payload: JSONValue) throws -> JSONValue {
        let object = try object(payload); let file = try file(object); let offset = try integer(object, "offset")
        guard let whence = ["set": SEEK_SET, "current": SEEK_CUR, "end": SEEK_END][object["whence"]?.stringValue ?? ""] else { throw PommeAgentOperationError.invalid }
        let position = lseek(file.descriptor, off_t(offset), whence); guard position >= 0 else { throw PommeAgentOperationError.io }
        return .object(["position": .integer(Int64(position))])
    }

    private func flush(_ payload: JSONValue) throws -> JSONValue { let file = try file(try object(payload)); guard fsync(file.descriptor) == 0 else { throw PommeAgentOperationError.io }; return .object([:]) }
    private func close(_ payload: JSONValue) throws -> JSONValue { let object = try object(payload); let id = try uuid(object, "fileID"); guard let file = files.removeValue(forKey: id), Darwin.close(file.descriptor) == 0 else { throw PommeAgentOperationError.notFound }; return .object([:]) }
    private func commitFile(_ payload: JSONValue) throws -> JSONValue {
        let values = try object(payload)
        guard Set(values.keys) == ["fileID", "expectedBytes", "expectedSHA256"] else {
            throw PommeAgentOperationError.invalid
        }
        let id = try uuid(values, "fileID")
        let expectedBytes = try integer(values, "expectedBytes")
        let expectedSHA256 = try string(values, "expectedSHA256")
        guard expectedBytes >= 0,
              expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw PommeAgentOperationError.invalid }
        guard let file = files.removeValue(forKey: id),
              let stage = file.stage,
              let destination = file.destination
        else { throw PommeAgentOperationError.notFound }

        var descriptorOpen = true
        var committed = false
        var preservePriorEntry = false
        defer {
            if descriptorOpen { _ = Darwin.close(file.descriptor) }
            if !committed {
                pendingFileCleanup[id] = .init(stage: stage, destination: destination, preservePriorEntry: preservePriorEntry)
                if !preservePriorEntry {
                    do {
                        try PommeAgentFileTransaction.removeAdjacentStage(stage, for: destination)
                        pendingFileCleanup.removeValue(forKey: id)
                        completedFileCleanup.insert(id)
                    } catch {
                        // Keep the exact cleanup record addressable by file.abort.
                    }
                }
            }
        }
        guard !file.tainted else { throw PommeAgentOperationError.invalid }
        var info = stat()
        guard fstat(file.descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size == off_t(expectedBytes),
              fsync(file.descriptor) == 0
        else { throw PommeAgentOperationError.io }
        let closeResult = Darwin.close(file.descriptor)
        descriptorOpen = false
        guard closeResult == 0 else { throw PommeAgentOperationError.io }
        let actualSHA256 = try mapFileTransactionError {
            try PommeAgentFileTransaction.sha256(stage)
        }
        guard actualSHA256 == expectedSHA256 else {
            throw PommeAgentOperationError.invalid
        }
        do {
            try mapFileTransactionError {
                try PommeAgentFileTransaction.commit(stage: stage, destination: destination)
            }
        } catch let error as PommeAgentFileTransaction.CommitError {
            preservePriorEntry = true
            throw error
        }
        committed = true
        return .object([
            "committed": .bool(true),
            "bytes": .integer(Int64(expectedBytes)),
            "sha256": .string(actualSHA256)
        ])
    }
    private func abortFile(_ payload: JSONValue) throws -> JSONValue {
        let id = try uuid(try object(payload), "fileID")
        if completedFileCleanup.remove(id) != nil { return .object(["aborted": .bool(true)]) }
        if let cleanup = pendingFileCleanup[id] {
            guard !cleanup.preservePriorEntry else {
                throw PommeAgentFileTransaction.CommitError.destinationPublishedCleanupFailed
            }
            try mapFileTransactionError {
                try PommeAgentFileTransaction.removeAdjacentStage(cleanup.stage, for: cleanup.destination)
            }
            pendingFileCleanup.removeValue(forKey: id)
            return .object(["aborted": .bool(true)])
        }
        guard let file = files[id], let stage = file.stage, let destination = file.destination else { throw PommeAgentOperationError.invalid }
        files.removeValue(forKey: id)
        let closeResult = Darwin.close(file.descriptor)
        pendingFileCleanup[id] = .init(stage: stage, destination: destination, preservePriorEntry: false)
        try mapFileTransactionError { try PommeAgentFileTransaction.removeAdjacentStage(stage, for: destination) }
        pendingFileCleanup.removeValue(forKey: id)
        guard closeResult == 0 else { throw PommeAgentOperationError.io }
        return .object(["aborted": .bool(true)])
    }
    private func remoteLogin(_ payload: JSONValue) throws -> JSONValue {
        let values = try object(payload); guard let enabled = bool(values["enabled"]) else { throw PommeAgentOperationError.invalid }
        let observed = try remoteLoginTransaction(enabled)
        guard observed == enabled else { throw PommeAgentOperationError.remoteLoginVerificationFailed }
        return .object(["enabled": .bool(observed)])
    }
    private func mdmEnrollment(_ payload: JSONValue) throws -> JSONValue {
        let values = try object(payload)
        switch try string(values, "action") {
        case "enroll":
            guard Set(values.keys) == ["action", "profilePath", "timeout"] else {
                throw PommeAgentOperationError.invalid
            }
            let execution = try GuestMDMEnrollment(
                requestTimeout: try timeout(values, "timeout")
            ).enroll(profilePath: try string(values, "profilePath"))
            let identifier = (execution.payload["profileIdentifier"] as? String) ?? ""
            return .object(["completed": .bool(execution.exitCode == 0), "profileIdentifier": .string(identifier)])
        case "approve":
            guard Set(values.keys) == ["action", "profileIdentifier", "timeout"] else {
                throw PommeAgentOperationError.invalid
            }
            let execution = try GuestMDMEnrollment(
                requestTimeout: try timeout(values, "timeout")
            ).markUserApproved(profileIdentifier: try string(values, "profileIdentifier"))
            return .object(["completed": .bool(execution.exitCode == 0)])
        default: throw PommeAgentOperationError.invalid
        }
    }

    private func mdmCleanup(_ payload: JSONValue) throws -> JSONValue {
        let values = try object(payload)
        guard Set(values.keys) == ["profilePath"] else {
            throw PommeAgentOperationError.invalid
        }
        return try GuestMDMEnrollment.cleanupStagedProfile(
            profilePath: try string(values, "profilePath")
        )
    }

    private func beginUpdate(_ payload: JSONValue) throws -> JSONValue {
        guard role == .persistent, update == nil else { throw PommeAgentOperationError.invalid }
        let values = try object(payload)
        let target = try string(values, "targetSHA256")
        let bytes = try integer(values, "targetBytes")
        let stagedPath = try string(values, "stagedExecutable")
        let staged = URL(fileURLWithPath: stagedPath).standardizedFileURL
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard staged.path.hasPrefix("/"), staged.deletingLastPathComponent() == executable.deletingLastPathComponent(), try PommeAgentFileTransaction.validatedRegularFile(staged) == UInt64(bytes) else { throw PommeAgentOperationError.invalid }
        let journal = try PommeAgentUpdateJournal(phase: .prepared, sourceSHA256: executableSHA256, targetSHA256: target, targetBytes: UInt64(bytes), stagedExecutable: staged.path)
        try PommeAgentJournalStore.write(journal, at: journalPath)
        update = journal; activationPending = true
        return .object(["transactionID": .string(journal.transactionID.uuidString.lowercased()), "accepted": .bool(true)])
    }
    private func commitUpdate(_ payload: JSONValue) throws -> JSONValue {
        guard let current = update, current.phase == .prepared else { throw PommeAgentOperationError.invalid }
        let values = try object(payload)
        guard try string(values, "transactionID") == current.transactionID.uuidString.lowercased(),
              try string(values, "targetSHA256") == current.targetSHA256 else { throw PommeAgentOperationError.invalid }
        let stagedURL = URL(fileURLWithPath: current.stagedExecutable)
        let executableURL = URL(fileURLWithPath: executablePath)
        guard try PommeAgentFileTransaction.validatedRegularFile(stagedURL) == current.targetBytes,
              try PommeAgentFileTransaction.sha256(stagedURL) == current.targetSHA256 else { throw PommeAgentOperationError.invalid }
        try PommeAgentFileTransaction.fsyncFile(stagedURL)
        let staged = try current.changing(.staged); try PommeAgentJournalStore.write(staged, at: journalPath)
        try PommeAgentFileTransaction.commit(stage: stagedURL, destination: executableURL)
        let pending = try staged.changing(.activationPending); try PommeAgentJournalStore.write(pending, at: journalPath)
        update = pending; activationPending = true
        return .object(["activationPending": .bool(true)])
    }
    private func finalizeUpdate(_ payload: JSONValue) throws -> JSONValue {
        guard let current = update, current.phase == .activationPending else { throw PommeAgentOperationError.invalid }
        let values = try object(payload)
        guard try string(values, "transactionID") == current.transactionID.uuidString.lowercased(),
              try string(values, "activatedSHA256") == current.targetSHA256,
              try PommeAgentFileTransaction.sha256(URL(fileURLWithPath: executablePath)) == current.targetSHA256 else { throw PommeAgentOperationError.invalid }
        let validated = try current.changing(.hostValidated); try PommeAgentJournalStore.write(validated, at: journalPath)
        try PommeAgentJournalStore.remove(at: journalPath)
        update = nil; activationPending = false
        return .object(["finalized": .bool(true)])
    }

    private func mapFileTransactionError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PommeAgentProtocol.Error where error == .invalidRequest {
            throw PommeAgentOperationError.invalid
        }
    }

    /// The daemon calls these for correlated JSONL stream frames.  PTY output
    /// is drained by the parent process, never by the forked child.
    func writePTY(jobID: UUID, data: Data) throws {
        guard role == .persistent else { throw PommeAgentOperationError.unsupported }
        guard data.count <= PommeAgentProtocol.maximumStreamChunkBytes, let job = jobs[jobID], let master = job.ptyMaster ?? job.stdin else { throw PommeAgentOperationError.invalid }
        let bytes = Array(data); var offset = 0
        while offset < bytes.count { let written = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress!.advanced(by: offset), $0.count - offset) }; guard written > 0 else { throw PommeAgentOperationError.io }; offset += written }
    }
    func resizePTY(jobID: UUID, columns: Int, rows: Int) throws {
        guard role == .persistent else { throw PommeAgentOperationError.unsupported }
        guard let job = jobs[jobID], let master = job.ptyMaster, columns > 0, rows > 0 else { throw PommeAgentOperationError.invalid }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(master, TIOCSWINSZ, &size) == 0 else { throw PommeAgentOperationError.io }
        _ = kill(-job.pid, SIGWINCH)
    }
    func drainPTY(jobID: UUID, requestID: UUID) throws -> [PommeAgentStreamFrame] {
        guard role == .persistent else { throw PommeAgentOperationError.unsupported }
        guard let job = jobs[jobID] else { throw PommeAgentOperationError.invalid }
        var output: [PommeAgentStreamFrame] = []
        if let terminal = job.ptyMaster { output += try drain(descriptor: terminal, stream: .stdout, requestID: requestID, isPTY: true, jobID: jobID) }
        if let stdout = job.stdout { output += try drain(descriptor: stdout, stream: .stdout, requestID: requestID, isPTY: false, jobID: jobID) }
        if let stderr = job.stderr { output += try drain(descriptor: stderr, stream: .stderr, requestID: requestID, isPTY: false, jobID: jobID) }
        return output
    }

    /// Drains repeated bounded reads for a logs or direct wait request. A
    /// completed child has no remaining writer, so continuing through empty
    /// reads records EOF and makes `outputComplete` reliable. A live writer
    /// stops at the byte or wall-clock budget and is retried by a later poll.
    private func captureAvailableOutput(jobID: UUID) throws -> [PommeAgentStreamFrame] {
        let deadline = ContinuousClock.now.advanced(by: Self.maximumJobCaptureDuration)
        var captured: [PommeAgentStreamFrame] = []
        var byteCount = 0
        while byteCount < Self.maximumJobCaptureBytes, ContinuousClock.now < deadline {
            let frames = try drainPTY(jobID: jobID, requestID: UUID())
            captured += frames
            let read = frames.reduce(0) { $0 + ($1.data?.count ?? 0) }
            byteCount += read
            if read == 0 { break }
        }
        return captured
    }

    private func drain(
        descriptor: Int32,
        stream: PommeAgentProtocol.Stream,
        requestID: UUID,
        isPTY: Bool,
        jobID: UUID
    ) throws -> [PommeAgentStreamFrame] {
        guard let job = jobs[jobID], !job.outputEOF.contains(descriptor) else { return [] }
        var readiness = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        var polled: Int32
        repeat { polled = poll(&readiness, 1, 0) } while polled < 0 && errno == EINTR
        guard polled > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: PommeAgentProtocol.maximumStreamChunkBytes)
        var count: Int
        repeat { count = Darwin.read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
        guard count > 0 else {
            if count == 0 || (count < 0 && isPTY && errno == EIO) {
                markOutputEOF(descriptor, jobID: jobID)
            }
            return []
        }
        // One read per descriptor is intentional. A normal exchange may
        // therefore contain at most one 64 KiB stdout and one 64 KiB stderr
        // frame, leaving room under the 256 KiB envelope limit.
        let data = Data(buffer.prefix(count))
        retainOutput(data, stream: stream, jobID: jobID)
        return [try .init(requestID: requestID, stream: stream, data: data)]
    }

    private func hasPendingOutput(_ job: Job) -> Bool {
        [job.ptyMaster, job.stdout, job.stderr]
            .compactMap { $0 }
            .filter { !job.outputEOF.contains($0) }
            .contains(where: descriptorHasReadableOutput)
    }

    private func outputIsDrained(_ job: Job) -> Bool {
        [job.ptyMaster, job.stdout, job.stderr]
            .compactMap { $0 }
            .allSatisfy { job.outputEOF.contains($0) }
    }

    private func markOutputEOF(_ descriptor: Int32, jobID: UUID) {
        guard var job = jobs[jobID] else { return }
        job.outputEOF.insert(descriptor)
        jobs[jobID] = job
    }

    private func retainOutput(_ data: Data, stream: PommeAgentProtocol.Stream, jobID: UUID) {
        guard var job = jobs[jobID], job.detached else { return }
        switch stream {
        case .stdout:
            job.stdoutBytes += Int64(data.count)
            let combined = job.stdoutLog + data
            if combined.count > Self.maximumRetainedJobLogBytes {
                job.stdoutLog = Data(combined.suffix(Self.maximumRetainedJobLogBytes))
                job.stdoutLogTruncated = true
            } else {
                job.stdoutLog = combined
            }
        case .stderr:
            job.stderrBytes += Int64(data.count)
            let combined = job.stderrLog + data
            if combined.count > Self.maximumRetainedJobLogBytes {
                job.stderrLog = Data(combined.suffix(Self.maximumRetainedJobLogBytes))
                job.stderrLogTruncated = true
            } else {
                job.stderrLog = combined
            }
        case .stdin, .eof, .resize, .signal, .exit:
            return
        }
        jobs[jobID] = job
    }

    private func descriptorHasReadableOutput(_ descriptor: Int32) -> Bool {
        var readiness = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        var polled: Int32
        repeat { polled = poll(&readiness, 1, 0) } while polled < 0 && errno == EINTR
        return polled > 0 && readiness.revents & Int16(POLLIN) != 0
    }
    func acceptStream(_ frame: PommeAgentStreamFrame, jobID: UUID) throws -> [PommeAgentStreamFrame] {
        guard role == .persistent else { throw PommeAgentOperationError.unsupported }
        switch frame.stream {
        case .stdin: try writePTY(jobID: jobID, data: frame.data ?? Data())
        case .resize: guard let dimensions = frame.dimensions else { throw PommeAgentOperationError.invalid }; try resizePTY(jobID: jobID, columns: dimensions.columns, rows: dimensions.rows)
        case .signal:
            guard let raw = frame.signal,
                  [Int32(SIGHUP), Int32(SIGINT), Int32(SIGTERM), Int32(SIGKILL)].contains(raw)
            else { throw PommeAgentOperationError.invalid }
            guard let job = jobs[jobID] else { throw PommeAgentOperationError.notFound }
            // Bytes written before a signal may already be readable from the
            // PTY master. Drain them before killing the process group so a
            // signal arriving immediately after launch cannot discard a
            // completed prompt or marker from the correlated exchange.
            let pending = try drainPTY(jobID: jobID, requestID: frame.requestID)
            let groupSignalled = kill(-job.pid, raw) == 0
            let processSignalled = kill(job.pid, raw) == 0
            guard groupSignalled || processSignalled else { throw PommeAgentOperationError.invalid }
            return pending + (try streamEvents(jobID: jobID, requestID: frame.requestID))
        case .eof:
            guard var job = jobs[jobID] else { throw PommeAgentOperationError.notFound }
            if job.ptyMaster != nil { try writePTY(jobID: jobID, data: Data([0x04])) }
            else if let stdin = job.stdin { _ = Darwin.close(stdin); job.stdin = nil; jobs[jobID] = job }
        case .stdout, .stderr, .exit: throw PommeAgentOperationError.invalid
        }
        return try streamEvents(jobID: jobID, requestID: frame.requestID)
    }
    func streamEvents(jobID: UUID, requestID: UUID) throws -> [PommeAgentStreamFrame] {
        guard role == .persistent else { throw PommeAgentOperationError.unsupported }
        _ = try refreshStatus(for: jobID)
        var frames = try drainPTY(jobID: jobID, requestID: requestID)
        // An exited child can still have bytes buffered in either pipe. Do
        // not publish the terminal frame until bounded nonblocking reads have
        // observed EOF on every output descriptor; POLLHUP remains readable
        // on Darwin after the final bytes are consumed.
        if let current = jobs[jobID], current.exited, outputIsDrained(current), let rawStatus = current.status {
            let terminal = terminalStatus(rawStatus)
            frames.append(try .init(requestID: requestID, stream: .exit, signal: terminal.signal))
        }
        return frames
    }

    /// Replays the bounded retained tail for a detached job. This is separate
    /// from `streamEvents`: a logs or wait request must be repeatable and must
    /// never consume the pipe data a later logs request needs.
    func retainedLogEvents(jobID: UUID, requestID: UUID) throws -> [PommeAgentStreamFrame] {
        guard role == .persistent else { throw PommeAgentOperationError.unsupported }
        guard let job = jobs[jobID] else { throw PommeAgentOperationError.notFound }
        guard job.detached else { throw PommeAgentOperationError.invalid }
        var frames: [PommeAgentStreamFrame] = []
        frames += try logFrames(data: job.stdoutLog, stream: .stdout, requestID: requestID)
        frames += try logFrames(data: job.stderrLog, stream: .stderr, requestID: requestID)
        if job.exited, outputIsDrained(job), let rawStatus = job.status {
            frames.append(try .init(requestID: requestID, stream: .exit, signal: terminalStatus(rawStatus).signal))
        }
        return frames
    }

    private func logFrames(
        data: Data,
        stream: PommeAgentProtocol.Stream,
        requestID: UUID
    ) throws -> [PommeAgentStreamFrame] {
        var frames: [PommeAgentStreamFrame] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + PommeAgentProtocol.maximumStreamChunkBytes, data.count)
            frames.append(try .init(requestID: requestID, stream: stream, data: Data(data[offset..<end])))
            offset = end
        }
        return frames
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] { guard let object = value.objectValue else { throw PommeAgentOperationError.invalid }; return object }
    private func string(_ object: [String: JSONValue], _ key: String) throws -> String { guard let value = object[key]?.stringValue, !value.isEmpty else { throw PommeAgentOperationError.invalid }; return value }
    private func strings(_ value: JSONValue?) throws -> [String] { guard let values = value?.arrayValue else { throw PommeAgentOperationError.invalid }; return try values.map { guard let value = $0.stringValue, !value.contains("\0") else { throw PommeAgentOperationError.invalid }; return value } }
    private func integer(_ object: [String: JSONValue], _ key: String) throws -> Int { if case .integer(let value) = object[key], let result = Int(exactly: value) { return result }; throw PommeAgentOperationError.invalid }
    private func timeout(_ object: [String: JSONValue], _ key: String) throws -> TimeInterval {
        let value: TimeInterval
        switch object[key] {
        case .integer(let integer): value = TimeInterval(integer)
        case .number(let number): value = number
        default: throw PommeAgentOperationError.invalid
        }
        guard value.isFinite, value >= 1, value <= 300 else {
            throw PommeAgentOperationError.invalid
        }
        return value
    }
    private func bool(_ value: JSONValue?) -> Bool? { if case .bool(let value) = value { return value }; return nil }
    private func strictBoolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard case .bool(let result) = value else { throw PommeAgentOperationError.invalid }
        return result
    }
    private func uuid(_ object: [String: JSONValue], _ key: String) throws -> UUID { guard let value = object[key]?.stringValue, let uuid = UUID(uuidString: value) else { throw PommeAgentOperationError.invalid }; return uuid }
    private func jobID(_ value: JSONValue) throws -> UUID { try uuid(try object(value), "jobID") }
    private func detachedJobID(_ value: JSONValue, keys: Set<String>) throws -> UUID {
        let values = try object(value)
        guard Set(values.keys) == keys else { throw PommeAgentOperationError.invalid }
        let id = try uuid(values, "jobID")
        guard let job = jobs[id] else { throw PommeAgentOperationError.notFound }
        guard job.detached else { throw PommeAgentOperationError.invalid }
        return id
    }
    private func file(_ object: [String: JSONValue]) throws -> OpenFile { let id = try uuid(object, "fileID"); guard let file = files[id] else { throw PommeAgentOperationError.notFound }; return file }

    private static func writeChunk(_ descriptor: Int32, _ data: Data, _ offset: Int) -> Int {
        data.withUnsafeBytes { bytes in Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset) }
    }
}

enum PommeAgentOperationError: Error, Equatable {
    case unsupported, activationPending, invalid, notFound, io
    case remoteLoginFullDiskAccessRequired, remoteLoginVerificationFailed
}

/// Remote Login's public status is `systemsetup -getremotelogin`; mutations
/// use that same setting and verify its observed value before reporting success.
enum PommeRemoteLogin {
    struct CommandOutput: Equatable, Sendable {
        let stdout: String
        let stderr: String
    }

    static let commandTimeout: TimeInterval = 15
    static let maximumOutputBytes = 64 * 1024

    static func apply(enabled: Bool) throws -> Bool {
        try apply(enabled: enabled, run: runSystemSetup)
    }

    static func apply(
        enabled: Bool,
        run: ([String]) throws -> CommandOutput
    ) throws -> Bool {
        try rejectFullDiskAccessDenial(in: run(["-f", "-setremotelogin", enabled ? "on" : "off"]))
        let observed = try state(from: run(["-getremotelogin"]))
        guard observed == enabled else { throw PommeAgentOperationError.remoteLoginVerificationFailed }
        return observed
    }

    static func state(from output: CommandOutput) throws -> Bool {
        try rejectFullDiskAccessDenial(in: output)
        guard output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PommeAgentOperationError.remoteLoginVerificationFailed
        }
        switch output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Remote Login: On": return true
        case "Remote Login: Off": return false
        default: throw PommeAgentOperationError.remoteLoginVerificationFailed
        }
    }

    private static func rejectFullDiskAccessDenial(in output: CommandOutput) throws {
        guard !output.stdout.localizedCaseInsensitiveContains("full disk access"),
              !output.stderr.localizedCaseInsensitiveContains("full disk access")
        else { throw PommeAgentOperationError.remoteLoginFullDiskAccessRequired }
    }

    private static func runSystemSetup(arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/systemsetup")
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        do { try process.run() } catch { throw PommeAgentOperationError.io }

        let stdoutDescriptor = standardOutput.fileHandleForReading.fileDescriptor
        let stderrDescriptor = standardError.fileHandleForReading.fileDescriptor
        guard makeNonBlocking(stdoutDescriptor), makeNonBlocking(stderrDescriptor) else {
            guard terminateAndReap(process) else { throw PommeAgentOperationError.io }
            throw PommeAgentOperationError.io
        }

        var stdout = Data()
        var stderr = Data()
        var stdoutEOF = false
        var stderrEOF = false
        let deadline = ProcessInfo.processInfo.systemUptime + commandTimeout
        while process.isRunning || !stdoutEOF || !stderrEOF {
            let stdoutOverflow = drain(
                stdoutDescriptor, into: &stdout, eof: &stdoutEOF, maximumBytes: maximumOutputBytes
            )
            let stderrOverflow = drain(
                stderrDescriptor, into: &stderr, eof: &stderrEOF, maximumBytes: maximumOutputBytes
            )
            if stdoutOverflow || stderrOverflow || ProcessInfo.processInfo.systemUptime >= deadline {
                guard terminateAndReap(process) else { throw PommeAgentOperationError.io }
                throw PommeAgentOperationError.io
            }
            if !process.isRunning && stdoutEOF && stderrEOF { break }
            usleep(10_000)
        }
        process.waitUntilExit()
        guard let stdoutText = String(data: stdout, encoding: .utf8),
              let stderrText = String(data: stderr, encoding: .utf8)
        else { throw PommeAgentOperationError.io }
        let captured = CommandOutput(stdout: stdoutText, stderr: stderrText)
        try rejectFullDiskAccessDenial(in: captured)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PommeAgentOperationError.io
        }
        return captured
    }

    private static func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func drain(
        _ descriptor: Int32,
        into data: inout Data,
        eof: inout Bool,
        maximumBytes: Int
    ) -> Bool {
        guard !eof else { return false }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let available = maximumBytes - data.count
                guard available >= count else { return true }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                eof = true
                return false
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                return true
            }
        }
    }

    private static func terminateAndReap(_ process: Process) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }
        process.terminate()
        let gracefulDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < gracefulDeadline {
            usleep(10_000)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            guard pid > 0, Darwin.kill(pid, SIGKILL) == 0 else { return false }
            let forcedDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < forcedDeadline {
                usleep(10_000)
            }
        }
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        return true
    }
}

struct PommePrivilege: Sendable {
    let account: String
    let uid: uid_t
    let gid: gid_t
    let supplementary: [gid_t]

    static func resolve(_ object: [String: JSONValue]) throws -> PommePrivilege? {
        let user = object["user"]?.stringValue; let uid = object["uid"]
        let group = object["group"]?.stringValue; let gid = object["gid"]
        guard !(user != nil && uid != nil), !(group != nil && gid != nil) else { throw PommeAgentOperationError.invalid }
        guard user != nil || uid != nil || group != nil || gid != nil else { return nil }
        let record: UnsafeMutablePointer<passwd>?
        if let user { record = getpwnam(user) }
        else if case .integer(let supplied) = uid, let parsed = uid_t(exactly: supplied) { record = getpwuid(parsed) }
        else if uid == nil { record = getpwuid(geteuid()) }
        else { record = nil }
        guard let record, let account = String(validatingCString: record.pointee.pw_name) else { throw PommeAgentOperationError.invalid }
        let resolvedUID = record.pointee.pw_uid
        let resolvedGID: gid_t
        if let group {
            guard let groupRecord = getgrnam(group) else { throw PommeAgentOperationError.invalid }
            resolvedGID = groupRecord.pointee.gr_gid
        } else if let gid {
            guard case .integer(let supplied) = gid, let parsed = gid_t(exactly: supplied) else {
                throw PommeAgentOperationError.invalid
            }
            resolvedGID = parsed
        } else {
            resolvedGID = record.pointee.pw_gid
        }
        let baseGroup = Int32(bitPattern: resolvedGID)
        // Darwin can report a zero count for a nil root buffer and does not
        // reliably grow a short buffer. Query once with the protocol's hard
        // 1,024-group ceiling and reject an account that exceeds it.
        var count: Int32 = 1_024
        var rawGroups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(account, baseGroup, &rawGroups, &count) >= 0,
              count > 0, count <= 1_024
        else { throw PommeAgentOperationError.invalid }
        let groups = rawGroups.prefix(Int(count)).map { value -> gid_t in
            gid_t(bitPattern: value)
        }
        return .init(account: account, uid: resolvedUID, gid: resolvedGID, supplementary: groups)
    }
}

enum PommeProcess {
    /// Process settings received through the authenticated request.  The
    /// agent validates them again here because the daemon accepts protocol
    /// envelopes directly, without passing through the CLI model layer.
    struct Options: Sendable {
        let cwd: String?
        let environment: [String: String]
        let stdinPath: String?
        let stdoutPath: String?
        let stderrPath: String?
        /// Echo is disabled unless an authenticated public-terminal caller
        /// explicitly opts in. Private PTYs must never inherit echo.
        let ptyEcho: Bool

        init(
            cwd: String? = nil,
            environment: [String: String] = [:],
            stdinPath: String? = nil,
            stdoutPath: String? = nil,
            stderrPath: String? = nil,
            ptyEcho: Bool = false
        ) {
            self.cwd = cwd
            self.environment = environment
            self.stdinPath = stdinPath
            self.stdoutPath = stdoutPath
            self.stderrPath = stderrPath
            self.ptyEcho = ptyEcho
        }

        init(payload: [String: JSONValue], pty: Bool) throws {
            let allowed: Set<String> = [
                "path", "arguments", "timeout", "stdinDataBase64", "attachStdin",
                "pty", "cwd", "environment", "user", "uid", "group", "gid",
                "stdinPath", "stdoutPath", "stderrPath", "detached", "ptyEcho"
            ]
            guard Set(payload.keys).isSubset(of: allowed) else {
                throw PommeAgentOperationError.invalid
            }
            let cwd = try Self.path(payload["cwd"])
            let stdinPath = try Self.path(payload["stdinPath"])
            let stdoutPath = try Self.path(payload["stdoutPath"])
            let stderrPath = try Self.path(payload["stderrPath"])
            let attachedStdin = try Self.boolean(payload["attachStdin"])
            let ptyEcho = try Self.boolean(payload["ptyEcho"])
            guard !(attachedStdin && stdinPath != nil),
                  !(pty && (stdinPath != nil || stdoutPath != nil || stderrPath != nil)),
                  !ptyEcho || pty
            else {
                throw PommeAgentOperationError.invalid
            }
            self.init(
                cwd: cwd,
                environment: try Self.environment(payload["environment"]),
                stdinPath: stdinPath,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath,
                ptyEcho: ptyEcho
            )
        }

        fileprivate func mergedEnvironment() throws -> [String: String] {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            try Self.validateEnvironment(merged)
            return merged
        }

        fileprivate static func validateEnvironment(_ environment: [String: String]) throws {
            guard environment.count <= 1_024 else { throw PommeAgentOperationError.invalid }
            for (key, value) in environment {
                guard !key.isEmpty,
                      key.utf8.count <= 256,
                      value.utf8.count <= 64 * 1_024,
                      !key.contains("\0"),
                      !value.contains("\0"),
                      key.first?.isASCII == true,
                      key.first?.isLetter == true || key.first == "_",
                      key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                else {
                    throw PommeAgentOperationError.invalid
                }
            }
        }

        private static func path(_ value: JSONValue?) throws -> String? {
            guard let value else { return nil }
            guard let path = value.stringValue,
                  !path.isEmpty,
                  path.utf8.count <= 4 * 1_024,
                  path.hasPrefix("/"),
                  !path.contains("\0"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            else {
                throw PommeAgentOperationError.invalid
            }
            return path
        }

        private static func environment(_ value: JSONValue?) throws -> [String: String] {
            guard let value else { return [:] }
            guard let object = value.objectValue else { throw PommeAgentOperationError.invalid }
            var result: [String: String] = [:]
            for (key, value) in object {
                guard let text = value.stringValue else { throw PommeAgentOperationError.invalid }
                result[key] = text
            }
            try validateEnvironment(result)
            return result
        }

        private static func boolean(_ value: JSONValue?) throws -> Bool {
            guard let value else { return false }
            guard case .bool(let result) = value else { throw PommeAgentOperationError.invalid }
            return result
        }
    }

    struct Spawned: Sendable {
        let pid: Int32
        let ptyMaster: Int32?
        let stdin: Int32?
        let stdout: Int32?
        let stderr: Int32?
        let ptyEchoDisabled: Bool
    }

    private static let helperStatusDescriptor: Int32 = 3
    private static let helperEnvironmentDescriptor: Int32 = 4
    private static let helperSuccessMarker: UInt8 = 0x7f

    static func spawn(
        path: String,
        arguments: [String],
        identity: PommePrivilege?,
        pty: Bool,
        options: Options = .init()
    ) throws -> Spawned {
        guard path.hasPrefix("/"),
              path.utf8.count <= 4 * 1_024,
              !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              arguments.count <= 1_024,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64 * 1_024 })
        else {
            throw PommeAgentOperationError.invalid
        }
        let environment = try options.mergedEnvironment()
        let usesIdentityHelper = try identity.map(requiresIdentityHelper) ?? false
        if usesIdentityHelper, geteuid() != 0 {
            throw PommeAgentOperationError.invalid
        }
        var master: Int32 = -1; var slave: Int32 = -1
        var stdinPipe: [Int32] = [-1, -1]; var stdoutPipe: [Int32] = [-1, -1]; var stderrPipe: [Int32] = [-1, -1]
        if pty {
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw PommeAgentOperationError.io }
            // Establish the requested echo policy before the child opens the
            // slave. Private PTYs may carry credentials, so their default is
            // fail-closed no-echo; public callers must explicitly opt in.
            var attributes = termios()
            guard tcgetattr(slave, &attributes) == 0 else {
                _ = Darwin.close(master); _ = Darwin.close(slave)
                throw PommeAgentOperationError.io
            }
            if options.ptyEcho {
                attributes.c_lflag |= tcflag_t(ECHO | ECHONL)
            } else {
                attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            }
            guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
                _ = Darwin.close(master); _ = Darwin.close(slave)
                throw PommeAgentOperationError.io
            }
        } else {
            guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
                [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
                throw PommeAgentOperationError.io
            }
        }

        var helperStatusPipe: [Int32] = [-1, -1]
        var helperEnvironmentPipe: [Int32] = [-1, -1]
        if usesIdentityHelper {
            var noSigPipe: Int32 = 1
            guard pipe(&helperStatusPipe) == 0,
                  socketpair(AF_UNIX, SOCK_STREAM, 0, &helperEnvironmentPipe) == 0,
                  setsockopt(helperEnvironmentPipe[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
                [helperStatusPipe, helperEnvironmentPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
                throw PommeAgentOperationError.io
            }
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            if actions != nil { _ = posix_spawn_file_actions_destroy(&actions) }
            closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
            [helperStatusPipe, helperEnvironmentPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            throw PommeAgentOperationError.io
        }
        defer {
            _ = posix_spawn_file_actions_destroy(&actions)
            _ = posix_spawnattr_destroy(&attributes)
        }

        var actionResults: [Int32] = []
        if pty {
            guard let terminalName = ttyname(slave) else {
                closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
                [helperStatusPipe, helperEnvironmentPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
                throw PommeAgentOperationError.io
            }
            actionResults += [
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, terminalName, O_RDWR, 0),
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO),
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
            ]
        } else {
            if let stdinPath = options.stdinPath, !usesIdentityHelper {
                actionResults.append(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, stdinPath, O_RDONLY, 0))
            } else {
                actionResults += [
                    posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO),
                    posix_spawn_file_actions_addclose(&actions, stdinPipe[1])
                ]
            }
            if let stdoutPath = options.stdoutPath, !usesIdentityHelper {
                actionResults.append(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdoutPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
            } else {
                actionResults += [
                    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
                    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
                ]
            }
            if let stderrPath = options.stderrPath, !usesIdentityHelper {
                actionResults.append(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
            } else {
                actionResults += [
                    posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
                    posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
                ]
            }
        }
        if let cwd = options.cwd, !usesIdentityHelper {
            if #available(macOS 26, *) {
                actionResults.append(cwd.withCString { posix_spawn_file_actions_addchdir(&actions, $0) })
            } else {
                actionResults.append(cwd.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) })
            }
        }
        if usesIdentityHelper {
            actionResults += [
                posix_spawn_file_actions_adddup2(&actions, helperStatusPipe[1], helperStatusDescriptor),
                posix_spawn_file_actions_adddup2(&actions, helperEnvironmentPipe[0], helperEnvironmentDescriptor),
                posix_spawn_file_actions_addclose(&actions, helperStatusPipe[0]),
                posix_spawn_file_actions_addclose(&actions, helperEnvironmentPipe[1])
            ]
            if helperStatusPipe[1] != helperStatusDescriptor {
                actionResults.append(posix_spawn_file_actions_addclose(&actions, helperStatusPipe[1]))
            }
            if helperEnvironmentPipe[0] != helperEnvironmentDescriptor {
                actionResults.append(posix_spawn_file_actions_addclose(&actions, helperEnvironmentPipe[0]))
            }
        }
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
            [helperStatusPipe, helperEnvironmentPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            throw PommeAgentOperationError.io
        }

        do {
            try configureSpawnAttributes(&attributes, pty: pty)
        } catch {
            closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
            [helperStatusPipe, helperEnvironmentPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            throw PommeAgentOperationError.io
        }

        let launchPath = usesIdentityHelper ? PommeAgentInstall.executable : path
        let launchArguments = try helperArguments(
            path: path,
            arguments: arguments,
            identity: identity,
            options: options,
            usesIdentityHelper: usesIdentityHelper
        )

        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.dropLast().forEach { free($0) } }
        var environmentPointers: [UnsafeMutablePointer<CChar>?]
        if usesIdentityHelper {
            // No caller-controlled value can affect the signed helper before
            // it has dropped credentials. The requested environment travels
            // over its dedicated inherited descriptor instead.
            environmentPointers = [nil]
        } else {
            environmentPointers = try makeEnvironmentPointers(environment)
        }
        defer { environmentPointers.dropLast().forEach { free($0) } }
        var pid: pid_t = 0
        let spawnStatus = launchPath.withCString { executable in
            posix_spawn(&pid, executable, &actions, &attributes, &argv, &environmentPointers)
        }
        guard spawnStatus == 0, pid > 0 else {
            closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
            [helperStatusPipe, helperEnvironmentPipe].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            throw PommeAgentOperationError.io
        }
        if usesIdentityHelper {
            _ = Darwin.close(helperStatusPipe[1])
            _ = Darwin.close(helperEnvironmentPipe[0])
            do {
                let environmentData = try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
                guard environmentData.count <= PommeAgentProtocol.maximumFrameBytes else {
                    throw PommeAgentOperationError.invalid
                }
                try writeAll(environmentData, to: helperEnvironmentPipe[1])
                _ = Darwin.close(helperEnvironmentPipe[1])
                helperEnvironmentPipe[1] = -1
                guard try helperSucceeded(statusDescriptor: helperStatusPipe[0]) else {
                    throw PommeAgentOperationError.io
                }
                _ = Darwin.close(helperStatusPipe[0])
                helperStatusPipe[0] = -1
            } catch {
                _ = Darwin.close(helperStatusPipe[0])
                _ = Darwin.close(helperEnvironmentPipe[1])
                _ = kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
                closeDescriptors(master: master, slave: slave, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe, pty: pty)
                throw error
            }
        }
        if pty {
            _ = Darwin.close(slave)
            _ = fcntl(master, F_SETFL, O_NONBLOCK)
            return .init(
                pid: pid,
                ptyMaster: master,
                stdin: nil,
                stdout: nil,
                stderr: nil,
                ptyEchoDisabled: !options.ptyEcho
            )
        }
        [stdinPipe[0], stdoutPipe[1], stderrPipe[1]].filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
        [stdinPipe[1], stdoutPipe[0], stderrPipe[0]].filter { $0 >= 0 }.forEach { _ = fcntl($0, F_SETFL, O_NONBLOCK) }
        return .init(
            pid: pid,
            ptyMaster: nil,
            stdin: stdinPipe[1],
            stdout: stdoutPipe[0],
            stderr: stderrPipe[0],
            ptyEchoDisabled: false
        )
    }

    /// Makes every executed command interruptible even when the launchd
    /// daemon inherited an ignored or blocked SIGINT disposition. This is
    /// applied through posix_spawn attributes, never in a post-fork path.
    static func configureSpawnAttributes(
        _ attributes: inout posix_spawnattr_t?,
        pty: Bool
    ) throws {
        var defaults = sigset_t()
        var mask = sigset_t()
        guard sigemptyset(&defaults) == 0,
              sigaddset(&defaults, SIGINT) == 0,
              sigemptyset(&mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0
        else {
            throw PommeAgentOperationError.io
        }
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            | Int16(pty ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP)
            | Int16(POSIX_SPAWN_SETSIGDEF)
            | Int16(POSIX_SPAWN_SETSIGMASK)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              (pty || posix_spawnattr_setpgroup(&attributes, 0) == 0)
        else {
            throw PommeAgentOperationError.io
        }
    }

    /// Runs in the already-execed, signed Pomme executable.  This is never a
    /// post-fork Swift path: the root agent starts it with posix_spawn, then
    /// it establishes the requested target identity and execs the command.
    static func runIdentityHelper(arguments: [String]) -> Int32 {
        do {
            let request = try IdentityHelperRequest(arguments: arguments)
            let environmentData = try readAll(from: helperEnvironmentDescriptor, maximumBytes: PommeAgentProtocol.maximumFrameBytes)
            guard Darwin.close(helperEnvironmentDescriptor) == 0 else {
                throw PommeAgentOperationError.io
            }
            guard let object = try JSONSerialization.jsonObject(with: environmentData) as? [String: String] else {
                throw PommeAgentOperationError.invalid
            }
            try Options.validateEnvironment(object)
            let initialGroup = Int32(bitPattern: request.identity.gid)
            guard geteuid() == 0,
                  request.identity.account.withCString({ initgroups($0, initialGroup) }) == 0,
                  setgid(request.identity.gid) == 0,
                  setuid(request.identity.uid) == 0
            else {
                throw PommeAgentOperationError.invalid
            }
            if let cwd = request.cwd, chdir(cwd) != 0 { throw PommeAgentOperationError.io }
            try redirect(request.stdinPath, descriptor: STDIN_FILENO, flags: O_RDONLY)
            try redirect(request.stdoutPath, descriptor: STDOUT_FILENO, flags: O_WRONLY | O_CREAT | O_TRUNC)
            try redirect(request.stderrPath, descriptor: STDERR_FILENO, flags: O_WRONLY | O_CREAT | O_TRUNC)
            for (key, value) in object {
                guard setenv(key, value, 1) == 0 else { throw PommeAgentOperationError.io }
            }
            guard fcntl(helperStatusDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw PommeAgentOperationError.io
            }
            try writeStatusMarker(helperSuccessMarker)
            var argv = ([request.path] + request.arguments).map { strdup($0) }
            argv.append(nil)
            defer { argv.dropLast().forEach { free($0) } }
            _ = request.path.withCString { executable in
                execv(executable, &argv)
            }
            throw PommeAgentOperationError.io
        } catch {
            var failure: UInt8 = 1
            _ = withUnsafePointer(to: &failure) { Darwin.write(helperStatusDescriptor, $0, 1) }
            return 64
        }
    }

    private struct IdentityHelperRequest {
        let identity: PommePrivilege
        let cwd: String?
        let stdinPath: String?
        let stdoutPath: String?
        let stderrPath: String?
        let path: String
        let arguments: [String]

        init(arguments: [String]) throws {
            guard arguments.first == "--pomme-exec-helper" else { throw PommeAgentOperationError.invalid }
            var values: [String: String] = [:]
            var index = 1
            while index < arguments.count, arguments[index] != "--" {
                let flag = arguments[index]
                guard ["--uid", "--gid", "--account", "--cwd", "--stdin-path", "--stdout-path", "--stderr-path"].contains(flag),
                      index + 1 < arguments.count,
                      values[flag] == nil
                else {
                    throw PommeAgentOperationError.invalid
                }
                values[flag] = arguments[index + 1]
                index += 2
            }
            guard index < arguments.count - 1,
                  let uidText = values["--uid"], let uid = uid_t(uidText),
                  let gidText = values["--gid"], let gid = gid_t(gidText),
                  let account = values["--account"],
                  !account.isEmpty,
                  account.utf8.count <= 256,
                  !account.contains("\0")
            else {
                throw PommeAgentOperationError.invalid
            }
            let options = try Options(
                cwd: Self.path(values["--cwd"]),
                environment: [:],
                stdinPath: Self.path(values["--stdin-path"]),
                stdoutPath: Self.path(values["--stdout-path"]),
                stderrPath: Self.path(values["--stderr-path"])
            )
            let target = arguments[index + 1]
            guard target.hasPrefix("/"), !target.contains("\0"), arguments.dropFirst(index + 2).allSatisfy({ !$0.contains("\0") }) else {
                throw PommeAgentOperationError.invalid
            }
            identity = .init(account: account, uid: uid, gid: gid, supplementary: [])
            cwd = options.cwd
            stdinPath = options.stdinPath
            stdoutPath = options.stdoutPath
            stderrPath = options.stderrPath
            path = target
            self.arguments = Array(arguments.dropFirst(index + 2))
        }

        private static func path(_ value: String?) throws -> String? {
            guard let value else { return nil }
            return try Options(payload: ["cwd": .string(value)], pty: false).cwd
        }
    }

    private static func helperArguments(
        path: String,
        arguments: [String],
        identity: PommePrivilege?,
        options: Options,
        usesIdentityHelper: Bool
    ) throws -> [String] {
        guard usesIdentityHelper, let identity else { return arguments }
        var result = [
            "--pomme-exec-helper", "--uid", String(identity.uid),
            "--gid", String(identity.gid),
            "--account", identity.account
        ]
        if let cwd = options.cwd { result += ["--cwd", cwd] }
        if let stdinPath = options.stdinPath { result += ["--stdin-path", stdinPath] }
        if let stdoutPath = options.stdoutPath { result += ["--stdout-path", stdoutPath] }
        if let stderrPath = options.stderrPath { result += ["--stderr-path", stderrPath] }
        return result + ["--", path] + arguments
    }

    private static func requiresIdentityHelper(_ identity: PommePrivilege) throws -> Bool {
        guard identity.uid == geteuid(), identity.gid == getegid() else { return true }
        let count = getgroups(0, nil)
        guard count >= 0, count <= 1_024 else { throw PommeAgentOperationError.io }
        guard count > 0 else { return !identity.supplementary.isEmpty }
        var rawGroups = [Int32](repeating: 0, count: Int(count))
        let populated = getgroups(count, &rawGroups)
        guard populated >= 0, populated <= count else { throw PommeAgentOperationError.io }
        let current = Set(rawGroups.prefix(Int(populated)).map { gid_t(bitPattern: $0) })
        return current != Set(identity.supplementary)
    }

    private static func makeEnvironmentPointers(_ environment: [String: String]) throws -> [UnsafeMutablePointer<CChar>?] {
        try Options.validateEnvironment(environment)
        var result = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") }
        guard !result.contains(where: { $0 == nil }) else {
            result.forEach { free($0) }
            throw PommeAgentOperationError.io
        }
        result.append(nil)
        return result
    }

    private static func closeDescriptors(
        master: Int32,
        slave: Int32,
        stdin: [Int32],
        stdout: [Int32],
        stderr: [Int32],
        pty: Bool
    ) {
        if pty {
            _ = Darwin.close(master)
            _ = Darwin.close(slave)
        } else {
            [stdin, stdout, stderr].flatMap { $0 }.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if result > 0 { offset += result }
                else if result < 0, errno == EINTR { continue }
                else { throw PommeAgentOperationError.io }
            }
        }
    }

    static func helperSucceeded(statusDescriptor: Int32, successMarker: UInt8 = helperSuccessMarker) throws -> Bool {
        var sawSuccess = false
        var result: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &result) { Darwin.read(statusDescriptor, $0, 1) }
            if count == 0 { return sawSuccess }
            if count > 0 {
                guard !sawSuccess, result == successMarker else { return false }
                sawSuccess = true
                continue
            }
            if errno == EINTR { continue }
            throw PommeAgentOperationError.io
        }
    }

    private static func writeStatusMarker(_ marker: UInt8) throws {
        var marker = marker
        while true {
            let count = withUnsafePointer(to: &marker) { Darwin.write(helperStatusDescriptor, $0, 1) }
            if count == 1 { return }
            if count < 0, errno == EINTR { continue }
            throw PommeAgentOperationError.io
        }
    }

    private static func readAll(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                guard data.count <= maximumBytes else { throw PommeAgentOperationError.invalid }
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw PommeAgentOperationError.io
            }
        }
    }

    private static func redirect(_ path: String?, descriptor: Int32, flags: Int32) throws {
        guard let path else { return }
        let opened = path.withCString { Darwin.open($0, flags, mode_t(0o600)) }
        guard opened >= 0 else { throw PommeAgentOperationError.io }
        defer {
            if opened != descriptor { _ = Darwin.close(opened) }
        }
        guard opened == descriptor || dup2(opened, descriptor) >= 0 else {
            throw PommeAgentOperationError.io
        }
    }
}
