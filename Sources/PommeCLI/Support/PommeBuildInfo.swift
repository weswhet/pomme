import Foundation

/// The version and source commit embedded in the executable's Info.plist
/// section by the build.
struct PommeBuildInfo: Equatable {
    static let current = PommeBuildInfo(dictionary: Bundle.main.infoDictionary ?? [:])

    let version: String
    let commit: String
    /// `release` for the builds that Scripts/build-release-pkg.sh publishes.
    /// Any other value, such as a local build's `source`, is a source build.
    let distribution: String

    init(dictionary: [String: Any]) {
        version = Self.value(dictionary["CFBundleShortVersionString"])
        commit = Self.value(dictionary["PommeGitCommit"])
        distribution = Self.value(dictionary["PommeDistribution"])
    }

    /// The line `pomme --version` prints, such as `pomme 0.1.0 (5ebd40f)`.
    var versionLine: String {
        "pomme \(version) (\(commit))"
    }

    /// Whether this is a published release build, which `pomme update` can
    /// replace.
    var isRelease: Bool {
        distribution == "release"
    }

    /// A missing, empty, or unexpanded `$(SETTING)` value is reported as
    /// `unknown` rather than printed literally.
    private static func value(_ raw: Any?) -> String {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else {
            return "unknown"
        }
        return text
    }
}
