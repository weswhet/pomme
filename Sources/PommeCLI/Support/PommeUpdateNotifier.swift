import ArgumentParser
import Darwin
import Foundation

/// The update check's record of the newest release, like Codex's
/// `version.json`. It is a cache: deleting it only causes another check.
struct PommeUpdateCheckCache: Codable, Equatable, Sendable {
    /// The feed that `latestVersion` came from. A cache from another feed,
    /// such as after switching from the install script to Homebrew, is stale.
    var feed: PommeReleaseFeed?
    /// The newest version in the feed, or nil when it has no release yet.
    var latestVersion: String?
    var checkedAt: Date?
    /// When a background check started. Another one doesn't start while it
    /// may still be running.
    var checkStartedAt: Date?
    var notifiedVersion: String?
    var notifiedAt: Date?

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.github.weswhet.pomme", isDirectory: true)
            .appendingPathComponent("update-check.json", isDirectory: false)
    }

    static func read(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    /// Writes the cache atomically. The update check is best effort, so a
    /// failure is ignored.
    func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: .atomic)
    }

    mutating func record(feed: PommeReleaseFeed, latest: PommeReleaseVersion?, at date: Date) {
        self.feed = feed
        latestVersion = latest?.description
        checkedAt = date
        checkStartedAt = nil
    }
}

/// A Codex-style update check that never delays a command on the network.
/// After a command finishes, it prints a notice when the cached newest
/// release is newer than this build. When the cache is more than 20 hours
/// old, it starts a detached `pomme --pomme-update-check` that refreshes the
/// cache for a later command.
///
/// It runs only for release builds, only when standard error is a terminal,
/// only for table output, and never when `CI` or `POMME_NO_UPDATE_CHECK` is
/// set, so scripts, coding agents, and JSON output never see it.
enum PommeUpdateNotifier {
    static let flag = "--pomme-update-check"
    static let disableVariable = "POMME_NO_UPDATE_CHECK"
    static let checkInterval: TimeInterval = 20 * 60 * 60
    static let noticeInterval: TimeInterval = 20 * 60 * 60
    /// A background check that hasn't recorded a result after this long is
    /// presumed to have failed, and the next command starts another.
    static let retryInterval: TimeInterval = 10 * 60

    struct Context {
        var buildInfo: PommeBuildInfo
        var environment: [String: String]
        var stderrIsTerminal: Bool
        var executable: URL?
        var fileExists: (String) -> Bool
        var now: Date

        static func live() -> Context {
            Context(
                buildInfo: .current,
                environment: ProcessInfo.processInfo.environment,
                stderrIsTerminal: isatty(STDERR_FILENO) == 1,
                executable: try? PommeExecutableIdentity.currentExecutableURL(),
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                now: Date()
            )
        }
    }

    struct Decision: Equatable {
        var notice: String?
        var refresh = false
        /// The cache to write, when it changed.
        var cache: PommeUpdateCheckCache?
    }

    static func isEnabled(_ context: Context) -> Bool {
        guard context.buildInfo.isRelease, context.stderrIsTerminal, context.environment["CI"] == nil else {
            return false
        }
        let disabled = context.environment[disableVariable] ?? ""
        return disabled.isEmpty || disabled == "0"
    }

    static func decide(context: Context, cache: PommeUpdateCheckCache?) -> Decision {
        guard isEnabled(context),
              let executable = context.executable,
              let installed = PommeReleaseVersion(context.buildInfo.version)
        else { return Decision() }
        let method = PommeInstallMethod.detect(
            buildInfo: context.buildInfo, executable: executable, fileExists: context.fileExists
        )
        guard method != .source else { return Decision() }
        let feed = PommeReleaseFeed(method: method, channel: .channel(installed: installed, method: method))
        let now = context.now
        func within(_ date: Date?, _ interval: TimeInterval) -> Bool {
            guard let date else { return false }
            return date <= now && now.timeIntervalSince(date) < interval
        }

        let original = cache ?? PommeUpdateCheckCache()
        var updated = original
        var decision = Decision()
        if original.feed == feed,
           let text = original.latestVersion,
           let latest = PommeReleaseVersion(text),
           latest > installed,
           !(original.notifiedVersion == text && within(original.notifiedAt, noticeInterval)) {
            decision.notice = notice(installed: installed, latest: latest)
            updated.notifiedVersion = text
            updated.notifiedAt = now
        }
        let fresh = original.feed == feed && within(original.checkedAt, checkInterval)
        if !fresh, !within(original.checkStartedAt, retryInterval) {
            decision.refresh = true
            updated.checkStartedAt = now
        }
        if updated != original { decision.cache = updated }
        return decision
    }

    static func notice(installed: PommeReleaseVersion, latest: PommeReleaseVersion) -> String {
        "Pomme \(latest) is available. You have \(installed). To update, run `pomme update`."
    }

    /// Runs after a public command succeeds. `pomme update` reports versions
    /// itself, and commands without table output never show the notice.
    static func afterCommand(_ command: ParsableCommand) {
        guard let options = (command as? CLIProgressCommand)?.progressOptions,
              (try? options.resolvedFormat()) == .table,
              let cacheURL = PommeUpdateCheckCache.defaultURL()
        else { return }
        let context = Context.live()
        guard isEnabled(context) else { return }
        let decision = decide(context: context, cache: PommeUpdateCheckCache.read(from: cacheURL))
        if let notice = decision.notice {
            FileHandle.standardError.write(Data((notice + "\n").utf8))
        }
        decision.cache?.write(to: cacheURL)
        if decision.refresh, let executable = context.executable {
            startBackgroundCheck(executable: executable)
        }
    }

    /// Starts `pomme --pomme-update-check` in its own session with no
    /// terminal and no inherited descriptors, so that it outlives this
    /// command and never holds a caller's pipe open.
    static func startBackgroundCheck(executable: URL) {
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { return }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { return }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0
        else { return }
        var argv = [executable.path, flag].map { strdup($0) }
        argv.append(nil)
        defer { argv.dropLast().forEach { free($0) } }
        var pid: pid_t = 0
        _ = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, environ)
    }

    /// The `--pomme-update-check` process: looks up the newest release and
    /// records it. A failure leaves the cache as it was.
    static func runBackgroundCheck() async -> Int32 {
        _ = try? await PommeSelfUpdate.status(dependencies: .live)
        return 0
    }
}
