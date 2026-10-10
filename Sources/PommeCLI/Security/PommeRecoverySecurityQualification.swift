import Foundation

/// Security operations accept any Recovery input contract the profile
/// planner qualifies: the reviewed Tahoe record or a planner-qualified
/// experimental identity. Builds whose review is pending, and evidence that
/// fails the locale, geometry, host ABI, manifest, or ownership checks, are
/// still rejected.
enum PommeRecoverySecurityQualification {
    enum Error: PommeDescribedError, Equatable, Sendable {
        case unqualifiedRestoreProfile

        var code: PommeErrorCode { .uiRecoveryUnqualified }

        var errorDescription: String? {
            "Pomme can't change SIP or AMFI on this VM because its macOS build isn't supported for Recovery automation or its review isn't finished."
        }

        var recoverySuggestion: String? {
            "Run `pomme inspect NAME` to check the VM's macOS version, and create the VM from a supported version."
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
