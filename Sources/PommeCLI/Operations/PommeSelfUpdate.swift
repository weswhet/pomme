import Darwin
import Foundation

/// A Pomme release version: `MAJOR.MINOR.PATCH` with an optional prerelease
/// such as `alpha.3`. Versions are ordered by Semantic Versioning 2.0
/// precedence, so an alpha sorts before its release and `alpha.10` sorts
/// after `alpha.9`.
struct PommeReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    /// Accepts an optional leading `v`, as in the tag `v0.1.0-alpha.3`.
    init?(_ text: String) {
        var text = Substring(text)
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        let numbers = core.compactMap { Self.isNumeric($0) ? Int($0) : nil }
        guard numbers.count == 3 else { return nil }
        var prerelease: [String] = []
        if parts.count == 2 {
            prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let valid = prerelease.allSatisfy { identifier in
                !identifier.isEmpty && identifier.utf8.allSatisfy { byte in
                    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                        || (0x61...0x7A).contains(byte) || byte == 0x2D
                }
            }
            guard valid else { return nil }
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        self.prerelease = prerelease
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A release has higher precedence than any of its prereleases.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (isNumeric(left) ? Int(left) : nil, isNumeric(right) ? Int(right) : nil) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isNumeric<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}

/// How this `pomme` was installed, which decides how `pomme update` replaces
/// it.
enum PommeInstallMethod: Equatable, Sendable {
    /// Built from source, such as by Scripts/build-local.sh.
    case source
    /// A Homebrew keg. `brew` is the `brew` executable of that Homebrew
    /// prefix.
    case homebrew(brew: String)
    /// The installer package, which installs /usr/local/bin/pomme.
    case package
    /// The install script, or a copy of the release tarball, in `directory`.
    case standalone(directory: String)

    static let packageExecutable = "/usr/local/bin/pomme"
    static let packageReceipt = "/var/db/receipts/com.github.weswhet.pomme.plist"

    var name: String {
        switch self {
        case .source: "source"
        case .homebrew: "homebrew"
        case .package: "package"
        case .standalone: "standalone"
        }
    }

    /// The path to run after an update to confirm the installed version.
    func installedExecutable(current: URL) -> String {
        switch self {
        case .source: current.path
        case .homebrew(let brew): URL(fileURLWithPath: brew).deletingLastPathComponent().appendingPathComponent("pomme").path
        case .package: Self.packageExecutable
        case .standalone(let directory): URL(fileURLWithPath: directory).appendingPathComponent("pomme").path
        }
    }

    /// Only release builds can be updated; a build from source is updated by
    /// rebuilding it. A release build in a Homebrew Cellar belongs to
    /// Homebrew, and /usr/local/bin/pomme with the package's receipt belongs
    /// to the installer package.
    static func detect(
        buildInfo: PommeBuildInfo,
        executable: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Self {
        guard buildInfo.isRelease else { return .source }
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        if let cellar = path.range(of: "/Cellar/pomme/") {
            return .homebrew(brew: String(path[..<cellar.lowerBound]) + "/bin/brew")
        }
        if path == packageExecutable, fileExists(packageReceipt) {
            return .package
        }
        return .standalone(directory: URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
}

/// Which releases an update can install. Homebrew's formula has only stable
/// releases. Otherwise an installed alpha follows the alphas, and an
/// installed stable release follows the stable releases.
enum PommeUpdateChannel: String, Sendable {
    case stable
    case alpha

    static func channel(installed: PommeReleaseVersion, method: PommeInstallMethod) -> Self {
        if case .homebrew = method { return .stable }
        return installed.isPrerelease ? .alpha : .stable
    }
}

/// Where `pomme update` and the update check find the newest release:
/// Homebrew's formula for a Homebrew install, which can lag the GitHub
/// release, and the GitHub releases otherwise.
enum PommeReleaseFeed: String, Codable, Sendable {
    case homebrew
    case stable
    case alpha

    static let repository = "weswhet/pomme"
    static let homebrewFormula = "weswhet/tap/pomme"
    static let installScript = "https://pommevm.dev/install.pl"
    static let formulaURL = URL(string: "https://raw.githubusercontent.com/weswhet/homebrew-tap/HEAD/Formula/pomme.rb")!
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/weswhet/pomme/releases/latest")!
    static let releasesURL = URL(string: "https://api.github.com/repos/weswhet/pomme/releases?per_page=30")!

    init(method: PommeInstallMethod, channel: PommeUpdateChannel) {
        if case .homebrew = method {
            self = .homebrew
        } else {
            self = channel == .alpha ? .alpha : .stable
        }
    }

    var url: URL {
        switch self {
        case .homebrew: Self.formulaURL
        case .stable: Self.latestReleaseURL
        case .alpha: Self.releasesURL
        }
    }

    static func releaseNotesURL(for version: PommeReleaseVersion) -> String {
        "https://github.com/\(repository)/releases/tag/v\(version)"
    }

    /// Returns the newest version in a response, or nil when the feed has no
    /// release yet.
    func newestVersion(in data: Data, statusCode: Int) throws -> PommeReleaseVersion? {
        // GitHub answers 404 for /releases/latest until a stable release is
        // published, and the tap has no formula until then.
        if statusCode == 404 { return nil }
        guard (200..<300).contains(statusCode) else {
            throw PommeSelfUpdateError.lookupFailed("\(url.host ?? "the server") answered HTTP \(statusCode).")
        }
        switch self {
        case .homebrew:
            return try Self.formulaVersion(String(decoding: data, as: UTF8.self))
        case .stable:
            guard let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let version = PommeReleaseVersion(tag)
            else { throw PommeSelfUpdateError.lookupFailed("GitHub's latest release has no version tag.") }
            return version
        case .alpha:
            guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw PommeSelfUpdateError.lookupFailed("GitHub's release list isn't readable.")
            }
            return releases
                .filter { $0["draft"] as? Bool != true }
                .compactMap { ($0["tag_name"] as? String).flatMap(PommeReleaseVersion.init) }
                .max()
        }
    }

    /// Reads the version from the formula's release URL, such as
    /// `.../releases/download/v0.1.0/pomme-0.1.0-arm64.tar.gz`.
    static func formulaVersion(_ formula: String) throws -> PommeReleaseVersion {
        let marker = "/releases/download/v"
        for line in formula.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url "), let start = trimmed.range(of: marker) else { continue }
            let tail = trimmed[start.upperBound...]
            if let end = tail.firstIndex(of: "/"), let version = PommeReleaseVersion(String(tail[..<end])) {
                return version
            }
        }
        throw PommeSelfUpdateError.lookupFailed("Homebrew's pomme formula has no release URL.")
    }
}

enum PommeSelfUpdateError: Error, LocalizedError, Equatable {
    case sourceBuild
    case unknownVersion(String)
    case noRelease(PommeReleaseFeed)
    case lookupFailed(String)
    case updateFailed(command: String, status: Int32)
    case versionMismatch(path: String, expected: String, observed: String?)

    var errorDescription: String? {
        switch self {
        case .sourceBuild:
            "This pomme was built from source, so `pomme update` can't replace it. "
                + "To update it, pull the newest source and run `bash Scripts/build-local.sh`."
        case .unknownVersion(let version):
            "This pomme reports version \(version), which isn't a release version, so `pomme update` can't compare it."
        case .noRelease(.homebrew):
            "Homebrew's \(PommeReleaseFeed.homebrewFormula) formula isn't published yet."
        case .noRelease(.stable):
            "No stable Pomme release is published yet. To install the newest alpha, run "
                + "`curl -fsSL \(PommeReleaseFeed.installScript) | POMME_CHANNEL=alpha perl`."
        case .noRelease(.alpha):
            "No Pomme release is published yet."
        case .lookupFailed(let detail):
            "Couldn't find the newest Pomme release. \(detail)"
        case .updateFailed(let command, let status):
            "Pomme wasn't updated: `\(command)` exited with status \(status)."
        case .versionMismatch(let path, let expected, let observed):
            "The update finished, but \(path) reports version \(observed ?? "nothing") instead of \(expected)."
        }
    }
}

/// `pomme update`: finds the newest release for this install's channel and
/// installs it the way this `pomme` was installed. Like Codex's updater, it
/// never replaces its own executable: Homebrew upgrades a Homebrew install,
/// and the install script, which checks the release's digest and Developer ID
/// signature, replaces any other release install.
enum PommeSelfUpdate {
    struct Dependencies: Sendable {
        /// Fetches a URL and returns the body and HTTP status code.
        var fetch: @Sendable (URL) async throws -> (Data, Int)
        /// Runs a program with this process's terminal and returns its exit
        /// status. With `stdoutToStderr`, the program's standard output goes
        /// to standard error so that JSON output stays parseable.
        var run: @Sendable (_ executable: String, _ arguments: [String], _ stdoutToStderr: Bool) throws -> Int32
        /// Runs `pomme --version` at a path and returns the version it reports.
        var installedVersion: @Sendable (_ executable: String) -> String?
        var buildInfo: PommeBuildInfo
        var executable: @Sendable () throws -> URL
        var fileExists: @Sendable (String) -> Bool
        var now: @Sendable () -> Date
        var cacheURL: URL?

        static let live = Dependencies(
            fetch: { url in try await PommeSelfUpdate.liveFetch(url) },
            run: { executable, arguments, stdoutToStderr in
                try PommeSelfUpdate.liveRun(executable, arguments: arguments, stdoutToStderr: stdoutToStderr)
            },
            installedVersion: { PommeSelfUpdate.liveInstalledVersion($0) },
            buildInfo: .current,
            executable: { try PommeExecutableIdentity.currentExecutableURL() },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            now: { Date() },
            cacheURL: PommeUpdateCheckCache.defaultURL()
        )
    }

    /// The state that decides an update: what is installed, how, and what
    /// its feed offers.
    struct Status: Sendable {
        let installed: PommeReleaseVersion
        let method: PommeInstallMethod
        let channel: PommeUpdateChannel
        let feed: PommeReleaseFeed
        let latest: PommeReleaseVersion?

        var updateAvailable: Bool { latest.map { $0 > installed } ?? false }
    }

    static let requestTimeout: TimeInterval = 10

    /// Looks up the newest release for this install and records it for the
    /// update check.
    static func status(dependencies: Dependencies) async throws -> Status {
        let method = PommeInstallMethod.detect(
            buildInfo: dependencies.buildInfo,
            executable: try dependencies.executable(),
            fileExists: dependencies.fileExists
        )
        guard method != .source else { throw PommeSelfUpdateError.sourceBuild }
        guard let installed = PommeReleaseVersion(dependencies.buildInfo.version) else {
            throw PommeSelfUpdateError.unknownVersion(dependencies.buildInfo.version)
        }
        let channel = PommeUpdateChannel.channel(installed: installed, method: method)
        let feed = PommeReleaseFeed(method: method, channel: channel)
        let latest: PommeReleaseVersion?
        do {
            let (data, statusCode) = try await dependencies.fetch(feed.url)
            latest = try feed.newestVersion(in: data, statusCode: statusCode)
        } catch let error as PommeSelfUpdateError {
            throw error
        } catch {
            throw PommeSelfUpdateError.lookupFailed(error.localizedDescription)
        }
        if let cacheURL = dependencies.cacheURL {
            var cache = PommeUpdateCheckCache.read(from: cacheURL) ?? .init()
            cache.record(feed: feed, latest: latest, at: dependencies.now())
            cache.write(to: cacheURL)
        }
        return Status(installed: installed, method: method, channel: channel, feed: feed, latest: latest)
    }

    /// The command that installs `version`, as a user would type it.
    static func commandLine(method: PommeInstallMethod, version: PommeReleaseVersion) -> String? {
        switch method {
        case .source:
            nil
        case .homebrew:
            "brew upgrade \(PommeReleaseFeed.homebrewFormula)"
        case .package:
            "curl -fsSL \(PommeReleaseFeed.installScript) | perl - --version \(version) --package"
        case .standalone(let directory):
            "curl -fsSL \(PommeReleaseFeed.installScript) | perl - --version \(version) --install-dir "
                + shellQuoted(directory)
        }
    }

    static func run(checkOnly: Bool, structuredOutput: Bool, dependencies: Dependencies = .live) async throws -> PommeOperationResult {
        let status = try await status(dependencies: dependencies)
        guard let latest = status.latest else { throw PommeSelfUpdateError.noRelease(status.feed) }
        let command = commandLine(method: status.method, version: latest) ?? ""
        var payload: [String: Any] = [
            "ok": true,
            "installedVersion": status.installed.description,
            "latestVersion": latest.description,
            "updateAvailable": status.updateAvailable,
            "installMethod": status.method.name,
            "channel": status.channel.rawValue,
            "updated": false,
            "hostExitCode": 0,
        ]
        guard status.updateAvailable else {
            return result(payload, text: "Pomme \(status.installed) is up to date.")
        }
        payload["updateCommand"] = command
        if checkOnly {
            return result(payload, text: "Pomme \(latest) is available. You have \(status.installed). "
                + "To update, run `pomme update`.\nRelease notes: \(PommeReleaseFeed.releaseNotesURL(for: latest))")
        }

        FileHandle.standardError.write(Data("Updating Pomme \(status.installed) to \(latest) with `\(command)`.\n".utf8))
        let exitStatus: Int32
        switch status.method {
        case .source:
            throw PommeSelfUpdateError.sourceBuild
        case .homebrew(let brew):
            exitStatus = try dependencies.run(brew, ["upgrade", PommeReleaseFeed.homebrewFormula], structuredOutput)
        case .package, .standalone:
            exitStatus = try await runInstallScript(
                method: status.method, version: latest, structuredOutput: structuredOutput, dependencies: dependencies
            )
        }
        guard exitStatus == 0 else { throw PommeSelfUpdateError.updateFailed(command: command, status: exitStatus) }

        let installedPath = status.method.installedExecutable(current: try dependencies.executable())
        let observed = dependencies.installedVersion(installedPath)
        guard observed == latest.description else {
            throw PommeSelfUpdateError.versionMismatch(path: installedPath, expected: latest.description, observed: observed)
        }
        payload["updated"] = true
        payload["updateAvailable"] = false
        payload["installedVersion"] = latest.description
        payload["previousVersion"] = status.installed.description
        return result(payload, text: "Updated Pomme from \(status.installed) to \(latest).")
    }

    /// Downloads the install script to a private file and runs it, so that a
    /// failed download fails the update instead of running a partial script.
    private static func runInstallScript(
        method: PommeInstallMethod,
        version: PommeReleaseVersion,
        structuredOutput: Bool,
        dependencies: Dependencies
    ) async throws -> Int32 {
        let (script, statusCode) = try await dependencies.fetch(URL(string: PommeReleaseFeed.installScript)!)
        guard statusCode == 200, script.starts(with: Data("#!/usr/bin/perl".utf8)) else {
            throw PommeSelfUpdateError.lookupFailed("The install script at \(PommeReleaseFeed.installScript) isn't available.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("install.pl")
        try script.write(to: scriptURL, options: .withoutOverwriting)
        var arguments = [scriptURL.path, "--version", version.description]
        switch method {
        case .package:
            arguments.append("--package")
        case .standalone(let installDirectory):
            arguments += ["--install-dir", installDirectory]
        case .source, .homebrew:
            break
        }
        return try dependencies.run("/usr/bin/perl", arguments, structuredOutput)
    }

    private static func result(_ payload: [String: Any], text: String) -> PommeOperationResult {
        PommeOperationResult(title: "Update", vmName: nil, ok: true, hostExitCode: 0, text: text, payload: payload)
    }

    static func shellQuoted(_ text: String) -> String {
        let safe = text.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || [0x2F, 0x2E, 0x5F, 0x2D].contains(byte)
        }
        return safe && !text.isEmpty ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Live dependencies

    static func liveFetch(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.setValue("pomme/\(PommeBuildInfo.current.version)", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = requestTimeout * 3
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func liveRun(_ executable: String, arguments: [String], stdoutToStderr: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = stdoutToStderr ? FileHandle.standardError : FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    }

    /// Parses `pomme VERSION (COMMIT)`.
    static func liveInstalledVersion(_ executable: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return versionFromVersionLine(String(decoding: data, as: UTF8.self))
    }

    static func versionFromVersionLine(_ line: String) -> String? {
        let words = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 3, words[0] == "pomme" else { return nil }
        return String(words[1])
    }
}
