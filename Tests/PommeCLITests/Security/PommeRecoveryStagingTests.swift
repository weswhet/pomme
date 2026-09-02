import Darwin
import CryptoKit
import Foundation
import Testing

@Suite("Pomme Recovery staging")
struct PommeRecoveryStagingTests {
    @Test("Staging is read-only and proves signature, digest, inode, and mode")
    func verifiedReadOnlyStaging() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let executable = temporary.url.appendingPathComponent("pomme")
        let bytes = Data("signed executable".utf8)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: bytes))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let credential = try credential()
        let request = try request(credential: credential, executable: bytes)
        let builder = PommeRecoveryStagingBuilder(dependencies: .init(
            verifyCodeSignature: { _ in },
            rootName: { "pomme-recovery-test" }
        ))
        let staging = try builder.build(.init(
            request: request,
            signedExecutableURL: executable,
            launcherScript: "#!/bin/sh\nexit 0\n",
            credential: credential,
            temporaryParentURL: temporary.url
        ))
        #expect(staging.proof.isComplete)
        #expect(staging.proof.readOnly)
        #expect(staging.directorySharingDevices.count == 1)
        #expect(try staging.rootEvidence(listenerReady: true).isAcceptable)
        let rootInfo = try FileManager.default.attributesOfItem(atPath: staging.rootURL.path)
        #expect((rootInfo[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try staging.removeHostArtifacts()
        #expect(!FileManager.default.fileExists(atPath: staging.rootURL.path))
    }

    @Test("A source symlink is rejected before staging")
    func rejectsSymlinkSource() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let target = temporary.url.appendingPathComponent("target")
        let link = temporary.url.appendingPathComponent("pomme")
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data(repeating: 1, count: 32)))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let credential = try credential()
        let request = try request(credential: credential, executable: Data(repeating: 1, count: 32))
        let builder = PommeRecoveryStagingBuilder(dependencies: .init(verifyCodeSignature: { _ in }))
        #expect(throws: PommeRecoveryStagingError.sourceRejected) {
            try builder.build(.init(
                request: request,
                signedExecutableURL: link,
                launcherScript: "run",
                credential: credential,
                temporaryParentURL: temporary.url
            ))
        }
    }

    @Test("A symlinked staging parent is rejected")
    func rejectsSymlinkParent() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let executable = temporary.url.appendingPathComponent("pomme")
        let bytes = Data(repeating: 2, count: 32)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: bytes))
        let alias = temporary.url.deletingLastPathComponent().appendingPathComponent("pomme-parent-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: temporary.url)
        defer { try? FileManager.default.removeItem(at: alias) }
        let credential = try credential()
        let request = try request(credential: credential, executable: bytes)
        let builder = PommeRecoveryStagingBuilder(dependencies: .init(verifyCodeSignature: { _ in }))
        #expect(throws: PommeRecoveryStagingError.unsafeParent) {
            try builder.build(.init(
                request: request,
                signedExecutableURL: executable,
                launcherScript: "run",
                credential: credential,
                temporaryParentURL: alias
            ))
        }
    }

    @Test("Unknown cleanup entries fail closed")
    func rejectsUnknownCleanupState() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let executable = temporary.url.appendingPathComponent("pomme")
        let bytes = Data(repeating: 7, count: 32)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: bytes))
        let credential = try credential()
        let request = try request(credential: credential, executable: bytes)
        let builder = PommeRecoveryStagingBuilder(dependencies: .init(
            verifyCodeSignature: { _ in },
            rootName: { "pomme-recovery-unknown" }
        ))
        let staging = try builder.build(.init(
            request: request,
            signedExecutableURL: executable,
            launcherScript: "run",
            credential: credential,
            temporaryParentURL: temporary.url
        ))
        let rogue = staging.rootURL.appendingPathComponent("unexpected")
        #expect(FileManager.default.createFile(atPath: rogue.path, contents: Data([1])))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rogue.path)
        #expect(throws: PommeRecoveryStagingError.unknownCleanupState) {
            try staging.removeHostArtifacts()
        }
        try FileManager.default.removeItem(at: rogue)
        try staging.removeHostArtifacts()
    }

    private func credential() throws -> PommeRecoveryCredential {
        try .init(secret: Data(repeating: 9, count: 32), expiresAt: Date().addingTimeInterval(120))
    }

    private func request(credential: PommeRecoveryCredential, executable: Data) throws -> PommeRecoverySessionRequest {
        try .init(
            vmUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            operation: .installAgent,
            issuedAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(60),
            executableSHA256: PommeRecoveryCrypto.hex(CryptoKit.SHA256.hash(data: executable)),
            credential: credential
        )
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appendingPathComponent("pomme-recovery-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
