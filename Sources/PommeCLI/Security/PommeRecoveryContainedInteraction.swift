import Foundation

enum PommeRecoveryScreen: String, CaseIterable, Equatable, Sendable {
    case startupOptions
    case language
    case user
    case password
    case home
    case utilities
    case unknown
}

struct PommeRecoveryScreenObservation: Equatable, Sendable {
    let lines: [String]

    var normalizedText: String {
        lines.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var screen: PommeRecoveryScreen {
        let text = normalizedText
        guard !text.isEmpty else { return .unknown }
        if text.contains("select a user") || text.contains("select an administrator") { return .user }
        if text.contains("enter password") || text.contains("password for") || text.contains("password:") {
            return .password
        }
        if text.contains("startup security utility") && text.contains("terminal") { return .utilities }
        if text.contains("restore from time machine") || text.contains("reinstall macos") {
            return .home
        }
        if text.contains("options")
            && (text.contains("macintosh hd") || text.contains("restart") || text.contains("continue")) {
            return .startupOptions
        }
        if text.contains("language") || text.contains("english") { return .language }
        return .unknown
    }

    func contains(_ phrase: String) -> Bool {
        normalizedText.contains(phrase.lowercased())
    }
}

protocol PommeRecoveryNavigationPort: Sendable {
    func observe() async throws -> PommeRecoveryScreenObservation
    func click(target: String) async throws
    func sendKey(_ key: String) async throws
    func typeText(_ text: String) async throws
}

struct PommeRecoveryInteractionEvidence: Equatable, Sendable {
    let observations: Int
    let inputs: Int
    let sensitiveInputAccepted: Bool
    let captureDisabledBeforeSensitiveInput: Bool
    let contained: Bool
}

/// Sensitive display frames never leave memory. `disableAndClear` is a
/// one-way gate: once a credential or mutating action is about to be entered,
/// no later observation may retain a frame.
actor PommeRecoverySensitiveFrameGate {
    private var captureEnabled = true
    private var frame: Data?
    private var captureCount = 0

    func capture(_ bytes: Data) -> Bool {
        guard captureEnabled, bytes.count <= 128 * 1_024 * 1_024 else { return false }
        frame = bytes
        captureCount = min(captureCount + 1, 1_024)
        return true
    }

    func disableAndClear() {
        captureEnabled = false
        frame = nil
    }

    func clear() {
        frame = nil
    }

    func evidence() -> (enabled: Bool, hasFrame: Bool, captures: Int) {
        (captureEnabled, frame != nil, captureCount)
    }
}

/// Bounded UI containment. It may inspect and manipulate the Recovery display
/// but has no guest-operation port and therefore cannot launch another guest
/// protocol as a rescue path.
struct PommeRecoveryContainedInteraction: Sendable {
    let navigation: any PommeRecoveryNavigationPort
    let frameGate: PommeRecoverySensitiveFrameGate
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        navigation: any PommeRecoveryNavigationPort,
        frameGate: PommeRecoverySensitiveFrameGate = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.navigation = navigation
        self.frameGate = frameGate
        self.now = now
        self.sleep = sleep
    }

    func disableSensitiveCapture() async {
        await frameGate.disableAndClear()
    }

    func recordFrame(_ bytes: Data) async -> Bool {
        await frameGate.capture(bytes)
    }

    func run(
        timeout: TimeInterval,
        user: String? = nil,
        secret: String? = nil
    ) async throws -> PommeRecoveryInteractionEvidence {
        guard timeout > 0 else { throw PommeRecoverySessionError.invalidRequest }
        let deadline = now().addingTimeInterval(timeout)
        var observations = 0
        var inputs = 0
        var sensitiveInputAccepted = false
        var captureDisabledBeforeSensitiveInput = false
        var previous = PommeRecoveryScreen.unknown

        while now() < deadline {
            let observation = try await navigation.observe()
            observations = min(observations + 1, 1_024)
            let screen = observation.screen
            switch screen {
            case .startupOptions:
                if previous != .startupOptions {
                    try await navigation.sendKey("right")
                    try await navigation.sendKey("return")
                    inputs = min(inputs + 2, 1_024)
                }
            case .language:
                if previous != .language {
                    try await navigation.click(target: "English")
                    try await navigation.sendKey("return")
                    inputs = min(inputs + 2, 1_024)
                }
            case .user:
                if let user, !user.isEmpty {
                    try await navigation.click(target: user)
                } else {
                    try await navigation.sendKey("return")
                }
                inputs = min(inputs + 1, 1_024)
            case .password:
                guard let secret, !secret.isEmpty,
                      !secret.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
                else { throw PommeRecoverySessionError.invalidCredential }
                await disableSensitiveCapture()
                captureDisabledBeforeSensitiveInput = true
                try await navigation.typeText(secret)
                try await navigation.sendKey("return")
                inputs = min(inputs + 2, 1_024)
                sensitiveInputAccepted = true
            case .home, .utilities:
                await disableSensitiveCapture()
                captureDisabledBeforeSensitiveInput = true
                return .init(
                    observations: observations,
                    inputs: inputs,
                    sensitiveInputAccepted: sensitiveInputAccepted,
                    captureDisabledBeforeSensitiveInput: captureDisabledBeforeSensitiveInput,
                    contained: true
                )
            case .unknown:
                break
            }
            previous = screen
            try await sleep(0.05)
        }
        throw PommeRecoverySessionError.invalidLifecycle
    }
}
