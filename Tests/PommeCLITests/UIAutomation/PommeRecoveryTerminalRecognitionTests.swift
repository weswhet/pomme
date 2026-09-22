import CoreGraphics
import Foundation
import Testing

@Suite("Pomme Recovery Terminal OCR")
struct PommeRecoveryTerminalRecognitionTests {
    @Test("capability command echo is a whitespace-tolerant diagnostic, never proof")
    func capabilityEchoDoesNotAuthorize() {
        let observation = diagnosticObservation([
            "-bash-3.2# p = /sbin ; u = /usr/bin ; test -x $p /mount_virtiofs &&",
            "case $( $u/printf abc | $p/sha256 -q ) in ba7816bf8f01cfea*)printf 'POMME ACDEHJKMNP OK\\n';;esac",
        ])
        let evidence = observation.terminalMarkerEvidenceDiagnostic("POMME ACDEHJKMNP OK")
        #expect(evidence.commandEcho)
        #expect(evidence.nearMarker == false)
        #expect(observation.terminalMarkerProofDiagnostic("POMME ACDEHJKMNP OK").isVerified == false)
    }

    @Test("only standalone nonexact marker-shaped output sets nearMarker")
    func nearMarkerIsDiagnosticOnly() {
        let expected = "POMME ACDEHJKMNP OK"
        let wrong = diagnosticObservation(["POMME ACDEHJKMNQ OK"])
        #expect(wrong.terminalMarkerEvidenceDiagnostic(expected).nearMarker)
        #expect(wrong.terminalMarkerProofDiagnostic(expected).exactMarker == false)
        #expect(wrong.terminalMarkerProofDiagnostic(expected).isVerified == false)
        for text in [expected, "prefix POMME ACDEHJKMNQ OK", "POMME ACDEHJKMNQ OK suffix",
                     "printf 'POMME ACDEHJKMNQ OK'", "-bash-3.2# POMME ACDEHJKMNQ OK"] {
            #expect(diagnosticObservation([text]).terminalMarkerEvidenceDiagnostic(expected).nearMarker == false)
        }
        #expect(diagnosticObservation([expected]).terminalMarkerProofDiagnostic(expected).isVerified)
    }

    @Test("rendered marker diagnostics contain only fixed labels and closed values")
    func markerDiagnosticRenderingIsClosed() {
        let expected = "POMME ACDEHJKMNP OK"
        let observation = diagnosticObservation([
            "p=/sbin;u=/usr/bin;test -x $p/mount_virtiofs&&PRIVATE_SENTINEL",
            "POMME ACDEHJKMNQ OK",
        ])
        let line = observation.terminalMarkerEvidenceDiagnostic(expected)
            .debugLine(frameChangedSincePreviousAttempt: .unknown)
        #expect(line == "[DEBUG-marker-20260922] commandEcho=true, nearMarker=true, frameChangedSincePreviousAttempt=unknown")
        for forbidden in [expected, "ACDEHJKMNQ", "PRIVATE_SENTINEL", "/sbin", "/usr/bin", "printf"] {
            #expect(line.contains(forbidden) == false)
        }
    }

    private func diagnosticObservation(_ output: [String]) -> RecoveryUIObservation {
        var text = ["Terminal", "-bash-3.2#"]
        text += output
        text.append("-bash-3.2#")
        return .init(lines: text.enumerated().map { index, value in
            .init(text: value, confidence: 1, rect: .init(x: 24, y: 18 + index * 25, width: 400, height: 18))
        })
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
