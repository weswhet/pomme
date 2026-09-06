import Foundation
import Testing

@Suite("Pomme executable identity")
struct PommeExecutableIdentityTests {
    @Test("production resolution agrees with the existing dyld resolver")
    func productionResolutionUsesDyldPath() throws {
        // Given: both production paths are evaluated in this process.
        let identity = try PommeCore.runningExecutableIdentity()
        let dyldURL = try PommeFirstBootProcessIsolation.currentExecutableURL()
        let dyldDigest = try PommeFirstBootProcessIsolation.executableDigest(at: dyldURL)

        // Then: the host identity is the process executable, not argv[0].
        #expect(identity.url == dyldURL)
        #expect(identity.sha256 == dyldDigest)
    }

    @Test("canonicalizes a symlink before hashing the executable")
    func canonicalizesSymlink() throws {
        // Given: a deterministic executable fixture and a symlink to it.
        let fixture = try ExecutableFixture()
        defer { fixture.cleanup() }
        let alias = fixture.root.appendingPathComponent("pomme-alias")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.executable
        )
        let executableURL = fixture.executable

        // When: the injectable path provider returns the symlink spelling.
        let identity = try PommeCore.runningExecutableIdentity(
            executableURLProvider: { alias }
        )

        // Then: both path and digest bind to the resolved target.
        #expect(identity.url == executableURL.resolvingSymlinksInPath())
        #expect(identity.sha256 == "1eeb1047bba7b642b2524a8fa9319f792bf9c2df890298427a70316f83d1a99e")
    }

    @Test("propagates executable path provider failures")
    func propagatesProviderFailure() {
        // Given: a provider that cannot resolve the process executable.
        // When/Then: the resolver does not replace the provider's error.
        #expect(throws: ExecutableIdentityTestError.unavailable) {
            try PommeCore.runningExecutableIdentity(
                executableURLProvider: { throw ExecutableIdentityTestError.unavailable }
            )
        }
    }

    @Test("rejects a missing executable after path resolution")
    func rejectsMissingExecutable() throws {
        // Given: a canonical path that does not exist.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-missing-executable-\(UUID().uuidString)")

        // When/Then: digesting the missing path fails closed.
        #expect(throws: PommeFirstBootProcessError.identityRejected) {
            try PommeCore.runningExecutableIdentity(executableURLProvider: { missing })
        }
    }

    @Test("rejects a directory as the executable")
    func rejectsDirectory() throws {
        // Given: a directory path with no executable bytes.
        let fixture = try ExecutableFixture()
        defer { fixture.cleanup() }
        let directoryURL = fixture.root

        // When/Then: the identity remains fail-closed for non-files.
        #expect(throws: PommeFirstBootProcessError.identityRejected) {
            try PommeCore.runningExecutableIdentity(
                executableURLProvider: { directoryURL }
            )
        }
    }
}

private enum ExecutableIdentityTestError: Error, Equatable, Sendable {
    case unavailable
}

private struct ExecutableFixture {
    let root: URL
    let executable: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-executable-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = root.appendingPathComponent("pomme")
        guard FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("pomme executable identity fixture\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw ExecutableIdentityTestError.unavailable
        }
        self.root = root
        self.executable = executable
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
