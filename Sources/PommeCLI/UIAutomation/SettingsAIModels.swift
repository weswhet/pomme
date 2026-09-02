import Foundation
import CoreGraphics

private func settingsAIFormattedConfidence(_ confidence: Double) -> String {
    confidence.formatted(
        .number
            .precision(.fractionLength(2))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))
    )
}

enum SettingsAIMode: String, Sendable {
    case suggest
    case step
    case loop

    static func parse(_ value: String) throws -> SettingsAIMode {
        guard let mode = SettingsAIMode(rawValue: value.lowercased()) else {
            throw RunnerError.invalidUICommand("ui ai settings --mode must be suggest, step, or loop.")
        }
        return mode
    }
}

enum SettingsAIProviderName: String, Sendable {
    case appleLocal = "apple-local"

    static func parse(_ value: String) throws -> SettingsAIProviderName {
        guard let provider = SettingsAIProviderName(rawValue: value.lowercased()) else {
            throw RunnerError.invalidUICommand("ui ai settings --provider currently supports apple-local.")
        }
        return provider
    }
}

struct SettingsAIRequest: @unchecked Sendable {
    static let defaultMaxSteps = 8
    static let defaultConfidence = 0.70
    static let defaultModelTimeout: TimeInterval = 60
    static let defaultDeterministicFallback = false

    let goal: String
    let mode: SettingsAIMode
    let provider: SettingsAIProviderName
    let maxSteps: Int
    let confidenceThreshold: Double
    let modelTimeout: TimeInterval
    let deterministicFallback: Bool
    let openSettings: Bool
    let settingsURL: String?
    let untilText: String?
    let screenshotOutputDirectory: String?

    var jsonPayload: [String: Any] {
        var payload: [String: Any] = [
            "operation": "settings-ai",
            "goal": goal,
            "mode": mode.rawValue,
            "provider": provider.rawValue,
            "maxSteps": maxSteps,
            "confidence": confidenceThreshold,
            "modelTimeout": modelTimeout,
            "deterministicFallback": deterministicFallback,
            "openSettings": openSettings
        ]
        if let settingsURL {
            payload["settingsURL"] = settingsURL
        }
        if let untilText {
            payload["untilText"] = untilText
        }
        if let screenshotOutputDirectory {
            payload["screenshotOutputDirectory"] = screenshotOutputDirectory
        }
        return payload
    }

    static func parse(from payload: [String: Any]) throws -> SettingsAIRequest {
        guard let goal = payload["goal"] as? String, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunnerError.invalidUICommand("ui ai settings requires a non-empty goal.")
        }

        let mode = try SettingsAIMode.parse((payload["mode"] as? String) ?? SettingsAIMode.suggest.rawValue)
        let provider = try SettingsAIProviderName.parse((payload["provider"] as? String) ?? SettingsAIProviderName.appleLocal.rawValue)
        let maxSteps = integerValue(payload["maxSteps"]) ?? Self.defaultMaxSteps
        let confidence = doubleValue(payload["confidence"]) ?? Self.defaultConfidence
        let modelTimeout = doubleValue(payload["modelTimeout"]) ?? doubleValue(payload["model_timeout"]) ?? Self.defaultModelTimeout
        let deterministicFallback = boolFromAny(payload["deterministicFallback"])
            ?? boolFromAny(payload["deterministic_fallback"])
            ?? Self.defaultDeterministicFallback
        guard maxSteps > 0 else {
            throw RunnerError.invalidUICommand("ui ai settings --max-steps requires a positive integer.")
        }
        guard confidence >= 0, confidence <= 1 else {
            throw RunnerError.invalidUICommand("ui ai settings --confidence must be between 0 and 1.")
        }
        guard modelTimeout > 0 else {
            throw RunnerError.invalidUICommand("ui ai settings --model-timeout requires a positive number of seconds.")
        }

        return SettingsAIRequest(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            provider: provider,
            maxSteps: maxSteps,
            confidenceThreshold: confidence,
            modelTimeout: modelTimeout,
            deterministicFallback: deterministicFallback,
            openSettings: boolFromAny(payload["openSettings"]) ?? true,
            settingsURL: payload["settingsURL"] as? String,
            untilText: payload["untilText"] as? String,
            screenshotOutputDirectory: payload["screenshotOutputDirectory"] as? String
        )
    }
}

enum SettingsAIActionKind: String, Sendable {
    case click
    case key
    case type
    case wait
    case done

