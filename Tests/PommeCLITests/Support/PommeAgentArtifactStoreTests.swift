import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Pinned Pomme agent artifact store")
struct PommeAgentArtifactStoreTests {
    @Test("Resolves the exact private digest layout and verifies the signature")
    func resolvesExactArtifact() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.cleanup() }

        let content = Data("signed-pomme-agent".utf8)
        let digest = sha256(content)
        let artifact = try fixture.install(content: content, digest: digest)
        let capture = SignatureCapture()
        let store = PommeAgentArtifactStore(
            rootURL: fixture.root,
            dependencies: .init(verifyCodeSignature: { url in capture.record(url) })
        )

        #expect(try store.resolve(sha256: digest) == artifact)
        #expect(capture.value == artifact)
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test("Resolution is read-only when a pinned artifact is absent")
    func missingArtifactDoesNotCreateStore() throws {
        let root = Self.fixtureRoot("pomme-artifacts-missing")
        let store = PommeAgentArtifactStore(
            rootURL: root,
            dependencies: .init(verifyCodeSignature: { _ in })
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            throws: PommeAgentArtifactStore.Error.storeUnavailable
        ) {
            try store.resolve(sha256: String(repeating: "a", count: 64))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Rejects non-lowercase and malformed pinned digests")
    func rejectsMalformedDigest() throws {
        let root = Self.fixtureRoot("pomme-artifacts-invalid")
        let store = PommeAgentArtifactStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }

        for value in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), "not-a-digest"] {
            #expect(throws: PommeAgentArtifactStore.Error.invalidDigest) {
                try store.resolve(sha256: value)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Rejects a digest mismatch without returning the retained file")
    func rejectsDigestMismatch() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.cleanup() }

        let expected = Data("expected".utf8)
        let digest = sha256(expected)
        let artifact = try fixture.install(content: Data("changed".utf8), digest: digest)
        let store = PommeAgentArtifactStore(
            rootURL: fixture.root,
            dependencies: .init(verifyCodeSignature: { _ in })
        )

        #expect(
            throws: PommeAgentArtifactStore.Error.digestMismatch
        ) {
            try store.resolve(sha256: digest)
        }
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test("Rejects signature failures before accepting an artifact")
    func rejectsSignature() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.cleanup() }

        let content = Data("unsigned".utf8)
        let digest = sha256(content)
        _ = try fixture.install(content: content, digest: digest)
        let store = PommeAgentArtifactStore(
            rootURL: fixture.root,
            dependencies: .init(verifyCodeSignature: { _ in throw TestSignatureError.rejected })
        )

        #expect(
            throws: PommeAgentArtifactStore.Error.signatureRejected
        ) {
            try store.resolve(sha256: digest)
        }
    }

    @Test("Rejects a configured root reached through a symlink alias")
    func rejectsRootSymlinkAlias() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.cleanup() }

        let alias = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent("pomme-artifacts-alias-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: alias) }

        let store = PommeAgentArtifactStore(
            rootURL: alias,
            dependencies: .init(verifyCodeSignature: { _ in })
        )
        #expect(
            throws: PommeAgentArtifactStore.Error.unsafeStore
        ) {
            try store.resolve(sha256: String(repeating: "a", count: 64))
        }
    }

    @Test("Rejects writable, multiply-linked, and symlinked artifacts")
    func rejectsUnsafeArtifactIdentity() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.cleanup() }

        let content = Data("identity".utf8)
        let digest = sha256(content)
        let artifact = try fixture.install(content: content, digest: digest)
        let store = PommeAgentArtifactStore(
            rootURL: fixture.root,
            dependencies: .init(verifyCodeSignature: { _ in })
        )

        chmod(artifact.path, 0o755 | 0o020)
        #expect(throws: PommeAgentArtifactStore.Error.artifactRejected) {
            try store.resolve(sha256: digest)
        }
        chmod(artifact.path, 0o555)
        chmod(artifact.path, 0o707)
        #expect(throws: PommeAgentArtifactStore.Error.artifactRejected) {
            try store.resolve(sha256: digest)
        }
        chmod(artifact.path, 0o555)

        let link = artifact.deletingLastPathComponent().appendingPathComponent("other-link")
        try FileManager.default.linkItem(at: artifact, to: link)
        #expect(throws: PommeAgentArtifactStore.Error.artifactRejected) {
            try store.resolve(sha256: digest)
        }
        try? FileManager.default.removeItem(at: link)

        try FileManager.default.removeItem(at: artifact)
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: fixture.source)
        #expect(throws: PommeAgentArtifactStore.Error.artifactRejected) {
            try store.resolve(sha256: digest)
        }
    }

    private static func fixtureRoot(_ prefix: String = "pomme-artifacts") -> URL {
        FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
    }

    private struct ArtifactFixture {
        let root: URL
        let source: URL

        init() throws {
            root = PommeAgentArtifactStoreTests.fixtureRoot()
            source = root.appendingPathComponent("source", isDirectory: false)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try Data("fixture".utf8).write(to: source)
            chmod(source.path, 0o555)
        }

        func install(content: Data, digest: String) throws -> URL {
            let digestDirectory = root
                .appendingPathComponent(PommeAgentArtifactStore.artifactDirectoryName, isDirectory: true)
                .appendingPathComponent(PommeAgentArtifactStore.digestDirectoryName, isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
            try FileManager.default.createDirectory(
                at: digestDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let artifact = digestDirectory.appendingPathComponent(PommeAgentArtifactStore.artifactName)
            try content.write(to: artifact)
            chmod(artifact.path, 0o555)
            return artifact
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum TestSignatureError: Error {
        case rejected
    }
}

private final class SignatureCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURL: URL?

    func record(_ url: URL) {
        lock.lock()
        recordedURL = url
        lock.unlock()
    }

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedURL
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
