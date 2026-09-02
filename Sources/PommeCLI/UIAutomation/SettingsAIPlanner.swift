import Foundation
import CoreGraphics
import ImageIO
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

struct SettingsAIHostDisplaySize: Sendable {
    let width: Int
    let height: Int

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    var jsonPayload: [String: Any] {
        ["width": width, "height": height]
    }
}

struct SettingsAIPlannerDependencies: @unchecked Sendable {
    let hostDisplaySize: @Sendable () -> SettingsAIHostDisplaySize
    let captureScreenshot: @Sendable (_ outputURL: URL, _ timeout: TimeInterval) async throws -> [String: Any]
    let optionalAXSnapshot: @Sendable (_ timeout: TimeInterval) async -> [String: JSONValue]?
    let openSettings: @Sendable (_ settingsURL: String?, _ timeout: TimeInterval) async -> [String: Any]
    let executeAction: @Sendable (_ action: SettingsAIAction, _ timeout: TimeInterval) async throws -> [String: Any]
    let provider: @Sendable (_ name: SettingsAIProviderName) -> any SettingsAIModelProvider
}

final class SettingsAIPlanner: @unchecked Sendable {
    private let dependencies: SettingsAIPlannerDependencies
    private let fileManager: FileManager

    init(dependencies: SettingsAIPlannerDependencies, fileManager: FileManager = .default) {
        self.dependencies = dependencies
        self.fileManager = fileManager
    }

