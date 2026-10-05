import Foundation
import CoreGraphics
import ImageIO
import Vision

private func settingsAIFormattedConfidence(_ confidence: Double) -> String {
    confidence.formatted(
        .number
            .precision(.fractionLength(2))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))
    )
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

struct SettingsAIOCRRecognitionOptions: Equatable, Sendable {
    let customWords: [String]
    let usesLanguageCorrection: Bool
}

enum SettingsAIOCRRecognitionLevel: String, Sendable {
    case fast
    case accurate
}

struct SettingsAIOCRRecognitionRequest: Sendable {
    let imageSize: CGSize
    let displaySize: CGSize
    let recognitionLevel: SettingsAIOCRRecognitionLevel
    let customWords: [String]
    let usesLanguageCorrection: Bool
}

struct SettingsAIOCRRecognizer: Sendable {
    /// Recovery Terminal's default 120x30 window at the fixed 1280x800 Lab
    /// display size. Full-frame Vision OCR intermittently omits its small
    /// marker and prompt lines even when both are visibly present. Keep the
    /// higher-resolution fallback confined to this known, non-secret surface.
    static let recoveryTerminalProofCrop = CGRect(x: 39, y: 50, width: 879, height: 500)

    /// A test-only executor can observe the recognition requests without
    /// constructing a VM or depending on Vision's model output. Production
    /// instances leave this nil and execute the real Vision request below.
    typealias RecognitionExecutor = @Sendable (
        SettingsAIOCRRecognitionRequest
    ) throws -> [SettingsAIOCRLine]

    let onRecognition: (@Sendable (TimeInterval) -> Void)?
    private let recognitionExecutor: RecognitionExecutor?

    init(
        onRecognition: (@Sendable (TimeInterval) -> Void)? = nil,
        recognitionExecutor: RecognitionExecutor? = nil
    ) {
        self.onRecognition = onRecognition
        self.recognitionExecutor = recognitionExecutor
    }

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

    /// Explicit Terminal-proof spelling for callers that have a marker. The
    /// shared Recovery recognizer performs accurate full-frame OCR first so a
    /// Terminal-looking crop cannot hide `Recovery Assistant`, `Share Disk`,
    /// or `Startup Security Utility` elsewhere on the display. If the full
    /// frame is incomplete, it supplements that evidence with the validated,
    /// mapped Terminal crop before the caller evaluates the closed proof.
    func recognizeRecoveryTerminalMarker(
        image: CGImage,
        displaySize: CGSize,
        marker: String
    ) throws -> [SettingsAIOCRLine] {
        return try recognizeRecovery(
            image: image,
            displaySize: displaySize,
            customWord: marker
        )
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
        if let recognitionExecutor {
            let request = SettingsAIOCRRecognitionRequest(
                imageSize: CGSize(width: image.width, height: image.height),
                displaySize: displaySize,
                recognitionLevel: recognitionLevel == .accurate ? .accurate : .fast,
                customWords: customWords,
                usesLanguageCorrection: usesLanguageCorrection
            )
            return try recognitionExecutor(request)
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted(by: Self.readingOrder)
        }

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

        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds &- startedAt
            onRecognition?(Double(elapsedNanoseconds) / 1_000_000_000)
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        if let requestError {
            throw requestError
        }
        return recognizedLines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: Self.readingOrder)
    }
}
