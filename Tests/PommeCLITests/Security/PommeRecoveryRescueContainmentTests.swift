import Foundation
import Testing

@Suite("Pomme Recovery rescue containment")
struct PommeRecoveryRescueContainmentTests {
    @Test("APFS attachment parsing rejects ambiguous image or volume evidence")
    func ambiguousAttachment() throws {
        let image = "/tmp/pomme.img"
        let volume = "pomme-r-test"
        let uuid = "11111111-2222-3333-4444-555555555555"
        let plist: [String: Any] = [
            "images": [
                ["image-path": image, "system-entities": [[
                    "dev-entry": "/dev/disk4", "mount-point": "/Volumes/\(volume)", "VolumeUUID": uuid
                ]]],
                ["image-path": image, "system-entities": [[
                    "dev-entry": "/dev/disk5", "mount-point": "/Volumes/\(volume)", "VolumeUUID": uuid
                ]]]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(throws: PommeAPFSAttachmentError.ambiguous) {
            try PommeAPFSAttachmentParser.parse(
                data,
                imageURL: URL(fileURLWithPath: image),
                volumeName: volume
            )
        }
    }

    @Test("A unique APFS attachment can be contained and removed exactly")
    func uniqueAttachment() throws {
        let temporary = try TemporaryRescueDirectory()
        defer { temporary.remove() }
        let image = temporary.directory.appendingPathComponent("rescue.img")
        #expect(FileManager.default.createFile(atPath: image.path, contents: Data([1, 2, 3])))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
        let attachment = PommeAPFSAttachment(
            imagePath: image.standardizedFileURL.path,
            wholeDisk: "disk4",
            mountPoint: "/Volumes/pomme-r-test",
            volumeUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let detacher = RescueDetacher()
        let containment = try PommeRecoveryRescueContainment(
            imageURL: image,
            directoryURL: temporary.directory,
            attachment: attachment,
            attachmentPort: detacher
        )
        try containment.cleanup()
        #expect(detacher.count == 1)
        #expect(!FileManager.default.fileExists(atPath: temporary.directory.path))
    }
}

private final class RescueDetacher: PommeRecoveryRescueAttachmentPort, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func detach(_ attachment: PommeAPFSAttachment) throws {
        lock.withLock { value += 1 }
    }
}

private struct TemporaryRescueDirectory {
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pomme-rescue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