    func run(request: SettingsAIRequest, timeout: TimeInterval) async -> [String: Any] {
        var steps: [[String: Any]] = []
        var openedSettings: [String: Any]?
        var stopReason: SettingsAIStopReason = .maxSteps
        var done = false
        var ok = true
        let startedAt = Date()
        let hostDisplay = dependencies.hostDisplaySize()
        let provider = dependencies.provider(request.provider)
        let maxStepCount = request.mode == .loop ? request.maxSteps : 1
        var previousActions: [SettingsAIAction] = []
        var didPreflightProvider = false

        if request.openSettings {
            openedSettings = await dependencies.openSettings(request.settingsURL, min(timeout, 30))
            if openedSettings?["ok"] as? Bool == false {
                ok = false
                stopReason = .executionError
                return responsePayload(
                    request: request,
                    hostDisplay: hostDisplay,
                    openedSettings: openedSettings,
                    steps: steps,
                    done: false,
                    ok: false,
                    stopReason: stopReason,
                    startedAt: startedAt,
                    error: openedSettings?["error"] as? String
                )
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        for stepIndex in 0..<maxStepCount {
            var step: [String: Any] = [
                "index": stepIndex,
                "executed": false
            ]
            var timing: [String: Any] = [:]

            do {
                let observationResult = try await makeObservation(
                    request: request,
                    stepIndex: stepIndex,
                    hostDisplay: hostDisplay,
                    timeout: timeout
                )
                let observation = observationResult.observation
                timing.merge(observationResult.timing) { _, new in new }
                step["observation"] = observation.jsonPayload
                step["timing"] = timing

                if let untilText = request.untilText,
                   !untilText.isEmpty,
                   observation.recognizedText.range(of: untilText, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    done = true
                    stopReason = .untilTextMatched
                    step["result"] = ["ok": true, "stopReason": stopReason.rawValue, "matchedText": untilText]
                    steps.append(step)
                    break
                }

                let context = SettingsAIScreenContext(
                    goal: request.goal,
                    displaySize: hostDisplay.cgSize,
                    stepIndex: stepIndex,
                    maxSteps: maxStepCount,
                    mode: request.mode,
                    observation: observation,
                    previousActions: previousActions
                )
                let promptBuildStart = Date()
                let prompt = context.prompt
                timing["promptBuildSeconds"] = elapsedSeconds(since: promptBuildStart)
                step["promptStats"] = context.promptStats(promptCharacterCount: prompt.count)
                step["timing"] = timing

                if didPreflightProvider {
                    timing["providerPreflightSeconds"] = 0
                    timing["providerPreflightSkipped"] = true
                    step["timing"] = timing
                } else {
                    let preflightStart = Date()
                    do {
                        try await provider.preflight()
                        didPreflightProvider = true
                        timing["providerPreflightSeconds"] = elapsedSeconds(since: preflightStart)
                        step["timing"] = timing
                    } catch let error as SettingsAIProviderError {
                        timing["providerPreflightSeconds"] = elapsedSeconds(since: preflightStart)
                        step["timing"] = timing
                        ok = false
                        stopReason = .providerError
                        step["result"] = error.jsonPayload
                        steps.append(step)
                        break
                    } catch {
                        timing["providerPreflightSeconds"] = elapsedSeconds(since: preflightStart)
                        step["timing"] = timing
                        ok = false
                        stopReason = .providerError
                        step["result"] = SettingsAIProviderError.failed(
                            code: "provider_failed",
                            message: error.localizedDescription
                        ).jsonPayload
                        steps.append(step)
                        break
                    }
                }

                let rawProposal: SettingsAIProposal
                let inferenceStart = Date()
                do {
                    rawProposal = try await proposeWithTimeout(
                        provider: provider,
                        context: context,
                        timeout: request.modelTimeout
                    )
                    timing["providerInferenceSeconds"] = elapsedSeconds(since: inferenceStart)
                    step["timing"] = timing
                    step["proposalSource"] = "provider"
                } catch let error as SettingsAIProviderError {
                    timing["providerInferenceSeconds"] = elapsedSeconds(since: inferenceStart)
                    step["timing"] = timing
                    if request.deterministicFallback,
                       let fallback = SettingsAIDeterministicFallbackPlanner.propose(
                        context: context,
                        providerError: error
                       ) {
                        rawProposal = fallback.proposal
                        step["providerFailure"] = error.jsonPayload
                        step["fallback"] = fallback.jsonPayload
                        step["proposalSource"] = "deterministic-fallback"
                    } else {
                        ok = false
                        stopReason = .providerError
                        step["result"] = error.jsonPayload
                        steps.append(step)
                        break
                    }
                } catch {
                    timing["providerInferenceSeconds"] = elapsedSeconds(since: inferenceStart)
                    step["timing"] = timing
                    let providerError = SettingsAIProviderError.failed(
                        code: "provider_failed",
                        message: error.localizedDescription
                    )
                    if request.deterministicFallback,
                       let fallback = SettingsAIDeterministicFallbackPlanner.propose(
                        context: context,
                        providerError: providerError
                       ) {
                        rawProposal = fallback.proposal
                        step["providerFailure"] = providerError.jsonPayload
                        step["fallback"] = fallback.jsonPayload
                        step["proposalSource"] = "deterministic-fallback"
                    } else {
                        ok = false
                        stopReason = .providerError
                        step["result"] = providerError.jsonPayload
                        steps.append(step)
                        break
                    }
                }

                let resolvedProposal = SettingsAITargetResolver.resolve(
                    proposal: rawProposal,
                    controlCandidates: observation.controlCandidates
                )
                let proposal = resolvedProposal.proposal
                step["proposal"] = proposal.jsonPayload
                if let targetResolution = resolvedProposal.targetResolution {
                    step["targetResolution"] = targetResolution.jsonPayload
                }

                let validation = SettingsAIActionValidator.validate(
                    proposal: proposal,
                    displaySize: hostDisplay.cgSize,
                    confidenceThreshold: request.confidenceThreshold,
                    targetResolution: resolvedProposal.targetResolution
                )
                step["validation"] = validation.jsonPayload
                if !validation.valid {
                    stopReason = validation.code == "low_confidence" ? .lowConfidence : .invalidAction
                    step["result"] = [
                        "ok": false,
                        "stopReason": stopReason.rawValue,
                        "errorCode": validation.code ?? "invalid_action",
                        "error": validation.message ?? "Invalid action."
                    ]
                    steps.append(step)
                    break
                }

                if proposal.action.kind == .done {
                    done = true
                    stopReason = .done
                    step["result"] = ["ok": true, "stopReason": stopReason.rawValue]
                    steps.append(step)
                    break
                }

                if request.mode == .suggest {
                    stopReason = .suggested
                    step["result"] = ["ok": true, "stopReason": stopReason.rawValue]
                    steps.append(step)
                    break
                }

                if request.mode == .loop,
                   previousActions.last?.signature == proposal.action.signature {
                    stopReason = .repeatedAction
                    step["result"] = [
                        "ok": false,
                        "stopReason": stopReason.rawValue,
                        "errorCode": "repeated_action",
                        "error": "Provider repeated the previous action."
                    ]
                    steps.append(step)
                    break
                }

                let executionStart = Date()
                let result = try await dependencies.executeAction(proposal.action, timeout)
                timing["executionSeconds"] = elapsedSeconds(since: executionStart)
                step["timing"] = timing
                step["executed"] = true
                step["result"] = result
                previousActions.append(proposal.action)
                steps.append(step)

                if request.mode == .step {
                    stopReason = .stepComplete
                    break
                }

                try? await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                ok = false
                stopReason = .executionError
                step["timing"] = timing
                if let automationError = error as? VirtualizationPrivateHeadlessError {
                    var failure = automationError.payload(operation: "settings-ai")
                    failure["stopReason"] = stopReason.rawValue
                    step["result"] = failure
                } else {
                    step["result"] = [
                        "ok": false,
                        "stopReason": stopReason.rawValue,
                        "errorCode": "execution_error",
                        "error": error.localizedDescription
                    ]
                }
                steps.append(step)
                break
            }
        }

        if request.mode == .loop, !done, stopReason == .maxSteps, steps.count >= maxStepCount {
            stopReason = .maxSteps
        }

        return responsePayload(
            request: request,
            hostDisplay: hostDisplay,
            openedSettings: openedSettings,
            steps: steps,
            done: done,
            ok: ok && ![.providerError, .executionError].contains(stopReason),
            stopReason: stopReason,
            startedAt: startedAt,
            error: nil
        )
    }

    private func makeObservation(
        request: SettingsAIRequest,
        stepIndex: Int,
        hostDisplay: SettingsAIHostDisplaySize,
        timeout: TimeInterval
    ) async throws -> SettingsAIObservationResult {
        var timing: [String: Any] = [:]
        let screenshotURL = try screenshotURL(request: request, stepIndex: stepIndex)
        let screenshotStart = Date()
        let screenshot = try await dependencies.captureScreenshot(screenshotURL, timeout)
        timing["screenshotSeconds"] = elapsedSeconds(since: screenshotStart)
        let bytes = integerValue(screenshot["bytes"]) ?? 0
        let ocrStart = Date()
        let ocrLines = try await recognizeOCRWithTimeout(
            imageURL: screenshotURL,
            displaySize: hostDisplay.cgSize,
            timeout: min(timeout, 3)
        )
        timing["ocrSeconds"] = elapsedSeconds(since: ocrStart)
        timing["ocrEngine"] = "vision-vn-fast"

        let perceptionStart = Date()
        let controlCandidates: [SettingsAIControlCandidate]
        do {
            controlCandidates = try SettingsAIPerception().controlCandidates(
                imageURL: screenshotURL,
                displaySize: hostDisplay.cgSize,
                ocrLines: ocrLines
            )
        } catch {
            controlCandidates = []
            timing["perceptionError"] = error.localizedDescription
        }
        timing["perceptionSeconds"] = elapsedSeconds(since: perceptionStart)

        let axStart = Date()
        let axSnapshot = await optionalAXSnapshotWithTimeout(timeout: min(timeout, 5))
            .map(compactAXSnapshot)?
            .mapValues(\.publicValue)
        timing["axSnapshotSeconds"] = elapsedSeconds(since: axStart)

        return SettingsAIObservationResult(
            observation: SettingsAIObservation(
                screenshotPath: screenshotURL.path,
                screenshotBytes: bytes,
                displaySize: hostDisplay.cgSize,
                ocrLines: ocrLines,
                controlCandidates: controlCandidates,
                axSnapshot: axSnapshot
            ),
            timing: timing
        )
    }

    private func screenshotURL(request: SettingsAIRequest, stepIndex: Int) throws -> URL {
        let baseURL: URL
        if let directory = request.screenshotOutputDirectory {
            baseURL = URL(fileURLWithPath: directory, isDirectory: true)
        } else {
            baseURL = fileManager.temporaryDirectory
                .appendingPathComponent("pomme-settings-ai-\(UUID().uuidString)", isDirectory: true)
        }
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let filename = "settings-ai-\(Date().pommeFileTimestamp)-step-\(stepIndex + 1).png"
        return baseURL.appendingPathComponent(filename)
    }

    private func responsePayload(
        request: SettingsAIRequest,
        hostDisplay: SettingsAIHostDisplaySize,
        openedSettings: [String: Any]?,
        steps: [[String: Any]],
        done: Bool,
        ok: Bool,
        stopReason: SettingsAIStopReason,
        startedAt: Date,
        error: String?
    ) -> [String: Any] {
        let durationSeconds = Date().timeIntervalSince(startedAt)
        var payload: [String: Any] = [
            "ok": ok,
            "schemaVersion": 2,
            "operation": "settings-ai",
            "backend": VirtualizationPrivateHeadlessBackend.backendName,
            "hostBuild": VirtualizationPrivateHeadlessBackend.hostBuild,
            "width": hostDisplay.width,
            "height": hostDisplay.height,
            "mode": request.mode.rawValue,
            "provider": request.provider.rawValue,
            "goal": request.goal,
            "modelTimeout": request.modelTimeout,
            "deterministicFallback": request.deterministicFallback,
            "hostDisplay": hostDisplay.jsonPayload,
            "steps": steps,
            "done": done,
            "stopReason": stopReason.rawValue,
            "durationSeconds": durationSeconds,
            "timing": ["totalSeconds": durationSeconds],
            "hostExitCode": ok ? 0 : 1
        ]
        if let openedSettings {
            payload["openSettings"] = openedSettings
        }
        if let error {
            payload["error"] = error
        }
        if stopReason == .providerError,
           let providerFailure = steps.compactMap({ $0["result"] as? [String: Any] }).first {
            for key in [
                "errorCode",
                "error",
                "recovery",
                "prompt",
                "settingsURL",
                "hostSettingsURL",
                "settingsPane",
                "openCommand",
                "requiresUserAction"
            ] {
                if let value = providerFailure[key] {
                    payload[key] = value
                }
            }
        }
        if !ok,
           let operationFailure = steps.compactMap({ $0["result"] as? [String: Any] }).last {
            for key in ["errorCode", "error", "partialInputPossible"] {
                if let value = operationFailure[key] {
                    payload[key] = value
                }
            }
        }
        if let untilText = request.untilText {
            payload["untilText"] = untilText
        }
        if let screenshotOutputDirectory = request.screenshotOutputDirectory {
            payload["screenshotOutputDirectory"] = screenshotOutputDirectory
        }
        return payload
    }

    private func proposeWithTimeout(
        provider: any SettingsAIModelProvider,
        context: SettingsAIScreenContext,
        timeout: TimeInterval
    ) async throws -> SettingsAIProposal {
        let timeout = max(1, timeout)
        let gate = SettingsAIProviderTimeoutGate<SettingsAIProposal>()
        return try await withCheckedThrowingContinuation { continuation in
            let providerTask = Task.detached {
                do {
                    let proposal = try await provider.propose(context: context)
                    guard !Task.isCancelled else {
                        return
                    }
                    await gate.resume(.success(proposal), continuation: continuation)
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    await gate.resume(.failure(error), continuation: continuation)
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                providerTask.cancel()
                await gate.resume(
                    .failure(
                        SettingsAIProviderError.failed(
                            code: "providerTimedOut",
                            message: "Settings AI provider timed out after \(Int(timeout.rounded())) seconds."
                        )
                    ),
                    continuation: continuation
                )
            }
        }
    }

    private func recognizeOCRWithTimeout(
        imageURL: URL,
        displaySize: CGSize,
        timeout: TimeInterval
    ) async throws -> [SettingsAIOCRLine] {
        let timeout = max(1, timeout)
        let gate = SettingsAIProviderTimeoutGate<[SettingsAIOCRLine]>()
        return try await withCheckedThrowingContinuation { continuation in
            let ocrTask = Task.detached {
                do {
                    let lines = try await SettingsAIOCRRecognizer().recognize(imageURL: imageURL, displaySize: displaySize)
                    guard !Task.isCancelled else {
                        return
                    }
                    await gate.resume(.success(lines), continuation: continuation)
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    await gate.resume(.failure(error), continuation: continuation)
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                ocrTask.cancel()
                do {
                    let fallbackLines = try SettingsAIOCRRecognizer().recognizeWithVN(
                        imageURL: imageURL,
                        displaySize: displaySize
                    )
                    await gate.resume(.success(fallbackLines), continuation: continuation)
                } catch {
                    await gate.resume(
                        .failure(
                            RunnerError.hostCommandFailed(
                                "Settings AI OCR timed out after \(Int(timeout.rounded())) seconds, and fallback OCR failed: \(error.localizedDescription)"
                            )
                        ),
                        continuation: continuation
                    )
                }
            }
        }
    }

    private func optionalAXSnapshotWithTimeout(timeout: TimeInterval) async -> [String: JSONValue]? {
        let timeout = max(1, timeout)
        let gate = SettingsAIOptionalTimeoutGate<[String: JSONValue]?>()
        return await withCheckedContinuation { continuation in
            let axTask = Task.detached { [dependencies] in
                let snapshot = await dependencies.optionalAXSnapshot(timeout)
                await gate.resume(snapshot, continuation: continuation)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                axTask.cancel()
                await gate.resume(nil, continuation: continuation)
            }
        }
    }

    private func compactAXSnapshot(_ snapshot: [String: JSONValue]) -> [String: JSONValue] {
        let maxElements = 80
        var compact = snapshot
        if let elements = snapshot["elements"]?.arrayValue, elements.count > maxElements {
            compact["elements"] = .array(Array(elements.prefix(maxElements)))
            compact["elementCountOriginal"] = .integer(Int64(elements.count))
            compact["elementsTruncated"] = .bool(true)
        }
        return compact
    }
}

private struct SettingsAIObservationResult {
    let observation: SettingsAIObservation
    let timing: [String: Any]
}

private func elapsedSeconds(since start: Date) -> Double {
    Date().timeIntervalSince(start)
}

private actor SettingsAIProviderTimeoutGate<Value: Sendable> {
    private var didResume = false

    func resume(
        _ result: Result<Value, Error>,
        continuation: CheckedContinuation<Value, Error>
    ) {
        guard !didResume else {
            return
        }
        didResume = true
        continuation.resume(with: result)
    }
}

private actor SettingsAIOptionalTimeoutGate<Value: Sendable> {
    private var didResume = false

    func resume(
        _ value: Value,
        continuation: CheckedContinuation<Value, Never>
    ) {
        guard !didResume else {
            return
        }
        didResume = true
        continuation.resume(returning: value)
    }
}

struct SettingsAIOCRRecognitionOptions: Equatable, Sendable {
    let customWords: [String]
    let usesLanguageCorrection: Bool
}

struct SettingsAIOCRRecognizer: Sendable {
    /// Recovery Terminal's default 120x30 window at the fixed 1280x800 Lab
    /// display size. Full-frame Vision OCR intermittently omits its small
    /// marker and prompt lines even when both are visibly present. Keep the
    /// higher-resolution fallback confined to this known, non-secret surface.
    static let recoveryTerminalProofCrop = CGRect(x: 39, y: 50, width: 879, height: 500)

    func recognize(imageURL: URL, displaySize: CGSize) async throws -> [SettingsAIOCRLine] {
        try recognizeWithVN(imageURL: imageURL, displaySize: displaySize)
    }

    /// Recovery startup and firmware screens use sparse, low-contrast text
    /// that the fast OCR mode can miss entirely. Keep this slower mode scoped
    /// to Recovery rather than changing Settings AI's normal interaction loop.
    func recognizeRecovery(
        imageURL: URL,
        displaySize: CGSize,
        customWord: String? = nil
    ) async throws -> [SettingsAIOCRLine] {
        if let customWord {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw RunnerError.hostCommandFailed("Could not load screenshot for fallback OCR.")
            }
            return try recognizeRecovery(
                image: image,
                displaySize: displaySize,
                customWord: customWord
            )
        }
        let options = Self.recoveryRecognitionOptions(customWord: customWord)
        return try recognizeWithVN(
            imageURL: imageURL,
            displaySize: displaySize,
            recognitionLevel: .accurate,
            customWords: options.customWords,
            usesLanguageCorrection: options.usesLanguageCorrection
        )
    }

    func recognizeRecovery(
        image: CGImage,
        displaySize: CGSize,
        customWord: String? = nil
    ) throws -> [SettingsAIOCRLine] {
        let options = Self.recoveryRecognitionOptions(customWord: customWord)
        let fullFrameLines = try recognizeWithVN(
            image: image,
            displaySize: displaySize,
            recognitionLevel: .accurate,
            customWords: options.customWords,
            usesLanguageCorrection: options.usesLanguageCorrection
        )
        guard let customWord else { return fullFrameLines }

        let fullFrameObservation = RecoveryUIObservation(lines: fullFrameLines)
        if fullFrameObservation.isLikelyTerminalWindow,
           fullFrameObservation.containsExactMarkerFollowedByShellPrompt(customWord)
        {
            return fullFrameLines
        }

        guard let terminalLines = try? recognizeRecoveryTerminalProof(
            image: image,
            displaySize: displaySize,
            customWord: customWord
        ) else {
            return fullFrameLines
        }
        return (fullFrameLines + terminalLines).sorted(by: Self.readingOrder)
    }

    static func recoveryRecognitionOptions(customWord: String?) -> SettingsAIOCRRecognitionOptions {
        .init(
            customWords: customWord.map { [$0] } ?? [],
            usesLanguageCorrection: customWord == nil
        )
    }

    static func recoveryTerminalProofRecognitionOptions(
        customWord: String
    ) -> SettingsAIOCRRecognitionOptions {
        let markerWords = customWord
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return .init(
            customWords: Array(Set([customWord, "POMME", "-bash-3.2#"] + markerWords)).sorted(),
            usesLanguageCorrection: false
        )
    }

    private func recognizeRecoveryTerminalProof(
        image: CGImage,
        displaySize: CGSize,
        customWord: String
    ) throws -> [SettingsAIOCRLine] {
        guard image.width == Int(VirtualizationPrivateHeadlessBackend.displayWidth),
              image.height == Int(VirtualizationPrivateHeadlessBackend.displayHeight),
              displaySize == CGSize(
                width: VirtualizationPrivateHeadlessBackend.displayWidth,
                height: VirtualizationPrivateHeadlessBackend.displayHeight
              ),
              let crop = image.cropping(to: Self.recoveryTerminalProofCrop)
        else { return [] }

        let scale = 2
        let scaledWidth = Int(Self.recoveryTerminalProofCrop.width) * scale
        let scaledHeight = Int(Self.recoveryTerminalProofCrop.height) * scale
        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RunnerError.hostCommandFailed("Could not create Recovery Terminal OCR surface.")
        }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        guard let scaledCrop = context.makeImage() else {
            throw RunnerError.hostCommandFailed("Could not render Recovery Terminal OCR surface.")
        }

        let options = Self.recoveryTerminalProofRecognitionOptions(customWord: customWord)
        return try recognizeWithVN(
            image: scaledCrop,
            displaySize: Self.recoveryTerminalProofCrop.size,
            recognitionLevel: .accurate,
            customWords: options.customWords,
            usesLanguageCorrection: options.usesLanguageCorrection
        ).map { line in
            SettingsAIOCRLine(
                text: line.text,
                confidence: line.confidence,
                rect: line.rect.offsetBy(
                    dx: Self.recoveryTerminalProofCrop.minX,
                    dy: Self.recoveryTerminalProofCrop.minY
                )
            )
        }
    }

    private static func readingOrder(
        _ lhs: SettingsAIOCRLine,
        _ rhs: SettingsAIOCRLine
    ) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 8 {
            return lhs.rect.minY < rhs.rect.minY
        }
        return lhs.rect.minX < rhs.rect.minX
    }

    func recognizeWithVN(
        imageURL: URL,
        displaySize: CGSize,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast,
        customWords: [String] = [],
        usesLanguageCorrection: Bool = true
    ) throws -> [SettingsAIOCRLine] {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RunnerError.hostCommandFailed("Could not load screenshot for fallback OCR.")
        }

        return try recognizeWithVN(
            image: image,
            displaySize: displaySize,
            recognitionLevel: recognitionLevel,
            customWords: customWords,
            usesLanguageCorrection: usesLanguageCorrection
        )
    }

