import CryptoKit
import Darwin
import Foundation

enum PommeDurableTerminalRole: String, Codable, Sendable {
    case normal
    case recovery
}

enum PommeDurableTerminalState: String, Codable, Sendable {
    case running
    case attached
    case detached
    case exited
    case lost
    case storageBlocked = "storage-blocked"
}

struct PommeDurableTerminalRecord: Codable, Equatable, Sendable {
    let sessionID: String
    let bootRole: PommeDurableTerminalRole
    let bootGeneration: String
    var state: PommeDurableTerminalState
    let pid: Int64
    let executable: String
    let arguments: [String]
    let createdAt: Date
    var updatedAt: Date
    var attachmentState: String
    var transcriptOffset: UInt64
    var acknowledgedOffset: UInt64
    var lastDeliveredOffset: UInt64
    var exitCode: Int?
    var signal: Int?
    var lossReason: String?
    var storageHealth: String

    var publicPayload: [String: Any] {
        var payload: [String: Any] = [
            "sessionID": sessionID,
            "bootRole": bootRole.rawValue,
            "bootGeneration": bootGeneration,
            "state": state.rawValue,
            "pid": pid,
            "executable": executable,
            "arguments": arguments,
            "createdAt": createdAt.pommeISO8601String,
            "updatedAt": updatedAt.pommeISO8601String,
            "attachmentState": attachmentState,
            "transcriptOffset": transcriptOffset,
            "acknowledgedOffset": acknowledgedOffset,
            "lastDeliveredOffset": lastDeliveredOffset,
            "storageHealth": storageHealth
        ]
        if let exitCode { payload["exitCode"] = exitCode }
        if let signal { payload["signal"] = signal }
        if let lossReason { payload["lossReason"] = lossReason }
        return payload
    }
}

struct PommeDurableTerminalAttachment: Sendable {
    let sessionID: UUID
    let token: UUID
    let cursor: UInt64
}

enum PommeTerminalMutationDigest {
    static func make(operation: String, payload: [String: JSONValue]) -> String {
        let value = JSONValue.object([
            "operation": .string(operation),
            "payload": .object(payload)
        ])
        return (try? PommeTerminalSessionMutationSupport.payloadSHA256(value)) ?? String(repeating: "0", count: 64)
    }
}

enum PommeDurableTerminalError: Error, Equatable, LocalizedError, Sendable {
    case invalidSessionID
    case notFound
    case attachmentBusy
    case attachmentReplaced
    case invalidOffset
    case invalidState
    case transcriptChanged
    case storageBlocked
    case recoveryNotPersistent

    var errorDescription: String? {
        switch self {
        case .invalidSessionID: "The terminal session ID is invalid."
        case .notFound: "The terminal session was not found."
        case .attachmentBusy: "The terminal session is already attached; use --takeover."
        case .attachmentReplaced: "The terminal attachment was replaced by another client."
        case .invalidOffset: "The terminal transcript offset is invalid."
        case .invalidState: "The terminal session is not in a state that permits this operation."
        case .transcriptChanged: "The terminal transcript changed unexpectedly."
        case .storageBlocked: "The terminal transcript storage is unavailable."
        case .recoveryNotPersistent: "Recovery terminal transcripts are transient and cannot be persisted."
        }
    }
}

struct PommeTerminalSessionControlRequest: Sendable {
    let operation: String
    let payload: [String: JSONValue]

    static let operations: Set<String> = [
        "terminal.create", "terminal.list", "terminal.inspect", "terminal.attach",
        "terminal.logs", "terminal.terminate", "terminal.delete"
    ]

