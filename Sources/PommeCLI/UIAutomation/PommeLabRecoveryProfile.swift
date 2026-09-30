import Foundation

/// The host reduces each qualification fact to a closed value before it
/// reaches Recovery input. No guest text, pixels, ABI details, or ownership
/// records are retained by this module.
enum PommeRecoveryBuild: Equatable, Sendable {
    case tahoe2660Build25G72
    case sequoia1561Build24G90
    case experimental(version: String, build: String)
    case unknown
}

enum PommeRecoveryLocale: Equatable, Sendable { case english, unknown }
enum PommeRecoveryGeometry: Equatable, Sendable { case pixels1280x800, unknown }
enum PommeRecoveryPrivateHostABI: Equatable, Sendable { case qualifiedRecoveryInputV1, unknown }
enum PommeRecoveryManifestHash: Equatable, Sendable {
    case tahoe2660Build25G72
    case sequoia1561Build24G90
    case experimentalProfile(String)
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
        case .experimental(_, _):
            // Experimental identities deliberately have no reviewed record.
            // Callers that need a bounded attempt must use inputForAttempt(for:)
            // so the planning descriptor and its manifest digest are checked.
            throw PommeRecoveryInputQualificationError.unsupportedBuild
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
        return .init(route: .reviewedMenus)
    }

    /// Selects the existing Tahoe input state machine for either the reviewed
    /// identity or a planner-qualified experimental identity. Experimental
    /// evidence remains bounded by the same locale, geometry, private ABI,
    /// ownership, descriptor, and manifest checks as reviewed input; only the
    /// exact observed identities opt into their bounded experimental traces.
    static func inputForAttempt(
        for evidence: PommeRecoveryProfileEvidence
    ) throws -> PommeTahoeReviewedInput {
        guard case .experimental(let version, let build) = evidence.build else {
            return try reviewedTahoeInput(for: evidence)
        }

        guard evidence.locale == .english else {
            throw PommeRecoveryInputQualificationError.unsupportedLocale
        }
        guard evidence.geometry == .pixels1280x800 else {
            throw PommeRecoveryInputQualificationError.unsupportedGeometry
        }
        guard evidence.privateHostABI == .qualifiedRecoveryInputV1 else {
            throw PommeRecoveryInputQualificationError.unqualifiedPrivateHostABI
        }
        guard evidence.ownership == .verified else {
            throw PommeRecoveryInputQualificationError.ownershipUnverified
        }

        let descriptor: PommeCreateRecoveryProfileDescriptor
        do {
            descriptor = try PommeRecoveryProfileSelector.descriptor(
                version: version,
                build: build
            )
        } catch {
            throw PommeRecoveryInputQualificationError.unsupportedBuild
        }
        guard descriptor.qualification == .experimental else {
            throw PommeRecoveryInputQualificationError.unsupportedBuild
        }
        guard evidence.manifestHash == .experimentalProfile(descriptor.digest) else {
            throw PommeRecoveryInputQualificationError.manifestHashMismatch
        }
        let route: PommeRecoveryNavigationRoute
        if descriptor.version == "26.6.2", descriptor.build == "25G83" {
            route = .directTerminal
        } else if descriptor.version.hasPrefix("27.") {
            // Every macOS 27 Recovery can present the chooser without key
            // focus, where a bare Return is silently dropped. Live-observed on
            // 27.0/26A428 and 27.0.1/26A434; later 27.x builds inherit the
            // route, and its frame proofs still gate the click and Return.
            route = .experimentalLanguageActivation
        } else if descriptor.version == "15.6.1", descriptor.build == "24G90" {
            // This remains an experimental identity. Its alternate Options
            // transition is not a reviewed-record extension.
            route = .experimentalMenusOptionalLanguage
        } else {
            route = .reviewedMenus
        }
        return .init(route: route)
    }
}

