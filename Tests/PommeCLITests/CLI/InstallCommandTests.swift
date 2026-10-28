import ArgumentParser
import Darwin
import Foundation
import Testing

/// A scratch folder with a flat package, a bundle package, and links to both.
struct InstallPackageFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (PommeHostPackage.xarMagic + Data([0, 28, 0, 1])).write(to: flat)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("not a package".utf8).write(to: root.appendingPathComponent("plain.pkg"))
        try Data("text".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("latest.pkg"), withDestinationURL: flat)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("folder.pkg"), withDestinationURL: bundle)
    }

    var flat: URL { root.appendingPathComponent("Tool.pkg") }
    var bundle: URL { root.appendingPathComponent("Bundle.pkg") }

    func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Install command grammar and package checks")
struct InstallCommandTests {
    @Test("--pkg is required")
    func packageIsRequired() {
        #expect(throws: (any Error).self) { _ = try InstallCommand.parse(["dev"]) }
    }

    @Test("The VM name is optional so POMME_VM_NAME can supply it")
    func nameIsOptional() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let omitted = try InstallCommand.parse(["--pkg", fixture.flat.path])
        let named = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path])
        #expect(omitted.name == nil)
        #expect(named.name == "dev")
    }

    @Test("Pomme waits 30 minutes for the installer unless --timeout says otherwise")
    func defaultTimeout() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let defaulted = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path])
        let explicit = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path, "--timeout", "5"])
        #expect(try defaulted.makeInstall(environment: [:]).install.timeout == 1_800)
        #expect(try explicit.makeInstall(environment: [:]).install.timeout == 5)
        // Other guest commands keep the 60-second default.
        #expect(try defaulted.timeout.value() == Constants.defaultGuestCommandTimeout)
        #expect(throws: (any Error).self) {
            _ = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path, "--timeout", "0"])
        }
    }

    @Test("A --timeout over one day is refused before it reaches the guest", arguments: ["86401", "1e300"])
    func refusesHugeTimeout(_ value: String) throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        do {
            _ = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path, "--timeout", value])
            Issue.record("--timeout \(value) was accepted.")
        } catch {
            #expect(InstallCommand.fullMessage(for: error).contains("at most 86400 seconds"))
        }
        let day = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path, "--timeout", "86400"])
        #expect(try day.makeInstall(environment: [:]).install.timeout == 86_400)
        #expect(PommeGuestPackageInstall.seconds(1e300).hasPrefix("1000000"))
    }

    @Test("The target is the given name, or POMME_VM_NAME when the name is omitted")
    func resolvesTarget() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let omitted = try InstallCommand.parse(["--pkg", fixture.flat.path])
        let named = try InstallCommand.parse(["dev", "--pkg", fixture.flat.path])
        #expect(try omitted.makeInstall(environment: ["POMME_VM_NAME": "fallback"]).vm == "fallback")
        #expect(try named.makeInstall(environment: ["POMME_VM_NAME": "fallback"]).vm == "dev")
        #expect(try named.makeInstall(environment: [:]).install.package.name == "Tool.pkg")
        #expect(throws: ValidationError.self) { _ = try omitted.makeInstall(environment: [:]) }
        #expect(throws: ValidationError.self) { _ = try omitted.makeInstall(environment: ["POMME_VM_NAME": ""]) }
    }

    @Test("A flat package is accepted whatever the extension's case")
    func acceptsFlatPackage() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let upper = fixture.root.appendingPathComponent("UPPER.PKG")
        try FileManager.default.copyItem(at: fixture.flat, to: upper)

        let package = try PommeHostPackage.validated(path: fixture.flat.path)
        #expect(package.name == "Tool.pkg")
        #expect(package.url.lastPathComponent == "Tool.pkg")
        #expect(try PommeHostPackage.validated(path: upper.path).name == "UPPER.PKG")
        let relative = try PommeHostPackage.validated(path: "Tool.pkg", currentDirectory: fixture.root.path)
        #expect(relative.url.lastPathComponent == "Tool.pkg")
    }

    @Test("A link to a package is copied from its target under the given name")
    func followsLinkToFile() throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        let package = try PommeHostPackage.validated(path: fixture.path("latest.pkg"))
        #expect(package.name == "latest.pkg")
        #expect(package.url.lastPathComponent == "Tool.pkg")
        var status = stat()
        #expect(lstat(package.url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG)
    }

    @Test("Paths that aren't flat packages are refused", arguments: [
        ("Bundle.pkg", "is a folder"),
        ("folder.pkg", "is a folder"),
        ("notes.txt", "ending in .pkg"),
        ("missing.pkg", "No such package"),
        ("plain.pkg", "xar header"),
        (".pkg", "ending in .pkg")
    ])
    func refusesNonPackages(_ name: String, _ message: String) throws {
        let fixture = try InstallPackageFixture()
        defer { fixture.remove() }
        do {
            _ = try InstallCommand.parse(["dev", "--pkg", fixture.path(name)])
            Issue.record("\(name) was accepted.")
        } catch {
            #expect(InstallCommand.fullMessage(for: error).contains(message))
        }
    }

    @Test("An empty --pkg value is refused")
    func refusesEmptyPath() {
        #expect(throws: ValidationError.self) { _ = try PommeHostPackage.validated(path: "") }
    }

    @Test("install is listed in root help and guest command discovery")
    func discovery() {
        #expect(PommeCLI.configuration.subcommands.contains { $0 == InstallCommand.self })
        #expect(CommandCatalog.groups.contains { $0.name == "guest" && $0.commands.contains("install") })
        #expect(CommandCatalog.agentHelp.contains("guest=exec|shell|log|jobs|sessions|cp|cat|install;"))
        #expect(InstallCommand.helpMessage().contains("--pkg <path>"))
    }
}