    private func recognizeWithVN(
        image: CGImage,
        displaySize: CGSize,
        recognitionLevel: VNRequestTextRecognitionLevel,
        customWords: [String],
        usesLanguageCorrection: Bool
    ) throws -> [SettingsAIOCRLine] {
        var requestError: Error?
        var recognizedLines: [SettingsAIOCRLine] = []
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                requestError = error
                return
            }
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            recognizedLines = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let box = observation.boundingBox
                let rect = CGRect(
                    x: box.minX * displaySize.width,
                    y: (1 - box.maxY) * displaySize.height,
                    width: box.width * displaySize.width,
                    height: box.height * displaySize.height
                )
                return SettingsAIOCRLine(
                    text: candidate.string,
                    confidence: Double(candidate.confidence),
                    rect: rect
                )
            }
        }
        request.recognitionLevel = recognitionLevel
        request.customWords = customWords
        request.usesLanguageCorrection = usesLanguageCorrection

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        if let requestError {
            throw requestError
        }
        return recognizedLines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: Self.readingOrder)
    }
}

struct AppleFoundationModelsSettingsPlanner: SettingsAIModelProvider {
    let name: SettingsAIProviderName = .appleLocal

    func preflight() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw SettingsAIProviderError.unavailable(
                code: "foundationModelsUnavailable",
                message: "FoundationModels requires macOS 26.0 or newer."
            )
        }
        try AppleFoundationModelsSettingsPlanner26().preflight()
        #else
        throw SettingsAIProviderError.unavailable(
            code: "foundationModelsUnavailable",
            message: "FoundationModels is not available in this SDK."
        )
        #endif
    }

    func propose(context: SettingsAIScreenContext) async throws -> SettingsAIProposal {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw SettingsAIProviderError.unavailable(
                code: "foundationModelsUnavailable",
                message: "FoundationModels requires macOS 26.0 or newer."
            )
        }
        return try await AppleFoundationModelsSettingsPlanner26().propose(context: context)
        #else
        throw SettingsAIProviderError.unavailable(
            code: "foundationModelsUnavailable",
            message: "FoundationModels is not available in this SDK."
        )
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct AppleSettingsAIModelResponse {
    @Guide(description: "One of click, key, type, wait, or done.")
    var action: String

    @Guide(description: "Confidence from 0.0 to 1.0 that this is the safe next action.")
    var confidence: Double

    @Guide(description: "Required for click actions. Host-display x coordinate in points from the top-left origin.")
    var x: Double?

    @Guide(description: "Required for click actions. Host-display y coordinate in points from the top-left origin.")
    var y: Double?

    @Guide(description: "Preferred for click actions when available targets are listed. Example: toggle_1.")
    var targetID: String?

    @Guide(description: "Required for key actions. Examples: return, tab, escape, up, down, left, right, cmd-a.")
    var key: String?

    @Guide(description: "Required for type actions.")
    var text: String?

    @Guide(description: "For type actions, whether to replace focused text before typing.")
    var replace: Bool?

    @Guide(description: "Required for wait actions. Seconds to wait, no more than 30.")
    var seconds: Double?

    @Guide(description: "Short reason for the proposed action.")
    var rationale: String

    var proposal: SettingsAIProposal {
        let object: [String: Any] = [
            "action": action,
            "confidence": confidence,
            "x": x as Any,
            "y": y as Any,
            "targetID": targetID as Any,
            "key": key as Any,
            "text": text as Any,
            "replace": replace as Any,
            "seconds": seconds as Any,
            "rationale": rationale
        ]
        return (try? SettingsAIProposal.decode(from: object)) ?? SettingsAIProposal(
            action: SettingsAIAction(kind: .done, x: nil, y: nil, targetID: nil, key: nil, text: nil, replace: false, seconds: nil),
            confidence: 0,
            rationale: "Could not decode model response."
        )
    }
}