/// Closed observer labels: no OCR output or pixels escape the observer.
enum PommeRecoveryFrame: Equatable, Sendable {
    case startupOptions, startupIntermediate, startupOptionsActivated, languageEnglish
    case languageEnglishInactive, languageEnglishActive
    case recoveryUtilities, applicationMenu, recoveryMenu, fileMenu, editMenu
    case utilitiesMenu, terminalMenuItem, terminal, unknown
}

enum PommeRecoveryVirtualKey: Equatable, Sendable {
    case controlF2, right, down, `return`, shiftCommandT
}

/// Closed navigation effects. The activation click has one fixed guest-display
/// point, qualified only for the experimental macOS 27 LanguageChooser.
/// This is deliberately not a general pointer or host-focus interface.
enum PommeRecoveryNavigationInput: Equatable, Sendable {
    case key(PommeRecoveryVirtualKey)
    case activateLanguageChooser

    var key: PommeRecoveryVirtualKey? {
        guard case .key(let key) = self else { return nil }
        return key
    }
}

/// One immutable, closed Recovery navigation transition. The input contract
/// validates the observed frames around every event before and after delivery.
struct PommeRecoveryNavigationEvent: Equatable, Sendable {
    struct AlternatePostcondition: Equatable, Sendable {
        let frame: PommeRecoveryFrame
        let nextEventIndex: Int
    }

    let preEventFrame: PommeRecoveryFrame
    let input: PommeRecoveryNavigationInput
    var key: PommeRecoveryVirtualKey? { input.key }
    let postEventFrame: PommeRecoveryFrame
    /// Bounded experimental branches require the same two stable observations
    /// as the primary transition. Each branch skips to an existing event and
    /// never authorizes an additional input.
    let alternatePostconditions: [AlternatePostcondition]

    init(
        preEventFrame: PommeRecoveryFrame,
        key: PommeRecoveryVirtualKey,
        postEventFrame: PommeRecoveryFrame,
        alternatePostconditions: [AlternatePostcondition] = []
    ) {
        self.init(preEventFrame: preEventFrame, input: .key(key), postEventFrame: postEventFrame,
                  alternatePostconditions: alternatePostconditions)
    }

    init(
        preEventFrame: PommeRecoveryFrame,
        input: PommeRecoveryNavigationInput,
        postEventFrame: PommeRecoveryFrame,
        alternatePostconditions: [AlternatePostcondition] = []
    ) {
        self.preEventFrame = preEventFrame
        self.input = input
        self.postEventFrame = postEventFrame
        self.alternatePostconditions = alternatePostconditions
    }

    var acceptedPostEventFrames: [PommeRecoveryFrame] {
        [postEventFrame] + alternatePostconditions.map(\.frame)
    }

    func nextEventIndex(after frame: PommeRecoveryFrame, defaultIndex: Int) -> Int? {
        if frame == postEventFrame { return defaultIndex }
        return alternatePostconditions.first { $0.frame == frame }?.nextEventIndex
    }
}

/// Qualified navigation traces. The direct route is intentionally opt-in and
/// is selected only for an identity qualified by the profile gate.
enum PommeRecoveryNavigationRoute: Equatable, Sendable {
    case reviewedMenus
    case directTerminal
    /// An experimental 15.6.1/24G90 trace. After Options, some observed
    /// Recovery boots open the utilities window directly instead of showing
    /// a language chooser. The branch is proved by two stable utilities
    /// observations and skips the otherwise required Return.
    case experimentalMenusOptionalLanguage
    case experimentalLanguageActivation

