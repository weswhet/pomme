import Foundation
import Testing

@Suite("Pomme template store")
struct PommeTemplateStoreTests {
    private func makeBundle() throws -> BundleLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-template-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BundleLayout(rootURL: root)
    }

    private func manifest(named name: String = "base") -> PommeTemplateManifest {
        .init(
            name: name,
            version: "26.6.2",
            build: "25G83",
            restoreImageDigest: String(repeating: "a", count: 64),
            restoreImagePath: "/tmp/Restore.ipsw",
            diskSizeBytes: 40 << 30
        )
    }

    @Test("manifest round-trips and requires the three image files")
    func manifestRoundTrip() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.rootURL) }
        let written = manifest()
        try PommeTemplateStore.write(written, to: bundle)

        #expect(throws: PommeTemplateError.incompleteBundle("base")) {
            try PommeTemplateStore.manifest(in: bundle)
        }
        for url in [bundle.diskImageURL, bundle.auxiliaryStorageURL, bundle.hardwareModelURL] {
            try Data("x".utf8).write(to: url)
        }
        let read = try PommeTemplateStore.manifest(in: bundle)
        #expect(read.name == written.name)
        #expect(read.build == written.build)
        #expect(read.restoreImageDigest == written.restoreImageDigest)
        #expect(read.diskSizeBytes == written.diskSizeBytes)
        #expect(abs(read.createdAt.timeIntervalSince(written.createdAt)) < 1)
    }

    @Test("manifests with a bad digest or size are rejected")
    func manifestValidation() {
        #expect(throws: PommeTemplateError.invalidManifest) {
            try PommeTemplateManifest(
                name: "x", version: "26.6.2", build: "25G83",
                restoreImageDigest: "nope", restoreImagePath: "/tmp/a", diskSizeBytes: 1
            ).validate()
        }
        #expect(throws: PommeTemplateError.invalidManifest) {
            try PommeTemplateManifest(
                name: "x", version: "26.6.2", build: "25G83",
                restoreImageDigest: String(repeating: "a", count: 64), restoreImagePath: "/tmp/a", diskSizeBytes: 0
            ).validate()
        }
    }

    @Test("clone reproduces file contents")
    func cloneCopiesBytes() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.rootURL) }
        let source = bundle.rootURL.appendingPathComponent("source.img")
        let destination = bundle.rootURL.appendingPathComponent("clone.img")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        try PommeTemplateStore.clone(source, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(throws: PommeTemplateError.self) {
            try PommeTemplateStore.clone(source, to: destination)
        }
    }
}