@available(macOS 26.0, *)
private struct AppleFoundationModelsSettingsPlanner26: Sendable {
    func preflight() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw SettingsAIProviderError.unavailable(
                code: unavailableCode(for: reason),
                message: unavailableMessage(for: reason)
            )
        }
    }

    func propose(context: SettingsAIScreenContext) async throws -> SettingsAIProposal {
        try preflight()
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are a cautious planner for macOS System Settings inside a virtual machine.
            Choose exactly one safe next UI action for the user's Settings goal.
            Use the available targets, OCR, and optional accessibility summary as the only screen state.
            Prefer returning targetID for click actions when an available target matches the goal.
            Use click coordinates in the supplied 1280x800 host-display coordinate system, origin at top-left.
            Prefer wait when the screen appears to be changing. Use done only when the goal is visibly complete.
            Avoid destructive or privacy-sensitive changes unless the goal explicitly asks for them.
            Return only a compact JSON object. Do not include markdown.
            """
        )
        do {
            return try await proposeViaStreamedJSON(session: session, context: context)
        } catch {
            return try await proposeViaSchema(session: session, context: context)
        }
    }

    private func proposeViaStreamedJSON(
        session: LanguageModelSession,
        context: SettingsAIScreenContext
    ) async throws -> SettingsAIProposal {
        let prompt = """
        \(context.prompt)

        JSON shape:
        {"action":"click|key|type|wait|done","targetID":"optional detected target id","x":0,"y":0,"key":"optional","text":"optional","replace":false,"seconds":1,"confidence":0.0,"rationale":"short reason"}
        For a detected toggle target, prefer {"action":"click","targetID":"toggle_1","confidence":0.9,"rationale":"..."}.
        """
        let stream = session.streamResponse(
            to: prompt,
            options: GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 300)
        )
        var content = ""
        for try await snapshot in stream {
            content = snapshot.content
        }
        return try decodeTextJSONProposal(content)
    }

    private func decodeTextJSONProposal(_ content: String) throws -> SettingsAIProposal {
        let jsonText = try extractJSONObjectText(from: content)
        guard let data = jsonText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SettingsAIProviderError.failed(
                code: "provider_invalid_response",
                message: "FoundationModels returned non-JSON Settings AI text."
            )
        }
        return try SettingsAIProposal.decode(from: object)
    }

    private func extractJSONObjectText(from content: String) throws -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                text = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else {
            throw SettingsAIProviderError.failed(
                code: "provider_invalid_response",
                message: "FoundationModels did not return a JSON object."
            )
        }
        return String(text[start...end])
    }

    private func proposeViaSchema(
        session: LanguageModelSession,
        context: SettingsAIScreenContext
    ) async throws -> SettingsAIProposal {
        do {
            let response = try await session.respond(
                to: context.prompt,
                generating: AppleSettingsAIModelResponse.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 500)
            )
            return response.content.proposal
        } catch {
            throw SettingsAIProviderError.failed(code: "provider_failed", message: error.localizedDescription)
        }
    }

    private func unavailableCode(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "deviceNotEligible"
        case .appleIntelligenceNotEnabled:
            return "appleIntelligenceNotEnabled"
        case .modelNotReady:
            return "modelNotReady"
        @unknown default:
            return "modelUnavailable"
        }
    }

    private func unavailableMessage(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac is not eligible for the local FoundationModels language model."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled for the local FoundationModels language model."
        case .modelNotReady:
            return "The local FoundationModels language model is not ready yet."
        @unknown default:
            return "The local FoundationModels language model is unavailable."
        }
    }
}
#endif