    static func parse(_ value: String) throws -> SettingsAIActionKind {
        guard let kind = SettingsAIActionKind(rawValue: value.lowercased()) else {
            throw RunnerError.invalidUICommand("Settings AI action must be click, key, type, wait, or done.")
        }
        return kind
    }
}

struct SettingsAIAction: Sendable, Equatable {
    let kind: SettingsAIActionKind
    let x: Double?
    let y: Double?
    let targetID: String?
    let key: String?
    let text: String?
    let replace: Bool
    let seconds: Double?

    var signature: String {
        switch kind {
        case .click:
            return "click:\(targetID ?? ""):\(roundedSignatureValue(x)):\(roundedSignatureValue(y))"
        case .key:
            return "key:\(key ?? "")"
        case .type:
            return "type:\(replace):\(text ?? "")"
        case .wait:
            return "wait:\(roundedSignatureValue(seconds))"
        case .done:
            return "done"
        }
    }

    var jsonPayload: [String: Any] {
        var payload: [String: Any] = ["action": kind.rawValue]
        if let x {
            payload["x"] = x
        }
        if let y {
            payload["y"] = y
        }
        if let targetID {
            payload["targetID"] = targetID
        }
        if let key {
            payload["key"] = key
        }
        if let text {
            payload["text"] = text
            payload["replace"] = replace
        }
        if let seconds {
            payload["seconds"] = seconds
        }
        return payload
    }

    private func roundedSignatureValue(_ value: Double?) -> String {
        guard let value else {
            return ""
        }
        return String(Int(value.rounded()))
    }
}

struct SettingsAIProposal: Sendable {
    let action: SettingsAIAction
    let confidence: Double
    let rationale: String

    var jsonPayload: [String: Any] {
        var payload = action.jsonPayload
        payload["confidence"] = confidence
        payload["rationale"] = rationale
        return payload
    }

    static func decode(from object: [String: Any]) throws -> SettingsAIProposal {
        let actionName = (object["action"] as? String) ?? (object["operation"] as? String) ?? ""
        let action = SettingsAIAction(
            kind: try SettingsAIActionKind.parse(actionName),
            x: doubleValue(object["x"]),
            y: doubleValue(object["y"]),
            targetID: stringValue(object["targetID"]) ?? stringValue(object["targetId"]) ?? stringValue(object["target_id"]),
            key: object["key"] as? String,
            text: object["text"] as? String,
            replace: boolFromAny(object["replace"]) ?? false,
            seconds: doubleValue(object["seconds"])
        )
        return SettingsAIProposal(
            action: action,
            confidence: doubleValue(object["confidence"]) ?? 0,
            rationale: object["rationale"] as? String ?? ""
        )
    }
}

struct SettingsAIControlCandidate: Sendable, Equatable {
    let id: String
    let kind: String
    let label: String?
    let state: String
    let rect: CGRect
    let center: CGPoint
    let source: String
    let confidence: Double

    var jsonPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "kind": kind,
            "state": state,
            "rect": [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ],
            "center": [
                "x": center.x,
                "y": center.y
            ],
            "source": source,
            "confidence": confidence
        ]
        if let label {
            payload["label"] = label
        }
        return payload
    }

    var promptLine: String {
        let labelText = label.map { " label=\"\(settingsAIEscapePromptValue($0))\"" } ?? ""
        let confidenceText = settingsAIFormattedConfidence(confidence)
        return "\(id) kind=\(kind)\(labelText) state=\(state) center=(\(Int(center.x.rounded())),\(Int(center.y.rounded()))) rect=(\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))) source=\(source) conf=\(confidenceText)"
    }
}

struct SettingsAITargetResolution: Sendable {
    let requestedID: String
    let resolvedID: String?
    let valid: Bool
    let code: String?
    let message: String?
    let center: CGPoint?
    let rect: CGRect?

    static func resolved(requestedID: String, candidate: SettingsAIControlCandidate) -> SettingsAITargetResolution {
        SettingsAITargetResolution(
            requestedID: requestedID,
            resolvedID: candidate.id,
            valid: true,
            code: nil,
            message: nil,
            center: candidate.center,
            rect: candidate.rect
        )
    }

    static func missing(requestedID: String) -> SettingsAITargetResolution {
        SettingsAITargetResolution(
            requestedID: requestedID,
            resolvedID: nil,
            valid: false,
            code: "unknown_target",
            message: "No detected Settings AI target has id \(requestedID).",
            center: nil,
            rect: nil
        )
    }

    var jsonPayload: [String: Any] {
        var payload: [String: Any] = [
            "ok": valid,
            "requestedID": requestedID,
            "code": code ?? "",
            "message": message ?? ""
        ]
        if let resolvedID {
            payload["resolvedID"] = resolvedID
        }
        if let center {
            payload["center"] = ["x": center.x, "y": center.y]
        }
        if let rect {
            payload["rect"] = [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ]
        }
        return payload
    }
}

