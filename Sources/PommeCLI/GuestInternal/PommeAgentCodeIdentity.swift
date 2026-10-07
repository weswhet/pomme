import Darwin
import Foundation

/// The kernel's record of the running agent's code signature.
///
/// The kernel validates the code directory of a signed executable when it
/// runs it, and terminates a process with hard and kill enforcement if a page
/// later fails validation. The code directory hash (CDHash) therefore
/// identifies the code that is actually running, not merely the file at the
/// executable's path.
struct PommeAgentCodeIdentity: Equatable, Sendable {
    let status: UInt32
    let cdhash: String

    // Code-signing status flags from xnu's cs_blobs.h.
    static let valid: UInt32 = 0x0000_0001
    static let adhoc: UInt32 = 0x0000_0002
    static let getTaskAllow: UInt32 = 0x0000_0004
    static let invalidAllowed: UInt32 = 0x0000_0020
    static let hard: UInt32 = 0x0000_0100
    static let kill: UInt32 = 0x0000_0200
    static let enforcement: UInt32 = 0x0000_1000
    static let runtime: UInt32 = 0x0001_0000
    static let linkerSigned: UInt32 = 0x0002_0000
    static let debugged: UInt32 = 0x1000_0000
    static let signed: UInt32 = 0x2000_0000

    static let requiredStatus = valid | hard | kill | enforcement | runtime | signed
    static let forbiddenStatus = adhoc | getTaskAllow | invalidAllowed | linkerSigned | debugged

    /// Pomme guests can run with AMFI relaxed, so a CDHash identifies the
    /// running code only while the kernel reports a valid, enforced,
    /// hardened, and non-ad-hoc signature for this process.
    var isEnforced: Bool {
        status & Self.requiredStatus == Self.requiredStatus && status & Self.forbiddenStatus == 0
    }

    private static let statusOperation: UInt32 = 0  // CS_OPS_STATUS
    private static let cdhashOperation: UInt32 = 5  // CS_OPS_CDHASH
    private static let cdhashLength = 20  // CS_CDHASH_LEN

    static func current() -> PommeAgentCodeIdentity? {
        let pid = getpid()
        var status: UInt32 = 0
        guard pommeCodeSigningOperation(pid, statusOperation, &status, MemoryLayout<UInt32>.size) == 0 else {
            return nil
        }
        var hash = [UInt8](repeating: 0, count: cdhashLength)
        let result = hash.withUnsafeMutableBytes {
            pommeCodeSigningOperation(pid, cdhashOperation, $0.baseAddress, $0.count)
        }
        guard result == 0 else { return nil }
        return .init(status: status, cdhash: hash.map { String(format: "%02x", $0) }.joined())
    }
}

/// A root-only record binding a verified SHA-256 digest to the CDHash of the
/// running code that produced it. The agent writes it only after it hashed
/// its executable, matched the digest that its LaunchDaemon pins, and the
/// kernel reported an enforced signature. A later launch whose pinned digest
/// and enforced CDHash both match can skip reading the executable.
///
/// The LaunchDaemon arguments are unchanged: launchd restarts an updated job
/// with the arguments it loaded at boot, and an older agent rejects any
/// argument it doesn't know. Older agents ignore this file, and a record for
/// a different digest or CDHash only means the full hash runs again.
struct PommeAgentVerifiedCodeRecord: Equatable, Sendable {
    let sha256: String
    let cdhash: String

    static let path = PommeAgentInstall.directory + "/agent-verified-code"

    init?(sha256: String, cdhash: String) {
        guard Self.isLowercaseHex(sha256, count: 64), Self.isLowercaseHex(cdhash, count: 40) else { return nil }
        self.sha256 = sha256
        self.cdhash = cdhash
    }

    var contents: Data { Data("\(sha256) \(cdhash)\n".utf8) }

    /// Returns nil for a missing, malformed, or unsafely owned record, so the
    /// caller falls back to hashing the executable.
    static func read(at url: URL, expectedOwner: uid_t) -> PommeAgentVerifiedCodeRecord? {
        guard let descriptor = try? PommeAgentFileTransaction.openRegular(url, flags: O_RDONLY) else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        let expectedSize = 64 + 1 + 40 + 1
        guard fstat(descriptor, &info) == 0,
              info.st_uid == expectedOwner,
              info.st_nlink == 1,
              info.st_mode & 0o077 == 0,
              info.st_size == off_t(expectedSize)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: expectedSize)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, expectedSize) }
        guard count == expectedSize, bytes.last == UInt8(ascii: "\n") else { return nil }
        let fields = String(decoding: bytes.dropLast(), as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        return PommeAgentVerifiedCodeRecord(sha256: String(fields[0]), cdhash: String(fields[1]))
    }

    /// Replaces the record atomically with a 0600 file in the same directory.
    func write(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: contents, attributes: [.posixPermissions: 0o600]
        ) else { throw PommeAgentProtocol.Error.invalidRequest }
        let descriptor = Darwin.open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        guard descriptor >= 0, fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw PommeAgentProtocol.Error.invalidRequest
        }
        try PommeAgentFileTransaction.fsyncDirectory(parent)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

@_silgen_name("csops")
private func pommeCodeSigningOperation(
    _ pid: pid_t,
    _ operation: UInt32,
    _ address: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int32
