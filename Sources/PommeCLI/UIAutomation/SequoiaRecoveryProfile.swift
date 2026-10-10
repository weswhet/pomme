import Foundation

/// Sequoia is documented only as a pending reference. It has no key, frame,
/// receipt, state-machine, or mutable qualification API.
enum SequoiaRecoveryReference {
    static let version = "15.6.1"
    static let build = "24G90"
    static let locale = "English"
    static let displayWidth = 1280
    static let displayHeight = 800

    /// A SHA-256-shaped record identifier for external review. Its presence
    /// does not authorize input, and there is no in-process enablement path.
    static let pendingReviewDigest =
        "4c59c22fd563d27c98cb525ea8e9e7c5efb2b787f4d964e5dcb8ce1c0d910356"
    static let productionInputEnabled = false
}

enum SequoiaRecoveryReferenceError: PommeDescribedError, Equatable, Sendable {
    case pendingExternalReview(String)

    var code: PommeErrorCode { .uiRecoveryReviewPending }

    var errorDescription: String? {
        "Recovery navigation for macOS Sequoia isn't available yet because the review of its Recovery screens isn't finished."
    }

    var recoverySuggestion: String? {
        "Create the VM from a supported macOS version, or update Pomme with `pomme update` to get newly supported builds."
    }
}

extension PommeRecoveryProfileSelector {
    /// Always fails closed. External review must result in a new reviewed
    /// newly reviewed Tahoe release artifact, not a process-local toggle.
    static func sequoiaInputIsUnavailable() throws -> Never {
        throw SequoiaRecoveryReferenceError.pendingExternalReview(
            SequoiaRecoveryReference.pendingReviewDigest
        )
    }
}
