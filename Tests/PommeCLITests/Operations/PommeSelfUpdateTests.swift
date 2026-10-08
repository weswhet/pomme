import Foundation
import Testing

@Suite("pomme update")
struct PommeSelfUpdateTests {
    // MARK: Versions

    @Test("Parses release and alpha versions, with or without a leading v")
    func parsesVersions() throws {
        let alpha = try #require(PommeReleaseVersion("v0.1.0-alpha.3"))
        #expect(alpha.description == "0.1.0-alpha.3")
        #expect(alpha.isPrerelease)
        #expect(PommeReleaseVersion("1.2.3")?.description == "1.2.3")
        #expect(PommeReleaseVersion("1.2.3")?.isPrerelease == false)
        for invalid in ["", "1.2", "1.2.3.4", "1.x.3", "1.2.3-", "1.2.3-alpha..1", "1.2.3-al pha", "unknown", "v"] {
            #expect(PommeReleaseVersion(invalid) == nil, "\(invalid)")
        }
    }

    @Test("Orders versions by Semantic Versioning precedence")
    func ordersVersions() throws {
        let ordered = ["0.1.0-alpha.1", "0.1.0-alpha.2", "0.1.0-alpha.10", "0.1.0-beta", "0.1.0", "0.1.1", "0.2.0-alpha.1", "0.10.0", "1.0.0"]
        let versions = try ordered.map { try #require(PommeReleaseVersion($0)) }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower), "\(higher) < \(lower)")
        }
        #expect(try #require(PommeReleaseVersion("1.0.0-alpha")) < #require(PommeReleaseVersion("1.0.0-alpha.1")))
        #expect(try #require(PommeReleaseVersion("1.0.0-1")) < #require(PommeReleaseVersion("1.0.0-alpha")))
    }

    // MARK: Install method and channel

