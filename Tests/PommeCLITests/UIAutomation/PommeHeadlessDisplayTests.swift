import Foundation
@preconcurrency import AppKit
import Testing

@Suite("Virtualization private headless backend")
struct VirtualizationPrivateHeadlessBackendTests {
    @Test("Callback gate buffers cancellation before continuation installation")
    func callbackGateCancellationBeforeBegin() async {
        let gate = HeadlessAutomationCallbackGate<Int>()
        gate.finish(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int, Error>) in
                gate.begin(continuation)
            }
        }
    }

    @Test("Callback gate accepts only the first completion")
    func callbackGateCompletesExactlyOnce() async throws {
        let gate = HeadlessAutomationCallbackGate<Int>()
        gate.finish(.success(43))
        gate.finish(.failure(CancellationError()))
        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, Error>) in
            gate.begin(continuation)
        }
        #expect(value == 43)
    }

    @Test("A missing screenshot callback produces the closed timeout")
    func screenshotCallbackTimeout() async {
        await #expect(throws: VirtualizationPrivateHeadlessError.self) {
            let _: Int = try await VirtualizationPrivateHeadlessBackend.awaitCallback(
                timeout: 0.01,
                start: { _ in }
            )
        }
    }

    @Test("Callback waiting propagates cancellation")
    func callbackCancellation() async {
        let task = Task<Int, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VirtualizationPrivateHeadlessBackend.awaitCallback(
                timeout: 1,
                start: { _ in }
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Runtime ABI accepts any host build with the exact private interface")
    func abiMatching() throws {
        let environment = VirtualizationPrivateABIEnvironment(
            architecture: "arm64",
            hostBuild: "99Z999",
            frameworkIdentifier: "com.apple.Virtualization",
            frameworkVersion: "999.1",
            frameworkPath: "/System/Library/Frameworks/Virtualization.framework"
        )
        let encodings = Dictionary(uniqueKeysWithValues:
            VirtualizationPrivateABIPreflight.requiredMethods.map { ($0.identity, $0.encoding) }
        )
        try VirtualizationPrivateABIPreflight.validate(
            environment: environment,
            observedMethods: encodings
        )

        var wrongEncoding = encodings
        wrongEncoding[VirtualizationPrivateABIPreflight.requiredMethods[0].identity] = "v16@0:8"
        do {
            try VirtualizationPrivateABIPreflight.validate(
                environment: environment,
                observedMethods: wrongEncoding
            )
            Issue.record("Expected a private ABI mismatch")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .privateABIMismatch)
            #expect(!error.partialInputPossible)
        }

        let unsupportedArchitecture = VirtualizationPrivateABIEnvironment(
            architecture: "x86_64",
            hostBuild: environment.hostBuild,
            frameworkIdentifier: environment.frameworkIdentifier,
            frameworkVersion: environment.frameworkVersion,
            frameworkPath: environment.frameworkPath
        )
        do {
            try VirtualizationPrivateABIPreflight.validate(
                environment: unsupportedArchitecture,
                observedMethods: encodings
            )
            Issue.record("Expected an unsupported architecture failure")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .unsupportedArchitecture)
        }

        let unexpectedFramework = VirtualizationPrivateABIEnvironment(
            architecture: environment.architecture,
            hostBuild: environment.hostBuild,
            frameworkIdentifier: environment.frameworkIdentifier,
            frameworkVersion: environment.frameworkVersion,
            frameworkPath: "/tmp/Virtualization.framework"
        )
        do {
            try VirtualizationPrivateABIPreflight.validate(
                environment: unexpectedFramework,
                observedMethods: encodings
            )
            Issue.record("Expected a private ABI mismatch")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .privateABIMismatch)
        }
    }

    @Test("The installed runtime is either exactly qualified or rejected")
    func installedRuntimeABI() throws {
        let observed = VirtualizationPrivateABIPreflight.observedMethodEncodings()
        do {
            try VirtualizationPrivateABIPreflight.validateRuntime()
            for method in VirtualizationPrivateABIPreflight.requiredMethods {
                #expect(observed[method.identity] == method.encoding)
            }
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .privateABIMismatch || error.code == .unsupportedArchitecture)
        }
    }

    @Test("Screenshot conversion accepts CGImage and NSImage")
    func screenshotConversion() throws {
        let image = try makeImage(width: 1280, height: 800, red: 24)
        let direct = try VirtualizationPrivateHeadlessBackend.convertScreenshotObject(image)
        #expect(direct.width == 1280)
        let appKit = NSImage(cgImage: image, size: NSSize(width: 1280, height: 800))
        let converted = try VirtualizationPrivateHeadlessBackend.convertScreenshotObject(appKit)
        #expect(converted.height == 800)
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            _ = try VirtualizationPrivateHeadlessBackend.convertScreenshotObject(nil)
        }
    }

    @Test("Private framebuffer layout accepts only engaged IOSurfaces")
    func privateFramebufferLayout() {
        let surface = NSObject()
        withExtendedLifetime(surface) {
            var frameUpdate = [UInt8](
                repeating: 0,
                count: MemoryLayout<UnsafeRawPointer?>.size + MemoryLayout<UInt8>.size
            )
            frameUpdate.withUnsafeMutableBytes { bytes in
                let expectedSurface: UnsafeRawPointer? = UnsafeRawPointer(
                    Unmanaged.passUnretained(surface).toOpaque()
                )
                bytes.storeBytes(
                    of: expectedSurface,
                    as: UnsafeRawPointer?.self
                )
                bytes.storeBytes(
                    of: UInt8(1),
                    toByteOffset: MemoryLayout<UnsafeRawPointer?>.size,
                    as: UInt8.self
                )
                #expect(HeadlessFramebufferFrameLayout.surfacePointer(
                    frameUpdatePointer: bytes.baseAddress
                ) == expectedSurface)
                bytes.storeBytes(
                    of: UInt8(0),
                    toByteOffset: MemoryLayout<UnsafeRawPointer?>.size,
                    as: UInt8.self
                )
                #expect(HeadlessFramebufferFrameLayout.surfacePointer(
                    frameUpdatePointer: bytes.baseAddress
                ) == nil)
            }
        }
    }

    @Test("Frame validation rejects wrong-sized and blank frames")
    func frameValidation() throws {
        let valid = try makeImage(width: 1280, height: 800, red: 32)
        try VirtualizationPrivateHeadlessBackend.validateFrame(valid)

        let wrongSize = try makeImage(width: 640, height: 480, red: 32)
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateHeadlessBackend.validateFrame(wrongSize)
        }
        let blank = try makeImage(width: 1280, height: 800, red: 0)
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateHeadlessBackend.validateFrame(blank)
        }
    }

    @Test("Pointer selection requires aligned USB screen-coordinate identities")
    func pointerDeviceSelection() {
        #expect(VirtualizationPrivateHeadlessBackend.selectPointingDeviceIndex(
            configuredClassNames: ["VZUSBScreenCoordinatePointingDeviceConfiguration"],
            runtimeClassNames: ["_VZScreenCoordinatePointingDevice"]
        ) == 0)
        #expect(VirtualizationPrivateHeadlessBackend.selectPointingDeviceIndex(
            configuredClassNames: ["Other", "VZUSBScreenCoordinatePointingDeviceConfiguration"],
            runtimeClassNames: ["Other", "_VZScreenCoordinatePointingDevice"]
        ) == 1)
        #expect(VirtualizationPrivateHeadlessBackend.selectPointingDeviceIndex(
            configuredClassNames: ["VZUSBScreenCoordinatePointingDeviceConfiguration"],
            runtimeClassNames: ["Other"]
        ) == nil)
    }

    @Test("CLI coordinates retain a top-left origin")
    func coordinateConversion() {
        #expect(VirtualizationPrivateHeadlessBackend.guestPoint(
            cliX: 0, cliY: 0, width: 1280, height: 800
        ) == NSPoint(x: 0, y: 800))
        #expect(VirtualizationPrivateHeadlessBackend.guestPoint(
            cliX: 1279, cliY: 799, width: 1280, height: 800
        ) == NSPoint(x: 1279, y: 1))
        #expect(VirtualizationPrivateHeadlessBackend.guestPoint(
            cliX: -3, cliY: 900, width: 1280, height: 800
        ) == NSPoint(x: 0, y: 1))
    }

    @Test("Only closed frame failures are retryable observations")
    func transientCaptureClassification() {
        for code in HostAutomationFailureCode.allCases {
            let error = VirtualizationPrivateHeadlessError(code, detail: "closed")
            #expect(
                VirtualizationPrivateHeadlessBackend.isTransientCaptureFailure(error)
                    == (code == .displayNotReady || code == .frameTimeout || code == .frameInvalid)
            )
        }
        #expect(!VirtualizationPrivateHeadlessBackend.isTransientCaptureFailure(
            RunnerError.hostCommandFailed("untyped")
        ))
    }

    @Test("Only unpublished private input resources are retryable")
    func transientInputReadinessClassification() {
        for code in HostAutomationFailureCode.allCases {
            let error = VirtualizationPrivateHeadlessError(code, detail: "closed")
            #expect(
                VirtualizationPrivateHeadlessBackend.isTransientInputReadinessFailure(error)
                    == (code == .displayNotReady || code == .inputUnavailable)
            )
        }
        #expect(!VirtualizationPrivateHeadlessBackend.isTransientInputReadinessFailure(
            RunnerError.hostCommandFailed("untyped")
        ))
    }

    @Test("Only unpublished display resources are transient")
    func displayResourceClassification() {
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: nil, displayClassName: nil, width: nil, height: nil
        ) == .notReady)
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: "VZMacGraphicsDevice",
            displayClassName: nil,
            width: nil,
            height: nil
        ) == .notReady)
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: "VZMacGraphicsDevice",
            displayClassName: "VZMacGraphicsDisplay",
            width: 0,
            height: 0
        ) == .notReady)
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: "OtherGraphicsDevice",
            displayClassName: nil,
            width: nil,
            height: nil
        ) == .unavailable)
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: "VZMacGraphicsDevice",
            displayClassName: "OtherGraphicsDisplay",
            width: 1280,
            height: 800
        ) == .unavailable)
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: "VZMacGraphicsDevice",
            displayClassName: "VZMacGraphicsDisplay",
            width: 1920,
            height: 1080
        ) == .unavailable)
        #expect(HeadlessDisplayResourceDisposition.classify(
            deviceClassName: "VZMacGraphicsDevice",
            displayClassName: "VZMacGraphicsDisplay",
            width: 1280,
            height: 800
        ) == .ready)
    }

    @Test("Observation output must be a pre-created regular file")
    func observationDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-headless-observation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("frame.png")
        try Data().write(to: file)
        try PommeProvisioningObservationDestination.validate(file)
        #expect(throws: Error.self) {
            try PommeProvisioningObservationDestination.validate(directory.appendingPathComponent("missing"))
        }
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: Error.self) { try PommeProvisioningObservationDestination.validate(link) }
    }

    private func makeImage(width: Int, height: Int, red: UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = red
            pixels[offset + 3] = 255
        }
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }
}