    static func parse(from object: [String: JSONValue]) throws -> Self {
        guard let operation = object["operation"]?.stringValue,
              operations.contains(operation), operation.utf8.count <= 128
        else { throw RunnerError.invalidControlCommand("terminal.session") }
        let payload = object.filter { $0.key != "operation" }
        let allowed: Set<String>
        switch operation {
        case "terminal.create":
            allowed = ["sessionID", "path", "arguments", "shell", "cwd", "environment", "user", "uid", "group", "gid", "columns", "rows"]
        case "terminal.list":
            allowed = ["pageToken", "pageSize"]
        case "terminal.inspect", "terminal.delete":
            allowed = ["sessionID"]
        case "terminal.attach":
            allowed = ["sessionID", "offset", "takeover"]
        case "terminal.logs":
            allowed = ["sessionID", "offset"]
        case "terminal.terminate":
            allowed = ["sessionID", "force"]
        default:
            allowed = []
        }
        guard Set(payload.keys).isSubset(of: allowed) else {
            throw RunnerError.invalidControlCommand("terminal.session")
        }
        try validateTypes(payload, operation: operation)
        return .init(operation: operation, payload: payload)
    }

    private static func validateTypes(_ payload: [String: JSONValue], operation: String) throws {
        for key in ["sessionID", "path", "cwd", "user", "group", "pageToken"] where payload[key] != nil {
            guard payload[key]?.stringValue != nil else { throw RunnerError.invalidControlCommand(operation) }
        }
        for key in ["offset", "pageSize", "uid", "gid", "columns", "rows"] where payload[key] != nil {
            guard case .integer(let value)? = payload[key], value >= 0 else {
                throw RunnerError.invalidControlCommand(operation)
            }
        }
        for key in ["shell", "takeover", "force"] where payload[key] != nil {
            guard case .bool? = payload[key] else { throw RunnerError.invalidControlCommand(operation) }
        }
        if let arguments = payload["arguments"] {
            guard case .array(let values) = arguments,
                  values.allSatisfy({ $0.stringValue != nil }) else { throw RunnerError.invalidControlCommand(operation) }
        }
        if let environment = payload["environment"] {
            guard case .object(let values) = environment,
                  values.values.allSatisfy({ $0.stringValue != nil }) else { throw RunnerError.invalidControlCommand(operation) }
        }
    }
}

