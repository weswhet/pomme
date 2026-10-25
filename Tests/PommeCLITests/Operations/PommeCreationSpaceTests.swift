import Foundation
import Testing

@Suite("Free-space check before creation")
struct PommeCreationSpaceTests {
    private let vms = URL(fileURLWithPath: "/Volumes/Store/VMs/lab.bundle")
    private let images = URL(fileURLWithPath: "/Volumes/Store/RestoreImages")

    @Test("A restore needs the rest of the download and the installed system, capped by the disk")
    func restoreNeeds() {
        let needs = PommeCreationSpace.restoreNeeds(
            downloadBytes: 20_000_000_000, downloadDirectory: images, diskSizeBytes: 64 << 30, destination: vms
        )
        #expect(needs.map(\.kind) == [.restoreImageDownload, .installedSystem])
        #expect(needs.map(\.bytes) == [20_000_000_000, PommeCreationSpace.installedSystemEstimateBytes])

        let small = PommeCreationSpace.restoreNeeds(
            downloadBytes: 0, downloadDirectory: images, diskSizeBytes: 1 << 30, destination: vms
        )
        #expect(small.map(\.kind) == [.installedSystem])
        #expect(small[0].bytes == 1 << 30)
    }

    @Test("Experimental Recovery adds its retained images only when selected")
    func experimentalRecoveryNeeds() {
        #expect(PommeCreationSpace.experimentalRecoveryNeeds(enabled: false, destination: vms).isEmpty)
        let needs = PommeCreationSpace.experimentalRecoveryNeeds(enabled: true, destination: vms)
        #expect(needs.map(\.kind) == [.experimentalRecoveryImages])
        #expect(needs.map(\.bytes) == [PommeCreationSpace.experimentalRecoveryEstimateBytes])
        #expect(needs.map(\.directory) == [vms])
        #expect(needs[0].phrase.contains("Recovery images"))
    }

    @Test("Needs on one volume add up, and a short volume stops creation with each part named")
    func enforceNamesEveryPart() throws {
        let needs = PommeCreationSpace.restoreNeeds(
            downloadBytes: 20_000_000_000, downloadDirectory: images, diskSizeBytes: 64 << 30, destination: vms
        )
        let sameVolume: (URL) -> AnyHashable? = { _ in AnyHashable("store") }
        let checks = PommeCreationSpace.check(needs, availableBytes: { _ in 100_000_000_000 }, volumeIdentifier: sameVolume)
        #expect(checks.count == 1)
        #expect(checks[0].requiredBytes == 55_000_000_000)
        #expect(checks[0].sufficient)

        let error = try #require(throws: PommeCreationSpaceError.self) {
            try PommeCreationSpace.enforce(
                needs, subject: "lab", availableBytes: { _ in 40_000_000_000 }, volumeIdentifier: sameVolume
            )
        }
        #expect(error.code == .hostDiskSpaceInsufficient)
        let message = try #require(error.errorDescription)
        #expect(message.hasPrefix("There isn't enough free space to create lab. It needs \(byteCountText(55_000_000_000))"))
        #expect(message.contains("to download the restore image and about \(byteCountText(35_000_000_000)) for the installed macOS system"))
        #expect(message.contains("Only \(byteCountText(40_000_000_000)) is available."))
        #expect(error.recoverySuggestion?.hasPrefix("Free at least \(byteCountText(15_000_000_000)) on that volume") == true)
        #expect(PommeErrorCatalog.entry(for: error.code) != nil)
    }

    @Test("Each volume is checked on its own, and one whose space is unknown never blocks")
    func separateVolumes() throws {
        let needs = PommeCreationSpace.restoreNeeds(
            downloadBytes: 20_000_000_000, downloadDirectory: images, diskSizeBytes: 64 << 30, destination: vms
        )
        let split: (URL) -> AnyHashable? = { AnyHashable($0.path.contains("RestoreImages") ? "images" : "vms") }
        let checks = try PommeCreationSpace.enforce(
            needs, subject: "lab",
            availableBytes: { $0.path.contains("RestoreImages") ? 25_000_000_000 : 40_000_000_000 },
            volumeIdentifier: split
        )
        #expect(checks.map(\.requiredBytes) == [20_000_000_000, 35_000_000_000])

        #expect(throws: PommeCreationSpaceError.self) {
            try PommeCreationSpace.enforce(
                needs, subject: "lab",
                availableBytes: { $0.path.contains("RestoreImages") ? 1 : 40_000_000_000 },
                volumeIdentifier: split
            )
        }
        let unknown = try PommeCreationSpace.enforce(
            needs, subject: "lab", availableBytes: { _ in nil }, volumeIdentifier: { _ in nil }
        )
        #expect(unknown.allSatisfy { $0.sufficient })
    }

    @Test("A download counts only the bytes it still has to write")
    func bytesToDownload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firmware = IPSWMEFirmware(
            identifier: "VirtualMac2,1", version: "27.0", buildid: "26A428", filesize: 100,
            url: "https://example.invalid/Restore.ipsw", releasedate: nil, uploaddate: nil,
            signed: true, sha1sum: nil, md5sum: nil, sha256sum: nil
        )
        #expect(PommeCore.restoreImageBytesToDownload(firmware, in: directory) == 100)

        try Data(count: 40).write(to: directory.appendingPathComponent(".Restore.ipsw.part"))
        #expect(PommeCore.restoreImageBytesToDownload(firmware, in: directory) == 60)

        try Data(count: 100).write(to: directory.appendingPathComponent("Restore.ipsw"))
        #expect(PommeCore.restoreImageBytesToDownload(firmware, in: directory) == 0)
    }

    @Test("A template on a volume that can clone needs only the clone's own changes")
    func templateClone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = directory.appendingPathComponent("Disk.img")
        try Data(count: 10).write(to: template)
        let destination = directory.appendingPathComponent("lab.bundle")
        let cloning = (try? directory.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true

        let needs = PommeCreationSpace.templateNeeds(template: template, templateBytes: 10, destination: destination)
        #expect(needs.map(\.kind) == (cloning ? [.cloneGrowth] : [.templateCopy, .cloneGrowth]))
    }

    @Test("The dry-run payload reports each volume and the total")
    func payload() {
        let check = PommeCreationSpace.VolumeCheck(
            directory: vms,
            needs: [.init(kind: .cloneGrowth, bytes: 5, directory: vms)],
            availableBytes: 4
        )
        let payload = PommeCreationSpace.payload([check])
        #expect(payload["requiredBytes"] as? UInt64 == 5)
        #expect(payload["sufficient"] as? Bool == false)
        let volume = (payload["volumes"] as? [[String: Any]])?.first
        #expect(volume?["availableBytes"] as? UInt64 == 4)
        #expect((volume?["needs"] as? [[String: Any]])?.first?["kind"] as? String == "cloneGrowth")
    }
}
