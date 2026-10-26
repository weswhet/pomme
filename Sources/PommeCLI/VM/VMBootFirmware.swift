import Darwin
import Foundation
import os

/// Reads and repairs the boot firmware that a macOS VM keeps in its auxiliary
/// storage, without Virtualization.framework.
///
/// Apple doesn't document this layout; Pomme relies only on what it has
/// observed. A restore writes the firmware, an IMG4 whose payload type is
/// `illb` (the low-level bootloader, such as `mBoot-18000.161.10`), into slot
/// A at 0x24000, and a `HUFA` header at 0x4000 that selects it. A software
/// update in the guest writes its firmware into the other slot (B, at
/// 0x224000) and a second header at 0x5000 with a higher generation, which
/// then selects slot B. The header with the highest generation is active.
///
/// The macOS 26.7 and 15.8 updates install the macOS 27 firmware
/// (`mBoot-20457.1.29`). Under it a macOS 26 or earlier guest gets about
/// 1.75 GiB of memory, the update's first boot never finishes, and Recovery,
/// whose root is a RAM disk, can't start (FB24791716). Copying the slot that
/// still holds the install-time firmware over the active slot restores the
/// VM; nothing else in the file changes.
enum VMBootFirmware {
    static let headerOffsets = [0x4000, 0x5000]
    static let headerLength = 0x1000
    /// A header's slot field is relative to this offset.
    static let slotBase = 0x4000
    static let slotOffsets = [0x24000, 0x224000]
    static let slotLength = 0x20_0000
    static let minimumFileLength = 0x224000 + slotLength
    /// The first firmware train that the macOS 27 releases ship. Earlier
    /// macOS releases can't use their memory under it.
    static let macOS27FirmwareTrain = 20457
    private static let maximumFileLength = 256 * 1_024 * 1_024
    private static let magic = Data("HUFA".utf8)

    struct Header: Equatable, Sendable {
        let offset: Int
        let generation: UInt32
        let slotOffset: Int
    }

    struct Slot: Equatable, Sendable {
        let offset: Int
        /// The firmware's version string, or nil when the slot doesn't start
        /// with a recognizable `illb` IMG4.
        let version: String?
        let empty: Bool

        var name: String { offset == VMBootFirmware.slotOffsets[0] ? "A" : "B" }
        var train: Int? { version.flatMap(VMBootFirmware.train(of:)) }
    }

    enum Status: String, Sendable {
        /// Only the firmware that the restore installed.
        case original
        /// A guest update replaced the firmware with one Pomme has no reason to doubt.
        case updated
        /// A guest update replaced firmware older than the macOS 27 train
        /// with the macOS 27 train.
        case incompatibleUpdate = "incompatible-update"
        /// The file doesn't match the layout above.
        case unrecognized
    }

    struct Inspection: Equatable, Sendable {
        let headers: [Header]
        let slots: [Slot]
        let active: Slot?
        let activeGeneration: UInt32?
        /// The slot that the active one replaced: the install-time firmware
        /// after the first guest update.
        let fallback: Slot?
        let status: Status

        var repairable: Bool { status == .incompatibleUpdate }

        var payload: [String: Any] {
            [
                "status": status.rawValue,
                "activeSlot": active?.name as Any? ?? NSNull(),
                "activeGeneration": activeGeneration.map { Int($0) as Any } ?? NSNull(),
                "activeVersion": active?.version as Any? ?? NSNull(),
                "fallbackVersion": fallback?.version as Any? ?? NSNull(),
                "repairable": repairable,
                "slots": slots.map { slot in
                    ["slot": slot.name, "version": slot.version as Any? ?? NSNull(), "empty": slot.empty] as [String: Any]
                }
            ]
        }
    }

    /// What the guest reports about itself, read through the Pomme agent.
    struct GuestReport: Equatable, Sendable {
        let memoryBytes: UInt64
        let usableMemoryBytes: UInt64
        let macOSVersion: String

        var macOSMajorVersion: Int? { macOSVersion.split(separator: ".").first.flatMap { Int($0) } }
        /// A healthy guest loses a few megabytes to the booter; the
        /// incompatible firmware leaves 1792 MiB at any memory size.
        var memoryLimited: Bool { usableMemoryBytes < memoryBytes / 10 * 9 }

        /// The guest command that produces the report.
        static let command = (path: "/usr/sbin/sysctl", arguments: ["-n", "hw.memsize", "hw.memsize_usable", "kern.osproductversion"])

