import CryptoKit
import Foundation
import Testing

@Suite("Restore-image plan integrity")
struct RestoreImageIntegrityTests {
    @Test("The installer input must match the immutable planned digest")
    func rejectsMutatedRestoreImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-restore-image-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("Restore.ipsw")
        let plannedBytes = Data("planned restore image".utf8)
        try plannedBytes.write(to: imageURL, options: .atomic)
        let expected = SHA256.hash(data: plannedBytes).map { String(format: "%02x", $0) }.joined()

        try PommeCore.verifyRestoreImageDigest(at: imageURL, expected: expected)

        try Data("substituted restore image".utf8).write(to: imageURL, options: .atomic)
        #expect(throws: PommeProvisioningError.self) {
            try PommeCore.verifyRestoreImageDigest(at: imageURL, expected: expected)
        }
    }
}
