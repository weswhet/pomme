import Darwin
import Foundation
import Synchronization
import Testing

/// Builds synthetic auxiliary storage in the layout that `VMBootFirmware`
/// reads. No real firmware or NVRAM bytes are used.
private struct AuxiliaryStorageFixture {
    static let length = VMBootFirmware.minimumFileLength + 0x10000

    var bytes = [UInt8](repeating: 0, count: length)

    /// A restored VM: one header that selects slot A.
    static func restored(_ version: String) -> Self {
        var fixture = Self()
        fixture.setHeader(at: 0x4000, generation: 1, slot: 0x24000)
        fixture.setFirmware(version, slot: 0x24000)
        fixture.bytes.replaceSubrange(0x424000 ..< 0x424010, with: Array("nvram-and-other".utf8) + [0])
        return fixture
    }

    /// A restored VM after one guest update that installed `update` in slot B.
    static func updated(from original: String, to update: String) -> Self {
        var fixture = restored(original)
        fixture.setHeader(at: 0x5000, generation: 2, slot: 0x224000)
        fixture.setFirmware(update, slot: 0x224000)
        return fixture
    }

    mutating func setHeader(at offset: Int, generation: UInt32, slot: Int, magic: String = "HUFA", version: UInt32 = 1) {
        var page = [UInt8](repeating: 0xFF, count: VMBootFirmware.headerLength)
        page.replaceSubrange(0 ..< 4, with: Array(magic.utf8))
        page.replaceSubrange(4 ..< 8, with: Self.little(version))
        page.replaceSubrange(8 ..< 12, with: Self.little(generation))
        page.replaceSubrange(12 ..< 16, with: Self.little(UInt32(slot - VMBootFirmware.slotBase)))
        page.replaceSubrange(16 ..< 32, with: [UInt8](repeating: 0, count: 16))
        page.replaceSubrange(32 ..< 64, with: (0 ..< 32).map { UInt8(truncatingIfNeeded: Int(generation) &* 31 &+ $0) })
        bytes.replaceSubrange(offset ..< offset + page.count, with: page)
    }

    /// An IMG4 of type `illb` whose payload is filler derived from the version.
    mutating func setFirmware(_ version: String, slot: Int) {
        let filler = (0 ..< 4_096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ version.utf8.count) }
        let payload = Self.der(0x30, Self.string("IM4P") + Self.string("illb") + Self.string(version) + Self.der(0x04, filler))
        let image = Self.der(0x30, Self.string("IMG4") + payload)
        let region = image + [UInt8](repeating: 0, count: VMBootFirmware.slotLength - image.count)
        bytes.replaceSubrange(slot ..< slot + VMBootFirmware.slotLength, with: region)
    }

    var data: Data { Data(bytes) }

    func slot(_ offset: Int) -> ArraySlice<UInt8> { bytes[offset ..< offset + VMBootFirmware.slotLength] }

    private static func little(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private static func string(_ value: String) -> [UInt8] { der(0x16, Array(value.utf8)) }
    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        if count < 0x80 { return [tag, UInt8(count)] + content }
        return [tag, 0x83, UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)] + content
    }
}

private final class FirmwareDirectory {
    let root: URL
    var auxiliaryStorage: URL { root.appendingPathComponent("AuxiliaryStorage") }
    var backups: URL { root.appendingPathComponent("FirmwareBackups", isDirectory: true) }

    init(_ fixture: AuxiliaryStorageFixture, mode: mode_t = 0o600) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-firmware-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try fixture.data.write(to: auxiliaryStorage)
        guard chmod(auxiliaryStorage.path, mode) == 0 else { throw RunnerError.posix(function: "chmod", code: errno) }
    }

    func contents() throws -> Data { try Data(contentsOf: auxiliaryStorage) }
    func backupNames() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [] }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("VM boot firmware")
struct VMBootFirmwareTests {
    @Test("A restored VM reports the firmware it was installed with")
    func restoredVM() {
        for version in ["mBoot-18000.161.10", "mBoot-20457.1.29"] {
            let inspection = VMBootFirmware.inspect(data: AuxiliaryStorageFixture.restored(version).data)
            #expect(inspection.status == .original)
            #expect(inspection.active?.version == version)
            #expect(inspection.active?.name == "A")
            #expect(inspection.fallback == nil)
            #expect(inspection.slots.map(\.empty) == [false, true])
            #expect(!inspection.repairable)
        }
    }