        init(memoryBytes: UInt64, usableMemoryBytes: UInt64, macOSVersion: String) {
            self.memoryBytes = memoryBytes
            self.usableMemoryBytes = usableMemoryBytes
            self.macOSVersion = macOSVersion
        }

        /// Parses the output of `command`: one value per line, in order.
        init?(sysctlOutput: String) {
            let lines = sysctlOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count == 3, let memory = UInt64(lines[0]), let usable = UInt64(lines[1]), memory > 0,
                  lines[2].range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
            else { return nil }
            self.init(memoryBytes: memory, usableMemoryBytes: usable, macOSVersion: lines[2])
        }

        var payload: [String: Any] {
            [
                "checked": true,
                "macOSVersion": macOSVersion,
                "memoryBytes": memoryBytes,
                "usableMemoryBytes": usableMemoryBytes,
                "memoryLimited": memoryLimited
            ]
        }
    }

    enum Diagnosis: String, Sendable {
        case affected
        case likelyAffected = "likely-affected"
        case notAffected = "not-affected"
        case unknown
    }

    /// The guest's own report outranks the file: a guest that upgraded to
    /// macOS 27 legitimately runs the macOS 27 firmware.
    static func diagnosis(_ inspection: Inspection, guest: GuestReport?) -> Diagnosis {
        switch inspection.status {
        case .unrecognized: return .unknown
        case .original, .updated: return .notAffected
        case .incompatibleUpdate:
            guard let guest else { return .likelyAffected }
            if let major = guest.macOSMajorVersion, major >= 27 { return .notAffected }
            return guest.memoryLimited ? .affected : .notAffected
        }
    }

