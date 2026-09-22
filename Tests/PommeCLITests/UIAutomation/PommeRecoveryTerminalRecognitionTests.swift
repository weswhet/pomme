import CoreGraphics
import CoreText
import Foundation
import Testing

@Suite("Pomme Recovery Terminal OCR")
struct PommeRecoveryTerminalRecognitionTests {
    @Test("generated probe output remains recognizable for repeated and alternating nonce nibbles",
          arguments: ["44444444-4444-4444-8444-444444444444", "34343434-3434-4434-8434-343434343434"])
    func generatedProbeHasStrictOCRProof(_ requestID: String) throws {
        let plan = try markerPlan(requestID)
        let probe = try #require(plan.capabilityProbes.first)
        let image = try renderedProbe(probe.command)
        let lines = try SettingsAIOCRRecognizer().recognizeRecoveryTerminalMarker(
            image: image, displaySize: displaySize, marker: probe.marker)
        let proof = RecoveryUIObservation(lines: lines).terminalMarkerProofDiagnostic(probe.marker)
        #expect(proof.terminalWindow)
        #expect(proof.exactMarker)
        #expect(proof.freshPromptAfterMarker)
        #expect(proof.isVerified)
    }

    @Test("word marker proof rejects changed, missing, extra, echoed, and stale output")
    func wordMarkerProofRemainsStrict() throws {
        let plan = try markerPlan("01234567-89ab-cdef-8123-456789abcdef")
        let marker = plan.completionMarker
        var words = marker.split(separator: " ").map(String.init)
        try #require(words.count == 12)
        words[1] = "pig"
        let wrong = words.joined(separator: " ")
        let missing = marker.split(separator: " ").enumerated().filter { $0.offset != 1 }.map { String($0.element) }.joined(separator: " ")
        let extra = marker.replacingOccurrences(of: " OK", with: " ash OK")
        for output in [wrong, missing, extra, "printf '\(marker)\\n\\n'", "-bash-3.2# printf '\(marker)\\n\\n'"] {
            let proof = markerObservation(output: output, promptBelow: true).terminalMarkerProofDiagnostic(marker)
            #expect(proof.exactMarker == false)
            #expect(proof.isVerified == false)
        }
        #expect(markerObservation(output: marker, promptBelow: false).terminalMarkerProofDiagnostic(marker).isVerified == false)
        #expect(markerObservation(output: marker, promptBelow: true).terminalMarkerProofDiagnostic(marker).isVerified)
    }

    @Test("real OCR does not accept a correct command echo as successful marker output")
    func generatedProbeEchoCannotAuthorize() throws {
        let plan = try markerPlan("01234567-89ab-cdef-8123-456789abcdef")
        let probe = try #require(plan.capabilityProbes.first)
        let words = probe.marker.split(separator: " ")
        let wrong = ([String(words[0]), "pig"] + words.dropFirst(2).map(String.init)).joined(separator: " ")
        for typedOnly in [false, true] {
            let image = try renderedProbe(probe.command, outputOverride: wrong + "\n\n", typedOnly: typedOnly)
            let lines = try SettingsAIOCRRecognizer().recognizeRecoveryTerminalMarker(
                image: image, displaySize: displaySize, marker: probe.marker)
            let proof = RecoveryUIObservation(lines: lines).terminalMarkerProofDiagnostic(probe.marker)
            #expect(proof.exactMarker == false)
            #expect(proof.isVerified == false)
        }
    }

    private func markerObservation(output: String, promptBelow: Bool) -> RecoveryUIObservation {
        .init(lines: [
            .init(text: "Terminal", confidence: 1, rect: .init(x: 24, y: 18, width: 100, height: 18)),
            .init(text: output, confidence: 1, rect: .init(x: 24, y: 100, width: 500, height: 18)),
            .init(text: "-bash-3.2#", confidence: 1, rect: .init(x: 24, y: promptBelow ? 150 : 70, width: 100, height: 18)),
        ])
    }

    private func markerPlan(_ requestID: String) throws -> PommeRecoveryVirtioFSTerminalPlan {
        let expiry = Date(timeIntervalSince1970: 10_060)
        let credential = try PommeRecoveryCredential(
            id: #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")),
            secret: Data(repeating: 0x42, count: 32), expiresAt: expiry)
        let request = try PommeRecoverySessionRequest(
            requestID: #require(UUID(uuidString: requestID)),
            vmUUID: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
            operation: .installAgent, issuedAt: expiry.addingTimeInterval(-60), expiresAt: expiry,
            executableSHA256: String(repeating: "a", count: 64), credential: credential)
        return try PommeRecoveryVirtioFSTerminalPlan(request: request)
    }

