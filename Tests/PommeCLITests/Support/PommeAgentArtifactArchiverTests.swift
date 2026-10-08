import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Retaining the pinned agent")
struct PommeAgentArtifactArchiverTests {
    @Test("Copies the executable into the private digest layout that the store resolves")
    func retainsExecutable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let content = Data("signed-pomme".utf8)
        let source = try fixture.executable(content)
        let digest = archiverSHA256(content)

        let retained = try fixture.archiver().retain(executableAt: source, sha256: digest)

        let store = PommeAgentArtifactStore(rootURL: fixture.root, dependencies: .init(verifyCodeSignature: { _ in }))
        #expect(try store.resolve(sha256: digest) == retained)
        #expect(try Data(contentsOf: retained) == content)
        var info = stat()
        #expect(lstat(retained.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o555)
        for directory in [retained.deletingLastPathComponent(),
                          retained.deletingLastPathComponent().deletingLastPathComponent(),
                          retained.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()] {
            #expect(lstat(directory.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o700)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: retained.deletingLastPathComponent().path)
            == [PommeAgentArtifactStore.artifactName])
    }

    @Test("Reuses an existing entry without rewriting it")
    func reusesExistingEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let content = Data("signed-pomme".utf8)
        let digest = archiverSHA256(content)
        let first = try fixture.archiver().retain(executableAt: try fixture.executable(content), sha256: digest)
        var before = stat()
        #expect(lstat(first.path, &before) == 0)

        let second = try fixture.archiver().retain(executableAt: try fixture.executable(content), sha256: digest)

        var after = stat()
        #expect(second == first)
        #expect(lstat(second.path, &after) == 0)
        #expect(after.st_ino == before.st_ino)
    }

    @Test("Rejects an executable whose bytes don't match the pinned digest")
    func rejectsDigestMismatch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let digest = archiverSHA256(Data("expected".utf8))

        #expect(throws: PommeAgentArtifactArchiver.Error.digestMismatch) {
            try fixture.archiver().retain(executableAt: try fixture.executable(Data("changed".utf8)), sha256: digest)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.digestDirectory(digest).path))
    }

    @Test("Leaves nothing behind when the copy's signature is rejected")
    func rejectsUnsignedExecutable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let content = Data("ad-hoc-pomme".utf8)
        let digest = archiverSHA256(content)
        let archiver = PommeAgentArtifactArchiver(
            rootURL: fixture.root,
            dependencies: .init(verifyCodeSignature: { _ in throw PommeAgentArtifactStore.Error.signatureRejected })
        )

        #expect(throws: PommeAgentArtifactStore.Error.signatureRejected) {
            try archiver.retain(executableAt: try fixture.executable(content), sha256: digest)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.digestDirectory(digest).path))
    }

    @Test("Refuses a store directory that others can write")
    func refusesSharedStore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let artifacts = fixture.root.appendingPathComponent(PommeAgentArtifactStore.artifactDirectoryName)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        chmod(artifacts.path, 0o777)
        let content = Data("signed-pomme".utf8)

        #expect(throws: PommeAgentArtifactArchiver.Error.unsafeStore) {
            try fixture.archiver().retain(executableAt: try fixture.executable(content), sha256: archiverSHA256(content))
        }
    }

    @Test("Needs an existing application-support root")
    func requiresRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let content = Data("signed-pomme".utf8)
        let source = try fixture.executable(content)
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
        let archiver = PommeAgentArtifactArchiver(rootURL: missing, dependencies: .init(verifyCodeSignature: { _ in }))

        #expect(throws: PommeAgentArtifactArchiver.Error.unsafeStore) {
            try archiver.retain(executableAt: source, sha256: archiverSHA256(content))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    private struct Fixture {
        let root: URL
        let sources: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent("pomme-archiver-" + UUID().uuidString, isDirectory: true)
            root = base.appendingPathComponent("pomme", isDirectory: true)
            sources = base.appendingPathComponent("sources", isDirectory: true)
            for directory in [base, root, sources] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
            }
        }

        func archiver() -> PommeAgentArtifactArchiver {
            PommeAgentArtifactArchiver(rootURL: root, dependencies: .init(verifyCodeSignature: { _ in }))
        }

        func executable(_ content: Data) throws -> URL {
            let url = sources.appendingPathComponent(UUID().uuidString)
            try content.write(to: url)
            chmod(url.path, 0o755)
            return url
        }

        func digestDirectory(_ digest: String) -> URL {
            root.appendingPathComponent(PommeAgentArtifactStore.artifactDirectoryName, isDirectory: true)
                .appendingPathComponent(PommeAgentArtifactStore.digestDirectoryName, isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }
}

private func archiverSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