    static func train(of version: String) -> Int? {
        guard let dash = version.firstIndex(of: "-") else { return nil }
        let digits = version[version.index(after: dash)...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: Reading

    static func inspect(url: URL) throws -> Inspection {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RunnerError.posix(function: "open auxiliary storage", code: errno) }
        defer { _ = Darwin.close(descriptor) }
        let inspection = inspect(data: try read(descriptor, length: minimumFileLength))
        log(inspection, context: "inspected \(url.path)")
        return inspection
    }

    private static func log(_ inspection: Inspection, context: String) {
        PommeUnifiedLog.firmware.info("""
            \(context, privacy: .public): status=\(inspection.status.rawValue, privacy: .public) \
            activeSlot=\(inspection.active?.name ?? "none", privacy: .public) \
            activeVersion=\(inspection.active?.version ?? "none", privacy: .public) \
            fallbackVersion=\(inspection.fallback?.version ?? "none", privacy: .public)
            """)
    }

    static func inspect(data: Data) -> Inspection {
        let bytes = [UInt8](data.prefix(minimumFileLength))
        let unrecognized = Inspection(headers: [], slots: [], active: nil, activeGeneration: nil, fallback: nil, status: .unrecognized)
        guard bytes.count == minimumFileLength else { return unrecognized }

        var headers: [Header] = []
        for offset in headerOffsets {
            let page = bytes[offset ..< offset + headerLength]
            if page.allSatisfy({ $0 == 0 }) { continue }
            guard Data(page.prefix(4)) == magic, littleEndian(bytes, offset + 4) == 1 else { return unrecognized }
            let slot = slotBase + Int(littleEndian(bytes, offset + 12))
            guard slotOffsets.contains(slot) else { return unrecognized }
            headers.append(Header(offset: offset, generation: littleEndian(bytes, offset + 8), slotOffset: slot))
        }
        let slots = slotOffsets.map { offset in
            let region = bytes[offset ..< offset + slotLength]
            return Slot(offset: offset, version: firmwareVersion(region),
                        empty: region.prefix(headerLength).allSatisfy { $0 == 0 })
        }
        func slot(_ header: Header) -> Slot { slots.first { $0.offset == header.slotOffset }! }

        let ordered = headers.sorted { $0.generation > $1.generation }
        guard let newest = ordered.first, slot(newest).version != nil else {
            return Inspection(headers: headers, slots: slots, active: nil, activeGeneration: nil, fallback: nil, status: .unrecognized)
        }
        let active = slot(newest)
        guard ordered.count == 2 else {
            return Inspection(headers: headers, slots: slots, active: active, activeGeneration: newest.generation,
                              fallback: nil, status: .original)
        }
        let older = ordered[1]
        guard older.generation != newest.generation, older.slotOffset != newest.slotOffset else {
            return Inspection(headers: headers, slots: slots, active: nil, activeGeneration: nil, fallback: nil, status: .unrecognized)
        }
        let fallback = slot(older)
        var status = Status.updated
        if let activeTrain = active.train, let fallbackTrain = fallback.train,
           activeTrain >= macOS27FirmwareTrain, fallbackTrain < macOS27FirmwareTrain {
            status = .incompatibleUpdate
        }
        return Inspection(headers: headers, slots: slots, active: active, activeGeneration: newest.generation,
                          fallback: fallback, status: status)
    }

    /// Reads the version from the start of an IMG4:
    /// SEQUENCE { "IMG4", SEQUENCE { "IM4P", "illb", version, ... } ... }.
    private static func firmwareVersion(_ region: ArraySlice<UInt8>) -> String? {
        var cursor = region.startIndex
        func element(_ tag: UInt8) -> Range<Int>? {
            guard cursor + 2 <= region.endIndex, region[cursor] == tag else { return nil }
            let first = Int(region[cursor + 1])
            var start = cursor + 2
            var length = first
            if first & 0x80 != 0 {
                let count = first & 0x7F
                guard (1...4).contains(count), start + count <= region.endIndex else { return nil }
                length = region[start ..< start + count].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= region.endIndex else { return nil }
            return start ..< start + length
        }
        func string() -> String? {
            guard let range = element(0x16) else { return nil }
            cursor = range.upperBound
            return String(bytes: region[range], encoding: .ascii)
        }
        guard let outer = element(0x30) else { return nil }
        cursor = outer.lowerBound
        guard string() == "IMG4", let payload = element(0x30) else { return nil }
        cursor = payload.lowerBound
        guard string() == "IM4P", string() == "illb", let version = string(),
              version.range(of: #"^[A-Za-z]+Boot-[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
        else { return nil }
        return version
    }

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset ..< offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func read(_ descriptor: Int32, length: Int, at offset: off_t = 0) throws -> Data {
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < length {
                let result = pread(descriptor, buffer.baseAddress! + total, length - total, offset + off_t(total))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return result < 0 ? -1 : total }
                total += result
            }
            return total
        }
        guard count >= 0 else { throw RunnerError.posix(function: "read auxiliary storage", code: errno) }
        return data.prefix(count)
    }

    // MARK: Repair

    struct RepairOutcome: Sendable {
        let before: Inspection
        let after: Inspection
        /// Nil when the firmware didn't need a repair and nothing changed.
        let backupURL: URL?
    }

    /// Copies the fallback slot over the active slot of a stopped VM, after
    /// it writes a backup of the whole file to `backupDirectory`. It holds
    /// the same exclusive lock that a running VM holds on the file, so a VM
    /// can't start while it writes.
    static func repair(auxiliaryStorageURL url: URL, backupDirectory: URL, now: Date = Date()) throws -> RepairOutcome {
        PommeUnifiedLog.firmware.notice("firmware repair requested for \(url.path, privacy: .public)")
        do {
            let outcome = try performRepair(auxiliaryStorageURL: url, backupDirectory: backupDirectory, now: now)
            if let backupURL = outcome.backupURL {
                PommeUnifiedLog.firmware.notice("firmware repaired; backup at \(backupURL.path, privacy: .public)")
                log(outcome.after, context: "repaired firmware")
            } else {
                PommeUnifiedLog.firmware.notice("firmware repair not needed: status=\(outcome.before.status.rawValue, privacy: .public)")
            }
            return outcome
        } catch {
            PommeUnifiedLog.error(error, context: "firmware repair", logger: PommeUnifiedLog.firmware)
            throw error
        }
    }

    private static func performRepair(auxiliaryStorageURL url: URL, backupDirectory: URL, now: Date) throws -> RepairOutcome {
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RunnerError.posix(function: "open auxiliary storage", code: errno) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw RunnerError.posix(function: "stat auxiliary storage", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o022 == 0, (minimumFileLength ... maximumFileLength).contains(Int(info.st_size))
        else { throw VMBootFirmwareError.unsafeFile }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw VMBootFirmwareError.inUse }
        defer { _ = flock(descriptor, LOCK_UN) }

        let original = try read(descriptor, length: Int(info.st_size))
        guard original.count == Int(info.st_size) else { throw VMBootFirmwareError.unrecognized }
        let before = inspect(data: original)
        switch before.status {
        case .unrecognized: throw VMBootFirmwareError.unrecognized
        case .original, .updated: return RepairOutcome(before: before, after: before, backupURL: nil)
        case .incompatibleUpdate: break
        }
        guard let active = before.active, let fallback = before.fallback else { throw VMBootFirmwareError.unrecognized }
        log(before, context: "firmware before repair")

        let backupURL = try writeBackup(original, directory: backupDirectory, now: now)
        let replacement = original.subdata(in: fallback.offset ..< fallback.offset + slotLength)
        let written = replacement.withUnsafeBytes { buffer -> Int in
            var total = 0
            while total < slotLength {
                let result = pwrite(descriptor, buffer.baseAddress! + total, slotLength - total, off_t(active.offset + total))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return -1 }
                total += result
            }
            return total
        }
        guard written == slotLength else { throw VMBootFirmwareError.repairFailed(backupPath: backupURL.path) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw VMBootFirmwareError.repairFailed(backupPath: backupURL.path)
        }

        let repaired = try read(descriptor, length: Int(info.st_size))
        let after = inspect(data: repaired)
        var expected = original
        expected.replaceSubrange(active.offset ..< active.offset + slotLength, with: replacement)
        guard repaired == expected, after.status == .updated, after.active?.version == fallback.version else {
            throw VMBootFirmwareError.repairFailed(backupPath: backupURL.path)
        }
        return RepairOutcome(before: before, after: after, backupURL: backupURL)
    }

