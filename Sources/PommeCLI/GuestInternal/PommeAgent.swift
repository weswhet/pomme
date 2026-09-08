import Darwin
import Foundation

enum PommeAgentRole: String, Sendable { case persistent, recovery }

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
    static let recoveryCapabilities = [
        "agent.install",
        "sip.status", "sip.disable", "sip.enable",
        "amfi.status", "amfi.disable", "amfi.enable"
    ]
    static let persistentCapabilities = ["agent.describe", "agent.health", "process.start", "process.status", "process.signal", "file.open", "file.read", "file.write", "file.seek", "file.flush", "file.close", "file.commit", "file.abort", "system.info", "network.interfaces", "remoteLogin.set", "mdm.staging.prepare", "mdm.enrollment", "mdm.staging.cleanup", "maintenance", "maintenance.update.begin", "maintenance.update.commit", "maintenance.update.finalize"] + normalAMFIOperations
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
    private let remoteLoginTransaction: @Sendable (Bool) throws -> Void
    private let writeChunk: @Sendable (Int32, Data, Int) -> Int
    private let recoveryInstaller: PommeAgentRecoveryInstaller?
    private let recoverySecurity: PommeGuestRecoverySecurityOperations

    init(role: PommeAgentRole, executableSHA256: String, journalPath: String = PommeAgentInstall.journal,
         executablePath: String = PommeAgentInstall.executable,
         remoteLoginTransaction: @escaping @Sendable (Bool) throws -> Void = PommeRemoteLogin.apply,
         writeChunk: @escaping @Sendable (Int32, Data, Int) -> Int = PommeAgent.writeChunk,
         recoveryInstaller: PommeAgentRecoveryInstaller? = nil,
         recoverySecurity: PommeGuestRecoverySecurityOperations = .init(),
         recoveredJournal: PommeAgentUpdateJournal? = nil) throws {
        guard executableSHA256.count == 64, executableSHA256.allSatisfy(\.isHexDigit) else {
            throw PommeAgentProtocol.Error.invalidRequest
        }
        self.role = role; self.executableSHA256 = executableSHA256.lowercased(); self.journalPath = journalPath; self.executablePath = executablePath; self.remoteLoginTransaction = remoteLoginTransaction; self.writeChunk = writeChunk
        self.recoveryInstaller = role == .recovery ? (recoveryInstaller ?? PommeAgentRecoveryInstaller()) : nil
        self.recoverySecurity = recoverySecurity
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
        if role == .recovery {
            switch request.operation {
            case "agent.describe":
                return .object([
                    "role": .string(role.rawValue), "protocol": .string(PommeAgentProtocol.name),
                    "version": .integer(Int64(PommeAgentProtocol.version)), "executableSHA256": .string(executableSHA256),
                    "capabilities": .array(Self.recoveryCapabilities.map(JSONValue.string))
                ])
            case "agent.health":
                return .object(["ok": .bool(true), "activationPending": .bool(false)])
            case "agent.install":
                guard let recoveryInstaller else { throw PommeAgentOperationError.invalid }
                return try recoveryInstaller.install(payload: request.payload, requestID: request.requestID)
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
            if request.payload.objectValue?["includeNormalAMFICapabilities"] == .bool(true) {
                description["normalAMFIWorkflowVersion"] = .integer(Int64(Self.normalAMFIWorkflowVersion))
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
        case "process.start": return try start(request.payload)
        case "process.status": return try status(request.payload)
        case "process.signal": return try signal(request.payload)
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

    private func start(_ payload: JSONValue) throws -> JSONValue {
        let object = try object(payload)
        let path = try string(object, "path")
        let arguments = try strings(object["arguments"])
        let identity = try PommePrivilege.resolve(object)
        let pty = bool(object["pty"]) ?? false
        guard !(pty && bool(object["detached"]) == true) else { throw PommeAgentOperationError.invalid }
        let detached = bool(object["detached"]) ?? false
        let launched = try PommeProcess.spawn(path: path, arguments: arguments, identity: identity, pty: pty)
        let job = Job(id: UUID(), pid: launched.pid, startedAt: Date(), exited: false, status: nil, ptyMaster: launched.ptyMaster, stdin: launched.stdin, stdout: launched.stdout, stderr: launched.stderr, outputEOF: [], detached: detached)
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
        let outputPending = hasPendingOutput(job)
        var result: [String: JSONValue] = [
            "jobID": .string(id.uuidString.lowercased()),
            "pid": .integer(Int64(job.pid)),
            "exited": .bool(job.exited),
            "outputPending": .bool(outputPending)
        ]
        if let rawStatus = job.status {
            let terminal = terminalStatus(rawStatus)
            if let exitCode = terminal.exitCode { result["exitCode"] = .integer(Int64(exitCode)) }
            if let signal = terminal.signal { result["signal"] = .integer(Int64(signal)) }
        }
        return .object(result)
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
        try remoteLoginTransaction(enabled)
        return .object(["enabled": .bool(enabled)])
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
        return [try .init(requestID: requestID, stream: stream, data: Data(buffer.prefix(count)))]
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
            let groupSignalled = kill(-job.pid, raw) == 0
            let processSignalled = kill(job.pid, raw) == 0
            guard groupSignalled || processSignalled else { throw PommeAgentOperationError.invalid }
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
    private func uuid(_ object: [String: JSONValue], _ key: String) throws -> UUID { guard let value = object[key]?.stringValue, let uuid = UUID(uuidString: value) else { throw PommeAgentOperationError.invalid }; return uuid }
    private func jobID(_ value: JSONValue) throws -> UUID { try uuid(try object(value), "jobID") }
    private func file(_ object: [String: JSONValue]) throws -> OpenFile { let id = try uuid(object, "fileID"); guard let file = files[id] else { throw PommeAgentOperationError.notFound }; return file }

    private static func writeChunk(_ descriptor: Int32, _ data: Data, _ offset: Int) -> Int {
        data.withUnsafeBytes { bytes in Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset) }
    }
}

enum PommeAgentOperationError: Error { case unsupported, activationPending, invalid, notFound, io }

/// launchd changes a single service-enable record atomically.  We only report
/// success after launchctl exits successfully; callers can inject this seam in
/// offline tests without altering host access state.
enum PommeRemoteLogin {
    static func apply(enabled: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [enabled ? "enable" : "disable", "system/com.openssh.sshd"]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PommeAgentOperationError.io }
    }
}

struct PommePrivilege: Sendable {
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
        guard let baseGroup = Int32(exactly: resolvedGID) else {
            throw PommeAgentOperationError.invalid
        }
        var count: Int32 = 0
        _ = getgrouplist(account, baseGroup, nil, &count)
        guard count > 0, count <= 1_024 else { throw PommeAgentOperationError.invalid }
        var rawGroups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(account, baseGroup, &rawGroups, &count) >= 0 else {
            throw PommeAgentOperationError.invalid
        }
        let groups = try rawGroups.prefix(Int(count)).map { value -> gid_t in
            guard value >= 0, let group = gid_t(exactly: value) else {
                throw PommeAgentOperationError.invalid
            }
            return group
        }
        return .init(uid: resolvedUID, gid: resolvedGID, supplementary: groups)
    }
}

enum PommeProcess {
    struct Spawned: Sendable {
        let pid: Int32
        let ptyMaster: Int32?
        let stdin: Int32?
        let stdout: Int32?
        let stderr: Int32?
        let ptyEchoDisabled: Bool
    }

    static func spawn(path: String, arguments: [String], identity: PommePrivilege?, pty: Bool) throws -> Spawned {
        guard path.hasPrefix("/"), !path.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw PommeAgentOperationError.invalid
        }
        var master: Int32 = -1; var slave: Int32 = -1
        var stdinPipe: [Int32] = [-1, -1]; var stdoutPipe: [Int32] = [-1, -1]; var stderrPipe: [Int32] = [-1, -1]
        if pty {
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw PommeAgentOperationError.io }
            // A private PTY may carry a credential after a prompt.  Disable
            // terminal echo before the child opens the slave so a password is
            // never returned as output.  Failure is fail-closed: a PTY with
            // unknown echo state is unsafe for streamed secrets.
            var attributes = termios()
            guard tcgetattr(slave, &attributes) == 0 else {
                _ = Darwin.close(master); _ = Darwin.close(slave)
                throw PommeAgentOperationError.io
            }
            attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
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

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            if actions != nil { _ = posix_spawn_file_actions_destroy(&actions) }
            if pty { _ = Darwin.close(master); _ = Darwin.close(slave) }
            else { [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.forEach { _ = Darwin.close($0) } }
            throw PommeAgentOperationError.io
        }
        defer {
            _ = posix_spawn_file_actions_destroy(&actions)
            _ = posix_spawnattr_destroy(&attributes)
        }

        let actionResults: [Int32]
        if pty {
            guard let terminalName = ttyname(slave) else {
                _ = Darwin.close(master); _ = Darwin.close(slave)
                throw PommeAgentOperationError.io
            }
            actionResults = [
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, terminalName, O_RDWR, 0),
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO),
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
            ]
        } else {
            actionResults = [
                posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO),
                posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
                posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
                posix_spawn_file_actions_addclose(&actions, stdinPipe[1]),
                posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
                posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
            ]
        }
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            if pty { _ = Darwin.close(master); _ = Darwin.close(slave) }
            else { [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.forEach { _ = Darwin.close($0) } }
            throw PommeAgentOperationError.io
        }

        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            | Int16(pty ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
              (pty || posix_spawnattr_setpgroup(&attributes, 0) == 0)
        else {
            if pty { _ = Darwin.close(master); _ = Darwin.close(slave) }
            else { [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.forEach { _ = Darwin.close($0) } }
            throw PommeAgentOperationError.io
        }

        let launchPath: String
        let launchArguments: [String]
        if let identity, identity.uid != geteuid() || identity.gid != getegid() {
            guard geteuid() == 0 else {
                if pty { _ = Darwin.close(master); _ = Darwin.close(slave) }
                else { [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.forEach { _ = Darwin.close($0) } }
                throw PommeAgentOperationError.invalid
            }
            // sudo is used only as the root-owned credential transition
            // helper. It initializes the already-resolved supplementary
            // groups, changes gid/uid, and then execs the requested absolute
            // path without involving a shell.
            launchPath = "/usr/bin/sudo"
            launchArguments = [
                "-n", "-H", "-u", "#\(identity.uid)", "-g", "#\(identity.gid)", "--", path
            ] + arguments
        } else {
            launchPath = path
            launchArguments = arguments
        }

        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.dropLast().forEach { free($0) } }
        var pid: pid_t = 0
        let spawnStatus = launchPath.withCString { executable in
            posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
        }
        guard spawnStatus == 0, pid > 0 else {
            if pty { _ = Darwin.close(master); _ = Darwin.close(slave) }
            else { [stdinPipe, stdoutPipe, stderrPipe].flatMap { $0 }.forEach { _ = Darwin.close($0) } }
            throw PommeAgentOperationError.io
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
                ptyEchoDisabled: true
            )
        }
        _ = Darwin.close(stdinPipe[0]); _ = Darwin.close(stdoutPipe[1]); _ = Darwin.close(stderrPipe[1])
        [stdinPipe[1], stdoutPipe[0], stderrPipe[0]].forEach { _ = fcntl($0, F_SETFL, O_NONBLOCK) }
        return .init(
            pid: pid,
            ptyMaster: nil,
            stdin: stdinPipe[1],
            stdout: stdoutPipe[0],
            stderr: stderrPipe[0],
            ptyEchoDisabled: false
        )
    }
}