    /// The complete immutable trace for this route. Every event has exactly
    /// one closed input and the frame labels required around that input.
    var eventTrace: [PommeRecoveryNavigationEvent] {
        switch self {
        case .experimentalLanguageActivation:
            return [
                .init(preEventFrame: .startupOptions, key: .right, postEventFrame: .startupIntermediate),
                .init(preEventFrame: .startupIntermediate, key: .right, postEventFrame: .startupOptionsActivated),
                .init(preEventFrame: .startupOptionsActivated, key: .return,
                      postEventFrame: .languageEnglishInactive,
                      alternatePostconditions: [
                        .init(frame: .languageEnglishActive, nextEventIndex: 4),
                        // macOS 27 can enter Utilities directly after Options.
                        .init(frame: .recoveryUtilities, nextEventIndex: 5),
                      ]),
                .init(preEventFrame: .languageEnglishInactive, input: .activateLanguageChooser,
                      postEventFrame: .languageEnglishActive,
                      alternatePostconditions: [.init(frame: .recoveryUtilities, nextEventIndex: 5)]),
                .init(preEventFrame: .languageEnglishActive, key: .return, postEventFrame: .recoveryUtilities),
            ] + Array(Self.reviewedMenus.eventTrace.dropFirst(4))
        case .reviewedMenus:
            return [
                .init(preEventFrame: .startupOptions, key: .right, postEventFrame: .startupIntermediate),
                .init(preEventFrame: .startupIntermediate, key: .right, postEventFrame: .startupOptionsActivated),
                .init(preEventFrame: .startupOptionsActivated, key: .return, postEventFrame: .languageEnglish),
                .init(preEventFrame: .languageEnglish, key: .return, postEventFrame: .recoveryUtilities),
                .init(preEventFrame: .recoveryUtilities, key: .controlF2, postEventFrame: .applicationMenu),
                .init(preEventFrame: .applicationMenu, key: .right, postEventFrame: .recoveryMenu),
                .init(preEventFrame: .recoveryMenu, key: .right, postEventFrame: .fileMenu),
                .init(preEventFrame: .fileMenu, key: .right, postEventFrame: .editMenu),
                .init(preEventFrame: .editMenu, key: .right, postEventFrame: .utilitiesMenu),
                .init(preEventFrame: .utilitiesMenu, key: .down, postEventFrame: .terminalMenuItem),
                .init(preEventFrame: .terminalMenuItem, key: .shiftCommandT, postEventFrame: .terminal),
            ]
        case .directTerminal:
            return [
                .init(preEventFrame: .startupOptions, key: .right, postEventFrame: .startupIntermediate),
                .init(preEventFrame: .startupIntermediate, key: .right, postEventFrame: .startupOptionsActivated),
                .init(preEventFrame: .startupOptionsActivated, key: .return,
                      postEventFrame: .languageEnglish,
                      alternatePostconditions: [.init(frame: .recoveryUtilities, nextEventIndex: 4)]),
                .init(preEventFrame: .languageEnglish, key: .return, postEventFrame: .recoveryUtilities),
                .init(preEventFrame: .recoveryUtilities, key: .shiftCommandT, postEventFrame: .terminal),
            ]
        case .experimentalMenusOptionalLanguage:
            return [
                .init(preEventFrame: .startupOptions, key: .right, postEventFrame: .startupIntermediate),
                .init(preEventFrame: .startupIntermediate, key: .right, postEventFrame: .startupOptionsActivated),
                .init(
                    preEventFrame: .startupOptionsActivated,
                    key: .return,
                    postEventFrame: .languageEnglish,
                    alternatePostconditions: [.init(frame: .recoveryUtilities, nextEventIndex: 4)]
                ),
                .init(preEventFrame: .languageEnglish, key: .return, postEventFrame: .recoveryUtilities),
                .init(preEventFrame: .recoveryUtilities, key: .controlF2, postEventFrame: .applicationMenu),
                .init(preEventFrame: .applicationMenu, key: .right, postEventFrame: .recoveryMenu),
                .init(preEventFrame: .recoveryMenu, key: .right, postEventFrame: .fileMenu),
                .init(preEventFrame: .fileMenu, key: .right, postEventFrame: .editMenu),
                .init(preEventFrame: .editMenu, key: .right, postEventFrame: .utilitiesMenu),
                .init(preEventFrame: .utilitiesMenu, key: .down, postEventFrame: .terminalMenuItem),
                .init(preEventFrame: .terminalMenuItem, key: .shiftCommandT, postEventFrame: .terminal),
            ]
        }
    }

