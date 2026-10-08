import Testing

@Suite("Build identity")
struct PommeBuildInfoTests {
    @Test("The version line carries the embedded version and commit")
    func versionLineCarriesVersionAndCommit() {
        let info = PommeBuildInfo(dictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "PommeGitCommit": "5ebd40f-dirty"
        ])

        #expect(info.versionLine == "pomme 0.1.0 (5ebd40f-dirty)")
    }

    @Test("Missing keys report unknown")
    func missingKeysReportUnknown() {
        #expect(PommeBuildInfo(dictionary: [:]).versionLine == "pomme unknown (unknown)")
        #expect(PommeBuildInfo(dictionary: ["CFBundleShortVersionString": "", "PommeGitCommit": 7]).versionLine
                == "pomme unknown (unknown)")
    }

    @Test("Only a release distribution is a release build")
    func distributionMarksReleaseBuilds() {
        #expect(PommeBuildInfo(dictionary: ["PommeDistribution": "release"]).isRelease)
        #expect(!PommeBuildInfo(dictionary: ["PommeDistribution": "source"]).isRelease)
        #expect(!PommeBuildInfo(dictionary: ["PommeDistribution": "$(POMME_DISTRIBUTION)"]).isRelease)
        #expect(!PommeBuildInfo(dictionary: [:]).isRelease)
    }

    @Test("An unexpanded build setting reports unknown")
    func unexpandedSettingReportsUnknown() {
        let info = PommeBuildInfo(dictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "PommeGitCommit": "$(POMME_GIT_COMMIT)"
        ])

        #expect(info.versionLine == "pomme 0.1.0 (unknown)")
    }
}