struct SettingsAIResolvedProposal: Sendable {
    let proposal: SettingsAIProposal
    let targetResolution: SettingsAITargetResolution?
}

enum SettingsAITargetResolver {
    static func resolve(
        proposal: SettingsAIProposal,
        controlCandidates: [SettingsAIControlCandidate]
    ) -> SettingsAIResolvedProposal {
        guard proposal.action.kind == .click,
              let rawTargetID = proposal.action.targetID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTargetID.isEmpty
        else {
            return SettingsAIResolvedProposal(proposal: proposal, targetResolution: nil)
        }
        guard let candidate = controlCandidates.first(where: { $0.id == rawTargetID }) else {
            return SettingsAIResolvedProposal(
                proposal: proposal,
                targetResolution: .missing(requestedID: rawTargetID)
            )
        }
        let action = SettingsAIAction(
            kind: proposal.action.kind,
            x: candidate.center.x,
            y: candidate.center.y,
            targetID: rawTargetID,
            key: proposal.action.key,
            text: proposal.action.text,
            replace: proposal.action.replace,
            seconds: proposal.action.seconds
        )
        return SettingsAIResolvedProposal(
            proposal: SettingsAIProposal(
                action: action,
                confidence: proposal.confidence,
                rationale: proposal.rationale
            ),
            targetResolution: .resolved(requestedID: rawTargetID, candidate: candidate)
        )
    }
}

struct SettingsAIDeterministicFallbackResult: Sendable {
    let proposal: SettingsAIProposal
    let target: SettingsAIControlCandidate
    let desiredState: String
    let providerErrorCode: String
    let reason: String

    var jsonPayload: [String: Any] {
        [
            "ok": true,
            "source": "deterministic-toggle-fallback",
            "desiredState": desiredState,
            "providerErrorCode": providerErrorCode,
            "reason": reason,
            "target": target.jsonPayload
        ]
    }
}

enum SettingsAIDeterministicFallbackPlanner {
    static func propose(
        context: SettingsAIScreenContext,
        providerError: SettingsAIProviderError
    ) -> SettingsAIDeterministicFallbackResult? {
        guard let intent = SettingsAIToggleIntent(goal: context.goal) else {
            return nil
        }
        let goal = settingsAINormalizedLabel(context.goal)
        let candidates = context.observation.controlCandidates
            .filter { candidate in
                guard candidate.kind == "toggle",
                      candidate.confidence >= 0.85,
                      let label = candidate.label.map(settingsAINormalizedLabel),
                      label.count >= 2,
                      goal.contains(label),
                      candidate.state == "on" || candidate.state == "off"
                else {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.rect.minY < rhs.rect.minY
            }
        guard let target = candidates.first else {
            return nil
        }

        let label = target.label ?? target.id
        let proposal: SettingsAIProposal
        let reason: String
        if target.state == intent.desiredState {
            reason = "Detected \(label) toggle is already \(intent.desiredState)."
            proposal = SettingsAIProposal(
                action: SettingsAIAction(
                    kind: .done,
                    x: nil,
                    y: nil,
                    targetID: nil,
                    key: nil,
                    text: nil,
                    replace: false,
                    seconds: nil
                ),
                confidence: min(0.99, target.confidence),
                rationale: reason
            )
        } else {
            reason = "Detected \(label) toggle is \(target.state); click it to turn it \(intent.desiredState)."
            proposal = SettingsAIProposal(
                action: SettingsAIAction(
                    kind: .click,
                    x: nil,
                    y: nil,
                    targetID: target.id,
                    key: nil,
                    text: nil,
                    replace: false,
                    seconds: nil
                ),
                confidence: min(0.99, target.confidence),
                rationale: reason
            )
        }

        return SettingsAIDeterministicFallbackResult(
            proposal: proposal,
            target: target,
            desiredState: intent.desiredState,
            providerErrorCode: providerError.code,
            reason: reason
        )
    }
}

private struct SettingsAIToggleIntent {
    let desiredState: String

    init?(goal: String) {
        let normalized = settingsAINormalizedLabel(goal)
        let offPhrases = [
            "turn off",
            "switch off",
            "toggle off",
            "set off",
            "disable",
            "deactivate"
        ]
        let onPhrases = [
            "turn on",
            "switch on",
            "toggle on",
            "set on",
            "enable",
            "activate"
        ]
        let wantsOff = offPhrases.contains { normalized.contains($0) }
        let wantsOn = onPhrases.contains { normalized.contains($0) }
        guard wantsOff != wantsOn else {
            return nil
        }
        desiredState = wantsOff ? "off" : "on"
    }
}

struct SettingsAIOCRLine: Sendable {
    let text: String
    let confidence: Double
    let rect: CGRect