    @Test("A macOS 27 firmware update on a VM installed with older firmware is incompatible")
    func incompatibleUpdate() {
        for original in ["mBoot-18000.161.10", "mBoot-11881.140.96"] {
            let inspection = VMBootFirmware.inspect(
                data: AuxiliaryStorageFixture.updated(from: original, to: "mBoot-20457.1.29").data)
            #expect(inspection.status == .incompatibleUpdate)
            #expect(inspection.active?.version == "mBoot-20457.1.29")
            #expect(inspection.active?.name == "B")
            #expect(inspection.activeGeneration == 2)
            #expect(inspection.fallback?.version == original)
            #expect(inspection.repairable)
            #expect(inspection.payload["status"] as? String == "incompatible-update")
            #expect(inspection.payload["fallbackVersion"] as? String == original)
        }
    }

    @Test("Updates within one firmware train, and repaired VMs, are not incompatible")
    func compatibleUpdates() {
        let cases = [
            ("mBoot-18000.161.10", "mBoot-18000.161.10"),
            ("mBoot-18000.161.10", "mBoot-18000.200.4"),
            ("mBoot-20457.1.29", "mBoot-20457.40.2"),
            ("mBoot-20457.1.29", "mBoot-21000.1.1")
        ]
        for (original, update) in cases {
            let inspection = VMBootFirmware.inspect(data: AuxiliaryStorageFixture.updated(from: original, to: update).data)
            #expect(inspection.status == .updated, "\(original) -> \(update)")
            #expect(inspection.active?.version == update)
            #expect(!inspection.repairable)
        }
    }

    @Test("The header with the highest generation selects the active slot")
    func newestHeaderWins() {
        var fixture = AuxiliaryStorageFixture.updated(from: "mBoot-18000.161.10", to: "mBoot-18000.161.10")
        // A second update writes slot A and the header at 0x4000 again.
        fixture.setHeader(at: 0x4000, generation: 3, slot: 0x24000)
        fixture.setFirmware("mBoot-20457.1.29", slot: 0x24000)
        let inspection = VMBootFirmware.inspect(data: fixture.data)
        #expect(inspection.status == .incompatibleUpdate)
        #expect(inspection.active?.name == "A")
        #expect(inspection.activeGeneration == 3)
        #expect(inspection.fallback?.name == "B")
    }

    @Test("Layouts that differ from the observed one are unrecognized")
    func unrecognizedLayouts() {
        var badMagic = AuxiliaryStorageFixture.restored("mBoot-18000.161.10")
        badMagic.setHeader(at: 0x5000, generation: 2, slot: 0x224000, magic: "ABCD")
        var badVersion = AuxiliaryStorageFixture.restored("mBoot-18000.161.10")
        badVersion.setHeader(at: 0x5000, generation: 2, slot: 0x224000, version: 2)
        var badSlot = AuxiliaryStorageFixture.restored("mBoot-18000.161.10")
        badSlot.setHeader(at: 0x5000, generation: 2, slot: 0x124000)
        var sameGeneration = AuxiliaryStorageFixture.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29")
        sameGeneration.setHeader(at: 0x5000, generation: 1, slot: 0x224000)
        var sameSlot = AuxiliaryStorageFixture.restored("mBoot-18000.161.10")
        sameSlot.setHeader(at: 0x5000, generation: 2, slot: 0x24000)
        var tornActive = AuxiliaryStorageFixture.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29")
        tornActive.bytes.replaceSubrange(0x224000 ..< 0x224040, with: [UInt8](repeating: 0xAB, count: 0x40))
        var notBootloader = AuxiliaryStorageFixture.restored("mBoot-18000.161.10")
        notBootloader.setFirmware("logo-1", slot: 0x24000)
        let empty = AuxiliaryStorageFixture()
        let short = AuxiliaryStorageFixture.restored("mBoot-18000.161.10").data.prefix(VMBootFirmware.minimumFileLength - 1)

        for data in [badMagic.data, badVersion.data, badSlot.data, sameGeneration.data, sameSlot.data,
                     tornActive.data, notBootloader.data, empty.data, Data(short)] {
            let inspection = VMBootFirmware.inspect(data: data)
            #expect(inspection.status == .unrecognized)
            #expect(!inspection.repairable)
        }
    }

