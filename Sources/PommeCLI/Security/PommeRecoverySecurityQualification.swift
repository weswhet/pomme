import Foundation

/// Security operations accept any Recovery input contract the profile
/// planner qualifies: the reviewed Tahoe record or a planner-qualified
/// experimental identity. Builds whose review is pending, and evidence that
/// fails the locale, geometry, host ABI, manifest, or ownership checks, are
/// still rejected.
enum PommeRecoverySecurityQualification {
    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unqualifiedRestoreProfile

        var errorDescription: String? {
            "SIP and AMFI Recovery operations require a restore profile the Recovery planner qualifies; this VM's profile is pending review or unsupported."
        }
    }

    static func require(profile: PommeRecoveryProfileEvidence) throws {
        do {
            _ = try PommeRecoveryProfileSelector.inputForAttempt(for: profile)
        } catch let error as PommeRecoveryInputQualificationError {
            switch error {
            case .unsupportedBuild, .externallyPendingReview:
                throw Error.unqualifiedRestoreProfile
            default:
                throw error
            }
        } catch {
            throw error
        }
    }
}