    /// Backups are never overwritten: each repair writes a new, owner-only
    /// file named for the time it started.
    private static func writeBackup(_ data: Data, directory: URL, now: Date) throws -> URL {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw RunnerError.posix(function: "create the firmware backup directory", code: errno)
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0
        else { throw VMBootFirmwareError.unsafeFile }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let url = directory.appendingPathComponent("AuxiliaryStorage-\(formatter.string(from: now))")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RunnerError.posix(function: "create the firmware backup", code: errno) }
        var closed = false
        defer { if !closed { _ = Darwin.close(descriptor) } }
        let written = data.withUnsafeBytes { buffer -> Int in
            var total = 0
            while total < data.count {
                let result = Darwin.write(descriptor, buffer.baseAddress! + total, data.count - total)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return -1 }
                total += result
            }
            return total
        }
        guard written == data.count, fsync(descriptor) == 0 else {
            throw RunnerError.posix(function: "write the firmware backup", code: errno)
        }
        guard Darwin.close(descriptor) == 0 else { closed = true; throw RunnerError.posix(function: "close the firmware backup", code: errno) }
        closed = true
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryDescriptor >= 0 { _ = fsync(directoryDescriptor); _ = Darwin.close(directoryDescriptor) }
        guard (try? Data(contentsOf: url)) == data else {
            throw RunnerError.posix(function: "verify the firmware backup", code: EIO)
        }
        return url
    }
}

enum VMBootFirmwareError: PommeDescribedError, Equatable, Sendable {
    case unrecognized
    case unsafeFile
    case inUse
    case running(name: String)
    case savedState(name: String)
    case repairFailed(backupPath: String)

    var code: PommeErrorCode {
        switch self {
        case .unrecognized: .bootFirmwareUnrecognized
        case .unsafeFile: .vmBundleDamaged
        case .inUse, .running: .vmRunning
        case .savedState: .vmStateInvalid
        case .repairFailed: .bootFirmwareRepairFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            "Pomme doesn't recognize the boot firmware layout in the VM's auxiliary storage, so it didn't change it."
        case .unsafeFile:
            "The VM's auxiliary storage, or its firmware backup folder, isn't a regular file or folder that only you can write."
        case .inUse:
            "Another process has the VM's auxiliary storage open, so the VM is probably running."
        case .running(let name):
            "VM '\(name)' is running. Pomme repairs the boot firmware only while the VM is stopped."
        case .savedState(let name):
            "VM '\(name)' has a saved state waiting to be restored, and a firmware repair would change the VM under it."
        case .repairFailed(let backupPath):
            "The repaired boot firmware didn't read back as expected. The original file is saved at \(backupPath)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unrecognized:
            "Run `pomme firmware inspect NAME`, then run `pomme bug-report NAME` and attach the file to a new issue."
        case .unsafeFile:
            "Run Pomme as the user who created the VM, not with `sudo`."
        case .inUse:
            "Stop the VM with `pomme stop NAME`, then retry."
        case .running(let name):
            "Stop the VM with `pomme stop \(name)`, then retry."
        case .savedState(let name):
            "Start the VM with `pomme start \(name)` and stop it with `pomme stop \(name)`, then retry."
        case .repairFailed:
            "With the VM stopped, copy the backup over the bundle's AuxiliaryStorage file, then run `pomme bug-report NAME` and attach the file to a new issue."
        }
    }
}
