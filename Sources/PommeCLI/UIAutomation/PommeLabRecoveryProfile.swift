import Foundation

/// The host reduces each qualification fact to a closed value before it
/// reaches Recovery input. No guest text, pixels, ABI details, or ownership
/// records are retained by this module.
enum PommeRecoveryBuild: Equatable, Sendable {
    case tahoe2660Build25G72
    case sequoia1561Build24G90
    case unknown
}

enum PommeRecoveryLocale: Equatable, Sendable { case english, unknown }
enum PommeRecoveryGeometry: Equatable, Sendable { case pixels1280x800, unknown }
enum PommeRecoveryPrivateHostABI: Equatable, Sendable { case qualifiedRecoveryInputV1, unknown }
enum PommeRecoveryManifestHash: Equatable, Sendable {
    case tahoe2660Build25G72
    case sequoia1561Build24G90
    case unknown
}
enum PommeRecoveryOwnership: Equatable, Sendable { case verified, unknown }

struct PommeRecoveryProfileEvidence: Equatable, Sendable {
    let build: PommeRecoveryBuild
    let locale: PommeRecoveryLocale
    let geometry: PommeRecoveryGeometry
    let privateHostABI: PommeRecoveryPrivateHostABI
    let manifestHash: PommeRecoveryManifestHash
    let ownership: PommeRecoveryOwnership
}

enum PommeRecoveryReviewedDescriptor: Equatable, Sendable {
    case tahoe2660Build25G72English1280x800
    case sequoia1561Build24G90English1280x800PendingReview

    /// SHA-256-shaped reviewed-record identifiers. The Sequoia record is
    /// pending only and is never an input-enabling token.
    var reviewedRecordDigest: String {
        switch self {
        case .tahoe2660Build25G72English1280x800:
            return "c7c9d456a752a2a8b7f0ca725bb2800f811211329a2f222f7bf77d24c5c1ea9f"
        case .sequoia1561Build24G90English1280x800PendingReview:
            return "4c59c22fd563d27c98cb525ea8e9e7c5efb2b787f4d964e5dcb8ce1c0d910356"
        }
    }
}

enum PommeRecoveryInputQualificationError: Error, Equatable, Sendable {
    case unsupportedBuild, unsupportedLocale, unsupportedGeometry
    case unqualifiedPrivateHostABI, manifestHashMismatch, ownershipUnverified
    case externallyPendingReview(String)
}

/// This evidence gate extends the repository's sole selector namespace; no
/// second selector or in-process mutable qualification exists.
extension PommeRecoveryProfileSelector {
    static func reviewedDescriptor(
        for evidence: PommeRecoveryProfileEvidence
    ) throws -> PommeRecoveryReviewedDescriptor {
        guard evidence.build != .unknown else { throw PommeRecoveryInputQualificationError.unsupportedBuild }
        guard evidence.locale == .english else { throw PommeRecoveryInputQualificationError.unsupportedLocale }
        guard evidence.geometry == .pixels1280x800 else { throw PommeRecoveryInputQualificationError.unsupportedGeometry }
        guard evidence.privateHostABI == .qualifiedRecoveryInputV1 else {
            throw PommeRecoveryInputQualificationError.unqualifiedPrivateHostABI
        }
        guard evidence.ownership == .verified else {
            throw PommeRecoveryInputQualificationError.ownershipUnverified
        }
        switch evidence.build {
        case .tahoe2660Build25G72:
            guard evidence.manifestHash == .tahoe2660Build25G72 else {
                throw PommeRecoveryInputQualificationError.manifestHashMismatch
            }
            return .tahoe2660Build25G72English1280x800
        case .sequoia1561Build24G90:
            guard evidence.manifestHash == .sequoia1561Build24G90 else {
                throw PommeRecoveryInputQualificationError.manifestHashMismatch
            }
            return .sequoia1561Build24G90English1280x800PendingReview
        case .unknown:
            throw PommeRecoveryInputQualificationError.unsupportedBuild
        }
    }

    static func reviewedTahoeInput(
        for evidence: PommeRecoveryProfileEvidence
    ) throws -> PommeTahoeReviewedInput {
        let descriptor = try reviewedDescriptor(for: evidence)
        guard descriptor == .tahoe2660Build25G72English1280x800 else {
            throw PommeRecoveryInputQualificationError.externallyPendingReview(
                descriptor.reviewedRecordDigest
            )
        }
        return .init()
    }
}

/// Closed observer labels: no OCR output or pixels escape the observer.
enum PommeRecoveryFrame: Equatable, Sendable {
    case startupOptions, startupIntermediate, startupOptionsActivated, languageEnglish
    case recoveryUtilities, applicationMenu, recoveryMenu, fileMenu, editMenu
    case utilitiesMenu, terminalMenuItem, terminal, unknown
}

enum PommeRecoveryVirtualKey: Equatable, Sendable {
    case controlF2, right, down, `return`, shiftCommandT
}

struct PommeRecoveryDurableInputReceipt: Equatable, Sendable {
    let key: PommeRecoveryVirtualKey
    let deliveredEventCount: Int
}