    /// Synthetic pixels only. Decode the generated literal printf output instead
    /// of independently constructing the expected marker or its prompt spacing.
    private func renderedProbe(_ command: String, outputOverride: String? = nil, typedOnly: Bool = false) throws -> CGImage {
        let start = try #require(command.range(of: "printf '", options: .backwards)).upperBound
        let end = try #require(command[start...].firstIndex(of: "'"))
        let output = outputOverride ?? command[start..<end].replacingOccurrences(of: "\\n", with: "\n")
        let outputRows = output.split(separator: "\n", omittingEmptySubsequences: false)
        try #require(outputRows.last?.isEmpty == true)
        let context = try #require(CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8,
            bytesPerRow: 5120, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        context.fill(CGRect(x: 39, y: 250, width: 879, height: 500))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1),
        ]
        let echo = Array("-bash-3.2# " + command)
        var rows = [("Terminal", 16)]
        for offset in stride(from: 0, to: echo.count, by: 120) {
            rows.append((String(echo[offset..<min(offset + 120, echo.count)]), 100 + (offset / 120) * 14))
        }
        let outputTop = 100 + ((echo.count + 119) / 120) * 14
        if !typedOnly {
            for (index, row) in outputRows.dropLast().enumerated() { rows.append((String(row), outputTop + index * 18)) }
            rows.append(("-bash-3.2#", outputTop + (outputRows.count - 1) * 18))
        }
        for (text, top) in rows {
            context.textPosition = CGPoint(x: 50, y: 800 - top - 12)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return try #require(context.makeImage())
    }

    @Test("an observed leading em dash in the fresh shell prompt preserves strict marker proof")
    func observedLeadingEmDashPrompt() {
        let proof = promptProof(prompt: "—bash-3.2#")
        #expect(proof.terminalWindow)
        #expect(proof.exactMarker)
        #expect(proof.freshPromptAfterMarker)
        #expect(proof.isVerified)
    }

    @Test("em dash support does not permit arbitrary prompt text or weaken marker ordering")
    func emDashPromptRemainsBounded() {
        for prompt in ["—", "——bash-3.2#", "prefix—bash-3.2#", "— bash-3.2#",
                       "—bash—3.2#", "—bash-3.2", "—bash-3.2# printf 'POMME TEST OK'",
                       "echo —bash-3.2#", "–bash-3.2#"] {
            #expect(promptProof(prompt: prompt).isVerified == false)
        }
        #expect(promptProof(prompt: "—bash-3.2#", promptBelow: false).isVerified == false)
        #expect(promptProof(prompt: "—bash-3.2#", markerOutput: "POMME WRONG OK").isVerified == false)
        #expect(promptProof(prompt: "—bash-3.2#", markerOutput: "printf 'POMME TEST OK'").isVerified == false)
        #expect(promptProof(prompt: "-bash-3.2#").isVerified)
        #expect(promptProof(prompt: "-bash-3.2$").isVerified)
    }

    private func promptProof(prompt: String, promptBelow: Bool = true,
                             markerOutput: String = "POMME TEST OK") -> RecoveryTerminalMarkerProofDiagnostic {
        RecoveryUIObservation(lines: [
            .init(text: "Terminal", confidence: 1, rect: .init(x: 24, y: 18, width: 100, height: 18)),
            .init(text: markerOutput, confidence: 1, rect: .init(x: 24, y: 100, width: 200, height: 18)),
            .init(text: prompt, confidence: 1, rect: .init(x: 24, y: promptBelow ? 130 : 70, width: 200, height: 18)),
        ]).terminalMarkerProofDiagnostic("POMME TEST OK")
    }

    private let displaySize = CGSize(
        width: VirtualizationPrivateHeadlessBackend.displayWidth,
        height: VirtualizationPrivateHeadlessBackend.displayHeight
    )
    private let marker = "POMME_READY"

    @Test("full-frame proof avoids the supplemental crop pass")
    func provenFullFrameIsTheOnlyRecognitionRequest() throws {
        let recorder = OCRRequestRecorder()
        let fullFrameLines = terminalLines(
            includeMarkerAndPrompt: true,
            includeTerminalIdentity: true
        )
        let recognizer = SettingsAIOCRRecognizer(recognitionExecutor: { request in
            recorder.record(request)
            return fullFrameLines
        })

        let lines = try recognizer.recognizeRecoveryTerminalMarker(
            image: try recoveryImage(),
            displaySize: displaySize,
            marker: marker
        )

        let requests = recorder.requests
        #expect(requests.count == 1)
        #expect(requests[0].displaySize == displaySize)
        #expect(requests[0].recognitionLevel == .accurate)
        #expect(RecoveryUIObservation(lines: lines).isLikelyTerminalWindow)
        #expect(RecoveryUIObservation(lines: lines).containsExactMarkerFollowedByShellPrompt(marker))
        #expect(lines.allSatisfy { $0.rect.maxX <= displaySize.width })
    }

    @Test("incomplete full frame uses the supplemental crop and combines mapped lines")
    func incompleteFullFrameUsesCropAndCombinesProofLines() throws {
        let recorder = OCRRequestRecorder()
        let cropLines = terminalLines(
            includeMarkerAndPrompt: true,
            includeTerminalIdentity: false
        )
        let fullFrameLines = terminalLines(
            includeMarkerAndPrompt: false,
            includeTerminalIdentity: true
        )
        let recognizer = SettingsAIOCRRecognizer(recognitionExecutor: { request in
            recorder.record(request)
            return request.displaySize == SettingsAIOCRRecognizer.recoveryTerminalProofCrop.size
                ? cropLines
                : fullFrameLines
        })

        let lines = try recognizer.recognizeRecoveryTerminalMarker(
            image: try recoveryImage(),
            displaySize: displaySize,
            marker: marker
        )

        let requests = recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].displaySize == displaySize)
        #expect(requests[1].displaySize == SettingsAIOCRRecognizer.recoveryTerminalProofCrop.size)
        #expect(requests[0].recognitionLevel == .accurate)
        #expect(requests[1].recognitionLevel == .accurate)
        let observation = RecoveryUIObservation(lines: lines)
        #expect(observation.isLikelyTerminalWindow)
        #expect(observation.containsExactMarkerFollowedByShellPrompt(marker))
    }

    @Test("an exclusion outside a complete crop prevents Terminal proof")
    func outsideCropExclusionPreventsTerminalProof() throws {
        let recorder = OCRRequestRecorder()
        let cropLines = terminalLines(includeMarkerAndPrompt: true, includeTerminalIdentity: true)
        let fullFrameLines = [
            SettingsAIOCRLine(
                text: "Recovery Assistant",
                confidence: 1,
                rect: CGRect(x: 950, y: 100, width: 180, height: 20)
            )
        ]
        let recognizer = SettingsAIOCRRecognizer(recognitionExecutor: { request in
            recorder.record(request)
            return request.displaySize == SettingsAIOCRRecognizer.recoveryTerminalProofCrop.size
                ? cropLines
                : fullFrameLines
        })

        let lines = try recognizer.recognizeRecoveryTerminalMarker(
            image: try recoveryImage(),
            displaySize: displaySize,
            marker: marker
        )

        #expect(recorder.requests.count == 2)
        #expect(lines.contains { $0.text == "Recovery Assistant" })
        #expect(!RecoveryUIObservation(lines: lines).isLikelyTerminalWindow)
        #expect(recorder.requests[0].displaySize == displaySize)
        #expect(recorder.requests[1].displaySize == SettingsAIOCRRecognizer.recoveryTerminalProofCrop.size)
    }

    @Test("marker proof diagnostic retains the exact-marker and fresh-prompt gates")
    func markerProofDiagnosticIsClosedAndStrict() {
        let complete = RecoveryUIObservation(lines: terminalLines(
            includeMarkerAndPrompt: true,
            includeTerminalIdentity: true
        )).terminalMarkerProofDiagnostic(marker)
        #expect(complete == .init(
            terminalWindow: true,
            exactMarker: true,
            freshPromptAfterMarker: true
        ))
        #expect(complete.isVerified)

        let stalePrompt = RecoveryUIObservation(lines: [
            SettingsAIOCRLine(
                text: "Terminal", confidence: 1,
                rect: CGRect(x: 24, y: 18, width: 72, height: 18)
            ),
            SettingsAIOCRLine(
                text: "-bash-3.2#", confidence: 1,
                rect: CGRect(x: 24, y: 48, width: 100, height: 18)
            ),
            SettingsAIOCRLine(
                text: marker, confidence: 1,
                rect: CGRect(x: 24, y: 100, width: 120, height: 18)
            ),
        ]).terminalMarkerProofDiagnostic(marker)
        #expect(stalePrompt == .init(
            terminalWindow: true,
            exactMarker: true,
            freshPromptAfterMarker: false
        ))
        #expect(!stalePrompt.isVerified)
    }

    private func terminalLines(
        includeMarkerAndPrompt: Bool,
        includeTerminalIdentity: Bool
    ) -> [SettingsAIOCRLine] {
        var lines: [SettingsAIOCRLine] = []
        if includeTerminalIdentity {
            lines += [
                SettingsAIOCRLine(
                    text: "Terminal",
                    confidence: 1,
                    rect: CGRect(x: 24, y: 18, width: 72, height: 18)
                ),
                SettingsAIOCRLine(
                    text: "-bash-3.2#",
                    confidence: 1,
                    rect: CGRect(x: 24, y: 48, width: 100, height: 18)
                )
            ]
        }
        if includeMarkerAndPrompt {
            lines += [
                SettingsAIOCRLine(
                    text: marker,
                    confidence: 1,
                    rect: CGRect(x: 24, y: 100, width: 120, height: 18)
                ),
                SettingsAIOCRLine(
                    text: "-bash-3.2#",
                    confidence: 1,
                    rect: CGRect(x: 24, y: 130, width: 100, height: 18)
                )
            ]
        }
        return lines
    }

    private func recoveryImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: Int(displaySize.width),
            height: Int(displaySize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw TerminalRecognitionFixtureError.couldNotCreateImage
        }
        return image
    }
}

private enum TerminalRecognitionFixtureError: Error {
    case couldNotCreateImage
}

private final class OCRRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SettingsAIOCRRecognitionRequest] = []

    var requests: [SettingsAIOCRRecognitionRequest] {
        lock.withLock { values }
    }

    func record(_ request: SettingsAIOCRRecognitionRequest) {
        lock.withLock { values.append(request) }
    }
}
