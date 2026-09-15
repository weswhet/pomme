import Foundation
import Testing

@Suite("Create memory preflight")
struct CreateMemoryPreflightTests {
    private let fourGiB: UInt64 = 4_294_967_296

    @Test("The provisional floor rejects memory below 4 GiB and accepts 4 GiB")
    func provisionalFloor() throws {
        do {
            try PommeCore.validateProvisionalMemoryFloor(512 * 1024 * 1024)
            Issue.record("512 MiB passed the provisional floor.")
        } catch let error as RunnerError {
            guard case .memoryBelowProvisionalFloor(let requested, let minimum) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(requested == 512 * 1024 * 1024)
            #expect(minimum == fourGiB)
            #expect(error.localizedDescription.contains("provisional guest minimum"))
        }
        try PommeCore.validateProvisionalMemoryFloor(fourGiB)
    }

    @Test("A cached restore image is recognised only when complete")
    func cachedRestoreImageLookup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-ipsw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firmware = firmware(url: "https://updates.example/UniversalMac_26.6.2_25G83_Restore.ipsw", size: 10)
        #expect(PommeCore.cachedRestoreImageURL(for: firmware, in: directory) == nil)

        let file = directory.appendingPathComponent("UniversalMac_26.6.2_25G83_Restore.ipsw")
        try Data(repeating: 1, count: 9).write(to: file)
        #expect(PommeCore.cachedRestoreImageURL(for: firmware, in: directory) == nil)
        try Data(repeating: 1, count: 10).write(to: file)
        #expect(PommeCore.cachedRestoreImageURL(for: firmware, in: directory) == file)
    }

    @Test("A dry run without a local image applies the floor and says so")
    func dryRunWithoutImageIsProvisional() async throws {
        let manifest = PommeTemplateManifest(
            name: "missing",
            version: "26.6.2",
            build: "25G83",
            restoreImageDigest: String(repeating: "0", count: 64),
            restoreImagePath: "/nonexistent/\(UUID().uuidString).ipsw",
            diskSizeBytes: 40 * 1024 * 1024 * 1024
        )
        let check = try await PommeCore.dryRunMemoryCheck(memoryBytes: fourGiB, source: .template(manifest), vmName: "t")
        #expect(check == .init(minimumBytes: fourGiB, provisional: true, restoreImagePath: nil))
        #expect(check.payload["provisional"] as? Bool == true)

        await #expect(throws: RunnerError.self) {
            _ = try await PommeCore.dryRunMemoryCheck(memoryBytes: 1024, source: .template(manifest), vmName: "t")
        }
    }

    private func firmware(url: String, size: Int64) -> IPSWMEFirmware {
        IPSWMEFirmware(
            identifier: "VirtualMac2,1", version: "26.6.2", buildid: "25G83", filesize: size, url: url,
            releasedate: nil, uploaddate: nil, signed: true, sha1sum: nil, md5sum: nil, sha256sum: nil
        )
    }
}
