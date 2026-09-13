import CryptoKit
import Darwin
import Foundation

/// Guest-owned durable terminal processes.  The service deliberately does not
/// share the public process/job table: terminal output is drained into a
/// replayable spool before a read acknowledgement is returned to the host.
actor PommeTerminalService {
    static let protocolVersion = PommeTerminalSessionProtocol.version
    static let maximumPageSize = 128

    private struct Terminal {
        let id: UUID
        let pid: Int32
        let executable: String
        let arguments: [String]
        let master: Int32
        let spoolFD: Int32
        let spoolURL: URL?
        var spoolLength: UInt64
        var acknowledgedOffset: UInt64
        var outputEOF = false
        var exited = false
        var rawStatus: Int32?
        var storageBlocked = false
        var pendingOutput = Data()
        var lastMutationSequence: UInt64 = 0
        var mutationDigests: [UInt64: String] = [:]
        var mutationResults: [UInt64: JSONValue] = [:]
    }

    private let role: PommeAgentRole
    private let spoolRoot: URL
    private let removesSpoolRoot: Bool
    private var terminals: [UUID: Terminal] = [:]
    private var pumpTasks: [UUID: Task<Void, Never>] = [:]

    init(role: PommeAgentRole, spoolRoot: URL? = nil) throws {
        self.role = role
        if let spoolRoot {
            self.spoolRoot = spoolRoot.standardizedFileURL
            self.removesSpoolRoot = false
        } else if role == .persistent {
            self.spoolRoot = URL(fileURLWithPath: "/private/var/db/pomme/terminal-spool", isDirectory: true)
            self.removesSpoolRoot = false
        } else {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("pomme-terminal-\(UUID().uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            guard Darwin.chmod(root.path, S_IRWXU) == 0 else {
                try? FileManager.default.removeItem(at: root)
                throw PommeAgentOperationError.io
            }
            self.spoolRoot = root
            self.removesSpoolRoot = true
        }

    }

    deinit {
        for task in pumpTasks.values { task.cancel() }
        for terminal in terminals.values {
            _ = kill(-terminal.pid, SIGHUP)
            _ = Darwin.close(terminal.master)
            _ = Darwin.close(terminal.spoolFD)
        }
        if removesSpoolRoot {
            try? FileManager.default.removeItem(at: spoolRoot)
        }
    }

    func perform(operation: String, payload: JSONValue) async throws -> JSONValue {
        switch operation {
        case "terminal.create": return try await create(payload)
        case "terminal.status": return try await status(payload)
        case "terminal.read": return try await read(payload)
        case "terminal.ack": return try ack(payload)
        case "terminal.input": return try input(payload)
        case "terminal.resize": return try resize(payload)
        case "terminal.signal": return try signal(payload)
        case "terminal.terminate": return try terminate(payload)
        case "terminal.release": return try release(payload)
        case "terminal.list": return try list(payload)
        default: throw PommeAgentOperationError.unsupported
        }
    }

    func describe() -> JSONValue {
        .object([
            "terminalSessionVersion": .integer(Int64(Self.protocolVersion)),
            "terminalCapabilities": .array([
                "terminal.create", "terminal.status", "terminal.read", "terminal.ack",
                "terminal.input", "terminal.resize", "terminal.signal", "terminal.terminate",
                "terminal.release", "terminal.list"
            ].map(JSONValue.string))
        ])
    }

    // MARK: Creation and lifecycle

    private func create(_ payload: JSONValue) async throws -> JSONValue {
        if role == .persistent {
            try ensurePersistentSpoolRoot()
        }
        let values = try object(payload)
        let allowed: Set<String> = [
            "sessionID", "sequence", "mutationDigest", "path", "arguments", "shell",
            "cwd", "environment", "user", "uid", "group", "gid", "columns", "rows"
        ]
        guard Set(values.keys).isSubset(of: allowed), values["sequence"] != nil,
              values["mutationDigest"]?.stringValue != nil,
              values["sessionID"] != nil
        else { throw PommeAgentOperationError.invalid }

        let sessionID = try uuid(values, "sessionID")
        let sequence = try uint64(values, "sequence")
        let digest = try string(values, "mutationDigest")
        if let existing = terminals[sessionID] {
            guard sequence == 0,
                  existing.mutationDigests[sequence] == digest,
                  let result = existing.mutationResults[sequence]
            else { throw PommeAgentOperationError.invalid }
            return result
        }
        guard sequence == 0 else { throw PommeAgentOperationError.invalid }
        let shell = try boolean(values["shell"])
        let rawPath = values["path"]?.stringValue
        let rawArguments = try strings(values["arguments"])
        let identity = try PommePrivilege.resolve(values)
        let resolved = try resolveCommand(
            path: rawPath,
            arguments: rawArguments,
            shell: shell,
            identity: identity,
            values: values
        )
        if role == .recovery {
            guard identity == nil,
                  resolved.path == "/bin/sh",
                  rawPath == nil || rawPath == "/bin/sh"
            else { throw PommeAgentOperationError.invalid }
            guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else {
                throw PommeAgentOperationError.io
            }
        }

        let options = try processOptions(values: values, identity: identity, resolved: resolved)
        let launched = try PommeProcess.spawn(
            path: resolved.path,
            arguments: resolved.arguments,
            identity: identity,
            pty: true,
            options: options
        )
        guard let master = launched.ptyMaster else {
            _ = kill(-launched.pid, SIGKILL)
            throw PommeAgentOperationError.io
        }

        var spoolFD: Int32 = -1
        var spoolURL: URL?
        do {
            if role == .persistent {
                let url = spoolRoot.appendingPathComponent("\(sessionID.uuidString.lowercased()).spool")
                spoolFD = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
                guard spoolFD >= 0 else { throw PommeAgentOperationError.io }
                spoolURL = url
                try Self.validatePrivateFileDescriptor(spoolFD)
            } else {
                var template = Array(spoolRoot.appendingPathComponent("pomme-terminal-XXXXXX").path.utf8) + [0]
                spoolFD = template.withUnsafeMutableBufferPointer { Darwin.mkstemp($0.baseAddress) }
                guard spoolFD >= 0 else { throw PommeAgentOperationError.io }
                _ = Darwin.unlink(String(cString: template.withUnsafeBufferPointer { $0.baseAddress! }))
                guard fcntl(spoolFD, F_SETFD, FD_CLOEXEC) == 0 else { throw PommeAgentOperationError.io }
            }
        } catch {
            _ = Darwin.close(master)
            _ = kill(-launched.pid, SIGKILL)
            _ = waitpid(launched.pid, nil, 0)
            if spoolFD >= 0 { _ = Darwin.close(spoolFD) }
            if let spoolURL { try? FileManager.default.removeItem(at: spoolURL) }
            throw error
        }

        var terminal = Terminal(
            id: sessionID,
            pid: launched.pid,
            executable: resolved.path,
            arguments: resolved.arguments,
            master: master,
            spoolFD: spoolFD,
            spoolURL: spoolURL,
            spoolLength: 0,
            acknowledgedOffset: 0
        )
        terminal.lastMutationSequence = sequence
        terminal.mutationDigests[sequence] = digest
        let result = try statusResult(for: terminal, includeOffsets: true)
        terminal.mutationResults[sequence] = result
        terminals[sessionID] = terminal
        if let columns = try optionalInt(values, "columns"), let rows = try optionalInt(values, "rows") {
            try applyResize(sessionID: sessionID, columns: columns, rows: rows)
        }
        startPump(sessionID)
        return result
    }

    private func status(_ payload: JSONValue) async throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID"])
        let id = try uuid(values, "sessionID")
        try refresh(id)
        guard let terminal = terminals[id] else { throw PommeAgentOperationError.notFound }
        return try statusResult(for: terminal, includeOffsets: true)
    }

    private func list(_ payload: JSONValue) throws -> JSONValue {
        let values = try object(payload)
        guard Set(values.keys).isSubset(of: ["pageToken", "pageSize"]) else { throw PommeAgentOperationError.invalid }
        let token = values["pageToken"]?.stringValue ?? ""
        let start = token.isEmpty ? 0 : Int(token) ?? -1
        let requested = try optionalInt(values, "pageSize") ?? Self.maximumPageSize
        guard start >= 0, requested > 0, requested <= Self.maximumPageSize else { throw PommeAgentOperationError.invalid }
        let ids = terminals.keys.sorted { $0.uuidString < $1.uuidString }
        let slice = ids.dropFirst(min(start, ids.count)).prefix(requested)
        var entries: [JSONValue] = []
        for id in slice {
            try refresh(id)
            if let terminal = terminals[id] { entries.append(try statusResult(for: terminal, includeOffsets: true)) }
        }
        let next: JSONValue = start + entries.count < ids.count
            ? .string(String(start + entries.count))
            : .null
        return .object(["sessions": .array(entries), "nextPageToken": next])
    }

    private func release(_ payload: JSONValue) throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID"])
        let id = try uuid(values, "sessionID")
        guard let terminal = terminals.removeValue(forKey: id) else { throw PommeAgentOperationError.notFound }
        pumpTasks.removeValue(forKey: id)?.cancel()
        _ = Darwin.close(terminal.master)
        _ = Darwin.close(terminal.spoolFD)
        if let spoolURL = terminal.spoolURL { try? FileManager.default.removeItem(at: spoolURL) }
        return .object(["sessionID": .string(id.uuidString.lowercased()), "released": .bool(true)])
    }

    // MARK: Replay and mutation operations

    private func read(_ payload: JSONValue) async throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID", "offset", "count"])
        let id = try uuid(values, "sessionID")
        let offset = try uint64(values, "offset")
        let requested = try integer(values, "count")
        guard requested >= 0, requested <= PommeAgentProtocol.maximumStreamChunkBytes else { throw PommeAgentOperationError.invalid }
        try refresh(id)
        guard var terminal = terminals[id] else { throw PommeAgentOperationError.notFound }
        do {
            try drain(&terminal)
        } catch {
            // Preserve bytes already copied to the guest spool and the
            // unwritten suffix if storage failed part-way through a drain.
            // The next read must resume from the exact durable spool length,
            // not from the stale pre-drain actor value.
            terminal.storageBlocked = true
            terminals[id] = terminal
            throw error
        }
        terminals[id] = terminal
        guard offset <= terminal.spoolLength else { throw PommeAgentOperationError.invalid }
        let count = min(requested, Int(terminal.spoolLength - offset))
        let data = try pread(fd: terminal.spoolFD, offset: offset, count: count)
        let nextOffset = offset + UInt64(data.count)
        let eof = terminal.exited && terminal.outputEOF && nextOffset >= terminal.spoolLength
        return .object([
            "sessionID": .string(id.uuidString.lowercased()),
            "offset": .integer(Int64(offset)),
            "nextOffset": .integer(Int64(nextOffset)),
            "dataBase64": .string(data.base64EncodedString()),
            "eof": .bool(eof),
            "exited": .bool(terminal.exited),
            "outputComplete": .bool(terminal.exited && terminal.outputEOF && terminal.pendingOutput.isEmpty),
            "outputLength": .integer(Int64(terminal.spoolLength)),
            "storageBlocked": .bool(terminal.storageBlocked)
        ])
    }

    private func ack(_ payload: JSONValue) throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID", "offset"])
        let id = try uuid(values, "sessionID")
        let offset = try uint64(values, "offset")
        guard var terminal = terminals[id], offset <= terminal.spoolLength,
              offset >= terminal.acknowledgedOffset else { throw PommeAgentOperationError.invalid }
        terminal.acknowledgedOffset = offset
        terminals[id] = terminal
        return .object(["sessionID": .string(id.uuidString.lowercased()), "acknowledgedOffset": .integer(Int64(offset))])
    }

    private func input(_ payload: JSONValue) throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID", "sequence", "mutationDigest", "dataBase64"])
        let data = try decodedData(values, key: "dataBase64")
        let id = try uuid(values, "sessionID")
        let sequence = try uint64(values, "sequence")
        let digest = try string(values, "mutationDigest")
        return try applyMutation(id: id, sequence: sequence, digest: digest) {
            guard let terminal = self.terminals[id], !terminal.exited else { throw PommeAgentOperationError.notFound }
            try writeAll(data, to: terminal.master)
            return .object(["sessionID": .string(id.uuidString.lowercased()), "sequence": .integer(Int64(sequence)), "accepted": .bool(true)])
        }
    }

    private func resize(_ payload: JSONValue) throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID", "sequence", "mutationDigest", "columns", "rows"])
        let id = try uuid(values, "sessionID")
        let sequence = try uint64(values, "sequence")
        let digest = try string(values, "mutationDigest")
        let columns = try integer(values, "columns")
        let rows = try integer(values, "rows")
        guard columns > 0, rows > 0, columns <= 32_768, rows <= 32_768 else { throw PommeAgentOperationError.invalid }
        return try applyMutation(id: id, sequence: sequence, digest: digest) {
            try self.applyResize(sessionID: id, columns: columns, rows: rows)
            return .object(["sessionID": .string(id.uuidString.lowercased()), "sequence": .integer(Int64(sequence)), "accepted": .bool(true)])
        }
    }

    private func signal(_ payload: JSONValue) throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID", "sequence", "mutationDigest", "signal"])
        let id = try uuid(values, "sessionID")
        let sequence = try uint64(values, "sequence")
        let digest = try string(values, "mutationDigest")
        let raw = try integer(values, "signal")
        guard [SIGHUP, SIGINT, SIGTERM, SIGKILL].contains(Int32(raw)) else { throw PommeAgentOperationError.invalid }
        return try applyMutation(id: id, sequence: sequence, digest: digest) {
            guard let terminal = self.terminals[id] else { throw PommeAgentOperationError.notFound }
            guard kill(-terminal.pid, Int32(raw)) == 0 || kill(terminal.pid, Int32(raw)) == 0 else { throw PommeAgentOperationError.io }
            return .object(["sessionID": .string(id.uuidString.lowercased()), "sequence": .integer(Int64(sequence)), "accepted": .bool(true)])
        }
    }

    private func terminate(_ payload: JSONValue) throws -> JSONValue {
        let values = try exactObject(payload, keys: ["sessionID", "sequence", "mutationDigest", "force"])
        let id = try uuid(values, "sessionID")
        let sequence = try uint64(values, "sequence")
        let digest = try string(values, "mutationDigest")
        let force = try boolean(values["force"])
        return try applyMutation(id: id, sequence: sequence, digest: digest) {
            guard let terminal = self.terminals[id] else { throw PommeAgentOperationError.notFound }
            let signal = force ? SIGKILL : SIGHUP
            guard kill(-terminal.pid, signal) == 0 || kill(terminal.pid, signal) == 0 else { throw PommeAgentOperationError.io }
            return .object(["sessionID": .string(id.uuidString.lowercased()), "sequence": .integer(Int64(sequence)), "accepted": .bool(true), "signal": .integer(Int64(signal))])
        }
    }

    private func applyMutation(
        id: UUID,
        sequence: UInt64,
        digest: String,
        operation: () throws -> JSONValue
    ) throws -> JSONValue {
        guard var terminal = terminals[id] else { throw PommeAgentOperationError.notFound }
        guard !digest.isEmpty, digest.count <= 128 else { throw PommeAgentOperationError.invalid }
        if sequence <= terminal.lastMutationSequence {
            guard terminal.mutationDigests[sequence] == digest,
                  let result = terminal.mutationResults[sequence]
            else { throw PommeAgentOperationError.invalid }
            return result
        }
        guard sequence == terminal.lastMutationSequence + 1 else { throw PommeAgentOperationError.invalid }
        let result = try operation()
        terminal.lastMutationSequence = sequence
        terminal.mutationDigests[sequence] = digest
        terminal.mutationResults[sequence] = result
        // Retain every acknowledgement so an exact retry remains idempotent
        // across reconnects. There is deliberately no artificial count or
        // transcript-size limit; skipped/conflicting sequences still fail.
        terminals[id] = terminal
        return result
    }

    // MARK: PTY and spool pumping

    private func startPump(_ id: UUID) {
        pumpTasks[id]?.cancel()
        pumpTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pumpOnce(id)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func pumpOnce(_ id: UUID) {
        guard terminals[id] != nil else { return }
        do {
            try refresh(id)
            guard var current = terminals[id] else { return }
            try drain(&current)
            terminals[id] = current
        } catch {
            guard var current = terminals[id] else { return }
            current.storageBlocked = true
            terminals[id] = current
        }
    }

    private func refresh(_ id: UUID) throws {
        guard var terminal = terminals[id] else { throw PommeAgentOperationError.notFound }
        if !terminal.exited {
            var status: Int32 = 0
            let result = waitpid(terminal.pid, &status, WNOHANG)
            if result == terminal.pid {
                terminal.exited = true
                terminal.rawStatus = status
            } else if result < 0, errno != EINTR, errno != ECHILD {
                throw PommeAgentOperationError.io
            }
        }
        do {
            try drain(&terminal)
        } catch {
            terminal.storageBlocked = true
        }
        terminals[id] = terminal
    }

    private func drain(_ terminal: inout Terminal) throws {
        var buffer = [UInt8](repeating: 0, count: PommeAgentProtocol.maximumStreamChunkBytes)
        while true {
            let count = Darwin.read(terminal.master, &buffer, buffer.count)
            if count > 0 {
                terminal.pendingOutput.append(contentsOf: buffer.prefix(count))
                try flushPending(&terminal)
            } else if count == 0 || (count < 0 && errno == EIO) {
                terminal.outputEOF = true
                try flushPending(&terminal)
                return
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try flushPending(&terminal)
                return
            } else {
                throw PommeAgentOperationError.io
            }
        }
    }

    private func flushPending(_ terminal: inout Terminal) throws {
        guard !terminal.pendingOutput.isEmpty else {
            terminal.storageBlocked = false
            return
        }
        var offset = 0
        while offset < terminal.pendingOutput.count {
            let count = terminal.pendingOutput.withUnsafeBytes { bytes in
                Darwin.write(terminal.spoolFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
                terminal.spoolLength += UInt64(count)
                terminal.pendingOutput.removeFirst(count)
                offset = 0
            }
            else if count < 0 && errno == EINTR { continue }
            else {
                terminal.storageBlocked = true
                throw PommeAgentOperationError.io
            }
        }
        terminal.storageBlocked = false
    }

    private func applyResize(sessionID: UUID, columns: Int, rows: Int) throws {
        guard let terminal = terminals[sessionID] else { throw PommeAgentOperationError.notFound }
        var window = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(terminal.master, TIOCSWINSZ, &window) == 0 else { throw PommeAgentOperationError.io }
    }

    private func statusResult(for terminal: Terminal, includeOffsets: Bool) throws -> JSONValue {
        var result: [String: JSONValue] = [
            "sessionID": .string(terminal.id.uuidString.lowercased()),
            "pid": .integer(Int64(terminal.pid)),
            "path": .string(terminal.executable),
            "arguments": .array(terminal.arguments.map(JSONValue.string)),
            "exited": .bool(terminal.exited),
            "outputComplete": .bool(terminal.exited && terminal.outputEOF && terminal.pendingOutput.isEmpty),
            "storageBlocked": .bool(terminal.storageBlocked),
            "outputLength": .integer(Int64(terminal.spoolLength))
        ]
        if includeOffsets {
            result["acknowledgedOffset"] = .integer(Int64(terminal.acknowledgedOffset))
        }
        if let rawStatus = terminal.rawStatus {
            let termination = rawStatus & 0x7f
            if termination == 0 {
                result["exitCode"] = .integer(Int64((rawStatus >> 8) & 0xff))
            } else if termination != 0x7f {
                result["signal"] = .integer(Int64(termination))
            }
        }
        return .object(result)
    }

    // MARK: command and payload validation

    private struct ResolvedCommand {
        let path: String
        let arguments: [String]
        let home: String?
        let shell: String?
    }

    private func resolveCommand(
        path: String?,
        arguments: [String],
        shell: Bool,
        identity: PommePrivilege?,
        values: [String: JSONValue]
    ) throws -> ResolvedCommand {
        if shell {
            guard path == nil || path == "/bin/sh", arguments.isEmpty else { throw PommeAgentOperationError.invalid }
            let account = identity ?? PommePrivilege.current()
            let passwd = try? passwdRecord(uid: account.uid)
            let home = passwd?.home ?? "/"
            let candidate = role == .recovery ? "/bin/sh" : (passwd?.shell ?? "")
            let shellPath = Self.executableAbsolutePath(candidate) ? candidate : "/bin/sh"
            return .init(path: shellPath, arguments: ["-l"], home: home, shell: shellPath)
        }
        guard let path, path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw PommeAgentOperationError.invalid }
        let home: String?
        if let identity { home = try? passwdRecord(uid: identity.uid).home }
        else { home = nil }
        return .init(path: path, arguments: arguments, home: home, shell: nil)
    }

    private func processOptions(
        values: [String: JSONValue],
        identity: PommePrivilege?,
        resolved: ResolvedCommand
    ) throws -> PommeProcess.Options {
        let suppliedCWD = try optionalPath(values, "cwd")
        let cwd = suppliedCWD ?? resolved.home
        var environment = try environment(values["environment"])
        if let home = resolved.home { environment["HOME"] = environment["HOME"] ?? home }
        if let shell = resolved.shell { environment["SHELL"] = environment["SHELL"] ?? shell }
        if let identity {
            environment["USER"] = environment["USER"] ?? identity.account
            environment["LOGNAME"] = environment["LOGNAME"] ?? identity.account
        }
        _ = identity
        return .init(cwd: cwd, environment: environment, ptyEcho: true)
    }

    private func passwdRecord(uid: uid_t) throws -> (home: String, shell: String) {
        guard let record = getpwuid(uid),
              let home = String(validatingCString: record.pointee.pw_dir),
              let shell = String(validatingCString: record.pointee.pw_shell),
              !home.isEmpty
        else { throw PommeAgentOperationError.invalid }
        return (home, shell)
    }

    private static func executableAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && access(path, X_OK) == 0
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let object = value.objectValue else { throw PommeAgentOperationError.invalid }
        return object
    }

    private func exactObject(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
        let object = try self.object(value)
        guard Set(object.keys) == keys else { throw PommeAgentOperationError.invalid }
        return object
    }

    private func string(_ object: [String: JSONValue], _ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty, !value.contains("\0") else { throw PommeAgentOperationError.invalid }
        return value
    }

    private func uuid(_ object: [String: JSONValue], _ key: String) throws -> UUID {
        guard let value = object[key]?.stringValue, let uuid = UUID(uuidString: value) else { throw PommeAgentOperationError.invalid }
        return uuid
    }

    private func strings(_ value: JSONValue?) throws -> [String] {
        guard let values = value?.arrayValue, values.count <= 1_024 else { throw PommeAgentOperationError.invalid }
        return try values.map { value in
            guard let string = value.stringValue, !string.contains("\0"), string.utf8.count <= 64 * 1_024 else { throw PommeAgentOperationError.invalid }
            return string
        }
    }

    private func integer(_ object: [String: JSONValue], _ key: String) throws -> Int {
        guard case .integer(let value) = object[key], let result = Int(exactly: value) else { throw PommeAgentOperationError.invalid }
        return result
    }

    private func optionalInt(_ object: [String: JSONValue], _ key: String) throws -> Int? {
        guard object[key] != nil else { return nil }
        return try integer(object, key)
    }

    private func uint64(_ object: [String: JSONValue], _ key: String) throws -> UInt64 {
        let value = try integer(object, key)
        guard value >= 0 else { throw PommeAgentOperationError.invalid }
        return UInt64(value)
    }

    private func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard case .bool(let result) = value else { throw PommeAgentOperationError.invalid }
        return result
    }

    private func optionalPath(_ object: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let path = value.stringValue, path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw PommeAgentOperationError.invalid }
        return path
    }

    private func environment(_ value: JSONValue?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let object = value.objectValue else { throw PommeAgentOperationError.invalid }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard let text = value.stringValue else { throw PommeAgentOperationError.invalid }
            result[key] = text
        }
        guard result.count <= 1_024 else { throw PommeAgentOperationError.invalid }
        for (key, text) in result {
            guard !key.isEmpty, key.utf8.count <= 256, text.utf8.count <= 64 * 1_024,
                  key.first?.isASCII == true,
                  key.first?.isLetter == true || key.first == "_",
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  !key.contains("\0"), !text.contains("\0")
            else { throw PommeAgentOperationError.invalid }
        }
        return result
    }

    private func decodedData(_ object: [String: JSONValue], key: String) throws -> Data {
        guard let encoded = object[key]?.stringValue,
              let data = Data(base64Encoded: encoded),
              data.count <= PommeAgentProtocol.maximumStreamChunkBytes
        else { throw PommeAgentOperationError.invalid }
        return data
    }

    private static func validatePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              info.st_nlink >= 2
        else { throw PommeAgentOperationError.io }
    }

    private func ensurePersistentSpoolRoot() throws {
        try FileManager.default.createDirectory(at: spoolRoot, withIntermediateDirectories: true)
        guard Darwin.chmod(spoolRoot.path, S_IRWXU) == 0 else { throw PommeAgentOperationError.io }
        try Self.validatePrivateDirectory(spoolRoot)
    }

    private static func validatePrivateFileDescriptor(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              info.st_nlink == 1
        else { throw PommeAgentOperationError.io }
    }

    private func pread(fd: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw PommeAgentOperationError.invalid }
        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(fd, bytes.baseAddress, count, off_t(offset))
            }
            if result >= 0 { return Data(buffer.prefix(Int(result))) }
            if errno == EINTR { continue }
            throw PommeAgentOperationError.io
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { throw PommeAgentOperationError.io }
        }
    }
}

private extension PommePrivilege {
    static func current() -> PommePrivilege {
        let uid = geteuid()
        let gid = getegid()
        let account = getpwuid(uid).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? "root"
        return .init(account: account, uid: uid, gid: gid, supplementary: [])
    }
}
