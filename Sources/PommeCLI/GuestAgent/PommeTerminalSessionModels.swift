import Foundation

/// Versioned constants shared by the host helper and the CLI for durable
/// terminal sessions.  Recovery sessions use the same wire contract, but
/// never use the on-disk names below.
enum PommeTerminalSessionProtocol {
    static let name = "PommeTerminalSession"
    static let version = 1
    static let protocolVersion = version
    static let metadataFileName = "metadata.json"
    static let transcriptFileName = "transcript.raw"
}

enum PommeTerminalSessionRole: String, Codable, CaseIterable, Sendable {
    case normal
    case recovery

    var isPersistent: Bool {
        self == .normal
    }
}

typealias PommeTerminalSessionBootRole = PommeTerminalSessionRole

/// The state machine deliberately has no catch-all case.  A newer state is
/// therefore rejected by an older helper instead of being misinterpreted.
enum PommeTerminalSessionState: String, Codable, CaseIterable, Sendable {
    case created
    case starting
    case running
    case stopping
    case attached
    case detached
    case exited
    case lost
    case failed
    case storageBlocked = "storage-blocked"

    var isTerminal: Bool {
        switch self {
        case .exited, .lost, .failed:
            true
        case .created, .starting, .running, .stopping, .attached, .detached, .storageBlocked:
            false
        }
    }
}

enum PommeTerminalSessionAttachmentState: String, Codable, CaseIterable, Sendable {
    case detached
    case attaching
    case attached
    case detaching
}

enum PommeTerminalSessionStorageHealth: String, Codable, CaseIterable, Sendable {
    case healthy
    case blocked
    case degraded
    case unavailable
    case corrupt
}

enum PommeTerminalSessionError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case invalidOffset
    case invalidRange
    case invalidGeneration
    case invalidMutationSequence
    case invalidDigest
    case invalidExecutable
    case invalidMetadata
    case roleMismatch
    case recoveryCannotPersist
    case unsafePath
    case symbolicLink
    case notRegularFile
    case transcriptChanged
    case storageUnavailable
    case ioFailure

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "The terminal session identifier is invalid."
        case .invalidOffset:
            "The terminal transcript offset is invalid."
        case .invalidRange:
            "The terminal transcript offset range is invalid."
        case .invalidGeneration:
            "The terminal boot generation is invalid."
        case .invalidMutationSequence:
            "The terminal mutation sequence is invalid."
        case .invalidDigest:
            "The terminal mutation digest is not a lowercase SHA-256 value."
        case .invalidExecutable:
            "The terminal executable identity is invalid."
        case .invalidMetadata:
            "The terminal session metadata is invalid."
        case .roleMismatch:
            "The terminal session role does not match its store."
        case .recoveryCannotPersist:
            "Recovery terminal sessions are transient and cannot be persisted."
        case .unsafePath:
            "The terminal session store path is unsafe."
        case .symbolicLink:
            "The terminal session store refuses symbolic links."
        case .notRegularFile:
            "The terminal session store entry is not a regular file."
        case .transcriptChanged:
            "The terminal transcript changed outside the session store."
        case .storageUnavailable:
            "The terminal session store is unavailable."
        case .ioFailure:
            "The terminal session store could not complete the requested operation."
        }
    }
}

/// A non-negative byte position measured from the beginning of the raw
/// transcript.  It is intentionally not an Int: transcript positions are a
/// wire value and must not change width between a 32-bit helper and its host.
struct PommeTerminalSessionByteOffset: Codable, Comparable, Equatable, Hashable, Sendable {
    let rawValue: UInt64

    private init(unchecked value: UInt64) {
        rawValue = value
    }

    init(_ value: UInt64) throws {
        try Self.validate(value)
        self.init(unchecked: value)
    }

    init(fromStart value: UInt64) throws {
        try self.init(value)
    }

    init(fromStart value: Int) throws {
        guard value >= 0 else { throw PommeTerminalSessionError.invalidOffset }
        try self.init(UInt64(value))
    }

    static func fromStart(_ value: UInt64) throws -> Self {
        try Self(value)
    }