    @Test("Detects how a release build was installed")
    func detectsInstallMethod() {
        let release = buildInfo(version: "0.1.0")
        #expect(PommeInstallMethod.detect(buildInfo: buildInfo(version: "0.1.0", distribution: "source"),
                                          executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/pomme/0.1.0/bin/pomme")) == .source)
        #expect(PommeInstallMethod.detect(buildInfo: release,
                                          executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/pomme/0.1.0/bin/pomme"))
            == .homebrew(brew: "/opt/homebrew/bin/brew"))
        #expect(PommeInstallMethod.detect(buildInfo: release,
                                          executable: URL(fileURLWithPath: "/usr/local/bin/pomme"),
                                          fileExists: { $0 == PommeInstallMethod.packageReceipt }) == .package)
        #expect(PommeInstallMethod.detect(buildInfo: release,
                                          executable: URL(fileURLWithPath: "/usr/local/bin/pomme"),
                                          fileExists: { _ in false }) == .standalone(directory: "/usr/local/bin"))
        #expect(PommeInstallMethod.detect(buildInfo: release,
                                          executable: URL(fileURLWithPath: "/Users/me/.local/bin/pomme"))
            == .standalone(directory: "/Users/me/.local/bin"))
    }

    @Test("An alpha follows alphas, a release follows releases, and Homebrew follows its formula")
    func choosesChannelAndFeed() throws {
        let alpha = try #require(PommeReleaseVersion("0.1.0-alpha.3"))
        let release = try #require(PommeReleaseVersion("0.1.0"))
        let standalone = PommeInstallMethod.standalone(directory: "/tmp")
        let homebrew = PommeInstallMethod.homebrew(brew: "/opt/homebrew/bin/brew")
        #expect(PommeUpdateChannel.channel(installed: alpha, method: standalone) == .alpha)
        #expect(PommeUpdateChannel.channel(installed: release, method: standalone) == .stable)
        #expect(PommeUpdateChannel.channel(installed: alpha, method: homebrew) == .stable)
        #expect(PommeReleaseFeed(method: standalone, channel: .alpha) == .alpha)
        #expect(PommeReleaseFeed(method: .package, channel: .stable) == .stable)
        #expect(PommeReleaseFeed(method: homebrew, channel: .stable) == .homebrew)
        #expect(PommeReleaseFeed.alpha.url.absoluteString.hasPrefix("https://api.github.com/repos/weswhet/pomme/releases?"))
        #expect(PommeReleaseFeed.stable.url.absoluteString == "https://api.github.com/repos/weswhet/pomme/releases/latest")
        #expect(PommeReleaseFeed.homebrew.url.absoluteString.hasSuffix("/weswhet/homebrew-tap/HEAD/Formula/pomme.rb"))
    }

    // MARK: Feeds

    @Test("Reads the newest version from each feed")
    func readsFeeds() throws {
        let latest = Data(#"{"tag_name": "v0.2.0", "body": null}"#.utf8)
        #expect(try PommeReleaseFeed.stable.newestVersion(in: latest, statusCode: 200)?.description == "0.2.0")

        let list = Data(#"[{"tag_name": "v0.1.0-alpha.9"}, {"tag_name": "v0.1.0-alpha.10"}, {"tag_name": "v0.1.0-alpha.11", "draft": true}, {"tag_name": "nightly"}]"#.utf8)
        #expect(try PommeReleaseFeed.alpha.newestVersion(in: list, statusCode: 200)?.description == "0.1.0-alpha.10")
        #expect(try PommeReleaseFeed.alpha.newestVersion(in: Data("[]".utf8), statusCode: 200) == nil)

        let formula = """
        class Pomme < Formula
          url "https://github.com/weswhet/pomme/releases/download/v0.1.0/pomme-0.1.0-arm64.tar.gz"
          sha256 "\(String(repeating: "a", count: 64))"
        end
        """
        #expect(try PommeReleaseFeed.homebrew.newestVersion(in: Data(formula.utf8), statusCode: 200)?.description == "0.1.0")
    }

    @Test("A missing feed means no release yet, and other failures are errors")
    func reportsFeedFailures() throws {
        #expect(try PommeReleaseFeed.stable.newestVersion(in: Data(), statusCode: 404) == nil)
        #expect(throws: PommeSelfUpdateError.self) {
            try PommeReleaseFeed.stable.newestVersion(in: Data(), statusCode: 403)
        }
        #expect(throws: PommeSelfUpdateError.self) {
            try PommeReleaseFeed.stable.newestVersion(in: Data("{}".utf8), statusCode: 200)
        }
        #expect(throws: PommeSelfUpdateError.self) {
            try PommeReleaseFeed.homebrew.newestVersion(in: Data("class Pomme < Formula\nend\n".utf8), statusCode: 200)
        }
    }

    @Test("Shows the command that each install method runs")
    func describesCommands() throws {
        let version = try #require(PommeReleaseVersion("0.1.0-alpha.4"))
        #expect(PommeSelfUpdate.commandLine(method: .homebrew(brew: "/opt/homebrew/bin/brew"), version: version)
            == "brew upgrade weswhet/tap/pomme")
        #expect(PommeSelfUpdate.commandLine(method: .package, version: version)
            == "curl -fsSL https://pommevm.dev/install.pl | perl - --version 0.1.0-alpha.4 --package")
        #expect(PommeSelfUpdate.commandLine(method: .standalone(directory: "/Users/me/My Tools"), version: version)
            == "curl -fsSL https://pommevm.dev/install.pl | perl - --version 0.1.0-alpha.4 --install-dir '/Users/me/My Tools'")
        #expect(PommeSelfUpdate.commandLine(method: .source, version: version) == nil)
        #expect(PommeSelfUpdate.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(PommeSelfUpdate.versionFromVersionLine("pomme 0.1.0-alpha.4 (abc1234)\n") == "0.1.0-alpha.4")
        #expect(PommeSelfUpdate.versionFromVersionLine("something else") == nil)
    }

    // MARK: Running an update

    @Test("Reports an installed release that is up to date and records the check")
    func reportsCurrentRelease() async throws {
        let harness = try Harness(version: "0.1.0-alpha.4", executable: "/Users/me/.local/bin/pomme",
                                  responses: [PommeReleaseFeed.alpha.url: alphaList("0.1.0-alpha.4")])
        defer { harness.cleanup() }

        let result = try await PommeSelfUpdate.run(checkOnly: false, structuredOutput: false, dependencies: harness.dependencies)

        #expect(result.text == "Pomme 0.1.0-alpha.4 is up to date.")
        #expect(result.payload["updateAvailable"] as? Bool == false)
        #expect(result.payload["installMethod"] as? String == "standalone")
        #expect(result.payload["channel"] as? String == "alpha")
        #expect(harness.recorder.runs.isEmpty)
        let cache = try #require(PommeUpdateCheckCache.read(from: harness.cacheURL))
        #expect(cache.feed == .alpha)
        #expect(cache.latestVersion == "0.1.0-alpha.4")
        #expect(cache.checkedAt == harness.now)
    }

    @Test("--check reports an update without installing it")
    func checksOnly() async throws {
        let harness = try Harness(version: "0.1.0-alpha.4", executable: "/Users/me/.local/bin/pomme",
                                  responses: [PommeReleaseFeed.alpha.url: alphaList("0.1.0-alpha.5")])
        defer { harness.cleanup() }

        let result = try await PommeSelfUpdate.run(checkOnly: true, structuredOutput: true, dependencies: harness.dependencies)

        #expect(result.payload["updateAvailable"] as? Bool == true)
        #expect(result.payload["latestVersion"] as? String == "0.1.0-alpha.5")
        #expect(result.payload["updated"] as? Bool == false)
        #expect((result.payload["updateCommand"] as? String)?.contains("--version 0.1.0-alpha.5 --install-dir /Users/me/.local/bin") == true)
        #expect(result.text.contains("https://github.com/weswhet/pomme/releases/tag/v0.1.0-alpha.5"))
        #expect(harness.recorder.runs.isEmpty)
    }

    @Test("A Homebrew install runs brew upgrade and confirms the new version")
    func updatesWithHomebrew() async throws {
        let harness = try Harness(version: "0.1.0", executable: "/opt/homebrew/Cellar/pomme/0.1.0/bin/pomme",
                                  responses: [PommeReleaseFeed.homebrew.url: formula("0.2.0")],
                                  installedVersion: "0.2.0")
        defer { harness.cleanup() }

        let result = try await PommeSelfUpdate.run(checkOnly: false, structuredOutput: true, dependencies: harness.dependencies)

        #expect(harness.recorder.runs == [.init(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "weswhet/tap/pomme"], stdoutToStderr: true)])
        #expect(harness.recorder.versionChecks == ["/opt/homebrew/bin/pomme"])
        #expect(result.text == "Updated Pomme from 0.1.0 to 0.2.0.")
        #expect(result.payload["updated"] as? Bool == true)
        #expect(result.payload["previousVersion"] as? String == "0.1.0")
        #expect(result.payload["installedVersion"] as? String == "0.2.0")
    }

    @Test("A standalone install runs the downloaded install script for the new version")
    func updatesWithInstallScript() async throws {
        let script = Data("#!/usr/bin/perl\nprint \"install\\n\";\n".utf8)
        let harness = try Harness(version: "0.1.0-alpha.4", executable: "/Users/me/.local/bin/pomme",
                                  responses: [PommeReleaseFeed.alpha.url: alphaList("0.1.0-alpha.6", "0.1.0-alpha.5"),
                                              URL(string: PommeReleaseFeed.installScript)!: script],
                                  installedVersion: "0.1.0-alpha.6")
        defer { harness.cleanup() }

        _ = try await PommeSelfUpdate.run(checkOnly: false, structuredOutput: false, dependencies: harness.dependencies)

        let run = try #require(harness.recorder.runs.first)
        #expect(harness.recorder.runs.count == 1)
        #expect(run.executable == "/usr/bin/perl")
        #expect(Array(run.arguments.dropFirst()) == ["--version", "0.1.0-alpha.6", "--install-dir", "/Users/me/.local/bin"])
        #expect(harness.recorder.scripts == [script])
        #expect(!run.stdoutToStderr)
        #expect(!FileManager.default.fileExists(atPath: run.arguments[0]))
        #expect(harness.recorder.versionChecks == ["/Users/me/.local/bin/pomme"])
    }

    @Test("A package install runs the install script with --package")
    func updatesPackage() async throws {
        let harness = try Harness(version: "0.1.0", executable: "/usr/local/bin/pomme",
                                  responses: [PommeReleaseFeed.stable.url: Data(#"{"tag_name": "v0.2.0"}"#.utf8),
                                              URL(string: PommeReleaseFeed.installScript)!: Data("#!/usr/bin/perl\n".utf8)],
                                  installedVersion: "0.2.0", receipt: true)
        defer { harness.cleanup() }

        _ = try await PommeSelfUpdate.run(checkOnly: false, structuredOutput: false, dependencies: harness.dependencies)

        #expect(Array(try #require(harness.recorder.runs.first).arguments.dropFirst()) == ["--version", "0.2.0", "--package"])
        #expect(harness.recorder.versionChecks == ["/usr/local/bin/pomme"])
    }

    @Test("Reports a failed update command and a version that didn't change")
    func reportsFailures() async throws {
        let failing = try Harness(version: "0.1.0", executable: "/opt/homebrew/Cellar/pomme/0.1.0/bin/pomme",
                                  responses: [PommeReleaseFeed.homebrew.url: formula("0.2.0")], runStatus: 1)
        defer { failing.cleanup() }
        await #expect(throws: PommeSelfUpdateError.updateFailed(command: "brew upgrade weswhet/tap/pomme", status: 1)) {
            try await PommeSelfUpdate.run(checkOnly: false, structuredOutput: false, dependencies: failing.dependencies)
        }

        let stale = try Harness(version: "0.1.0", executable: "/opt/homebrew/Cellar/pomme/0.1.0/bin/pomme",
                                responses: [PommeReleaseFeed.homebrew.url: formula("0.2.0")], installedVersion: "0.1.0")
        defer { stale.cleanup() }
        await #expect(throws: PommeSelfUpdateError.versionMismatch(path: "/opt/homebrew/bin/pomme", expected: "0.2.0", observed: "0.1.0")) {
            try await PommeSelfUpdate.run(checkOnly: false, structuredOutput: false, dependencies: stale.dependencies)
        }
    }

    @Test("Refuses a source build and explains a feed without releases")
    func refusesWithoutRelease() async throws {
        let source = try Harness(version: "0.1.0", executable: "/Users/me/.local/bin/pomme", responses: [:], distribution: "source")
        defer { source.cleanup() }
        await #expect(throws: PommeSelfUpdateError.sourceBuild) {
            try await PommeSelfUpdate.run(checkOnly: true, structuredOutput: false, dependencies: source.dependencies)
        }
        #expect(source.recorder.fetches.isEmpty)

        let unpublished = try Harness(version: "0.1.0", executable: "/Users/me/.local/bin/pomme", responses: [:])
        defer { unpublished.cleanup() }
        await #expect(throws: PommeSelfUpdateError.noRelease(.stable)) {
            try await PommeSelfUpdate.run(checkOnly: true, structuredOutput: false, dependencies: unpublished.dependencies)
        }
        #expect(PommeSelfUpdateError.noRelease(.stable).errorDescription?.contains("| POMME_CHANNEL=alpha perl") == true)
        #expect(PommeSelfUpdateError.noRelease(.homebrew).errorDescription == "Homebrew's weswhet/tap/pomme formula isn't published yet.")
    }
}

