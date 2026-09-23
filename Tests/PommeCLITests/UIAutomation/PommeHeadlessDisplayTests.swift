import Foundation
@preconcurrency import AppKit
import Testing
import IOSurface

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

    @Test(
        "Runtime ABI accepts any host build with the exact private interface",
        arguments: VirtualizationPrivateABIPreflight.frameObservationVariants
    )
    func abiMatching(observation: VirtualizationPrivateFrameObservation) throws {
        let environment = VirtualizationPrivateABIEnvironment(
            architecture: "arm64",
            hostBuild: "99Z999",
            frameworkIdentifier: "com.apple.Virtualization",
            frameworkVersion: "999.1",
            frameworkPath: "/System/Library/Frameworks/Virtualization.framework"
        )
        let required = VirtualizationPrivateABIPreflight.requiredMethods(for: observation)
        let encodings = Dictionary(uniqueKeysWithValues:
            required.map { ($0.identity, $0.encoding) }
        )
        try VirtualizationPrivateABIPreflight.validate(
            environment: environment,
            observedMethods: encodings,
            requiring: required
        )

        // Every entry is load-bearing, including the variant's own callback.
        for requirement in required {
            var wrongEncoding = encodings
            wrongEncoding[requirement.identity] = "v16@0:8"
            do {
                try VirtualizationPrivateABIPreflight.validate(
                    environment: environment,
                    observedMethods: wrongEncoding,
                    requiring: required
                )
                Issue.record("Expected a private ABI mismatch for \(requirement.identity)")
            } catch let error as VirtualizationPrivateHeadlessError {
                #expect(error.code == .privateABIMismatch)
                #expect(!error.partialInputPossible)
            }

            var missing = encodings
            missing.removeValue(forKey: requirement.identity)
            #expect(throws: VirtualizationPrivateHeadlessError.self) {
                try VirtualizationPrivateABIPreflight.validate(
                    environment: environment,
                    observedMethods: missing,
                    requiring: required
                )
            }
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
                observedMethods: encodings,
                requiring: required
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
                observedMethods: encodings,
                requiring: required
            )
            Issue.record("Expected a private ABI mismatch")
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(error.code == .privateABIMismatch)
        }
    }

    /// The oldest host whose private Virtualization interface Pomme qualifies.
    /// Below it a mismatch is expected; at or above it a mismatch is a
    /// regression. A runtime check, not `#available`: this is a claim about the
    /// host being tested, not about the SDK the tests were built against.
    private static let privateABISupportFloor = OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 0,
        patchVersion: 0
    )

    /// Tolerating a mismatch on a supported host is what let the macOS 27
    /// rename pass this suite while `create` was failing.
    @Test("A supported host qualifies exactly; an older host is rejected, never approximated")
    func installedRuntimeABI() throws {
        let isSupportedHost = ProcessInfo.processInfo
            .isOperatingSystemAtLeast(Self.privateABISupportFloor)
        do {
            try VirtualizationPrivateABIPreflight.validateRuntime()
            let observation = try VirtualizationPrivateABIPreflight.frameObservation()
            let methods = VirtualizationPrivateABIPreflight.requiredMethods(for: observation)
            let observed = VirtualizationPrivateABIPreflight.observedMethodEncodings(for: methods)
            for method in methods {
                #expect(observed[method.identity] == method.encoding, "\(method.identity)")
            }
        } catch let error as VirtualizationPrivateHeadlessError {
            #expect(
                !isSupportedHost || error.code == .unsupportedArchitecture,
                "A supported host no longer qualifies: \(error.code.rawValue)."
            )
        }
    }

    /// The layout `HeadlessFramebufferFrameLayout` decodes is only valid for
    /// this exact callback shape, so the constant is pinned rather than merely
    /// shared between the variants.
    @Test("The frame callback shape is the one the frame layout decodes")
    func frameUpdateEncodingIsPinned() {
        #expect(
            VirtualizationPrivateABIPreflight.frameUpdateEncoding
                == "v40@0:8@16{shared_ptr<const VzCore::Hardware::FrameUpdate>="
                + "^{FrameUpdate}^{__shared_weak_count}}24"
        )
        for variant in VirtualizationPrivateABIPreflight.frameObservationVariants {
            #expect(variant.encoding == VirtualizationPrivateABIPreflight.frameUpdateEncoding)
        }
    }

    @Test("The frame observation table is closed and unambiguous")
    func frameObservationTableIsWellFormed() {
        let variants = VirtualizationPrivateABIPreflight.frameObservationVariants
        let shared = VirtualizationPrivateABIPreflight.sharedRequiredMethods
        #expect(variants.count >= 2)
        #expect(Set(variants.map(\.variantName)).count == variants.count)
        #expect(Set(variants.map(\.protocolName)).count == variants.count)
        #expect(Set(variants.map(\.selectorName)).count == variants.count)
        for variant in variants {
            #expect(variant.method.className == "_VZVNCServer")
            #expect(!shared.contains(variant.method))
            // The association selector, where the interface needs one, is part
            // of what the host must prove.
            let extra = variant.virtualMachineMethod.map { [$0] } ?? []
            for method in extra {
                #expect(method.className == "_VZVNCServer")
                #expect(!shared.contains(method))
            }
            #expect(
                VirtualizationPrivateABIPreflight.requiredMethods(for: variant)
                    == shared + [variant.method] + extra
            )
        }
    }

    @Test("Each known host publishes exactly one qualified frame observation")
    func frameObservationVariantSelection() throws {
        let variants = VirtualizationPrivateABIPreflight.frameObservationVariants
        let framebuffer = try #require(variants.first { $0.variantName == "gen1" })
        let presenter = try #require(variants.first { $0.variantName == "gen2" })

        // The rename moved names only; a drifting encoding would mean the
        // callback shape changed and the frame layout can no longer be reused.
        #expect(framebuffer.encoding == presenter.encoding)
        #expect(framebuffer.protocolName != presenter.protocolName)
        #expect(framebuffer.selectorName != presenter.selectorName)

        for variant in [framebuffer, presenter] {
            let resolved = try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: Self.probe(publishing: [variant])
            )
            #expect(resolved == variant)
            #expect(
                VirtualizationPrivateABIPreflight.requiredMethods(for: variant)
                    == VirtualizationPrivateABIPreflight.sharedRequiredMethods
                    + [variant.method]
                    + (variant.virtualMachineMethod.map { [$0] } ?? [])
            )
            #expect(!VirtualizationPrivateABIPreflight.sharedRequiredMethods.contains(variant.method))
        }

        // A host that still declares a superseded interface alongside its
        // successor cannot prove which one actually delivers.
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: Self.probe(publishing: variants)
            )
        }
    }

    @Test("An unqualified frame observation interface is rejected, never approximated")
    func frameObservationRejection() throws {
        let presenter = try #require(
            VirtualizationPrivateABIPreflight.frameObservationVariants
                .first { $0.variantName == "gen2" }
        )

        // No interface at all.
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: Self.probe(publishing: [])
            )
        }

        // The selector is present with an unexpected encoding.
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: .init(
                    observerConforms: { $0 == presenter.protocolName },
                    selectorEncoding: { $0 == presenter.selectorName ? "v24@0:8@16" : nil },
                    protocolRequirementEncoding: { _, _ in presenter.encoding }
                )
            )
        }

        // The protocol exists but `_VZVNCServer` does not adopt it.
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: .init(
                    observerConforms: { _ in false },
                    selectorEncoding: { $0 == presenter.selectorName ? presenter.encoding : nil },
                    protocolRequirementEncoding: { _, _ in presenter.encoding }
                )
            )
        }

        // The protocol is adopted but the callback is absent.
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: .init(
                    observerConforms: { $0 == presenter.protocolName },
                    selectorEncoding: { _ in nil },
                    protocolRequirementEncoding: { _, _ in presenter.encoding }
                )
            )
        }

        // The class declares the exact callback but the protocol requires a
        // different shape: a rename that also reshaped the callback.
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: .init(
                    observerConforms: { $0 == presenter.protocolName },
                    selectorEncoding: { $0 == presenter.selectorName ? presenter.encoding : nil },
                    protocolRequirementEncoding: { _, _ in "v24@0:8@16" }
                )
            )
        }
    }

    @Test("A mismatched protocol and callback pairing never resolves")
    func frameObservationRejectsCrossedInterfaces() throws {
        let variants = VirtualizationPrivateABIPreflight.frameObservationVariants
        #expect(throws: VirtualizationPrivateHeadlessError.self) {
            try VirtualizationPrivateABIPreflight.resolveFrameObservation(
                using: .init(
                    observerConforms: { $0 == variants[0].protocolName },
                    selectorEncoding: { $0 == variants[1].selectorName ? variants[1].encoding : nil },
                    protocolRequirementEncoding: { _, _ in variants[1].encoding }
                )
            )
        }
    }

    /// The private interface is never named to a user, so the reported reason
    /// cannot carry a protocol, selector, or encoding.
    @Test("Frame observation failures never name the private interface")
    func frameObservationFailureIsRedacted() {
        let variants = VirtualizationPrivateABIPreflight.frameObservationVariants
        let secrets = variants.flatMap { [$0.protocolName, $0.selectorName, $0.encoding] }
        for probe in [Self.probe(publishing: []), Self.probe(publishing: variants)] {
            do {
                _ = try VirtualizationPrivateABIPreflight.resolveFrameObservation(using: probe)
                Issue.record("Expected a private ABI mismatch")
            } catch let error as VirtualizationPrivateHeadlessError {
                #expect(error.code == .privateABIMismatch)
                let description = error.errorDescription ?? ""
                for secret in secrets {
                    #expect(!description.contains(secret))
                }
                #expect(!description.contains("_VZ"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    /// A host that publishes exactly the named variants and nothing else.
    private static func probe(
        publishing variants: [VirtualizationPrivateFrameObservation]
    ) -> VirtualizationPrivateFrameObservationProbe {
        .init(
            observerConforms: { name in variants.contains { $0.protocolName == name } },
            selectorEncoding: { name in
                variants.first { $0.selectorName == name }?.encoding
            },
            protocolRequirementEncoding: { protocolName, selectorName in
                variants.first {
                    $0.protocolName == protocolName && $0.selectorName == selectorName
                }?.encoding
            }
        )
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

    @Test("Retained gen2 display avoids native observer rebinding")
    func retainedObserverActions() {
        typealias Registration = HeadlessFramebufferPresenterRegistration
        #expect(Registration.actions(hasObserver: true, sameDisplay: true, gen2: true).isEmpty)
        #expect(Registration.actions(hasObserver: true, sameDisplay: true, gen2: false)
            == [.detach, .invalidate, .associateVirtualMachine, .attach])
        for gen2 in [false, true] {
            #expect(Registration.actions(hasObserver: false, sameDisplay: false, gen2: gen2)
                == [.invalidate, .makeObserver, .associateVirtualMachine, .attach])
            #expect(Registration.actions(hasObserver: true, sameDisplay: false, gen2: gen2)
                == [.detach, .invalidate, .makeObserver, .associateVirtualMachine, .attach])
        }
    }

    @Test("Presenter replacement discards retained scanout before damage reuse")
    func presenterReplacementDiscardsSurface() throws {
        let state = HeadlessFramebufferCaptureState()
        let first = NSObject()
        let second = NSObject()
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 8,
            kIOSurfaceAllocSize: 16
        ] as CFDictionary))
        state.associateSource(first)
        var frame = [UInt64](repeating: 0, count: 2)
        frame.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: Unmanaged.passUnretained(surface).toOpaque(), as: UnsafeMutableRawPointer.self)
            bytes.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
            var pointer: UnsafeRawPointer? = bytes.baseAddress.map(UnsafeRawPointer.init)
            withUnsafePointer(to: &pointer) { shared in
                state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared))
                #expect(state.hasLatestSurface)
                state.associateSource(first)
                #expect(state.hasLatestSurface)
                state.associateSource(second)
                #expect(!state.hasLatestSurface)
                #expect(!state.acceptsSource(first))
                #expect(state.acceptsSource(second))
                // Simulate a delayed full callback from the detached presenter.
                #expect(!state.receive(
                    sharedFrameUpdatePointer: UnsafeRawPointer(shared),
                    allowDamageReuse: true,
                    source: first
                ))
                #expect(!state.hasLatestSurface)
                bytes.storeBytes(of: UInt8(0), toByteOffset: 8, as: UInt8.self)
                state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared), allowDamageReuse: true, source: second)
                #expect(!state.hasLatestSurface)
                // Gen1 has no presenter identity; explicit detach still clears
                // its retained scanout even when both old/new identities are nil.
                state.associateSource(nil)
                bytes.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
                state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared))
                #expect(state.hasLatestSurface)
                state.associateSource(nil)
                #expect(!state.hasLatestSurface)
            }
        }
    }

    @Test("Retained scanout renders changed pixels and rejects replacement during render")
    func retainedScanoutPixels() throws {
        let state = HeadlessFramebufferCaptureState()
        let source = NSObject()
        let replacement = NSObject()
        state.associateSource(source)
        let request = try state.beginRequest()
        #expect(try state.renderLatestSurface() == nil)
        #expect(state.takeResult(requestID: request) == nil)
        state.cancel(requestID: request)
        let next = try state.beginRequest()
        state.cancel(requestID: next)
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 2, kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 8,
            kIOSurfacePixelFormat: 0x42475241, kIOSurfaceAllocSize: 16
        ] as CFDictionary))
        func fill(_ pixel: UInt32) {
            IOSurfaceLock(surface, [], nil)
            let address = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
            for index in 0..<4 { address[index] = pixel }
            IOSurfaceUnlock(surface, [], nil)
        }
        fill(0xffff0000)
        var frame = [UInt64](repeating: 0, count: 2)
        frame.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: Unmanaged.passUnretained(surface).toOpaque(), as: UnsafeMutableRawPointer.self)
            bytes.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
            var pointer = bytes.baseAddress.map(UnsafeRawPointer.init)
            withUnsafePointer(to: &pointer) { shared in
                #expect(state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared), source: source))
            }
        }
        func pixel(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 16)
            let context = try #require(CGContext(data: &bytes, width: 2, height: 2,
                bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
            return bytes
        }
        let first = try pixel(#require(try state.renderLatestSurface()))
        fill(0xff00ff00)
        let second = try pixel(#require(try state.renderLatestSurface()))
        #expect(first != second)
        #expect(first[0] > first[1])
        #expect(second[1] > second[0])
        let oldGeneration = state.generation
        #expect(try state.renderLatestSurface(beforeValidation: {
            state.associateSource(replacement)
        }) == nil)
        #expect(try state.renderLatestSurface() == nil)
        #expect(!state.acceptsSource(source))
        frame.withUnsafeMutableBytes { bytes in
            var pointer = bytes.baseAddress.map(UnsafeRawPointer.init)
            withUnsafePointer(to: &pointer) { shared in
                #expect(!state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared), source: source))
                #expect(state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared), source: replacement))
            }
        }
        #expect(try state.renderLatestSurface(expectedGeneration: oldGeneration) == nil)
        #expect(try state.renderLatestSurface(expectedGeneration: state.generation) != nil)
    }

    @Test("Every presenter registration caches replay but waits for a live callback", arguments: [false, true])
    func registrationWaitsForPublication(damageOnly: Bool) async throws {
        let state = HeadlessFramebufferCaptureState()
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 8,
            kIOSurfacePixelFormat: 0x42475241,
            kIOSurfaceAllocSize: 16
        ] as CFDictionary))
        func deliver(source: NSObject, full: Bool = true) -> Bool {
            var frame = [UInt64](repeating: 0, count: 2)
            return frame.withUnsafeMutableBytes { bytes in
                bytes.storeBytes(of: Unmanaged.passUnretained(surface).toOpaque(), as: UnsafeMutableRawPointer.self)
                bytes.storeBytes(of: UInt8(full ? 1 : 0), toByteOffset: 8, as: UInt8.self)
                var pointer = bytes.baseAddress.map(UnsafeRawPointer.init)
                return withUnsafePointer(to: &pointer) { shared in
                    state.receive(sharedFrameUpdatePointer: UnsafeRawPointer(shared), allowDamageReuse: true, source: source)
                }
            }
        }
        var priorSource: NSObject?
        for _ in 0..<3 {
            state.associateSource(nil)
            let source = NSObject()
            let request = try state.beginRequest()
            HeadlessFramebufferPresenterRegistration.associate(source: source, state: state) {
                #expect(deliver(source: source))
            }
            #expect(state.hasLatestSurface)
            if let priorSource {
                #expect(!deliver(source: priorSource))
                #expect(!deliver(source: priorSource, full: false))
            }
            // Allow any accidentally scheduled replay render to finish.
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(state.takeResult(requestID: request) == nil)
            #expect(deliver(source: source, full: !damageOnly))
            let deadline = Date().addingTimeInterval(2)
            var completed = false
            while Date() < deadline {
                if let result = state.takeResult(requestID: request) {
                    let image = try result.get().value
                    #expect(image.width == 2)
                    #expect(image.height == 2)
                    completed = true
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(completed, "The live callback did not complete capture")
            state.cancel(requestID: request)
            priorSource = source
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