    var jsonPayload: [String: Any] {
        [
            "text": text,
            "confidence": confidence,
            "rect": [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ]
        ]
    }

    var promptLine: String {
        let x = Int(rect.midX.rounded())
        let y = Int(rect.midY.rounded())
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        let confidenceText = settingsAIFormattedConfidence(confidence)
        return "[center=(\(x),\(y)) size=\(width)x\(height) conf=\(confidenceText)] \(text)"
    }
}

struct SettingsAIObservation: @unchecked Sendable {
    let screenshotPath: String
    let screenshotBytes: Int
    let displaySize: CGSize
    let ocrLines: [SettingsAIOCRLine]
    let controlCandidates: [SettingsAIControlCandidate]
    let axSnapshot: [String: Any]?

    var recognizedText: String {
        ocrLines.map(\.text).joined(separator: "\n")
    }

    var jsonPayload: [String: Any] {
        var payload: [String: Any] = [
            "screenshot": [
                "hostPath": screenshotPath,
                "bytes": screenshotBytes,
                "width": Int(displaySize.width),
                "height": Int(displaySize.height)
            ],
            "ocr": [
                "text": recognizedText,
                "lines": ocrLines.map(\.jsonPayload)
            ],
            "controls": controlCandidates.map(\.jsonPayload)
        ]
        if let axSnapshot {
            payload["accessibility"] = axSnapshot
        }
        return payload
    }
}

struct SettingsAIScreenContext: @unchecked Sendable {
    let goal: String
    let displaySize: CGSize
    let stepIndex: Int
    let maxSteps: Int
    let mode: SettingsAIMode
    let observation: SettingsAIObservation
    let previousActions: [SettingsAIAction]

    var prompt: String {
        var lines: [String] = [
            "Goal: \(goal)",
            "Display: \(Int(displaySize.width))x\(Int(displaySize.height)) host-display points, origin top-left.",
            "Mode: \(mode.rawValue); step \(stepIndex + 1) of \(maxSteps).",
            "Return one next action only. Supported actions: click(targetID or x,y), key(name), type(text, replace), wait(seconds), done.",
            "Prefer targetID for clicks when an available target matches the goal. Raw coordinates are still allowed.",
            "Use click coordinates in host-display points. Prefer done only when the goal is visibly complete.",
            "Do not click outside System Settings or take destructive actions unless the goal explicitly requires it."
        ]
        if !previousActions.isEmpty {
            lines.append("Previous actions: \(previousActions.map(\.signature).joined(separator: ", "))")
        }
        if observation.controlCandidates.isEmpty {
            lines.append("Available targets: none detected.")
        } else {
            lines.append("Available targets:")
            lines.append(contentsOf: observation.controlCandidates.map(\.promptLine))
        }
        let ocrPrompt = compactOCRPromptLines().map(\.promptLine)
        if ocrPrompt.isEmpty {
            lines.append("OCR: no text recognized.")
        } else {
            lines.append("Relevant OCR:")
            lines.append(contentsOf: ocrPrompt)
        }
        if let axSnapshot = observation.axSnapshot {
            lines.append("Perception summary:")
            lines.append(settingsAICompactDescription(axSnapshot, maxCharacters: 2_000))
        }
        return lines.joined(separator: "\n")
    }

    func promptStats(promptCharacterCount: Int? = nil) -> [String: Any] {
        [
            "ocrLineCount": observation.ocrLines.count,
            "ocrPromptLineCount": compactOCRPromptLines().count,
            "controlCandidateCount": observation.controlCandidates.count,
            "promptCharacterCount": promptCharacterCount ?? prompt.count
        ]
    }

    private func compactOCRPromptLines() -> [SettingsAIOCRLine] {
        let associatedLabels = Set(
            observation.controlCandidates
                .compactMap(\.label)
                .map { settingsAINormalizedLabel($0) }
        )
        let highConfidence = observation.ocrLines.filter { line in
            line.confidence >= 0.30 || associatedLabels.contains(settingsAINormalizedLabel(line.text))
        }
        return Array(highConfidence.prefix(40))
    }
}

enum SettingsAIStopReason: String {
    case suggested
    case stepComplete = "step-complete"
    case done
    case untilTextMatched = "until-text-matched"
    case lowConfidence = "low-confidence"
    case repeatedAction = "repeated-action"
    case invalidAction = "invalid-action"
    case maxSteps = "max-steps"
    case providerError = "provider-error"
    case executionError = "execution-error"
}

struct SettingsAIValidationResult: Sendable {
    let valid: Bool
    let code: String?
    let message: String?