private func buildInfo(version: String, distribution: String = "release") -> PommeBuildInfo {
    PommeBuildInfo(dictionary: [
        "CFBundleShortVersionString": version,
        "PommeGitCommit": "abc1234",
        "PommeDistribution": distribution,
    ])
}

private func alphaList(_ versions: String...) -> Data {
    Data(("[" + versions.map { #"{"tag_name": "v\#($0)", "prerelease": true}"# }.joined(separator: ",") + "]").utf8)
}

private func formula(_ version: String) -> Data {
    Data(#"  url "https://github.com/weswhet/pomme/releases/download/v\#(version)/pomme-\#(version)-arm64.tar.gz""#.utf8)
}

/// Fake network, processes, and cache for one update.
private struct Harness {
    struct Run: Equatable {
        let executable: String
        let arguments: [String]
        let stdoutToStderr: Bool
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs: [Run] = []
        private var _scripts: [Data] = []
        private var _fetches: [URL] = []
        private var _versionChecks: [String] = []

        func record<T>(_ body: (Recorder) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }

        var runs: [Run] { record { $0._runs } }
        var scripts: [Data] { record { $0._scripts } }
        var fetches: [URL] { record { $0._fetches } }
        var versionChecks: [String] { record { $0._versionChecks } }
        func add(run: Run, script: Data?) { record { $0._runs.append(run); if let script { $0._scripts.append(script) } } }
        func add(fetch: URL) { record { $0._fetches.append(fetch) } }
        func add(versionCheck: String) { record { $0._versionChecks.append(versionCheck) } }
    }

    let recorder: Recorder
    let directory: URL
    let cacheURL: URL
    let now: Date
    let dependencies: PommeSelfUpdate.Dependencies

    init(
        version: String,
        executable: String,
        responses: [URL: Data],
        installedVersion: String? = nil,
        runStatus: Int32 = 0,
        receipt: Bool = false,
        distribution: String = "release"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-self-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        cacheURL = directory.appendingPathComponent("cache/update-check.json")
        let recorder = Recorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        self.recorder = recorder
        self.now = now
        dependencies = PommeSelfUpdate.Dependencies(
            fetch: { url in
                recorder.add(fetch: url)
                guard let data = responses[url] else { return (Data(), 404) }
                return (data, 200)
            },
            run: { executable, arguments, stdoutToStderr in
                let script = executable == "/usr/bin/perl" ? try? Data(contentsOf: URL(fileURLWithPath: arguments[0])) : nil
                recorder.add(run: Run(executable: executable, arguments: arguments, stdoutToStderr: stdoutToStderr), script: script)
                return runStatus
            },
            installedVersion: { path in
                recorder.add(versionCheck: path)
                return installedVersion
            },
            buildInfo: buildInfo(version: version, distribution: distribution),
            executable: { URL(fileURLWithPath: executable) },
            fileExists: { receipt && $0 == PommeInstallMethod.packageReceipt },
            now: { now },
            cacheURL: cacheURL
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