    @Test("Firmware trains come from the first number of the version")
    func trains() {
        #expect(VMBootFirmware.train(of: "mBoot-20457.1.29") == 20457)
        #expect(VMBootFirmware.train(of: "iBoot-11881.140.96") == 11881)
        #expect(VMBootFirmware.train(of: "mBoot") == nil)
        #expect(VMBootFirmware.train(of: "mBoot-x") == nil)
    }

    @Test("The guest report parses sysctl output and flags limited memory")
    func guestReport() throws {
        let limited = try #require(VMBootFirmware.GuestReport(sysctlOutput: "4294967296\n1879031808\n26.6.2\n"))
        #expect(limited.memoryLimited)
        #expect(limited.macOSMajorVersion == 26)
        let healthy = try #require(VMBootFirmware.GuestReport(sysctlOutput: "4294967296\n4283662336\n26.7.1\n"))
        #expect(!healthy.memoryLimited)
        let small = try #require(VMBootFirmware.GuestReport(sysctlOutput: "2147483648\n1879031808\n15.8\n"))
        #expect(small.memoryLimited)
        #expect(small.macOSMajorVersion == 15)
        #expect(healthy.payload["usableMemoryBytes"] as? UInt64 == 4283662336)

        for output in ["", "4294967296\n1879031808\n", "x\n1\n26.6\n", "4294967296\n1879031808\n26.6 beta\n",
                       "0\n0\n26.6\n", "1\n2\n3\n4\n"] {
            #expect(VMBootFirmware.GuestReport(sysctlOutput: output) == nil, "\(output)")
        }
    }

    @Test("The guest's own report decides whether the firmware affects it")
    func diagnosis() {
        let incompatible = VMBootFirmware.inspect(
            data: AuxiliaryStorageFixture.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29").data)
        let original = VMBootFirmware.inspect(data: AuxiliaryStorageFixture.restored("mBoot-18000.161.10").data)
        let unrecognized = VMBootFirmware.inspect(data: AuxiliaryStorageFixture().data)
        let limited26 = VMBootFirmware.GuestReport(memoryBytes: 4_294_967_296, usableMemoryBytes: 1_879_031_808, macOSVersion: "26.6.2")
        let healthy26 = VMBootFirmware.GuestReport(memoryBytes: 4_294_967_296, usableMemoryBytes: 4_283_662_336, macOSVersion: "26.6.2")
        let upgraded27 = VMBootFirmware.GuestReport(memoryBytes: 4_294_967_296, usableMemoryBytes: 1_879_031_808, macOSVersion: "27.0.1")

        #expect(VMBootFirmware.diagnosis(incompatible, guest: nil) == .likelyAffected)
        #expect(VMBootFirmware.diagnosis(incompatible, guest: limited26) == .affected)
        #expect(VMBootFirmware.diagnosis(incompatible, guest: healthy26) == .notAffected)
        #expect(VMBootFirmware.diagnosis(incompatible, guest: upgraded27) == .notAffected)
        #expect(VMBootFirmware.diagnosis(original, guest: limited26) == .notAffected)
        #expect(VMBootFirmware.diagnosis(unrecognized, guest: nil) == .unknown)
    }

    @Test("Repair copies the install-time slot over the active slot and keeps a backup")
    func repairs() throws {
        let fixture = AuxiliaryStorageFixture.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29")
        let directory = try FirmwareDirectory(fixture)
        let outcome = try VMBootFirmware.repair(
            auxiliaryStorageURL: directory.auxiliaryStorage, backupDirectory: directory.backups,
            now: Date(timeIntervalSince1970: 1_792_000_000))

        var expected = fixture.bytes
        expected.replaceSubrange(0x224000 ..< 0x224000 + VMBootFirmware.slotLength, with: fixture.slot(0x24000))
        #expect(try directory.contents() == Data(expected))
        #expect(outcome.before.status == .incompatibleUpdate)
        #expect(outcome.after.status == .updated)
        #expect(outcome.after.active?.version == "mBoot-18000.161.10")
        let backup = try #require(outcome.backupURL)
        #expect(backup.lastPathComponent == "AuxiliaryStorage-20261014T174640Z")
        #expect(try Data(contentsOf: backup) == fixture.data)
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.backups.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.auxiliaryStorage.path)[.posixPermissions] as? Int == 0o600)