    static let ok = SettingsAIValidationResult(valid: true, code: nil, message: nil)

    static func invalid(_ code: String, _ message: String) -> SettingsAIValidationResult {
        SettingsAIValidationResult(valid: false, code: code, message: message)
    }

    var jsonPayload: [String: Any] {
        [
            "ok": valid,
            "code": code ?? "",
            "message": message ?? ""
        ]
    }
}

enum SettingsAIActionValidator {
    static func validate(
        proposal: SettingsAIProposal,
        displaySize: CGSize,
        confidenceThreshold: Double,
        targetResolution: SettingsAITargetResolution? = nil
    ) -> SettingsAIValidationResult {
        guard proposal.confidence >= confidenceThreshold else {
            return .invalid("low_confidence", "Proposal confidence \(proposal.confidence) is below threshold \(confidenceThreshold).")
        }
        if let targetResolution, !targetResolution.valid {
            return .invalid(targetResolution.code ?? "unknown_target", targetResolution.message ?? "The requested target ID could not be resolved.")
        }

        switch proposal.action.kind {
        case .click:
            guard let x = proposal.action.x, let y = proposal.action.y, x.isFinite, y.isFinite else {
                return .invalid("invalid_click", "click requires finite x and y coordinates.")
            }
            guard x >= 0, y >= 0, x < displaySize.width, y < displaySize.height else {
                return .invalid("invalid_coordinates", "click coordinates are outside the host display bounds.")
            }
            return .ok
        case .key:
            guard let key = proposal.action.key, !key.isEmpty else {
                return .invalid("invalid_key", "key requires a key name.")
            }
            guard HostDisplayKey.lookup(key) != nil else {
                return .invalid("unsupported_key", "Unsupported host display key: \(key).")
            }
            return .ok
        case .type:
            guard proposal.action.text != nil else {
                return .invalid("invalid_type", "type requires text.")
            }
            return .ok
        case .wait:
            guard let seconds = proposal.action.seconds, seconds.isFinite, seconds > 0, seconds <= 30 else {
                return .invalid("invalid_wait", "wait requires seconds in the range 0...30.")
            }
            return .ok
        case .done:
            return .ok
        }
    }
}

enum SettingsAIProviderError: Error {
    case unavailable(code: String, message: String)
    case failed(code: String, message: String)

    var code: String {
        switch self {
        case .unavailable(let code, _), .failed(let code, _):
            return code
        }
    }

    var message: String {
        switch self {
        case .unavailable(_, let message), .failed(_, let message):
            return message
        }
    }

    var jsonPayload: [String: Any] {
        var payload: [String: Any] = [
            "ok": false,
            "errorCode": code,
            "error": message
        ]
        switch code {
        case "appleIntelligenceNotEnabled":
            let settingsURL = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
            payload["settingsURL"] = settingsURL
            payload["hostSettingsURL"] = settingsURL
            payload["settingsPane"] = "Apple Intelligence & Siri"
            payload["prompt"] = "Apple Intelligence is off. Open System Settings to Apple Intelligence & Siri, turn on Apple Intelligence, wait for the local model to finish preparing, then retry."
            payload["openCommand"] = "open '\(settingsURL)'"
            payload["requiresUserAction"] = true
            payload["recovery"] = "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri."
        case "modelNotReady":
            payload["prompt"] = "The local FoundationModels language model is not ready. Wait for it to finish downloading or preparing, then retry."
            payload["recovery"] = "Wait for the local FoundationModels language model to finish downloading or preparing, then retry."
        default:
            break
        }
        return payload
    }
}

protocol SettingsAIModelProvider: Sendable {
    var name: SettingsAIProviderName { get }

    func preflight() async throws
    func propose(context: SettingsAIScreenContext) async throws -> SettingsAIProposal
}

extension SettingsAIModelProvider {
    func preflight() async throws {}
}

func settingsAICompactDescription(_ value: Any, maxCharacters: Int) -> String {
    let text: String
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        text = json
    } else {
        text = String(describing: value)
    }
    if text.count <= maxCharacters {
        return text
    }
    return String(text.prefix(maxCharacters)) + "...[truncated]"
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return nil
}

private func settingsAIEscapePromptValue(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func settingsAINormalizedLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}
