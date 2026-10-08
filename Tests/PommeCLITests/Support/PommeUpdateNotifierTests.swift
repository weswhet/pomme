import Foundation
import Testing

@Suite("Update check")
struct PommeUpdateNotifierTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 60 * 60

    @Test("Runs only for an interactive release build without CI or POMME_NO_UPDATE_CHECK")
    func gating() {
        #expect(PommeUpdateNotifier.isEnabled(context()))
        #expect(PommeUpdateNotifier.isEnabled(context(environment: ["POMME_NO_UPDATE_CHECK": "0"])))
        #expect(PommeUpdateNotifier.isEnabled(context(environment: ["POMME_NO_UPDATE_CHECK": ""])))
        #expect(!PommeUpdateNotifier.isEnabled(context(distribution: "source")))
        #expect(!PommeUpdateNotifier.isEnabled(context(terminal: false)))
        #expect(!PommeUpdateNotifier.isEnabled(context(environment: ["CI": "true"])))
        #expect(!PommeUpdateNotifier.isEnabled(context(environment: ["POMME_NO_UPDATE_CHECK": "1"])))
        #expect(PommeUpdateNotifier.decide(context: context(terminal: false), cache: nil) == .init())
    }

    @Test("A first run starts a background check and shows nothing")
    func firstRunRefreshes() throws {
        let decision = PommeUpdateNotifier.decide(context: context(), cache: nil)

        #expect(decision.notice == nil)
        #expect(decision.refresh)
        #expect(decision.cache?.checkStartedAt == now)
    }

    @Test("A fresh cache with a newer release shows the notice once per 20 hours")
    func showsNotice() throws {
        let cache = fresh(latest: "0.1.0-alpha.5")
        let first = PommeUpdateNotifier.decide(context: context(), cache: cache)

        #expect(first.notice == "Pomme 0.1.0-alpha.5 is available. You have 0.1.0-alpha.4. To update, run `pomme update`.")
        #expect(!first.refresh)
        let shown = try #require(first.cache)
        #expect(shown.notifiedVersion == "0.1.0-alpha.5")
        #expect(shown.notifiedAt == now)

        #expect(PommeUpdateNotifier.decide(context: context(now: now + hour), cache: shown).notice == nil)
        #expect(PommeUpdateNotifier.decide(context: context(now: now + 21 * hour), cache: shown).notice != nil)
        var newer = shown
        newer.latestVersion = "0.1.0-alpha.6"
        #expect(PommeUpdateNotifier.decide(context: context(now: now + hour), cache: newer).notice?.contains("0.1.0-alpha.6") == true)
    }

    @Test("Shows nothing when the cached release isn't newer or is from another feed")
    func noNotice() {
        #expect(PommeUpdateNotifier.decide(context: context(), cache: fresh(latest: "0.1.0-alpha.4")) == .init())
        #expect(PommeUpdateNotifier.decide(context: context(), cache: fresh(latest: "0.1.0-alpha.3")) == .init())
        #expect(PommeUpdateNotifier.decide(context: context(), cache: fresh(latest: nil)) == .init())
        var homebrew = fresh(latest: "9.0.0")
        homebrew.feed = .homebrew
        let decision = PommeUpdateNotifier.decide(context: context(), cache: homebrew)
        #expect(decision.notice == nil)
        #expect(decision.refresh)
    }

    @Test("Refreshes a stale cache unless a background check started recently")
    func refreshesStaleCache() {
        var stale = fresh(latest: "0.1.0-alpha.4")
        stale.checkedAt = now - 21 * hour
        #expect(PommeUpdateNotifier.decide(context: context(), cache: stale).refresh)

        stale.checkStartedAt = now - 5 * 60
        #expect(PommeUpdateNotifier.decide(context: context(), cache: stale) == .init())

        stale.checkStartedAt = now - 11 * 60
        #expect(PommeUpdateNotifier.decide(context: context(), cache: stale).refresh)

        var future = fresh(latest: "0.1.0-alpha.4")
        future.checkedAt = now + hour
        #expect(PommeUpdateNotifier.decide(context: context(), cache: future).refresh)
    }

    @Test("A Homebrew install reads the Homebrew feed")
    func homebrewFeed() {
        var cache = fresh(latest: "0.2.0")
        cache.feed = .homebrew
        let decision = PommeUpdateNotifier.decide(
            context: context(version: "0.1.0", executable: "/opt/homebrew/Cellar/pomme/0.1.0/bin/pomme"),
            cache: cache
        )
        #expect(decision.notice?.contains("Pomme 0.2.0 is available") == true)
        #expect(!decision.refresh)
    }

    @Test("The cache round-trips through its file")
    func cacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-update-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/update-check.json")
        let cache = fresh(latest: "0.1.0-alpha.5")

        cache.write(to: url)

        #expect(PommeUpdateCheckCache.read(from: url) == cache)
        try Data("not json".utf8).write(to: url)
        #expect(PommeUpdateCheckCache.read(from: url) == nil)
        #expect(PommeUpdateCheckCache.defaultURL()?.path.hasSuffix("Library/Caches/com.github.weswhet.pomme/update-check.json") == true)
    }

    private func context(
        version: String = "0.1.0-alpha.4",
        distribution: String = "release",
        environment: [String: String] = [:],
        terminal: Bool = true,
        executable: String = "/Users/me/.local/bin/pomme",
        now: Date? = nil
    ) -> PommeUpdateNotifier.Context {
        PommeUpdateNotifier.Context(
            buildInfo: PommeBuildInfo(dictionary: [
                "CFBundleShortVersionString": version,
                "PommeGitCommit": "abc1234",
                "PommeDistribution": distribution,
            ]),
            environment: environment,
            stderrIsTerminal: terminal,
            executable: URL(fileURLWithPath: executable),
            fileExists: { _ in false },
            now: now ?? self.now
        )
    }

    private func fresh(latest: String?) -> PommeUpdateCheckCache {
        PommeUpdateCheckCache(feed: .alpha, latestVersion: latest, checkedAt: now - hour)
    }
}