enum PommeTahoeReviewedInputError: Error, Equatable, Sendable {
    case unstablePreEventFrames, unexpectedPreEventFrame, inputOutstanding
    case invalidReceipt, unstablePostEventFrames, unexpectedPostEventFrame, cancelled
}

/// Tahoe's sole production input contract: two equal pre-event observations,
/// one key, one durable receipt, and two equal post-event observations.
struct PommeTahoeReviewedInput: Sendable {
    private enum Stage: Sendable {
        case startupFirstRight, startupSecondRight, activateOptions, chooseEnglish
        case activateMenuBar, recoveryMenuRight, fileMenuRight, editMenuRight
        case utilitiesMenuRight, utilitiesMenuDown, terminalShortcut, complete
    }

    private var stage: Stage = .startupFirstRight
    private var outstandingKey: PommeRecoveryVirtualKey?
    private(set) var committedInputCount = 0

    mutating func authorize(preEventFrames: [PommeRecoveryFrame]) throws -> PommeRecoveryVirtualKey {
        do { try Task.checkCancellation() }
        catch { throw PommeTahoeReviewedInputError.cancelled }
        guard outstandingKey == nil else { throw PommeTahoeReviewedInputError.inputOutstanding }
        guard preEventFrames.count == 2,
              preEventFrames[0] == preEventFrames[1],
              preEventFrames[0] != .unknown
        else { throw PommeTahoeReviewedInputError.unstablePreEventFrames }
        guard preEventFrames[0] == expectedPreFrame else {
            throw PommeTahoeReviewedInputError.unexpectedPreEventFrame
        }
        let key = expectedKey
        outstandingKey = key
        return key
    }

    mutating func commit(
        _ receipt: PommeRecoveryDurableInputReceipt,
        postEventFrames: [PommeRecoveryFrame]
    ) throws {
        do { try Task.checkCancellation() }
        catch { throw PommeTahoeReviewedInputError.cancelled }
        guard receipt.deliveredEventCount == 1, receipt.key == outstandingKey else {
            throw PommeTahoeReviewedInputError.invalidReceipt
        }
        guard postEventFrames.count == 2,
              postEventFrames[0] == postEventFrames[1],
              postEventFrames[0] != .unknown
        else { throw PommeTahoeReviewedInputError.unstablePostEventFrames }
        guard postEventFrames[0] == expectedPostFrame else {
            throw PommeTahoeReviewedInputError.unexpectedPostEventFrame
        }
        outstandingKey = nil
        committedInputCount += 1
        stage = nextStage
    }

    var isComplete: Bool { stage == .complete && outstandingKey == nil }

    private var expectedPreFrame: PommeRecoveryFrame {
        switch stage {
        case .startupFirstRight: .startupOptions
        case .startupSecondRight: .startupIntermediate
        case .activateOptions: .startupOptionsActivated
        case .chooseEnglish: .languageEnglish
        case .activateMenuBar: .recoveryUtilities
        case .recoveryMenuRight: .applicationMenu
        case .fileMenuRight: .recoveryMenu
        case .editMenuRight: .fileMenu
        case .utilitiesMenuRight: .editMenu
        case .utilitiesMenuDown: .utilitiesMenu
        case .terminalShortcut: .terminalMenuItem
        case .complete: .unknown
        }
    }

    private var expectedKey: PommeRecoveryVirtualKey {
        switch stage {
        case .startupFirstRight, .startupSecondRight, .recoveryMenuRight,
             .fileMenuRight, .editMenuRight, .utilitiesMenuRight: .right
        case .activateOptions, .chooseEnglish: .return
        case .activateMenuBar: .controlF2
        case .utilitiesMenuDown: .down
        case .terminalShortcut: .shiftCommandT
        case .complete: .return
        }
    }

    private var expectedPostFrame: PommeRecoveryFrame {
        switch stage {
        case .startupFirstRight: .startupIntermediate
        case .startupSecondRight: .startupOptionsActivated
        case .activateOptions: .languageEnglish
        case .chooseEnglish: .recoveryUtilities
        case .activateMenuBar: .applicationMenu
        case .recoveryMenuRight: .recoveryMenu
        case .fileMenuRight: .fileMenu
        case .editMenuRight: .editMenu
        case .utilitiesMenuRight: .utilitiesMenu
        case .utilitiesMenuDown: .terminalMenuItem
        case .terminalShortcut: .terminal
        case .complete: .unknown
        }
    }

    private var nextStage: Stage {
        switch stage {
        case .startupFirstRight: .startupSecondRight
        case .startupSecondRight: .activateOptions
        case .activateOptions: .chooseEnglish
        case .chooseEnglish: .activateMenuBar
        case .activateMenuBar: .recoveryMenuRight
        case .recoveryMenuRight: .fileMenuRight
        case .fileMenuRight: .editMenuRight
        case .editMenuRight: .utilitiesMenuRight
        case .utilitiesMenuRight: .utilitiesMenuDown
        case .utilitiesMenuDown: .terminalShortcut
        case .terminalShortcut, .complete: .complete
        }
    }
}