        // A second repair finds nothing to do and writes no second backup.
        let again = try VMBootFirmware.repair(auxiliaryStorageURL: directory.auxiliaryStorage, backupDirectory: directory.backups)
        #expect(again.backupURL == nil)
        #expect(again.before.status == .updated)
        #expect(directory.backupNames() == [backup.lastPathComponent])
        #expect(try directory.contents() == Data(expected))
    }

    @Test("Repair changes nothing when the firmware is original or unrecognized")
    func repairRefusals() throws {
        let original = try FirmwareDirectory(.restored("mBoot-18000.161.10"))
        let unchanged = try VMBootFirmware.repair(auxiliaryStorageURL: original.auxiliaryStorage, backupDirectory: original.backups)
        #expect(unchanged.backupURL == nil)
        #expect(unchanged.before.status == .original)
        #expect(!FileManager.default.fileExists(atPath: original.backups.path))

        let unrecognized = try FirmwareDirectory(AuxiliaryStorageFixture())
        #expect(throws: VMBootFirmwareError.unrecognized) {
            try VMBootFirmware.repair(auxiliaryStorageURL: unrecognized.auxiliaryStorage, backupDirectory: unrecognized.backups)
        }
        #expect(try unrecognized.contents() == AuxiliaryStorageFixture().data)
        #expect(!FileManager.default.fileExists(atPath: unrecognized.backups.path))
    }

    @Test("Repair refuses a file that a running VM holds or that others can write")
    func repairRequiresExclusiveSafeFile() throws {
        let fixture = AuxiliaryStorageFixture.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29")
        let locked = try FirmwareDirectory(fixture)
        let holder = open(locked.auxiliaryStorage.path, O_RDWR)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: VMBootFirmwareError.inUse) {
            try VMBootFirmware.repair(auxiliaryStorageURL: locked.auxiliaryStorage, backupDirectory: locked.backups)
        }
        #expect(try locked.contents() == fixture.data)
        #expect(locked.backupNames().isEmpty)

        let shared = try FirmwareDirectory(fixture, mode: 0o664)
        #expect(throws: VMBootFirmwareError.unsafeFile) {
            try VMBootFirmware.repair(auxiliaryStorageURL: shared.auxiliaryStorage, backupDirectory: shared.backups)
        }
        #expect(try shared.contents() == fixture.data)
    }

    @Test("Inspect output shows the firmware and, when it is incompatible, the next step")
    func inspectPayload() throws {
        let incompatible = try FirmwareDirectory(.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29"))
        let reference = VMReference(name: "fw-test", bundle: BundleLayout(rootURL: incompatible.root))
        let payload = PommeApplication.bootFirmwareInspectPayload(reference: reference)
        #expect(payload["status"] as? String == "incompatible-update")
        let advice = try #require(payload["advice"] as? String)
        #expect(advice.contains("pomme firmware repair fw-test"))
        let text = PommeApplication.formatBootFirmwareInspect(payload)
        #expect(text.hasPrefix("bootFirmware: mBoot-20457.1.29 status=incompatible-update\nbootFirmware.advice: "))

        let original = try FirmwareDirectory(.restored("mBoot-18000.161.10"))
        let originalPayload = PommeApplication.bootFirmwareInspectPayload(
            reference: VMReference(name: "fw-test", bundle: BundleLayout(rootURL: original.root)))
        #expect(originalPayload["advice"] == nil)
        #expect(PommeApplication.formatBootFirmwareInspect(originalPayload) == "bootFirmware: mBoot-18000.161.10 status=original")
    }

    @Test("A Recovery boot warns only when the firmware is incompatible")
    func recoveryWarning() async throws {
        let incompatible = try FirmwareDirectory(.updated(from: "mBoot-18000.161.10", to: "mBoot-20457.1.29"))
        let original = try FirmwareDirectory(.restored("mBoot-18000.161.10"))
        let roots = [incompatible.root, original.root]
        let messages = Mutex<[String]>([])
        await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
            for root in roots {
                PommeCore.warnIfBootFirmwareBlocksRecovery(
                    reference: VMReference(name: "fw-test", bundle: BundleLayout(rootURL: root)))
            }
        }
        let lines = messages.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("fw-test has boot firmware mBoot-20457.1.29 from a guest update.") == true)
        #expect(lines.first?.contains("pomme firmware repair fw-test") == true)
    }

    @Test("The command inventory lists the firmware subcommands")
    func inventory() {
        #expect(CommandCatalog.groups.first { $0.name == "vm" }?.commands.contains("firmware") == true)
        let names = FirmwareCommand.configuration.subcommands.map { $0._commandName }.joined(separator: "|")
        #expect(CommandCatalog.agentHelp.contains("firmware=\(names)"))
    }
}