/// Helper-owned host session state.  The actor owns attachment cursors and
/// storage mutation so a client disconnect cannot terminate the guest PTY.
actor PommeDurableTerminalSessionManager {
    struct CreateInput: Sendable {
        let sessionID: UUID
        let role: PommeDurableTerminalRole
        let bootGeneration: UUID
        let pid: Int64
        let executable: String
        let arguments: [String]
    }

    private struct Session {
        var record: PommeDurableTerminalRecord
        var transcript: Data
        let rawURL: URL?
        let metadataURL: URL?
        var attachedToken: UUID?
        var replacedTokens: Set<UUID> = []
    }

    private let role: PommeDurableTerminalRole
    private let vmKey: String
    private let rootURL: URL?
    private var sessions: [UUID: Session] = [:]
    private var mutationSequences: [UUID: UInt64] = [:]

    init(
        role: PommeDurableTerminalRole,
        vmPath: String,
        rootURL: URL? = nil,
        generation: UUID = UUID()
    ) {
        self.role = role
        self.vmKey = Self.key(for: vmPath)
        if role == .normal {
            let root = rootURL ?? (try? applicationSupportRoot(create: true))?
                .appendingPathComponent("TerminalSessions", isDirectory: true)
                .appendingPathComponent(Self.key(for: vmPath), isDirectory: true)
            self.rootURL = root.flatMap { try? Self.preparePrivateDirectory($0) }
            if let root = self.rootURL {
                self.sessions = Self.loadNormalSessions(from: root, currentGeneration: generation)
            }
        } else {
            self.rootURL = nil
        }
    }

    func register(_ input: CreateInput) throws -> PommeDurableTerminalRecord {
        guard sessions[input.sessionID] == nil else { throw PommeDurableTerminalError.invalidState }
        let now = Date()
        let record = PommeDurableTerminalRecord(
            sessionID: input.sessionID.uuidString.lowercased(),
            bootRole: input.role,
            bootGeneration: input.bootGeneration.uuidString.lowercased(),
            state: .detached,
            pid: input.pid,
            executable: input.executable,
            arguments: input.arguments,
            createdAt: now,
            updatedAt: now,
            attachmentState: "detached",
            transcriptOffset: 0,
            acknowledgedOffset: 0,
            lastDeliveredOffset: 0,
            exitCode: nil,
            signal: nil,
            lossReason: nil,
            storageHealth: "healthy"
        )
        let paths = try normalPaths(for: input.sessionID)
        if let raw = paths.raw {
            let descriptor = Darwin.open(raw.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PommeDurableTerminalError.storageBlocked }
            _ = Darwin.close(descriptor)
        }
        let session = Session(record: record, transcript: Data(), rawURL: paths.raw, metadataURL: paths.metadata)
        sessions[input.sessionID] = session
        mutationSequences[input.sessionID] = 0
        do {
            try persist(input.sessionID)
        } catch {
            sessions.removeValue(forKey: input.sessionID)
            mutationSequences.removeValue(forKey: input.sessionID)
            if let raw = paths.raw { try? FileManager.default.removeItem(at: raw) }
            if let metadata = paths.metadata { try? FileManager.default.removeItem(at: metadata) }
            throw error
        }
        return record
    }

    func list() -> [PommeDurableTerminalRecord] {
        sessions.values.map(\.record).sorted { $0.createdAt < $1.createdAt }
    }

    func page(pageToken: String?, pageSize: Int) throws -> ([PommeDurableTerminalRecord], String?) {
        guard pageSize > 0, pageSize <= 128 else { throw PommeDurableTerminalError.invalidOffset }
        let records = list()
        let start: Int
        if let pageToken, !pageToken.isEmpty, let parsed = Int(pageToken), parsed >= 0 {
            start = parsed
        } else if pageToken == nil || pageToken?.isEmpty == true {
            start = 0
        } else {
            throw PommeDurableTerminalError.invalidOffset
        }
        guard start <= records.count else { throw PommeDurableTerminalError.invalidOffset }
        let end = min(start + pageSize, records.count)
        let next = end < records.count ? String(end) : nil
        return (Array(records[start..<end]), next)
    }

    func inspect(_ id: UUID) throws -> PommeDurableTerminalRecord {
        guard let session = sessions[id] else { throw PommeDurableTerminalError.notFound }
        return session.record
    }

    func append(_ data: Data, sessionID id: UUID) throws -> UInt64 {
        guard var session = sessions[id] else { throw PommeDurableTerminalError.notFound }
        guard !data.isEmpty else { return session.record.transcriptOffset }
        let rawURL = session.rawURL
        do {
            if let rawURL {
                let descriptor = Darwin.open(rawURL.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw PommeDurableTerminalError.storageBlocked }
                defer { _ = Darwin.close(descriptor) }
                let before = try Self.fileSize(descriptor: descriptor)
                guard before == session.record.transcriptOffset else {
                    throw PommeDurableTerminalError.transcriptChanged
                }
                try Self.writeAll(data, descriptor: descriptor)
                guard fsync(descriptor) == 0 else { throw PommeDurableTerminalError.storageBlocked }
                let after = try Self.fileSize(descriptor: descriptor)
                guard after == before + UInt64(data.count) else {
                    throw PommeDurableTerminalError.transcriptChanged
                }
            } else {
                session.transcript.append(data)
            }
            session.record.transcriptOffset += UInt64(data.count)
            session.record.storageHealth = "healthy"
            if session.record.state == .storageBlocked { session.record.state = session.attachedToken == nil ? .detached : .attached }
            session.record.updatedAt = Date()
            sessions[id] = session
            try persist(id)
            return session.record.transcriptOffset
        } catch let error as PommeDurableTerminalError {
            if let rawURL, let actual = try? Self.fileSize(rawURL: rawURL), actual >= session.record.transcriptOffset {
                // A short write or a successful append followed by an fsync
                // error is already durable in the raw spool. Advance the
                // in-memory cursor to that exact byte boundary so the next
                // guest read requests only the unwritten suffix instead of
                // duplicating bytes.
                session.record.transcriptOffset = actual
            }
            session.record.state = .storageBlocked
            session.record.storageHealth = "blocked"
            session.record.updatedAt = Date()
            sessions[id] = session
            try? persist(id)
            throw error
        } catch {
            if let rawURL, let actual = try? Self.fileSize(rawURL: rawURL), actual >= session.record.transcriptOffset {
                session.record.transcriptOffset = actual
            }
            session.record.state = .storageBlocked
            session.record.storageHealth = "blocked"
            session.record.updatedAt = Date()
            sessions[id] = session
            try? persist(id)
            throw PommeDurableTerminalError.storageBlocked
        }
    }

    func read(_ id: UUID, from offset: UInt64, maximumBytes: Int = PommeControlProtocol.maximumStreamChunkBytes) throws -> Data {
        guard let session = sessions[id] else { throw PommeDurableTerminalError.notFound }
        guard offset <= session.record.transcriptOffset, maximumBytes >= 0 else { throw PommeDurableTerminalError.invalidOffset }
        let count = min(
            maximumBytes,
            Int(min(UInt64(maximumBytes), session.record.transcriptOffset - offset))
        )
        if let rawURL = session.rawURL {
            let descriptor = Darwin.open(rawURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw PommeDurableTerminalError.storageBlocked }
            defer { _ = Darwin.close(descriptor) }
            guard try Self.fileSize(descriptor: descriptor) >= session.record.transcriptOffset else {
                throw PommeDurableTerminalError.storageBlocked
            }
            return try Self.read(descriptor: descriptor, offset: offset, count: count)
        }
        return Data(session.transcript[Int(offset)..<Int(offset) + count])
    }

    func acknowledgeGuest(_ id: UUID, offset: UInt64) throws {
        guard var session = sessions[id], offset <= session.record.transcriptOffset else {
            throw PommeDurableTerminalError.invalidOffset
        }
        // Guest acknowledgements may be retried after an unknown outcome. An
        // exact retry is already satisfied and must not rewrite metadata.
        if offset == session.record.acknowledgedOffset { return }
        guard offset > session.record.acknowledgedOffset else {
            throw PommeDurableTerminalError.invalidOffset
        }
        session.record.acknowledgedOffset = offset
        session.record.updatedAt = Date()
        sessions[id] = session
        try persist(id)
    }

    func attach(_ id: UUID, from offset: UInt64?, takeover: Bool) throws -> PommeDurableTerminalAttachment {
        guard var session = sessions[id] else { throw PommeDurableTerminalError.notFound }
        guard [.running, .detached, .storageBlocked, .attached, .exited].contains(session.record.state) else {
            throw PommeDurableTerminalError.invalidState
        }
        if let attachedToken = session.attachedToken {
            guard takeover else { throw PommeDurableTerminalError.attachmentBusy }
            session.replacedTokens.insert(attachedToken)
        }
        let token = UUID()
        let cursor = try validatedCursor(offset ?? session.record.lastDeliveredOffset, length: session.record.transcriptOffset)
        session.attachedToken = token
        session.record.attachmentState = "attached"
        session.record.state = .attached
        session.record.updatedAt = Date()
        sessions[id] = session
        try persist(id)
        return .init(sessionID: id, token: token, cursor: cursor)
    }

    func isReplaced(_ attachment: PommeDurableTerminalAttachment) throws -> Bool {
        guard var session = sessions[attachment.sessionID] else { throw PommeDurableTerminalError.notFound }
        if session.replacedTokens.remove(attachment.token) != nil {
            sessions[attachment.sessionID] = session
            throw PommeDurableTerminalError.attachmentReplaced
        }
        return session.attachedToken != attachment.token
    }

    func markDelivered(_ attachment: PommeDurableTerminalAttachment, offset: UInt64) throws {
        guard var session = sessions[attachment.sessionID], session.attachedToken == attachment.token,
              offset <= session.record.transcriptOffset
        else { throw PommeDurableTerminalError.attachmentReplaced }
        // A replay from --from-start must not erase the durable high-water
        // mark used by the next default attachment. Explicit offsets control
        // the current attachment; this field records the furthest byte any
        // attachment has successfully delivered.
        session.record.lastDeliveredOffset = max(session.record.lastDeliveredOffset, offset)
        session.record.updatedAt = Date()
        sessions[attachment.sessionID] = session
        try persist(attachment.sessionID)
    }

    func detach(_ attachment: PommeDurableTerminalAttachment) throws {
        guard var session = sessions[attachment.sessionID] else { throw PommeDurableTerminalError.notFound }
        guard session.attachedToken == attachment.token else { return }
        session.attachedToken = nil
        session.record.attachmentState = "detached"
        if session.record.state == .attached { session.record.state = .detached }
        session.record.updatedAt = Date()
        sessions[attachment.sessionID] = session
        try persist(attachment.sessionID)
    }

    func updateGuestStatus(
        _ id: UUID,
        exited: Bool,
        exitCode: Int?,
        signal: Int?,
        outputComplete: Bool,
        outputLength: UInt64?,
        storageBlocked: Bool
    ) throws {
        guard var session = sessions[id] else { throw PommeDurableTerminalError.notFound }
        session.record.exitCode = exitCode
        session.record.signal = signal
        let hostStorageBlocked = storageBlocked || session.record.state == .storageBlocked
        session.record.storageHealth = hostStorageBlocked ? "blocked" : "healthy"
        if hostStorageBlocked {
            // Host-side storage remains blocked until a subsequent append
            // succeeds. A healthy guest spool alone cannot clear that state.
            session.record.state = .storageBlocked
        }
        else if exited && outputComplete,
                let outputLength,
                session.record.transcriptOffset >= outputLength {
            // Guest completion only describes the guest spool. The helper
            // cannot close the durable session until its own transcript has
            // caught up to that spool length, or the final bytes can be lost
            // when the next pump iteration observes `.exited`.
            session.record.state = .exited
        }
        else if session.attachedToken != nil { session.record.state = .attached }
        else { session.record.state = .detached }
        session.record.updatedAt = Date()
        sessions[id] = session
        try persist(id)
    }

    func markAllLost(reason: String) {
        for id in sessions.keys {
            guard var session = sessions[id], ![.exited, .lost].contains(session.record.state) else { continue }
            session.attachedToken = nil
            session.record.state = .lost
            session.record.attachmentState = "detached"
            session.record.lossReason = reason
            session.record.updatedAt = Date()
            sessions[id] = session
            try? persist(id)
        }
    }

    func logs(_ id: UUID, from offset: UInt64?) throws -> (PommeDurableTerminalRecord, Data) {
        let record = try inspect(id)
        let cursor = try validatedCursor(offset ?? 0, length: record.transcriptOffset)
        return (record, try read(id, from: cursor, maximumBytes: PommeControlProtocol.maximumStreamChunkBytes))
    }

    func delete(_ id: UUID) throws {
        guard let session = sessions[id] else { throw PommeDurableTerminalError.notFound }
        guard [.exited, .lost].contains(session.record.state) else { throw PommeDurableTerminalError.invalidState }
        if let raw = session.rawURL, FileManager.default.fileExists(atPath: raw.path) {
            try FileManager.default.removeItem(at: raw)
        }
        if let metadata = session.metadataURL, FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
        sessions.removeValue(forKey: id)
        mutationSequences.removeValue(forKey: id)
    }

    func nextMutationSequence(for id: UUID) throws -> UInt64 {
        guard sessions[id] != nil else { throw PommeDurableTerminalError.notFound }
        return (mutationSequences[id] ?? 0) + 1
    }

    func commitMutationSequence(_ id: UUID, sequence: UInt64) throws {
        guard sessions[id] != nil,
              sequence == (mutationSequences[id] ?? 0) + 1
        else { throw PommeDurableTerminalError.invalidState }
        mutationSequences[id] = sequence
    }

    private func validatedCursor(_ offset: UInt64, length: UInt64) throws -> UInt64 {
        guard offset <= length else { throw PommeDurableTerminalError.invalidOffset }
        return offset
    }

    private func normalPaths(for id: UUID) throws -> (raw: URL?, metadata: URL?) {
        if role == .recovery { return (nil, nil) }
        guard let rootURL else { throw PommeDurableTerminalError.storageBlocked }
        guard Self.isPrivateDirectory(rootURL) else { throw PommeDurableTerminalError.storageBlocked }
        return (
            rootURL.appendingPathComponent("\(id.uuidString.lowercased()).raw"),
            rootURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
        )
    }

    private func persist(_ id: UUID) throws {
        guard role == .normal, let session = sessions[id], let metadata = session.metadataURL else { return }
        let data = try JSONEncoder.pommeStable.encode(session.record)
        let temporary = metadata.appendingPathExtension("tmp-\(UUID().uuidString.lowercased())")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PommeDurableTerminalError.storageBlocked }
        do {
            try Self.writeAll(data, descriptor: descriptor)
            guard fsync(descriptor) == 0 else { throw PommeDurableTerminalError.storageBlocked }
            _ = Darwin.close(descriptor)
            guard Darwin.rename(temporary.path, metadata.path) == 0 else { try throwPOSIX("rename terminal metadata") }
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func loadNormalSessions(from root: URL, currentGeneration: UUID) -> [UUID: Session] {
        var loaded: [UUID: Session] = [:]
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for metadata in entries where metadata.pathExtension == "json" {
            guard isPrivateRegularFile(metadata) else { continue }
            guard let data = try? Data(contentsOf: metadata),
                  let record = try? JSONDecoder().decode(PommeDurableTerminalRecord.self, from: data),
                  let id = UUID(uuidString: record.sessionID)
            else { continue }
            var stale = record
            if ![.exited, .lost].contains(stale.state), stale.bootGeneration != currentGeneration.uuidString.lowercased() {
                stale.state = .lost
                stale.lossReason = "helper-exited"
                stale.attachmentState = "detached"
                stale.updatedAt = Date()
            }
            let raw = metadata.deletingPathExtension().appendingPathExtension("raw")
            let rawIsSafe = isPrivateRegularFile(raw)
            let transcript = rawIsSafe ? ((try? Data(contentsOf: raw)) ?? Data()) : Data()
            if !rawIsSafe {
                stale.state = .storageBlocked
                stale.storageHealth = "blocked"
            } else if UInt64(transcript.count) < stale.transcriptOffset {
                stale.state = .storageBlocked
                stale.storageHealth = "blocked"
            } else if UInt64(transcript.count) > stale.transcriptOffset {
                // The raw append is authoritative if a helper stopped after
                // writing bytes but before replacing metadata. Preserve those
                // bytes and resume from their actual end.
                stale.transcriptOffset = UInt64(transcript.count)
            }
            loaded[id] = Session(record: stale, transcript: transcript, rawURL: raw, metadataURL: metadata)
        }
        return loaded
    }

    private static func preparePrivateDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard Darwin.chmod(url.path, S_IRWXU) == 0, isPrivateDirectory(url) else {
            throw PommeDurableTerminalError.storageBlocked
        }
        return url
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid()
            && info.st_mode & 0o077 == 0
    }

    private static func isPrivateRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && info.st_mode & S_IFMT == S_IFREG
            && info.st_uid == geteuid()
            && info.st_mode & 0o077 == 0
            && info.st_nlink == 1
    }

    private static func key(for path: String) -> String {
        String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { throw PommeDurableTerminalError.storageBlocked }
        }
    }

    private static func fileSize(descriptor: Int32) throws -> UInt64 {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else {
            throw PommeDurableTerminalError.storageBlocked
        }
        return UInt64(info.st_size)
    }

    private static func fileSize(rawURL: URL) throws -> UInt64 {
        let descriptor = Darwin.open(rawURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PommeDurableTerminalError.storageBlocked }
        defer { _ = Darwin.close(descriptor) }
        return try fileSize(descriptor: descriptor)
    }

    private static func read(descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw PommeDurableTerminalError.invalidOffset }
        var bytes = [UInt8](repeating: 0, count: count)
        while true {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(descriptor, buffer.baseAddress, count, off_t(offset))
            }
            if result >= 0 { return Data(bytes.prefix(Int(result))) }
            if errno == EINTR { continue }
            throw PommeDurableTerminalError.storageBlocked
        }
    }
}

private extension JSONEncoder {
    static var pommeStable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