    var keys: [PommeRecoveryVirtualKey] {
        eventTrace.compactMap(\.key)
    }
}

struct PommeRecoveryDurableInputReceipt: Equatable, Sendable {
    let input: PommeRecoveryNavigationInput
    let deliveredEventCount: Int

    init(input: PommeRecoveryNavigationInput, deliveredEventCount: Int) {
        self.input = input
        self.deliveredEventCount = deliveredEventCount
    }

    init(key: PommeRecoveryVirtualKey, deliveredEventCount: Int) {
        self.init(input: .key(key), deliveredEventCount: deliveredEventCount)
    }
}

enum PommeTahoeReviewedInputError: Error, Equatable, Sendable {
    case unstablePreEventFrames, unexpectedPreEventFrame, inputOutstanding
    case invalidReceipt, unstablePostEventFrames, unexpectedPostEventFrame, cancelled
}

/// Tahoe's sole production input contract: two equal pre-event observations,
/// one closed input, one durable receipt, and two equal post-event observations.
struct PommeTahoeReviewedInput: Sendable {
    let route: PommeRecoveryNavigationRoute
    private var eventIndex = 0
    private var outstandingInput: PommeRecoveryNavigationInput?
    private(set) var committedInputCount = 0

    init(route: PommeRecoveryNavigationRoute = .reviewedMenus) {
        self.route = route
    }

    mutating func authorize(preEventFrames: [PommeRecoveryFrame]) throws -> PommeRecoveryVirtualKey {
        guard currentEvent?.input.key != nil else {
            throw PommeTahoeReviewedInputError.unexpectedPreEventFrame
        }
        let input = try authorizeInput(preEventFrames: preEventFrames)
        guard let key = input.key else { throw PommeTahoeReviewedInputError.unexpectedPreEventFrame }
        return key
    }

    mutating func authorizeInput(preEventFrames: [PommeRecoveryFrame]) throws -> PommeRecoveryNavigationInput {
        do { try Task.checkCancellation() }
        catch { throw PommeTahoeReviewedInputError.cancelled }
        guard outstandingInput == nil else { throw PommeTahoeReviewedInputError.inputOutstanding }
        guard preEventFrames.count == 2,
              preEventFrames[0] == preEventFrames[1],
              preEventFrames[0] != .unknown
        else { throw PommeTahoeReviewedInputError.unstablePreEventFrames }
        guard let event = currentEvent, preEventFrames[0] == event.preEventFrame else {
            throw PommeTahoeReviewedInputError.unexpectedPreEventFrame
        }
        outstandingInput = event.input
        return event.input
    }

    mutating func commit(
        _ receipt: PommeRecoveryDurableInputReceipt,
        postEventFrames: [PommeRecoveryFrame]
    ) throws {
        do { try Task.checkCancellation() }
        catch { throw PommeTahoeReviewedInputError.cancelled }
        guard receipt.deliveredEventCount == 1, receipt.input == outstandingInput else {
            throw PommeTahoeReviewedInputError.invalidReceipt
        }
        guard postEventFrames.count == 2,
              postEventFrames[0] == postEventFrames[1],
              postEventFrames[0] != .unknown
        else { throw PommeTahoeReviewedInputError.unstablePostEventFrames }
        guard let event = currentEvent,
              let nextEventIndex = event.nextEventIndex(
                after: postEventFrames[0],
                defaultIndex: eventIndex + 1
              ),
              nextEventIndex <= route.eventTrace.count
        else {
            throw PommeTahoeReviewedInputError.unexpectedPostEventFrame
        }
        outstandingInput = nil
        committedInputCount += 1
        eventIndex = nextEventIndex
    }

    var isComplete: Bool {
        eventIndex == route.eventTrace.count && outstandingInput == nil
    }

    private var currentEvent: PommeRecoveryNavigationEvent? {
        guard eventIndex < route.eventTrace.count else { return nil }
        return route.eventTrace[eventIndex]
    }
}
