import Foundation

/// A pure Recovery-navigation contract for keyboard-only bootstrap profiles.
///
/// The host owns frame capture and OCR. It must reduce each frame to a closed
/// `ScreenFocus` value before calling the coordinator; this contract never
/// receives frame pixels, recognized text, pointer coordinates, or secrets.
/// The coordinator has no input capability. A caller can emit a key only after
/// it obtains a directive and commits that directive through its profile.
protocol RecoveryKeyboardOnlyBootstrapProfile: Sendable {
    associatedtype ScreenFocus: Equatable & Sendable
    associatedtype ClassificationContext: Sendable
    associatedtype Observation: Sendable
    associatedtype Directive: Sendable

    /// The sole focus value allowed to authorize the current cross-screen
    /// boundary. A `nil` value means this stage is deterministic and consumes
    /// no OCR observation.
    var requiredStableScreenFocus: ScreenFocus? { get }

    /// Context the OCR classifier may use while deriving its closed result.
    var classificationContext: ClassificationContext { get }

    static func stableObservation(for screenFocus: ScreenFocus) -> Observation

    mutating func authorize(after observation: Observation?) throws -> Directive
    mutating func commit(_ directive: Directive) throws
}

/// Requires two consecutive OCR classifications of the same, expected focus.
/// Any unknown or wrong classification clears the previous frame so a stale
/// Recovery surface can never authorize a keyboard event.
struct RecoveryKeyboardFrameStability<ScreenFocus: Equatable & Sendable>: Sendable {
    let expectedFocus: ScreenFocus
    private var previous: ScreenFocus?

    init(expectedFocus: ScreenFocus) {
        self.expectedFocus = expectedFocus
    }

    mutating func observe(screenFocus: ScreenFocus) -> ScreenFocus? {
        guard screenFocus == expectedFocus else {
            previous = nil
            return nil
        }
        defer { previous = screenFocus }
        guard previous == screenFocus else { return nil }
        return screenFocus
    }
}

/// Reusable bridge between an OCR classifier and a keyboard-only Recovery
/// profile. It deliberately does not capture frames or send HID events, which
/// keeps pointer/click fallback out of public SIP Recovery bootstrap paths.
struct RecoveryKeyboardOnlyBootstrap<Profile: RecoveryKeyboardOnlyBootstrapProfile>: Sendable {
    private var profile: Profile
    private var frameStability: RecoveryKeyboardFrameStability<Profile.ScreenFocus>?
    private var stableScreenFocus: Profile.ScreenFocus?

    init(profile: Profile) {
        self.profile = profile
    }

    var requiredStableScreenFocus: Profile.ScreenFocus? {
        profile.requiredStableScreenFocus
    }

    var classificationContext: Profile.ClassificationContext {
        profile.classificationContext
    }

    /// Records one already-classified frame. Only two consecutive exact
    /// matches for the profile's current required focus yield a value.
    /// Deterministic profile stages ignore every classified frame.
    @discardableResult
    mutating func observe(screenFocus: Profile.ScreenFocus) -> Profile.ScreenFocus? {
        guard let expectedFocus = profile.requiredStableScreenFocus else {
            frameStability = nil
            stableScreenFocus = nil
            return nil
        }
        if frameStability?.expectedFocus != expectedFocus {
            frameStability = .init(expectedFocus: expectedFocus)
            stableScreenFocus = nil
        }
        guard var stability = frameStability else { return nil }
        let stable = stability.observe(screenFocus: screenFocus)
        frameStability = stability
        stableScreenFocus = stable
        return stable
    }

    /// Obtains exactly one profile directive. At an OCR boundary this passes a
    /// stable observation only when `observe(screenFocus:)` has just proven
    /// the required focus. The profile continues to own cancellation and
    /// durable directive-commit rules.
    mutating func authorizeNextDirective() throws -> Profile.Directive {
        let observation = stableScreenFocus.map(Profile.stableObservation)
        let directive = try profile.authorize(after: observation)
        stableScreenFocus = nil
        return directive
    }

    mutating func commit(_ directive: Profile.Directive) throws {
        try profile.commit(directive)
        frameStability = nil
        stableScreenFocus = nil
    }
}
