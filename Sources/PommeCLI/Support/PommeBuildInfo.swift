import Foundation

/// The version and source commit embedded in the executable's Info.plist
/// section by the build.
struct PommeBuildInfo: Equatable {
    static let current = PommeBuildInfo(dictionary: Bundle.main.infoDictionary ?? [:])

    let version: String
    let commit: String

    init(dictionary: [String: Any]) {
        version = Self.value(dictionary["CFBundleShortVersionString"])
        commit = Self.value(dictionary["PommeGitCommit"])
    }

    /// The line `pomme --version` prints, such as `pomme 0.1.0 (5ebd40f)`.
    var versionLine: String {
        "pomme \(version) (\(commit))"
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
