import CoreGraphics
import Foundation
import Testing

@Suite("Pomme Recovery framebuffer observation readiness")
struct PommeRecoveryVirtualizationKeyboardPortTests {
    @Test("frame stability digest includes pixel bytes, not just geometry")
    func frameDigestIncludesPixels() throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 8, height: 8))
        let first = try PommeRecoveryFrameCapture(image: #require(context.makeImage()))
        let same = try PommeRecoveryFrameCapture(image: #require(context.makeImage()))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 8, height: 8))
        let changed = try PommeRecoveryFrameCapture(image: #require(context.makeImage()))

        #expect(first.digest == same.digest)
        #expect(first.digest != changed.digest)
    }

    @Test("selected picker stays anchored when OCR omits bottom power actions")
    func selectedPickerContinueAnchor() {
        // Reviewed, non-secret label geometry; no Recovery screenshot is stored.
        let captions = [
            SettingsAIOCRLine(text: "Macintosh HD", confidence: 1, rect: .init(x: 486, y: 417, width: 80, height: 14)),
            SettingsAIOCRLine(text: "Options", confidence: 1, rect: .init(x: 730, y: 417, width: 44, height: 14))
        ]
        let action = SettingsAIOCRLine(
            text: "Continue", confidence: 1, rect: .init(x: 724, y: 474, width: 56, height: 14)
        )

        #expect(RecoveryUIObservation(lines: captions + [action]).isAnchoredStartupPicker)
        let diskAction = SettingsAIOCRLine(
            text: "Continue", confidence: 1, rect: .init(x: 498, y: 474, width: 56, height: 14)
        )
        #expect(RecoveryUIObservation(lines: captions + [diskAction]).isAnchoredStartupPicker)
        #expect(!RecoveryUIObservation(lines: captions).isAnchoredStartupPicker)
        #expect(!RecoveryUIObservation(lines: [captions[1], action]).isAnchoredStartupPicker)
        #expect(!RecoveryUIObservation(lines: [captions[0], action]).isAnchoredStartupPicker)
        for rect in [
            CGRect(x: 1100, y: 474, width: 56, height: 14),
            CGRect(x: 724, y: 100, width: 56, height: 14),
            CGRect(x: 724, y: 700, width: 56, height: 14)
        ] {
            let unrelated = SettingsAIOCRLine(text: "Continue", confidence: 1, rect: rect)
            #expect(!RecoveryUIObservation(lines: captions + [unrelated]).isAnchoredStartupPicker)
        }
    }

    @Test("cached classification still requires two fresh matching captures")
    func cacheDoesNotReplaceFreshObservations() async throws {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript(Array(repeating: .success(.init(digest: "picker")), count: 4))
        let classifications = RecoveryClassificationCounter()
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in classifications.increment(); return .startupOptions },
            sleep: { clock.advance(nanoseconds: $0) },
            clock: { clock.now }
        )

        _ = try await readiness.waitForExpected(.startupOptions, context: .unproven, timeout: 1)
        _ = try await readiness.waitForExpected(.startupOptions, context: .unproven, timeout: 1)

        #expect(captures.remaining == 0)
        #expect(classifications.value == 1)
    }

    @Test("a cached mismatching frame remains available to timeout diagnostics")
    func cachedMismatchRetainsLastObservedFrame() async throws {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript(Array(repeating: .success(.init(digest: "picker")), count: 4))
        let classifications = RecoveryClassificationCounter()
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in
                classifications.increment()
                return .startupOptions
            },
            sleep: { nanoseconds in
                clock.advance(nanoseconds: nanoseconds)
                clock.advance(nanoseconds: 1)
            },
            clock: { clock.now },
            pollNanoseconds: 500_000_000
        )

        _ = try await readiness.waitForExpectedStablePair(
            .startupOptions,
            context: .unproven,
            timeout: 1
        )

        await #expect(throws: PommeRecoveryVirtualizationPortError.observationTimedOut(.languageEnglish)) {
            try await readiness.waitForExpectedStablePair(
                .languageEnglish,
                context: .unproven,
                timeout: 0.6
            )
        }
        #expect(classifications.value == 1)
        #expect(await readiness.lastObservedFrameDiagnostic() == .some(.startupOptions))
    }

    @Test("a new checkpoint can classify immediately after a recent checkpoint")
    func checkpointResetsClassificationCooldown() async throws {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript([
            .success(.init(digest: "checkpoint-a")),
            .success(.init(digest: "checkpoint-a")),
            .success(.init(digest: "checkpoint-b")),
            .success(.init(digest: "checkpoint-b")),
        ])
        let classifications = RecoveryClassificationCounter()
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { capture, _ in
                classifications.increment()
                switch capture.digest {
                case "checkpoint-a": return .startupOptions
                case "checkpoint-b": return .languageEnglish
                default: return .unknown
                }
            },
            sleep: { nanoseconds in
                clock.advance(nanoseconds: nanoseconds)
            },
            clock: { clock.now },
            pollNanoseconds: 100_000_000
        )

        let start = clock.now
        let first = try await readiness.waitForExpectedStablePair(
            .startupOptions,
            context: .unproven,
            timeout: 0.3
        )
        let second = try await readiness.waitForExpectedStablePair(
            .languageEnglish,
            context: .unproven,
            timeout: 0.3
        )
        #expect(first == [.startupOptions, .startupOptions])
        #expect(second == [.languageEnglish, .languageEnglish])
        #expect(classifications.value == 2)
        #expect(captures.remaining == 0)
        #expect(clock.now.timeIntervalSince(start) < 2)
    }

    @Test("a mismatching checkpoint throttles OCR retries within its deadline")
    func mismatchingFramesThrottleClassificationRetries() async {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript([
            .success(.init(digest: "wrong-one")),
            .success(.init(digest: "wrong-one")),
            .success(.init(digest: "wrong-two")),
            .success(.init(digest: "wrong-two")),
            .success(.init(digest: "wrong-three")),
            .success(.init(digest: "wrong-three")),
        ])
        let classifications = RecoveryClassificationCounter()
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in
                classifications.increment()
                return .languageEnglish
            },
            sleep: { nanoseconds in
                clock.advance(nanoseconds: nanoseconds)
            },
            clock: { clock.now },
            pollNanoseconds: 200_000_000
        )

        // Stable pairs complete at 0.2 s, 0.6 s, and 1.0 s; the 0.5 s
        // classification cool-down skips the middle one.
        await #expect(throws: PommeRecoveryVirtualizationPortError.observationTimedOut(.startupOptions)) {
            try await readiness.waitForExpectedStablePair(
                .startupOptions,
                context: .unproven,
                timeout: 1.2
            )
        }
        #expect(classifications.value == 2)
        #expect(await readiness.lastObservedFrameDiagnostic() == .some(.languageEnglish))
    }

    @Test("waits through a blank transition and OCRs an identical stable frame once")
    func waitsForStableCheckpoint() async throws {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript([
            .failure(VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The framebuffer was blank.",
                isBlankFrame: true
            )),
            .success(.init(digest: "language")),
            .success(.init(digest: "language")),
            .success(.init(digest: "language"))
        ])
        let classifications = RecoveryClassificationCounter()
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in
                classifications.increment()
                return .languageEnglish
            },
            sleep: { nanoseconds in
                clock.advance(nanoseconds: nanoseconds)
            },
            clock: { clock.now },
            pollNanoseconds: 500_000_000
        )

        let observed = try await readiness.waitForExpected(
            .languageEnglish,
            context: .optionsActivated,
            timeout: 1.5
        )
        #expect(observed == .languageEnglish)
        #expect(classifications.value == 1)
        #expect(captures.remaining == 1)
    }

    @Test("an explicit alternate checkpoint still requires a stable pair")
    func acceptsStableAlternateCheckpoint() async throws {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript([
            .success(.init(digest: "utilities")),
            .success(.init(digest: "utilities")),
        ])
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in .recoveryUtilities },
            sleep: { clock.advance(nanoseconds: $0) },
            clock: { clock.now }
        )

        let observed = try await readiness.waitForExpectedStablePair(
            anyOf: [.languageEnglish, .recoveryUtilities],
            context: .optionsActivated,
            timeout: 1
        )
        #expect(observed == [.recoveryUtilities, .recoveryUtilities])
    }

    @Test("fails malformed framebuffer errors immediately instead of retrying")
    func rejectsMalformedFrame() async {
        let captures = RecoveryCaptureScript([
            .failure(VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The framebuffer dimensions do not match the configured display."
            ))
        ])
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in .startupOptions },
            sleep: { _ in },
            clock: { Date() },
            pollNanoseconds: 500_000_000
        )

        await #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try await readiness.waitForExpected(
                .startupOptions,
                context: .unproven,
                timeout: 1
            )
        }
        #expect(captures.remaining == 0)
    }

    @Test("Recovery retries only explicitly blank frame-invalid captures")
    func classifiesRecoveryCaptureFailuresStrictly() {
        let blank = VirtualizationPrivateHeadlessError(
            .frameInvalid,
            detail: "The framebuffer was blank.",
            isBlankFrame: true
        )
        let malformed = VirtualizationPrivateHeadlessError(
            .frameInvalid,
            detail: "The framebuffer dimensions do not match the configured display."
        )
        let abiMismatch = VirtualizationPrivateHeadlessError(
            .privateABIMismatch,
            detail: "A required Virtualization private method is missing."
        )

        #expect(VirtualizationPrivateHeadlessBackend.isTransientRecoveryCaptureFailure(blank))
        #expect(!VirtualizationPrivateHeadlessBackend.isTransientRecoveryCaptureFailure(malformed))
        #expect(!VirtualizationPrivateHeadlessBackend.isTransientRecoveryCaptureFailure(abiMismatch))
    }

    @Test("times out when stable frames remain unknown")
    func unknownFrameTimesOut() async {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript([
            .success(.init(digest: "unknown")),
            .success(.init(digest: "unknown")),
            .success(.init(digest: "unknown")),
            .success(.init(digest: "unknown"))
        ])
        let classifications = RecoveryClassificationCounter()
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in
                classifications.increment()
                return .unknown
            },
            sleep: { nanoseconds in
                clock.advance(nanoseconds: nanoseconds)
            },
            clock: { clock.now },
            pollNanoseconds: 500_000_000
        )

        await #expect(throws: PommeRecoveryVirtualizationPortError.observationTimedOut(.startupOptions)) {
            try await readiness.waitForExpected(
                .startupOptions,
                context: .unproven,
                timeout: 1
            )
        }
        #expect(classifications.value == 1)
    }

    @Test("a timeout before stable classification reports no observed closed frame")
    func unstableFrameTimeoutHasNoObservedFrame() async {
        let clock = RecoveryTestClock()
        let captures = RecoveryCaptureScript([
            .failure(VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The framebuffer was blank.",
                isBlankFrame: true
            )),
        ])
        let readiness = PommeRecoveryObservationReadiness(
            capture: { _ in try captures.next() },
            classify: { _, _ in .startupOptions },
            sleep: { clock.advance(nanoseconds: $0) },
            clock: { clock.now },
            pollNanoseconds: 500_000_000
        )

        await #expect(throws: PommeRecoveryVirtualizationPortError.observationTimedOut(.startupOptions)) {
            try await readiness.waitForExpectedStablePair(
                .startupOptions,
                context: .unproven,
                timeout: 0.2
            )
        }
        #expect(await readiness.lastObservedFrameDiagnostic() == nil)
    }
}

private final class RecoveryCaptureScript: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<PommeRecoveryFrameCapture, Error>]

    init(_ values: [Result<PommeRecoveryFrameCapture, Error>]) {
        self.values = values
    }

    var remaining: Int {
        lock.withLock { values.count }
    }

    func next() throws -> PommeRecoveryFrameCapture {
        try lock.withLock {
            guard !values.isEmpty else {
                throw PommeRecoveryVirtualizationPortError.observationTimedOut(.unknown)
            }
            return try values.removeFirst().get()
        }
    }
}

private final class RecoveryClassificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class RecoveryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)

    var now: Date { lock.withLock { value } }

    func advance(nanoseconds: UInt64) {
        lock.withLock {
            value = value.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
        }
    }
}
