import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Pomme Recovery path walker")
struct PommeAgentPathWalkerTests {
    @Test("An open failure is diagnosed as missing, a directory, unreadable, or a link")
    func diagnosesOpenFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-diagnose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            _ = chmod(root.appendingPathComponent("unreadable").path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("file")
        try Data("bytes".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let unreadable = root.appendingPathComponent("unreadable")
        try Data("bytes".utf8).write(to: unreadable)
        #expect(chmod(unreadable.path, 0o000) == 0)
        let missing = root.appendingPathComponent("missing")
        func diagnose(_ url: URL, write: Bool = false) -> PommeAgentFileTransaction.OpenFailure? {
            PommeAgentFileTransaction.diagnoseOpenFailure(url, forWrite: write)
        }

        #expect(diagnose(missing) == .missing(missing.path))
        #expect(diagnose(root) == .notRegular(root.path, isDirectory: true))
        #expect(diagnose(link) == .unsafe(link.path))
        #expect(diagnose(file) == nil)
        if geteuid() != 0 {
            #expect(diagnose(unreadable) == .permission(unreadable.path))
        }
        #expect(diagnose(missing.appendingPathComponent("x"), write: true) == .missing(missing.path))
        #expect(diagnose(root.appendingPathComponent("new"), write: true) == nil)
        #expect(diagnose(URL(fileURLWithPath: "/tmp")) == .notRegular("/tmp", isDirectory: true))
    }

    @Test("accepts observed private alias spellings and lexical var/tmp aliases")
    func acceptsObservedPrivateAliasAndCompatibilitySpellings() throws {
        for layout in [PathWalkerLayout.observedPrivateAlias, .observedAbsolutePrivateAlias] {
            let fixture = try PathWalkerFixture(layout: layout)
            defer { fixture.cleanup() }

            for path in fixture.compatibilityPaths {
                let digest = try readDigest(
                    fixture,
                    logicalPath: path,
                    trustedAliasOwner: geteuid()
                )
                #expect(digest == fixture.digest)
            }
            #expect(try Data(contentsOf: fixture.fileURL) == fixture.bytes)
            if let tmpFileURL = fixture.tmpFileURL {
                #expect(try Data(contentsOf: tmpFileURL) == fixture.bytes)
            }
        }
    }

    @Test("accepts an ordinary private directory and lexical var/tmp aliases")
    func acceptsOrdinaryPrivateDirectoryAndCompatibilitySpellings() throws {
        let fixture = try PathWalkerFixture(layout: .ordinaryPrivateDirectory)
        defer { fixture.cleanup() }

        for path in fixture.compatibilityPaths {
            let digest = try readDigest(
                fixture,
                logicalPath: path,
                trustedAliasOwner: geteuid()
            )
            #expect(digest == fixture.digest)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == fixture.bytes)
        if let tmpFileURL = fixture.tmpFileURL {
            #expect(try Data(contentsOf: tmpFileURL) == fixture.bytes)
        }
    }

    @Test("rejects a different or unsafe relative private alias target without mutation")
    func rejectsUnsafePrivateAliasTargets() throws {
        try assertRejected(layout: .differentAbsolutePrivateTarget)
        try assertRejected(layout: .unsafeRelativePrivateTarget)
    }

    @Test("rejects a private alias owned by an untrusted owner without mutation")
    func rejectsPrivateAliasWithWrongOwner() throws {
        let wrongOwner: uid_t = geteuid() == 0 ? 1 : 0
        try assertRejected(layout: .observedPrivateAlias, trustedAliasOwner: wrongOwner)
    }

    @Test("rejects symlinks below the private alias and inside its target prefix")
    func rejectsNestedSymlinksWithoutMutation() throws {
        try assertRejected(layout: .nestedBelowPrivateAlias)
        try assertRejected(layout: .nestedInsidePrivateTarget)
    }

    @Test("rejects dot-dot path components without mutation")
    func rejectsDotDotPath() throws {
        let fixture = try PathWalkerFixture(layout: .observedPrivateAlias)
        defer { fixture.cleanup() }
        let traversal = "/private/var/tmp/\(fixture.workspaceName)/../\(fixture.workspaceName)/pomme-agent"
        try assertRejected(fixture: fixture, logicalPath: traversal)
    }
}

private enum PathWalkerLayout {
    case observedPrivateAlias
    case observedAbsolutePrivateAlias
    case ordinaryPrivateDirectory
    case differentAbsolutePrivateTarget
    case unsafeRelativePrivateTarget
    case nestedBelowPrivateAlias
    case nestedInsidePrivateTarget
}

private final class PathWalkerFixture {
    let root: URL
    let rootDescriptor: Int32
    let workspaceName: String
    let fileURL: URL
    let tmpFileURL: URL?
    let bytes: Data
    let digest: String

    init(layout: PathWalkerLayout) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-path-walker-\(UUID().uuidString)", isDirectory: true)
        do {
            try makeDirectory(root)
            let workspaceName = "pomme-recovery-\(UUID().uuidString.lowercased())"
            let bytes = Data("pomme-path-walker-test-bytes".utf8)
            let digest = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined()

            let privateRoot: URL
            switch layout {
            case .ordinaryPrivateDirectory:
                privateRoot = root.appendingPathComponent("private", isDirectory: true)
                try makeDirectory(privateRoot)

            case .observedPrivateAlias,
                 .observedAbsolutePrivateAlias,
                 .differentAbsolutePrivateTarget,
                 .unsafeRelativePrivateTarget,
                 .nestedBelowPrivateAlias,
                 .nestedInsidePrivateTarget:
                let canonicalPrivate = root
                    .appendingPathComponent("System", isDirectory: true)
                    .appendingPathComponent("Volumes", isDirectory: true)
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent("private", isDirectory: true)
                try makeDirectory(canonicalPrivate)

                let target: String
                let mappedPrivate: URL
                switch layout {
                case .observedPrivateAlias,
                     .nestedBelowPrivateAlias:
                    target = "System/Volumes/Data/private"
                    mappedPrivate = canonicalPrivate
                case .observedAbsolutePrivateAlias:
                    target = "/System/Volumes/Data/private"
                    mappedPrivate = canonicalPrivate
                case .differentAbsolutePrivateTarget:
                    target = "/System/Volumes/Data/not-private"
                    mappedPrivate = root.appendingPathComponent(
                        "System/Volumes/Data/not-private", isDirectory: true
                    )
                    try makeDirectory(mappedPrivate)
                case .unsafeRelativePrivateTarget:
                    target = "./System/Volumes/Data/private"
                    mappedPrivate = canonicalPrivate
                case .nestedInsidePrivateTarget:
                    let dataRoot = root.appendingPathComponent(
                        "System/Volumes/Data", isDirectory: true
                    )
                    let otherDataRoot = root.appendingPathComponent(
                        "System/Volumes/OtherData", isDirectory: true
                    )
                    try FileManager.default.moveItem(at: dataRoot, to: otherDataRoot)
                    try FileManager.default.createSymbolicLink(
                        atPath: dataRoot.path,
                        withDestinationPath: "/System/Volumes/OtherData"
                    )
                    target = "System/Volumes/Data/private"
                    mappedPrivate = otherDataRoot.appendingPathComponent(
                        "private", isDirectory: true
                    )
                case .ordinaryPrivateDirectory:
                    fatalError("ordinary layout handled above")
                }
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("private", isDirectory: true).path,
                    withDestinationPath: target
                )
                privateRoot = mappedPrivate
            }

            let fileRoot: URL
            switch layout {
            case .nestedBelowPrivateAlias:
                let alternate = privateRoot.appendingPathComponent("other-var", isDirectory: true)
                try makeDirectory(alternate)
                try FileManager.default.createSymbolicLink(
                    atPath: privateRoot.appendingPathComponent("var", isDirectory: true).path,
                    withDestinationPath: "other-var"
                )
                fileRoot = alternate

            case .nestedInsidePrivateTarget:
                fileRoot = privateRoot

            default:
                fileRoot = privateRoot
            }

            let workspace: URL
            switch layout {
            case .nestedBelowPrivateAlias:
                workspace = fileRoot
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(workspaceName, isDirectory: true)
            case .nestedInsidePrivateTarget:
                workspace = fileRoot
                    .appendingPathComponent("var", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(workspaceName, isDirectory: true)
            default:
                workspace = fileRoot
                    .appendingPathComponent("var", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(workspaceName, isDirectory: true)
            }
            try makeDirectory(workspace)
            let fileURL = workspace.appendingPathComponent("pomme-agent")
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: bytes,
                attributes: [.posixPermissions: 0o400]
            ) else { throw PathWalkerTestError.fixtureCreationFailed }
            guard chmod(fileURL.path, 0o400) == 0 else {
                throw PathWalkerTestError.fixtureCreationFailed
            }

            // Keep this rejection fixture honest: if the walker followed the
            // Data prefix link, the logical path would reach this exact file.
            // Read the physical, non-symlinked target so the test cannot pass
            // merely because an expected parent is missing or because a path
            // accidentally escaped the isolated fixture root.
            if case .nestedInsidePrivateTarget = layout {
                let expectedPhysicalFile = root
                    .appendingPathComponent("System/Volumes/OtherData", isDirectory: true)
                    .appendingPathComponent("private", isDirectory: true)
                    .appendingPathComponent("var", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(workspaceName, isDirectory: true)
                    .appendingPathComponent("pomme-agent")
                guard fileURL.path == expectedPhysicalFile.path,
                      try Data(contentsOf: expectedPhysicalFile) == bytes
                else { throw PathWalkerTestError.fixtureCreationFailed }
            }

            let tmpFileURL: URL?
            switch layout {
            case .observedPrivateAlias, .observedAbsolutePrivateAlias, .ordinaryPrivateDirectory:
                let tmpWorkspace = privateRoot
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(workspaceName, isDirectory: true)
                try makeDirectory(tmpWorkspace)
                let candidate = tmpWorkspace.appendingPathComponent("pomme-agent")
                guard FileManager.default.createFile(
                    atPath: candidate.path,
                    contents: bytes,
                    attributes: [.posixPermissions: 0o400]
                ), chmod(candidate.path, 0o400) == 0 else {
                    throw PathWalkerTestError.fixtureCreationFailed
                }
                tmpFileURL = candidate
            default:
                tmpFileURL = nil
            }

            let descriptor = Darwin.open(
                root.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { throw PathWalkerTestError.fixtureCreationFailed }

            self.root = root
            rootDescriptor = descriptor
            self.workspaceName = workspaceName
            self.fileURL = fileURL
            self.tmpFileURL = tmpFileURL
            self.bytes = bytes
            self.digest = digest
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    var compatibilityPaths: [String] {
        [
            "/private/var/tmp/\(workspaceName)/pomme-agent",
            "/var/tmp/\(workspaceName)/pomme-agent",
            "/tmp/\(workspaceName)/pomme-agent"
        ]
    }

    func cleanup() {
        _ = Darwin.close(rootDescriptor)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum PathWalkerTestError: Error {
    case fixtureCreationFailed
    case invalidLeaf
    case openFailed
    case statFailed
    case readFailed
}

private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(url.path, 0o700) == 0 else {
        throw PathWalkerTestError.fixtureCreationFailed
    }
}

private func readDigest(
    _ fixture: PathWalkerFixture,
    logicalPath: String,
    trustedAliasOwner: uid_t
) throws -> String {
    let data = try PommeAgentFileTransaction.withVerifiedParent(
        of: URL(fileURLWithPath: logicalPath),
        rootDescriptor: fixture.rootDescriptor,
        trustedAliasOwner: trustedAliasOwner
    ) { parent, leaf in
        guard leaf == "pomme-agent" else { throw PathWalkerTestError.invalidLeaf }
        let descriptor = openat(parent, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PathWalkerTestError.openFailed }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= 64 * 1024
        else { throw PathWalkerTestError.statFailed }

        var data = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw PathWalkerTestError.readFailed
            }
        }
        guard data.count == Int(info.st_size) else { throw PathWalkerTestError.readFailed }
        return data
    }
    return SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func assertRejected(
    layout: PathWalkerLayout,
    trustedAliasOwner: uid_t = geteuid()
) throws {
    let fixture = try PathWalkerFixture(layout: layout)
    defer { fixture.cleanup() }
    try assertRejected(
        fixture: fixture,
        logicalPath: fixture.compatibilityPaths[0],
        trustedAliasOwner: trustedAliasOwner
    )
}

private func assertRejected(
    fixture: PathWalkerFixture,
    logicalPath: String,
    trustedAliasOwner: uid_t = geteuid()
) throws {
    let before = try Data(contentsOf: fixture.fileURL)
    #expect(throws: Error.self) {
        _ = try readDigest(
            fixture,
            logicalPath: logicalPath,
            trustedAliasOwner: trustedAliasOwner
        )
    }
    #expect(try Data(contentsOf: fixture.fileURL) == before)
}