    static var zero: Self {
        Self(unchecked: 0)
    }

    var isAtStart: Bool {
        rawValue == 0
    }

    func advanced(by distance: UInt64) throws -> Self {
        guard rawValue <= UInt64.max - distance else {
            throw PommeTerminalSessionError.invalidOffset
        }
        return try Self(rawValue + distance)
    }

    func distance(from earlier: Self) throws -> UInt64 {
        guard earlier <= self else { throw PommeTerminalSessionError.invalidRange }
        return rawValue - earlier.rawValue
    }

    func index(in data: Data) throws -> Int {
        guard rawValue <= UInt64(Int.max), rawValue <= UInt64(data.count) else {
            throw PommeTerminalSessionError.invalidOffset
        }
        return Int(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(UInt64.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func validate(_ value: UInt64) throws {
        // The UInt64 representation already rejects negative values.  This
        // validation hook keeps all construction paths visibly checked and
        // leaves room for a protocol maximum without changing the wire type.
        _ = value
    }
}

typealias PommeTerminalSessionTranscriptOffset = PommeTerminalSessionByteOffset

struct PommeTerminalSessionTranscriptOffsets: Codable, Equatable, Sendable {
    let start: PommeTerminalSessionByteOffset
    let end: PommeTerminalSessionByteOffset

    init(
        start: PommeTerminalSessionByteOffset = .zero,
        end: PommeTerminalSessionByteOffset = .zero
    ) throws {
        guard start <= end else { throw PommeTerminalSessionError.invalidRange }
        self.start = start
        self.end = end
    }

    static var empty: Self {
        // Both values are produced by the checked zero constructor.
        try! Self()
    }

    var byteCount: UInt64 {
        end.rawValue - start.rawValue
    }

    var next: PommeTerminalSessionByteOffset {
        end
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case start
        case end
    }

    init(from decoder: Decoder) throws {
        try PommeTerminalSessionCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(PommeTerminalSessionByteOffset.self, forKey: .start)
        let end = try container.decode(PommeTerminalSessionByteOffset.self, forKey: .end)
        guard start <= end else { throw PommeTerminalSessionError.invalidRange }
        self.start = start
        self.end = end
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}

struct PommeTerminalSessionProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int64
    let startTime: Date

    init(pid: Int64, startTime: Date) throws {
        guard pid > 0, startTime.timeIntervalSince1970.isFinite else {
            throw PommeTerminalSessionError.invalidMetadata
        }
        self.pid = pid
        self.startTime = startTime
    }

    init(pid: Int32, startTime: Date) throws {
        try self.init(pid: Int64(pid), startTime: startTime)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pid
        case startTime
    }

    init(from decoder: Decoder) throws {
        try PommeTerminalSessionCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pid = try container.decode(Int32.self, forKey: .pid)
        let startTime = try container.decode(Date.self, forKey: .startTime)
        try self.init(pid: pid, startTime: startTime)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(startTime, forKey: .startTime)
    }
}

/// The single inspection payload shared by status, attach, and resume.  The
/// custom decoder rejects unknown keys, making this a closed contract even
/// when an older helper receives a newer record.
struct PommeTerminalSessionInspection: Codable, Equatable, Sendable {
    let sessionID: UUID
    let bootRole: PommeTerminalSessionRole
    let bootGeneration: UInt64
    let state: PommeTerminalSessionState
    let processIdentity: PommeTerminalSessionProcessIdentity?
    let executable: String?
    let createdAt: Date
    let startedAt: Date?
    let updatedAt: Date
    let endedAt: Date?
    let attachmentState: PommeTerminalSessionAttachmentState
    let transcriptOffsets: PommeTerminalSessionTranscriptOffsets
    let exitStatus: Int32?
    let lossReason: String?
    let storageHealth: PommeTerminalSessionStorageHealth

    init(
        sessionID: UUID,
        bootRole: PommeTerminalSessionRole,
        bootGeneration: UInt64,
        state: PommeTerminalSessionState,
        processIdentity: PommeTerminalSessionProcessIdentity? = nil,
        executable: String? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        updatedAt: Date,
        endedAt: Date? = nil,
        attachmentState: PommeTerminalSessionAttachmentState,
        transcriptOffsets: PommeTerminalSessionTranscriptOffsets = .empty,
        exitStatus: Int32? = nil,
        lossReason: String? = nil,
        storageHealth: PommeTerminalSessionStorageHealth
    ) throws {
        try Self.validate(
            sessionID: sessionID,
            bootGeneration: bootGeneration,
            processIdentity: processIdentity,
            executable: executable,
            createdAt: createdAt,
            startedAt: startedAt,
            updatedAt: updatedAt,
            endedAt: endedAt,
            transcriptOffsets: transcriptOffsets,
            exitStatus: exitStatus,
            lossReason: lossReason
        )
        self.sessionID = sessionID
        self.bootRole = bootRole
        self.bootGeneration = bootGeneration
        self.state = state
        self.processIdentity = processIdentity
        self.executable = executable
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.attachmentState = attachmentState
        self.transcriptOffsets = transcriptOffsets
        self.exitStatus = exitStatus
        self.lossReason = lossReason
        self.storageHealth = storageHealth
    }

    var transcriptStartOffset: PommeTerminalSessionByteOffset {
        transcriptOffsets.start
    }

    var transcriptEndOffset: PommeTerminalSessionByteOffset {
        transcriptOffsets.end
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID
        case bootRole
        case bootGeneration
        case state
        case processIdentity
        case executable
        case createdAt
        case startedAt
        case updatedAt
        case endedAt
        case attachmentState
        case transcriptOffsets
        case exitStatus
        case lossReason
        case storageHealth
    }

    init(from decoder: Decoder) throws {
        try PommeTerminalSessionCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionID = try container.decode(UUID.self, forKey: .sessionID)
        let bootRole = try container.decode(PommeTerminalSessionRole.self, forKey: .bootRole)
        let bootGeneration = try container.decode(UInt64.self, forKey: .bootGeneration)
        let state = try container.decode(PommeTerminalSessionState.self, forKey: .state)
        let processIdentity = try container.decodeIfPresent(
            PommeTerminalSessionProcessIdentity.self,
            forKey: .processIdentity
        )
        let executable = try container.decodeIfPresent(String.self, forKey: .executable)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        let attachmentState = try container.decode(
            PommeTerminalSessionAttachmentState.self,
            forKey: .attachmentState
        )
        let transcriptOffsets = try container.decode(
            PommeTerminalSessionTranscriptOffsets.self,
            forKey: .transcriptOffsets
        )
        let exitStatus = try container.decodeIfPresent(Int32.self, forKey: .exitStatus)
        let lossReason = try container.decodeIfPresent(String.self, forKey: .lossReason)
        let storageHealth = try container.decode(
            PommeTerminalSessionStorageHealth.self,
            forKey: .storageHealth
        )

        try Self.validate(
            sessionID: sessionID,
            bootGeneration: bootGeneration,
            processIdentity: processIdentity,
            executable: executable,
            createdAt: createdAt,
            startedAt: startedAt,
            updatedAt: updatedAt,
            endedAt: endedAt,
            transcriptOffsets: transcriptOffsets,
            exitStatus: exitStatus,
            lossReason: lossReason
        )
        self.sessionID = sessionID
        self.bootRole = bootRole
        self.bootGeneration = bootGeneration
        self.state = state
        self.processIdentity = processIdentity
        self.executable = executable
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.attachmentState = attachmentState
        self.transcriptOffsets = transcriptOffsets
        self.exitStatus = exitStatus
        self.lossReason = lossReason
        self.storageHealth = storageHealth
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(bootRole, forKey: .bootRole)
        try container.encode(bootGeneration, forKey: .bootGeneration)
        try container.encode(state, forKey: .state)
        try container.encode(processIdentity, forKey: .processIdentity)
        try container.encode(executable, forKey: .executable)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(attachmentState, forKey: .attachmentState)
        try container.encode(transcriptOffsets, forKey: .transcriptOffsets)
        try container.encode(exitStatus, forKey: .exitStatus)
        try container.encode(lossReason, forKey: .lossReason)
        try container.encode(storageHealth, forKey: .storageHealth)
    }

    private static func validate(
        sessionID: UUID,
        bootGeneration: UInt64,
        processIdentity: PommeTerminalSessionProcessIdentity?,
        executable: String?,
        createdAt: Date,
        startedAt: Date?,
        updatedAt: Date,
        endedAt: Date?,
        transcriptOffsets: PommeTerminalSessionTranscriptOffsets,
        exitStatus: Int32?,
        lossReason: String?
    ) throws {
        _ = sessionID
        _ = bootGeneration
        guard createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              startedAt?.timeIntervalSince1970.isFinite ?? true,
              endedAt?.timeIntervalSince1970.isFinite ?? true
        else { throw PommeTerminalSessionError.invalidMetadata }
        if let executable {
            guard !executable.isEmpty,
                  executable.utf8.count <= 4 * 1024,
                  !executable.contains("\0")
            else { throw PommeTerminalSessionError.invalidExecutable }
        }
        if let exitStatus, exitStatus < 0 {
            throw PommeTerminalSessionError.invalidMetadata
        }
        if let lossReason {
            guard !lossReason.isEmpty,
                  lossReason.utf8.count <= 512,
                  !lossReason.contains("\0")
            else { throw PommeTerminalSessionError.invalidMetadata }
        }
        _ = processIdentity
        _ = transcriptOffsets
    }
}

/// A mutation's identity is the sequence number plus the digest of its
/// canonical payload.  Replaying the same identity is safe; reusing a
/// sequence for different bytes is not.
struct PommeTerminalSessionMutation: Codable, Equatable, Sendable {
    let sequence: UInt64
    let payloadSHA256: String

    init(sequence: UInt64, payloadSHA256: String) throws {
        guard PommeTerminalSessionMutationSupport.isSHA256(payloadSHA256) else {
            throw PommeTerminalSessionError.invalidDigest
        }
        self.sequence = sequence
        self.payloadSHA256 = payloadSHA256
    }

    init<T: Encodable>(sequence: UInt64, payload: T) throws {
        try self.init(
            sequence: sequence,
            payloadSHA256: PommeTerminalSessionMutationSupport.payloadSHA256(payload)
        )
    }

    var payloadDigest: String {
        payloadSHA256
    }

    var idempotencyKey: String {
        "\(sequence):\(payloadSHA256)"
    }

    func matches<T: Encodable>(sequence: UInt64, payload: T) throws -> Bool {
        guard sequence == self.sequence else { return false }
        let digest = try PommeTerminalSessionMutationSupport.payloadSHA256(payload)
        return payloadSHA256 == digest
    }

    static func canonicalPayload<T: Encodable>(_ payload: T) throws -> Data {
        try PommeTerminalSessionMutationSupport.canonicalPayload(payload)
    }

    static func payloadSHA256<T: Encodable>(for payload: T) throws -> String {
        try PommeTerminalSessionMutationSupport.payloadSHA256(payload)
    }

    static func idempotencyKey<T: Encodable>(sequence: UInt64, payload: T) throws -> String {
        try Self(sequence: sequence, payload: payload).idempotencyKey
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sequence
        case payloadSHA256
    }

    init(from decoder: Decoder) throws {
        try PommeTerminalSessionCoding.requireExactKeys(
            decoder,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(UInt64.self, forKey: .sequence),
            payloadSHA256: container.decode(String.self, forKey: .payloadSHA256)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(payloadSHA256, forKey: .payloadSHA256)
    }
}

enum PommeTerminalSessionMutationSupport {
    static func canonicalPayload<T: Encodable>(_ payload: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    static func payloadSHA256<T: Encodable>(_ payload: T) throws -> String {
        try sha256(canonicalPayload(payload))
    }

    static func idempotencyKey<T: Encodable>(sequence: UInt64, payload: T) throws -> String {
        try PommeTerminalSessionMutation(sequence: sequence, payload: payload).idempotencyKey
    }

    static func sha256(_ data: Data) -> String {
        PommeTerminalSessionSHA256.hexDigest(data)
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

/// A Foundation-only SHA-256 implementation keeps this contract usable by
/// both the host helper and the CLI without importing a project-specific
/// crypto wrapper or changing the wire digest representation.
private enum PommeTerminalSessionSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hexDigest(_ data: Data) -> String {
        var bytes = Array(data)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        bytes.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian) { Array($0) })

        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = chunkStart + index * 4
                words[index] = (UInt32(bytes[start]) << 24)
                    | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8)
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], 7)
                    ^ rotateRight(words[index - 15], 18)
                    ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], 17)
                    ^ rotateRight(words[index - 2], 19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let sigma1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ ((~e) & g)
                let temporary1 = h &+ sigma1 &+ choice &+ constants[index] &+ words[index]
                let sigma0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sigma0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

/// A normal session is rooted at <root>/<vm UUID>/<session UUID>.  Recovery
/// sessions use the same model but hold metadata and transcript bytes only in
/// memory; their path properties are nil and no filesystem operation is made.
final class PommeTerminalSessionStore: @unchecked Sendable {
    let role: PommeTerminalSessionRole
    let vmID: UUID?
    let sessionID: UUID

    private let lock = NSLock()
    private let directoryURL: URL?
    private let metadataURL: URL?
    private let transcriptURL: URL?
    private var transientMetadata: PommeTerminalSessionInspection?
    private var transientTranscript = Data()

    var isPersistent: Bool {
        role.isPersistent
    }

    /// Creates a normal persistent store.  Passing `.recovery` intentionally
    /// creates the transient variant and never touches rootURL.
    init(
        rootURL: URL,
        vmID: UUID,
        sessionID: UUID,
        role: PommeTerminalSessionRole = .normal
    ) throws {
        self.role = role
        self.vmID = vmID
        self.sessionID = sessionID
        self.transientMetadata = nil

        guard role == .normal else {
            self.directoryURL = nil
            self.metadataURL = nil
            self.transcriptURL = nil
            return
        }

        try Self.validateDirectoryPath(rootURL)
        let root = rootURL.standardizedFileURL
        let vmDirectory = root.appendingPathComponent(vmID.uuidString.lowercased(), isDirectory: true)
        let sessionDirectory = vmDirectory.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
        try Self.ensureDirectoryChain(sessionDirectory)

        let metadata = sessionDirectory.appendingPathComponent(
            PommeTerminalSessionProtocol.metadataFileName,
            isDirectory: false
        )
        let transcript = sessionDirectory.appendingPathComponent(
            PommeTerminalSessionProtocol.transcriptFileName,
            isDirectory: false
        )
        self.directoryURL = sessionDirectory
        self.metadataURL = metadata
        self.transcriptURL = transcript
        try Self.ensureRegularFile(at: transcript, createIfMissing: true)
    }

    /// Creates a transient Recovery store.  It has no root URL and cannot
    /// accidentally persist a Recovery inspection or transcript.
    init(
        recoverySessionID: UUID,
        vmID: UUID? = nil,
        initialMetadata: PommeTerminalSessionInspection? = nil
    ) throws {
        self.role = .recovery
        self.vmID = vmID
        self.sessionID = recoverySessionID
        self.directoryURL = nil
        self.metadataURL = nil
        self.transcriptURL = nil
        self.transientMetadata = nil
        if let initialMetadata {
            guard initialMetadata.sessionID == recoverySessionID,
                  initialMetadata.bootRole == .recovery
            else { throw PommeTerminalSessionError.roleMismatch }
            self.transientMetadata = initialMetadata
        }
    }

    static func normal(rootURL: URL, vmID: UUID, sessionID: UUID) throws -> Self {
        try Self(rootURL: rootURL, vmID: vmID, sessionID: sessionID, role: .normal)
    }

    static func transient(
        sessionID: UUID,
        vmID: UUID? = nil,
        initialMetadata: PommeTerminalSessionInspection? = nil
    ) throws -> Self {
        try Self(
            recoverySessionID: sessionID,
            vmID: vmID,
            initialMetadata: initialMetadata
        )
    }

    var persistentDirectoryURL: URL? {
        directoryURL
    }

    func loadMetadata() throws -> PommeTerminalSessionInspection? {
        lock.lock()
        defer { lock.unlock() }

        guard isPersistent else { return transientMetadata }
        guard let metadataURL, let directoryURL else {
            throw PommeTerminalSessionError.storageUnavailable
        }
        try Self.ensureDirectoryChain(directoryURL)
        try Self.rejectSymbolicLink(at: metadataURL)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        try Self.ensureRegularFile(at: metadataURL, createIfMissing: false)
        do {
            let data = try Data(contentsOf: metadataURL)
            let inspection = try JSONDecoder().decode(
                PommeTerminalSessionInspection.self,
                from: data
            )
            try validate(inspection)
            return inspection
        } catch let error as PommeTerminalSessionError {
            throw error
        } catch {
            throw PommeTerminalSessionError.invalidMetadata
        }
    }

    func saveMetadata(_ inspection: PommeTerminalSessionInspection) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(inspection)

        guard inspection.sessionID == sessionID,
              inspection.bootRole == role
        else { throw PommeTerminalSessionError.roleMismatch }

        guard isPersistent else {
            transientMetadata = inspection
            return
        }
        guard let directoryURL, let metadataURL else {
            throw PommeTerminalSessionError.storageUnavailable
        }
        try Self.ensureDirectoryChain(directoryURL)
        try Self.writeMetadataAtomically(inspection, to: metadataURL)
    }

    func append(_ bytes: Data) throws -> PommeTerminalSessionByteOffset {
        lock.lock()
        defer { lock.unlock() }

        guard !bytes.isEmpty else { return try currentOffsetLocked() }
        guard isPersistent else {
            let start = try PommeTerminalSessionByteOffset.fromStart(UInt64(transientTranscript.count))
            transientTranscript.append(bytes)
            return start
        }
        guard let directoryURL, let transcriptURL else {
            throw PommeTerminalSessionError.storageUnavailable
        }
        try Self.ensureDirectoryChain(directoryURL)
        try Self.ensureRegularFile(at: transcriptURL, createIfMissing: true)
        let expected = try Self.fileSize(at: transcriptURL)
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: transcriptURL)
        } catch {
            throw PommeTerminalSessionError.storageUnavailable
        }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            guard end == expected else { throw PommeTerminalSessionError.transcriptChanged }
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch let error as PommeTerminalSessionError {
            throw error
        } catch {
            throw PommeTerminalSessionError.ioFailure
        }
        let finalSize = try Self.fileSize(at: transcriptURL)
        guard finalSize == expected + UInt64(bytes.count) else {
            throw PommeTerminalSessionError.transcriptChanged
        }
        return try PommeTerminalSessionByteOffset.fromStart(expected)
    }

    func appendTranscript(_ bytes: Data) throws -> PommeTerminalSessionByteOffset {
        try append(bytes)
    }

    func read(
        from offset: PommeTerminalSessionByteOffset,
        upTo count: Int
    ) throws -> Data {
        guard count >= 0 else { throw PommeTerminalSessionError.invalidOffset }
        lock.lock()
        defer { lock.unlock() }

        if !isPersistent {
            let start = try offset.index(in: transientTranscript)
            let length = min(count, transientTranscript.count - start)
            return transientTranscript.subdata(in: start..<(start + length))
        }
        guard let directoryURL, let transcriptURL else {
            throw PommeTerminalSessionError.storageUnavailable
        }
        try Self.ensureDirectoryChain(directoryURL)
        try Self.ensureRegularFile(at: transcriptURL, createIfMissing: true)
        let size = try Self.fileSize(at: transcriptURL)
        guard offset.rawValue <= size else { throw PommeTerminalSessionError.invalidOffset }
        do {
            let handle = try FileHandle(forReadingFrom: transcriptURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset.rawValue)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw PommeTerminalSessionError.ioFailure
        }
    }

    func readTranscript(
        from offset: PommeTerminalSessionByteOffset,
        upTo count: Int
    ) throws -> Data {
        try read(from: offset, upTo: count)
    }

    func currentOffset() throws -> PommeTerminalSessionByteOffset {
        lock.lock()
        defer { lock.unlock() }
        return try currentOffsetLocked()
    }

    private func currentOffsetLocked() throws -> PommeTerminalSessionByteOffset {
        if !isPersistent {
            return try PommeTerminalSessionByteOffset.fromStart(UInt64(transientTranscript.count))
        }
        guard let directoryURL, let transcriptURL else {
            throw PommeTerminalSessionError.storageUnavailable
        }
        try Self.ensureDirectoryChain(directoryURL)
        try Self.ensureRegularFile(at: transcriptURL, createIfMissing: true)
        return try PommeTerminalSessionByteOffset.fromStart(Self.fileSize(at: transcriptURL))
    }

    private func validate(_ inspection: PommeTerminalSessionInspection) throws {
        guard inspection.sessionID == sessionID,
              inspection.bootRole == role
        else { throw PommeTerminalSessionError.roleMismatch }
    }

    private static func writeMetadataAtomically(
        _ inspection: PommeTerminalSessionInspection,
        to url: URL
    ) throws {
        try ensureRegularFile(at: url, createIfMissing: false, allowMissing: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(inspection)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            throw PommeTerminalSessionError.ioFailure
        }
        try ensureRegularFile(at: url, createIfMissing: false)
    }

    private static func ensureRegularFile(
        at url: URL,
        createIfMissing: Bool,
        allowMissing: Bool = false
    ) throws {
        try validateFilePath(url)
        try rejectSymbolicLink(at: url)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            guard createIfMissing else {
                if allowMissing { return }
                throw PommeTerminalSessionError.storageUnavailable
            }
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else { throw PommeTerminalSessionError.storageUnavailable }
        }
        try rejectSymbolicLink(at: url)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular
        else { throw PommeTerminalSessionError.notRegularFile }
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        try ensureRegularFile(at: url, createIfMissing: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber
        else { throw PommeTerminalSessionError.storageUnavailable }
        return value.uint64Value
    }

    private static func validateDirectoryPath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw PommeTerminalSessionError.unsafePath
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else {
            throw PommeTerminalSessionError.unsafePath
        }
    }

    private static func validateFilePath(_ url: URL) throws {
        try validateDirectoryPath(url)
        guard !url.path.hasSuffix("/") else { throw PommeTerminalSessionError.unsafePath }
    }

    private static func rejectSymbolicLink(at url: URL) throws {
        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw PommeTerminalSessionError.symbolicLink
        }
        if let symbolic = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
           symbolic == true
        {
            throw PommeTerminalSessionError.symbolicLink
        }
    }

    private static func ensureDirectoryChain(_ url: URL) throws {
        try validateDirectoryPath(url)
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let fileManager = FileManager.default
        for component in components {
            current.appendPathComponent(String(component), isDirectory: true)
            try rejectSymbolicLink(at: current)
            if fileManager.fileExists(atPath: current.path) {
                guard let values = try? current.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true
                else { throw PommeTerminalSessionError.notRegularFile }
            } else {
                do {
                    try fileManager.createDirectory(
                        at: current,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: NSNumber(value: 0o700)]
                    )
                } catch {
                    try rejectSymbolicLink(at: current)
                    guard fileManager.fileExists(atPath: current.path) else {
                        throw PommeTerminalSessionError.storageUnavailable
                    }
                }
                try rejectSymbolicLink(at: current)
            }
        }
    }
}

private enum PommeTerminalSessionCoding {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func requireExactKeys(
        _ decoder: Decoder,
        allowed: [String]
    ) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(allowed) else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyCodingKey(stringValue: "contract")!,
                in: container,
                debugDescription: "Unknown or missing terminal session fields."
            )
        }
    }
}
