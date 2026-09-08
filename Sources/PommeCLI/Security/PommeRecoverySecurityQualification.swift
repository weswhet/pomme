import Foundation

/// Security operations require the one reviewed Recovery input contract. VM
/// creation may retain an experimental restore plan, but that plan cannot
/// issue credentials or authorize Recovery input for SIP or AMFI.
enum PommeRecoverySecurityQualification {
    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unqualifiedRestoreProfile

        var errorDescription: String? {
            "SIP and AMFI Recovery operations require Pomme's reviewed macOS Tahoe 26.6.0 (25G72) restore profile. This profile is not qualified for security operations; experimental creation does not qualify it."
        }
    }

    static func require(profile: PommeRecoveryProfileEvidence) throws {
        do {
            _ = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: profile)
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
