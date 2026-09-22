import CoreGraphics
import Foundation
import ImageIO
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

    @Test("debug navigation screenshots are private, ordered PNGs and survive capture failure")
    func debugNavigationScreenshots() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "pomme-recovery-screenshot-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? fileManager.removeItem(at: root) }

        let image = try recoveryScreenshotTestImage()
        let captures = RecoveryScreenshotCaptureCounter(image: image)
        let recorder = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "test vm/with unsafe characters",
            capture: { _ in try captures.capture() },
            temporaryDirectory: root,
            clock: { Date(timeIntervalSince1970: 1_790_000_000) },
            log: { _ in }
        )
        try await recorder.captureNavigation(
            from: .recoveryUtilities,
            key: .shiftCommandT,
            expectedDestinations: [.terminal]
        )
        try await recorder.captureTimeout(awaiting: [.languageEnglish])

        let directory = try #require(await recorder.directory())
        let files = await recorder.savedFiles()
        #expect(captures.count == 2)
        #expect(files.count == 2)
        #expect(directory.lastPathComponent.hasPrefix("pomme-recovery-debug-test-vm-with-unsafe-characters-"))
        #expect(files[0].lastPathComponent.contains("0001_"))
        #expect(files[0].lastPathComponent.hasSuffix("_recoveryUtilities_shift-command-t_to_terminal.png"))
        #expect(files[1].lastPathComponent.contains("0002_"))
        #expect(files[1].lastPathComponent.hasSuffix("_timeout-awaiting-languageEnglish.png"))
        #expect(try recoveryPOSIXMode(at: directory, fileManager: fileManager) == 0o700)
        #expect(try recoveryPOSIXMode(at: files[0], fileManager: fileManager) == 0o600)
        #expect(CGImageSourceCreateWithData(try Data(contentsOf: files[0]) as CFData, nil) != nil)

        // Disabling occurs at the Terminal command boundary and cannot create
        // an additional image even if the port stays alive.
        await recorder.disable()
        try await recorder.captureNavigation(
            from: .terminal,
            key: .return,
            expectedDestinations: [.terminal]
        )
        #expect(captures.count == 2)
        #expect((await recorder.savedFiles()).count == 2)
        #expect(fileManager.fileExists(atPath: files[0].path))

        let second = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "test vm/with unsafe characters",
            capture: { _ in try captures.capture() },
            temporaryDirectory: root,
            clock: { Date(timeIntervalSince1970: 1_790_000_000) },
            log: { _ in }
        )
        try await second.captureTimeout(awaiting: [.startupOptions])
        let secondDirectory = await second.directory()
        #expect(directory != secondDirectory)

        let failures = RecoveryScreenshotCaptureFailure()
        let failingRecorder = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "failure",
            capture: { _ in try failures.capture() },
            temporaryDirectory: root,
            log: { _ in }
        )
        // A failed diagnostic capture is one attempt and does not throw, so
        // the caller proceeds to its existing single key delivery.
        try await failingRecorder.captureNavigation(
            from: .startupOptions,
            key: .right,
            expectedDestinations: [.startupIntermediate]
        )
        #expect(failures.count == 1)
        #expect((await failingRecorder.savedFiles()).isEmpty)
        let failingDirectory = try #require(await failingRecorder.directory())
        #expect(fileManager.fileExists(atPath: failingDirectory.path))
    }

    @Test("every Recovery route has one redacted screenshot label per navigation event")
    func screenshotLabelsCoverNavigationRoutes() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "pomme-recovery-screenshot-route-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let image = try recoveryScreenshotTestImage()

        for route in [
            PommeRecoveryNavigationRoute.reviewedMenus,
            .directTerminal,
            .experimentalMenusOptionalLanguage,
        ] {
            let recorder = PommeRecoveryNavigationScreenshotRecorder(
                vmName: "route",
                capture: { _ in image },
                temporaryDirectory: root,
                log: { _ in }
            )
            for event in route.eventTrace {
                try await recorder.captureNavigation(
                    from: event.preEventFrame,
                    input: event.input,
                    expectedDestinations: event.acceptedPostEventFrames
                )
            }
            #expect((await recorder.savedFiles()).count == route.eventTrace.count)
            if route == .experimentalMenusOptionalLanguage {
                let files = await recorder.savedFiles()
                #expect(files[2].lastPathComponent.hasSuffix(
                    "_startupOptionsActivated_return_to_languageEnglish-or-recoveryUtilities.png"
                ))
            }
        }
    }

    @Test("navigation debug capture is after readiness, before one key, and cancellation prevents delivery")
    func navigationDebugCaptureOrdering() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "pomme-recovery-screenshot-order-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let image = try recoveryScreenshotTestImage()

        let ordering = RecoveryNavigationOrdering()
        let recorder = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "ordering",
            capture: { timeout in
                ordering.append("capture")
                ordering.record(timeout: timeout)
                return image
            },
            temporaryDirectory: root,
            log: { _ in }
        )
        try await PommeRecoveryNavigationScreenshotRecorder.captureBeforeNavigationInput(
            recorder: recorder,
            from: .startupOptions,
            key: .right,
            expectedDestinations: [.startupIntermediate],
            awaitInputReadiness: { ordering.append("ready") },
            reproveAfterCapture: { ordering.append("reprove") },
            deliver: { ordering.append("send") }
        )
        #expect(ordering.events == ["ready", "capture", "reprove", "send"])
        #expect(ordering.timeouts == [PommeRecoveryNavigationScreenshotRecorder.captureTimeout])

        let captureFailureOrdering = RecoveryNavigationOrdering()
        let failingRecorder = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "capture-failure",
            capture: { _ in
                captureFailureOrdering.append("capture")
                throw PommeRecoveryVirtualizationPortError.unprovenFrame
            },
            temporaryDirectory: root,
            log: { _ in }
        )
        try await PommeRecoveryNavigationScreenshotRecorder.captureBeforeNavigationInput(
            recorder: failingRecorder,
            from: .startupOptions,
            key: .right,
            expectedDestinations: [.startupIntermediate],
            awaitInputReadiness: { captureFailureOrdering.append("ready") },
            reproveAfterCapture: { captureFailureOrdering.append("reprove") },
            deliver: { captureFailureOrdering.append("send") }
        )
        #expect(captureFailureOrdering.events == ["ready", "capture", "reprove", "send"])

        let disabledOrdering = RecoveryNavigationOrdering()
        let disabledRecorder = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "disabled",
            capture: { _ in
                disabledOrdering.append("capture")
                return image
            },
            temporaryDirectory: root,
            log: { _ in }
        )
        await disabledRecorder.disable()
        try await PommeRecoveryNavigationScreenshotRecorder.captureBeforeNavigationInput(
            recorder: disabledRecorder,
            from: .startupOptions,
            key: .right,
            expectedDestinations: [.startupIntermediate],
            awaitInputReadiness: { disabledOrdering.append("ready") },
            deliver: { disabledOrdering.append("send") }
        )
        #expect(disabledOrdering.events == ["ready", "send"])
        #expect(await disabledRecorder.directory() == nil)

        let cancellationOrdering = RecoveryNavigationOrdering()
        let cancellationRecorder = PommeRecoveryNavigationScreenshotRecorder(
            vmName: "cancellation",
            capture: { _ in
                cancellationOrdering.append("capture")
                withUnsafeCurrentTask { $0?.cancel() }
                return image
            },
            temporaryDirectory: root,
            log: { _ in }
        )
        let cancelledNavigation = Task {
            try await PommeRecoveryNavigationScreenshotRecorder.captureBeforeNavigationInput(
                recorder: cancellationRecorder,
                from: .startupOptions,
                key: .right,
                expectedDestinations: [.startupIntermediate],
                awaitInputReadiness: { cancellationOrdering.append("ready") },
                deliver: { cancellationOrdering.append("send") }
            )
        }
        await #expect(throws: CancellationError.self) {
            try await cancelledNavigation.value
        }
        #expect(cancellationOrdering.events == ["ready", "capture"])
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

private final class RecoveryScreenshotCaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let image: CGImage
    private var value = 0

    init(image: CGImage) { self.image = image }

    var count: Int { lock.withLock { value } }

    func capture() throws -> CGImage {
        lock.withLock { value += 1 }
        return image
    }
}

private final class RecoveryScreenshotCaptureFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func capture() throws -> CGImage {
        lock.withLock { value += 1 }
        throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
}

private final class RecoveryNavigationOrdering: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var captureTimeouts: [TimeInterval] = []

    var events: [String] { lock.withLock { values } }
    var timeouts: [TimeInterval] { lock.withLock { captureTimeouts } }

    func append(_ event: String) {
        lock.withLock { values.append(event) }
    }

    func record(timeout: TimeInterval) {
        lock.withLock { captureTimeouts.append(timeout) }
    }
}

private func recoveryScreenshotTestImage() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(.init(x: 0, y: 0, width: 8, height: 8))
    return try #require(context.makeImage())
}

private func recoveryPOSIXMode(at url: URL, fileManager: FileManager) throws -> Int {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
}
