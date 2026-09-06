import Foundation
import ArgumentParser
@preconcurrency import AppKit
@preconcurrency import CoreImage
import IOSurface
import ObjectiveC.runtime
@preconcurrency import Virtualization
import Darwin

enum HostAutomationFailureCode: String, CaseIterable, Codable, Equatable, Sendable {
    case unsupportedArchitecture = "unsupported_architecture"
    case privateABIMismatch = "private_abi_mismatch"
    case vmStateInvalid = "vm_state_invalid"
    case displayNotReady = "display_not_ready"
    case displayUnavailable = "display_unavailable"
    case inputUnavailable = "input_unavailable"
    case frameTimeout = "frame_timeout"
    case frameInvalid = "frame_invalid"
    case inputInterrupted = "input_interrupted"
    case inputTimeout = "input_timeout"
}

struct VirtualizationPrivateHeadlessError: LocalizedError, Equatable, Sendable {
    let code: HostAutomationFailureCode
    let partialInputPossible: Bool
    /// True only when the framebuffer contains no visible pixels. During a
    /// Recovery boot this is an expected transition surface; malformed frame
    /// dimensions, decode failures, and ABI errors remain non-transient.
    let isBlankFrame: Bool
    private let detail: String

    init(
        _ code: HostAutomationFailureCode,
        detail: String,
        partialInputPossible: Bool = false,
        isBlankFrame: Bool = false
    ) {
        self.code = code
        self.partialInputPossible = partialInputPossible
        self.isBlankFrame = isBlankFrame
        self.detail = detail
    }

    var errorDescription: String? {
        "Headless VM automation failed [code=\(code.rawValue), partialInputPossible=\(partialInputPossible)]: \(detail)"
    }

    func payload(operation: String, width: Int? = nil, height: Int? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "ok": false,
            "schemaVersion": 2,
            "operation": operation,
            "backend": VirtualizationPrivateHeadlessBackend.backendName,
            "hostBuild": VirtualizationPrivateHeadlessBackend.hostBuild,
            "errorCode": code.rawValue,
            "error": errorDescription ?? code.rawValue,
            "partialInputPossible": partialInputPossible,
            "hostExitCode": 1
        ]
        if let width { result["width"] = width }
        if let height { result["height"] = height }
        return result
    }
}

struct VirtualizationPrivateABIEnvironment: Equatable, Sendable {
    let architecture: String
    let hostBuild: String
    let frameworkIdentifier: String?
    let frameworkVersion: String?
    let frameworkPath: String
}

struct VirtualizationPrivateABIMethod: Equatable, Sendable {
    let className: String
    let selectorName: String
    let encoding: String

    var identity: String { "\(className).\(selectorName)" }
}

enum VirtualizationPrivateABIPreflight {
    static let supportedArchitecture = "arm64"
    static let frameworkIdentifier = "com.apple.Virtualization"
    static let frameworkPath = "/System/Library/Frameworks/Virtualization.framework"

    static let requiredMethods = [
        VirtualizationPrivateABIMethod(
            className: "_VZVNCServer",
            selectorName: "initWithPort:",
            encoding: "@20@0:8S16"
        ),
        VirtualizationPrivateABIMethod(
            className: "_VZVNCServer",
            selectorName: "setGraphicsDisplay:",
            encoding: "v24@0:8@16"
        ),
        VirtualizationPrivateABIMethod(
            className: "_VZVNCServer",
            selectorName: "framebuffer:didUpdateFrame:",
            encoding: "v40@0:8@16{shared_ptr<const VzCore::Hardware::FrameUpdate>=^{FrameUpdate}^{__shared_weak_count}}24"
        ),
        VirtualizationPrivateABIMethod(
            className: "VZVirtualMachine",
            selectorName: "_keyboards",
            encoding: "@16@0:8"
        ),
        VirtualizationPrivateABIMethod(
            className: "VZVirtualMachine",
            selectorName: "_pointingDevices",
            encoding: "@16@0:8"
        ),
        VirtualizationPrivateABIMethod(
            className: "VZVirtualMachine",
            selectorName: "_shouldSendHIDReports",
            encoding: "B16@0:8"
        ),
        VirtualizationPrivateABIMethod(
            className: "VZVirtualMachine",
            selectorName: "_hidEventMonitor",
            encoding: "@16@0:8"
        ),
        VirtualizationPrivateABIMethod(
            className: "VZVirtualMachine",
            selectorName: "sendPointerNSEvent:pointingDeviceIndex:",
            encoding: "v28@0:8@16I24"
        ),
        VirtualizationPrivateABIMethod(
            className: "_VZHIDEventFilter",
            selectorName: "updateCoordinateTransform:isFlipped:",
            encoding: "v52@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16B48"
        ),
        VirtualizationPrivateABIMethod(
            className: "_VZKeyboard",
            selectorName: "sendKeyEvents:",
            encoding: "v24@0:8@16"
        ),
        VirtualizationPrivateABIMethod(
            className: "_VZKeyEvent",
            selectorName: "initWithEvent:",
            encoding: "@24@0:8@16"
        )
    ]

    static var environment: VirtualizationPrivateABIEnvironment {
        let bundle = Bundle(for: VZVirtualMachine.self)
        return .init(
            architecture: currentArchitecture,
            hostBuild: currentHostBuild,
            frameworkIdentifier: bundle.bundleIdentifier,
            frameworkVersion: bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String,
            frameworkPath: bundle.bundlePath
        )
    }

    static func validate(
        environment: VirtualizationPrivateABIEnvironment,
        observedMethods: [String: String]
    ) throws {
        guard environment.architecture == supportedArchitecture else {
            throw VirtualizationPrivateHeadlessError(
                .unsupportedArchitecture,
                detail: "This backend requires an arm64 host."
            )
        }
        guard environment.frameworkIdentifier == frameworkIdentifier,
              environment.frameworkPath == frameworkPath
        else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The loaded Virtualization framework is not the expected system framework."
            )
        }
        for requirement in requiredMethods {
            guard observedMethods[requirement.identity] == requirement.encoding else {
                throw VirtualizationPrivateHeadlessError(
                    .privateABIMismatch,
                    detail: "A required Virtualization private method is missing or has an unqualified encoding."
                )
            }
        }
    }

    static func validateRuntime() throws {
        try validate(environment: environment, observedMethods: observedMethodEncodings())
        guard let framebufferObserverProtocol = objc_getProtocol("_VZFramebufferObserver"),
              let observerClass = NSClassFromString("_VZVNCServer"),
              class_conformsToProtocol(observerClass, framebufferObserverProtocol)
        else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The private framebuffer observer protocol is unavailable or incompatible."
            )
        }
        guard let monitorClass = NSClassFromString("_VZHIDEventMonitor"),
              class_getInstanceSize(monitorClass) == 24,
              let filterIvar = class_getInstanceVariable(monitorClass, "_filter"),
              ivar_getOffset(filterIvar) == 8,
              let filterEncoding = ivar_getTypeEncoding(filterIvar),
              String(cString: filterEncoding) == "@\"_VZHIDEventFilter\"",
              let enabledIvar = class_getInstanceVariable(monitorClass, "_enabled"),
              ivar_getOffset(enabledIvar) == 16,
              let enabledEncoding = ivar_getTypeEncoding(enabledIvar),
              String(cString: enabledEncoding) == "B",
              let translatorsIvar = class_getInstanceVariable(
                monitorClass,
                "_hasEventTranslators"
              ),
              ivar_getOffset(translatorsIvar) == 17,
              let translatorsEncoding = ivar_getTypeEncoding(translatorsIvar),
              String(cString: translatorsEncoding) == "B"
        else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The private HID coordinate filter layout is unavailable or incompatible."
            )
        }
    }

    static func observedMethodEncodings() -> [String: String] {
        requiredMethods.reduce(into: [:]) { result, requirement in
            guard let cls: AnyClass = NSClassFromString(requirement.className),
                  let method = class_getInstanceMethod(
                    cls,
                    NSSelectorFromString(requirement.selectorName)
                  ),
                  let encoding = method_getTypeEncoding(method)
            else { return }
            result[requirement.identity] = String(cString: encoding)
        }
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#else
        "unsupported"
#endif
    }

    private static var currentHostBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }
}

final class HeadlessAutomationCallbackGate<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case waitingForBegin
        case waitingForResult(CheckedContinuation<Value, Error>)
        case buffered(Result<Value, Error>)
        case completed
    }

    private let lock = NSLock()
    private var state: State = .waitingForBegin

    func begin(_ continuation: CheckedContinuation<Value, Error>) {
        let bufferedResult: Result<Value, Error>?
        lock.lock()
        switch state {
        case .waitingForBegin:
            state = .waitingForResult(continuation)
            bufferedResult = nil
        case .buffered(let result):
            state = .completed
            bufferedResult = result
        case .waitingForResult, .completed:
            lock.unlock()
            preconditionFailure("HeadlessAutomationCallbackGate may begin only once.")
        }
        lock.unlock()
        if let bufferedResult { continuation.resume(with: bufferedResult) }
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        switch state {
        case .waitingForBegin:
            state = .buffered(result)
            continuation = nil
        case .waitingForResult(let installed):
            state = .completed
            continuation = installed
        case .buffered, .completed:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct HeadlessInputReadinessToken: Equatable, Sendable {
    fileprivate let virtualMachineIdentity: ObjectIdentifier
    fileprivate let keyboardIdentity: ObjectIdentifier
    fileprivate let hostBuild: String
}

enum HeadlessInputTiming {
    static let keyDownDwellNanoseconds: UInt64 = 20_000_000
    static let transitionGapNanoseconds: UInt64 = 8_000_000
    static let pointerHoverNanoseconds: UInt64 = 250_000_000
    static let minimumKeyCycleNanoseconds = keyDownDwellNanoseconds + transitionGapNanoseconds
}

/// A monotonic operation budget for direct VM input. The budget is
/// checked before any event is emitted, and again only at complete key-chord
/// boundaries. That lets an in-flight chord finish without leaving a modifier
/// pressed while still refusing an obviously overlong plan up front.
struct HeadlessInputBudget: Sendable {
    typealias Clock = @Sendable () -> UInt64

    private let deadline: UInt64
    private let clock: Clock
    private let operation: String

    init(
        timeout: TimeInterval,
        operation: String,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw Self.timeoutError(
                partialInputPossible: false,
                detail: "The direct VM \(operation) timeout must be finite and positive."
            )
        }
        self.deadline = Self.addingSaturating(
            clock(),
            Self.nanoseconds(for: timeout)
        )
        self.clock = clock
        self.operation = operation
    }

    /// The minimum elapsed time introduced by the backend's event dwell and
    /// transition gaps. Saturating arithmetic keeps malformed/huge requests
    /// fail-closed instead of wrapping to a deceptively small budget.
    static func minimumDurationNanoseconds(
        for plan: [HostDisplayInputEvent]
    ) -> UInt64 {
        plan.reduce(into: UInt64.zero) { total, event in
            let delay = event.kind == .keyDown
                ? HeadlessInputTiming.keyDownDwellNanoseconds
                : HeadlessInputTiming.transitionGapNanoseconds
            total = addingSaturating(total, delay)
        }
    }

    static func minimumDurationNanoseconds(
        for plans: [[HostDisplayInputEvent]]
    ) -> UInt64 {
        plans.reduce(into: UInt64.zero) { total, plan in
            total = addingSaturating(total, minimumDurationNanoseconds(for: plan))
        }
    }

    static func minimumDurationNanoseconds(for delays: [UInt64]) -> UInt64 {
        delays.reduce(into: UInt64.zero) { total, delay in
            total = addingSaturating(total, delay)
        }
    }

    static func minimumDurationNanoseconds(for delayPlans: [[UInt64]]) -> UInt64 {
        delayPlans.reduce(into: UInt64.zero) { total, plan in
            total = addingSaturating(total, minimumDurationNanoseconds(for: plan))
        }
    }

    func requireFullPlan(_ plans: [[HostDisplayInputEvent]]) throws {
        try requireFullDuration(
            Self.minimumDurationNanoseconds(for: plans),
            partialInputPossible: false
        )
    }

    func requireNextChord(
        _ plan: [HostDisplayInputEvent],
        partialInputPossible: Bool
    ) throws {
        try requireNextDuration(
            Self.minimumDurationNanoseconds(for: plan),
            partialInputPossible: partialInputPossible
        )
    }

    func requireFullDuration(
        _ nanoseconds: UInt64,
        partialInputPossible: Bool
    ) throws {
        try requireMinimumDuration(nanoseconds, partialInputPossible: partialInputPossible)
    }

    func requireNextDuration(
        _ nanoseconds: UInt64,
        partialInputPossible: Bool
    ) throws {
        try requireMinimumDuration(nanoseconds, partialInputPossible: partialInputPossible)
    }

    func requireMinimumDuration(
        _ nanoseconds: UInt64,
        partialInputPossible: Bool
    ) throws {
        let now = clock()
        guard now <= deadline,
              deadline - now >= nanoseconds
        else {
            throw Self.timeoutError(
                partialInputPossible: partialInputPossible,
                detail: "The direct VM \(operation) input plan exceeded its bounded deadline."
            )
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        let raw = seconds * 1_000_000_000
        guard raw.isFinite else { return .max }
        let rounded = raw.rounded(.up)
        guard rounded < Double(UInt64.max) else { return .max }
        return max(1, UInt64(rounded))
    }

    fileprivate static func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func timeoutError(
        partialInputPossible: Bool,
        detail: String
    ) -> VirtualizationPrivateHeadlessError {
        VirtualizationPrivateHeadlessError(
            .inputTimeout,
            detail: detail,
            partialInputPossible: partialInputPossible
        )
    }
}

/// Executes cancellation-safe input units with injectable timing and event
/// delivery. A unit is a complete key chord or a complete pointer phase; a
/// cancellation observed during its dwell is deferred until every event in
/// that unit has been delivered.
struct HeadlessInputEventDispatcher {
    typealias EventSender = (_ unitIndex: Int, _ eventIndex: Int) throws -> Void
    typealias Sleeper = (UInt64) async throws -> Void
    typealias Clock = @Sendable () -> UInt64

    static func dispatch(
        delayPlans: [[UInt64]],
        timeout: TimeInterval,
        operation: String,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        send: @escaping EventSender
    ) async throws -> Int {
        let budget = try HeadlessInputBudget(
            timeout: timeout,
            operation: operation,
            clock: clock
        )
        return try await dispatch(
            delayPlans: delayPlans,
            budget: budget,
            sleep: sleep,
            send: send
        )
    }

    static func dispatch(
        delayPlans: [[UInt64]],
        budget: HeadlessInputBudget,
        sleep: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        send: @escaping EventSender
    ) async throws -> Int {
        try budget.requireFullDuration(
            HeadlessInputBudget.minimumDurationNanoseconds(for: delayPlans),
            partialInputPossible: false
        )

        var emitted = 0
        for (unitIndex, delays) in delayPlans.enumerated() {
            try budget.requireNextDuration(
                HeadlessInputBudget.minimumDurationNanoseconds(for: delays),
                partialInputPossible: emitted > 0
            )
            if Task.isCancelled {
                throw interruptedError(from: CancellationError(), emitted: emitted)
            }

            var cancellationObserved = false
            for (eventIndex, delay) in delays.enumerated() {
                do {
                    // No cancellation check occurs between events in one
                    // unit. This is what guarantees key-up/release and
                    // pointer button-up after a cancellation during dwell.
                    try send(unitIndex, eventIndex)
                    emitted += 1
                } catch {
                    throw interruptedError(from: error, emitted: emitted)
                }
                do {
                    try await sleep(delay)
                } catch {
                    cancellationObserved = true
                }
            }
            if cancellationObserved {
                throw interruptedError(from: CancellationError(), emitted: emitted)
            }
        }
        return emitted
    }

    private static func interruptedError(from error: Error, emitted: Int) -> Error {
        guard emitted > 0 else { return error }
        return VirtualizationPrivateHeadlessError(
            .inputInterrupted,
            detail: "Direct VM input readiness disappeared during the operation.",
            partialInputPossible: true
        )
    }
}

enum PommeProvisioningObservationDestination {
    static func validate(_ observationURL: URL) throws {
        guard observationURL.isFileURL else {
            throw RunnerError.hostCommandFailed(
                "Pomme provisioning observation destination must be a local pre-created file."
            )
        }
        let values = try observationURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RunnerError.hostCommandFailed(
                "Pomme provisioning observation destination must be a pre-created regular file."
            )
        }
    }
}

enum HeadlessDisplayResourceDisposition: Equatable, Sendable {
    case ready
    case notReady
    case unavailable

    static func classify(
        deviceClassName: String?,
        displayClassName: String?,
        width: Int?,
        height: Int?,
        expectedWidth: Int = VirtualizationPrivateHeadlessBackend.displayWidth,
        expectedHeight: Int = VirtualizationPrivateHeadlessBackend.displayHeight
    ) -> Self {
        guard let deviceClassName else { return .notReady }
        guard deviceClassName == "VZMacGraphicsDevice" else { return .unavailable }
        guard let displayClassName else { return .notReady }
        guard displayClassName == "VZMacGraphicsDisplay" else { return .unavailable }
        guard let width, let height, width > 0, height > 0 else { return .notReady }
        return width == expectedWidth && height == expectedHeight ? .ready : .unavailable
    }
}

enum HeadlessFramebufferFrameLayout {
    static func surfacePointer(frameUpdatePointer: UnsafeRawPointer?) -> UnsafeRawPointer? {
        guard let frameUpdatePointer,
              frameUpdatePointer.advanced(by: MemoryLayout<UnsafeRawPointer?>.size)
                .load(as: UInt8.self) != 0
        else { return nil }
        return frameUpdatePointer.load(as: UnsafeRawPointer?.self)
    }

    static func surfacePointer(sharedFrameUpdatePointer: UnsafeRawPointer?) -> UnsafeRawPointer? {
        guard let sharedFrameUpdatePointer else { return nil }
        let frameUpdatePointer = sharedFrameUpdatePointer.load(as: UnsafeRawPointer?.self)
        return surfacePointer(frameUpdatePointer: frameUpdatePointer)
    }
}

private final class HeadlessFramebufferCaptureState: @unchecked Sendable {
    private struct CompletedFrame {
        let requestID: UInt64
        let result: Result<QueueConfined<CGImage>, Error>
    }

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "pomme.private-framebuffer-render")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var nextRequestID: UInt64 = 0
    private var pendingRequestID: UInt64?
    private var renderingRequestID: UInt64?
    private var completedFrame: CompletedFrame?

    func beginRequest() throws -> UInt64 {
        try lock.withLock {
            guard pendingRequestID == nil, renderingRequestID == nil else {
                throw VirtualizationPrivateHeadlessError(
                    .frameInvalid,
                    detail: "A private framebuffer capture is already pending."
                )
            }
            nextRequestID &+= 1
            if nextRequestID == 0 { nextRequestID = 1 }
            pendingRequestID = nextRequestID
            completedFrame = nil
            return nextRequestID
        }
    }

    func receive(sharedFrameUpdatePointer: UnsafeRawPointer?) {
        // Damage-only updates do not carry a surface. Keep waiting for the next
        // full framebuffer update instead of consuming the pending request.
        guard let surfacePointer = HeadlessFramebufferFrameLayout.surfacePointer(
            sharedFrameUpdatePointer: sharedFrameUpdatePointer
        ) else { return }
        let requestID = lock.withLock { () -> UInt64? in
            guard let pendingRequestID, renderingRequestID == nil else { return nil }
            renderingRequestID = pendingRequestID
            return pendingRequestID
        }
        guard let requestID else { return }

        let retainedSurface = QueueConfined(
            value: Unmanaged<IOSurface>.fromOpaque(surfacePointer).retain()
        )
        renderQueue.async { [weak self, retainedSurface] in
            let retained = retainedSurface.value
            let surface = retained.takeUnretainedValue()
            defer { retained.release() }
            guard let self else { return }
            let width = IOSurfaceGetWidth(surface)
            let height = IOSurfaceGetHeight(surface)
            guard width > 0, height > 0 else {
                self.finish(
                    requestID: requestID,
                    result: .failure(VirtualizationPrivateHeadlessError(
                        .frameInvalid,
                        detail: "The private framebuffer IOSurface has invalid dimensions."
                    ))
                )
                return
            }
            let image = CIImage(ioSurface: surface)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            guard let rendered = self.context.createCGImage(image, from: bounds) else {
                self.finish(
                    requestID: requestID,
                    result: .failure(VirtualizationPrivateHeadlessError(
                        .frameInvalid,
                        detail: "The private framebuffer IOSurface could not be rendered."
                    ))
                )
                return
            }
            self.finish(
                requestID: requestID,
                result: .success(QueueConfined(value: rendered))
            )
        }
    }

    func takeResult(requestID: UInt64) -> Result<QueueConfined<CGImage>, Error>? {
        lock.withLock {
            guard completedFrame?.requestID == requestID else { return nil }
            let result = completedFrame?.result
            completedFrame = nil
            return result
        }
    }

    func cancel(requestID: UInt64) {
        lock.withLock {
            if pendingRequestID == requestID { pendingRequestID = nil }
            if renderingRequestID == requestID { renderingRequestID = nil }
            if completedFrame?.requestID == requestID { completedFrame = nil }
        }
    }

    private func finish(
        requestID: UInt64,
        result: Result<QueueConfined<CGImage>, Error>
    ) {
        lock.withLock {
            guard renderingRequestID == requestID else { return }
            pendingRequestID = nil
            renderingRequestID = nil
            completedFrame = CompletedFrame(requestID: requestID, result: result)
        }
    }
}

private enum HeadlessFramebufferObserverRuntime {
    private typealias FrameUpdateIMP = @convention(c) (
        AnyObject, Selector, AnyObject, UnsafeRawPointer
    ) -> Void
    private typealias InitWithPortIMP = @convention(c) (
        AnyObject, Selector, UInt16
    ) -> AnyObject?
    private typealias SetGraphicsDisplayIMP = @convention(c) (
        AnyObject, Selector, AnyObject?
    ) -> Void

    private static nonisolated(unsafe) var stateAssociationKey: UInt8 = 0
    private static let frameUpdateSelector = NSSelectorFromString("framebuffer:didUpdateFrame:")
    private static let subclassName = "PommePrivateHeadlessFramebufferObserver"

    private static let frameUpdateImplementation: FrameUpdateIMP = {
        observer, _, _, sharedFrameUpdatePointer in
        guard let state = objc_getAssociatedObject(
            observer,
            &stateAssociationKey
        ) as? HeadlessFramebufferCaptureState else { return }
        state.receive(sharedFrameUpdatePointer: sharedFrameUpdatePointer)
    }

    private static let observerClass: AnyClass? = {
        if let existing = NSClassFromString(subclassName) { return existing }
        guard let superclass = NSClassFromString("_VZVNCServer"),
              let callbackMethod = class_getInstanceMethod(superclass, frameUpdateSelector),
              let callbackEncoding = method_getTypeEncoding(callbackMethod),
              let subclass = objc_allocateClassPair(superclass, subclassName, 0)
        else { return nil }
        guard class_addMethod(
            subclass,
            frameUpdateSelector,
            unsafeBitCast(frameUpdateImplementation, to: IMP.self),
            callbackEncoding
        ) else {
            objc_disposeClassPair(subclass)
            return nil
        }
        objc_registerClassPair(subclass)
        return subclass
    }()

    static func make(state: HeadlessFramebufferCaptureState) throws -> AnyObject {
        guard let observerClass,
              let allocated = class_createInstance(observerClass, 0) as AnyObject?,
              let method = class_getInstanceMethod(
                observerClass,
                NSSelectorFromString("initWithPort:")
              )
        else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The private headless framebuffer observer could not be allocated."
            )
        }
        let selector = NSSelectorFromString("initWithPort:")
        let initialize = unsafeBitCast(
            method_getImplementation(method),
            to: InitWithPortIMP.self
        )
        guard let observer = initialize(allocated, selector, 1) else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The private headless framebuffer observer could not be initialized."
            )
        }
        objc_setAssociatedObject(
            observer,
            &stateAssociationKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return observer
    }

    static func setDisplay(_ display: AnyObject?, on observer: AnyObject) throws {
        let selector = NSSelectorFromString("setGraphicsDisplay:")
        guard let method = class_getInstanceMethod(object_getClass(observer), selector) else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The private headless framebuffer attachment selector disappeared."
            )
        }
        let setDisplay = unsafeBitCast(
            method_getImplementation(method),
            to: SetGraphicsDisplayIMP.self
        )
        setDisplay(observer, selector, display)
    }
}

final class VirtualizationPrivateHeadlessBackend: @unchecked Sendable {
    static let backendName = "virtualization-private-direct"
    static let displayWidth = 1280
    static let displayHeight = 800
    static let displaySize = NSSize(width: displayWidth, height: displayHeight)
    static var hostBuild: String { VirtualizationPrivateABIPreflight.environment.hostBuild }

    private typealias ObjectGetterIMP = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias BoolGetterIMP = @convention(c) (AnyObject, Selector) -> Bool
    private typealias SendObjectsIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias KeyEventInitIMP = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
    private typealias SendPointerIMP = @convention(c) (AnyObject, Selector, AnyObject, UInt32) -> Void
    private typealias UpdatePointerTransformIMP = @convention(c) (
        AnyObject, Selector, CGRect, Bool
    ) -> Void

    private struct CaptureResources: @unchecked Sendable {
        let display: VZGraphicsDisplay
        let width: Int
        let height: Int
    }

    private struct KeyboardResources: @unchecked Sendable {
        let keyboard: AnyObject
        let width: Int
        let height: Int
    }

    private struct PointerResources: Sendable {
        let pointingDeviceIndex: UInt32
        let width: Int
        let height: Int
    }

    private struct PreparedKeyEvent: @unchecked Sendable {
        let object: AnyObject
        let kind: HostDisplayInputEventKind
    }

    private let virtualMachine: QueueConfined<VZVirtualMachine>
    private let configuration: QueueConfined<VZVirtualMachineConfiguration>
    private let queue: DispatchQueue
    private let framebufferCaptureState = HeadlessFramebufferCaptureState()
    private var framebufferObserver: QueueConfined<AnyObject>?
    private var observedDisplayIdentity: ObjectIdentifier?

    init(
        virtualMachine: VZVirtualMachine,
        configuration: VZVirtualMachineConfiguration,
        queue: DispatchQueue
    ) {
        self.virtualMachine = QueueConfined(value: virtualMachine)
        self.configuration = QueueConfined(value: configuration)
        self.queue = queue
    }

    func availabilityPayload() -> [String: JSONValue] {
        do {
            try VirtualizationPrivateABIPreflight.validateRuntime()
            let resources = try captureResources()
            return [
                "available": .bool(true),
                "backend": .string(Self.backendName),
                "hostBuild": .string(Self.hostBuild),
                "width": .integer(Int64(resources.width)),
                "height": .integer(Int64(resources.height))
            ]
        } catch let error as VirtualizationPrivateHeadlessError {
            return [
                "available": .bool(false),
                "backend": .string(Self.backendName),
                "hostBuild": .string(Self.hostBuild),
                "failureCode": .string(error.code.rawValue)
            ]
        } catch {
            return [
                "available": .bool(false),
                "backend": .string(Self.backendName),
                "hostBuild": .string(Self.hostBuild),
                "failureCode": .string(HostAutomationFailureCode.privateABIMismatch.rawValue)
            ]
        }
    }

    func screenshot(to outputURL: URL, timeout: TimeInterval) async throws -> [String: JSONValue] {
        let image = try await captureFrame(timeout: timeout)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The captured framebuffer could not be encoded as PNG."
            )
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL)
        return successPayload(operation: "screenshot", image: image).merging([
            "hostPath": .string(outputURL.path),
            "bytes": .integer(Int64(data.count))
        ]) { _, new in new }
    }

    func capture(to observationURL: URL, timeout: TimeInterval) async throws -> [String: JSONValue] {
        try PommeProvisioningObservationDestination.validate(observationURL)
        let image = try await captureFrame(timeout: timeout)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The Pomme provisioning framebuffer could not be encoded as PNG."
            )
        }
        try data.write(to: observationURL)
        return successPayload(operation: "provisioningFirstBootObservation", image: image).merging([
            "bytes": .integer(Int64(data.count))
        ]) { _, new in new }
    }

    func captureImage(timeout: TimeInterval) async throws -> CGImage {
        try await captureFrame(timeout: timeout)
    }

    func recoveryFrame(timeout: TimeInterval) async throws -> CGImage {
        try await captureFrame(timeout: timeout)
    }

    func click(x: Double, y: Double, timeout: TimeInterval) async throws -> [String: JSONValue] {
        let budget = try HeadlessInputBudget(timeout: timeout, operation: "click")
        let delayPlans = [
            [HeadlessInputTiming.pointerHoverNanoseconds],
            [UInt64.zero, UInt64.zero],
        ]
        try budget.requireFullDuration(
            HeadlessInputBudget.minimumDurationNanoseconds(for: delayPlans),
            partialInputPossible: false
        )
        try VirtualizationPrivateABIPreflight.validateRuntime()
        let resources = try pointerResources()
        let clampedX = max(0, min(Double(resources.width - 1), x))
        let clampedY = max(0, min(Double(resources.height - 1), y))
        let point = NSPoint(x: clampedX, y: Double(resources.height) - clampedY)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let descriptions: [(NSEvent.EventType, Int, Float, TimeInterval)] = [
            (.mouseMoved, 0, 0, timestamp),
            (.leftMouseDown, 1, 1, timestamp + 0.25),
            (.leftMouseUp, 1, 0, timestamp + 0.30)
        ]
        let events = try descriptions.map { type, clickCount, pressure, eventTimestamp in
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: eventTimestamp,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: pressure
            ) else {
                throw VirtualizationPrivateHeadlessError(
                    .inputUnavailable,
                    detail: "A direct pointer event could not be constructed."
                )
            }
            return event
        }

        _ = try await HeadlessInputEventDispatcher.dispatch(
            delayPlans: delayPlans,
            budget: budget,
            send: { unitIndex, eventIndex in
                let event = unitIndex == 0 ? events[0] : events[eventIndex + 1]
                try self.sendPointerEvent(
                    event,
                    deviceIndex: resources.pointingDeviceIndex,
                    width: resources.width,
                    height: resources.height
                )
            }
        )
        return successPayload(
            operation: "click",
            width: resources.width,
            height: resources.height
        ).merging([
            "point": .object(["x": .number(x), "y": .number(y)]),
            "deliveredPoint": .object(["x": .number(clampedX), "y": .number(clampedY)])
        ]) { _, new in new }
    }

    func sendKey(name: String, timeout: TimeInterval) async throws -> [String: JSONValue] {
        guard let key = HostDisplayKey.lookup(name) else {
            throw RunnerError.invalidUICommand("Unsupported direct VM key: \(name)")
        }
        let dimensions = try await dispatchKeyPlan(
            [key.inputEventPlan],
            timeout: timeout,
            operation: "key"
        )
        return successPayload(
            operation: "key",
            width: dimensions.width,
            height: dimensions.height
        ).merging(["key": .string(name)]) { _, new in new }
    }

    func sendKeySequence(
        names: [String],
        timeout: TimeInterval
    ) async throws -> [String: JSONValue] {
        guard !names.isEmpty else {
            throw RunnerError.invalidUICommand("A direct VM key sequence may not be empty.")
        }
        let keys = try names.map { name -> HostDisplayKey in
            guard let key = HostDisplayKey.lookup(name) else {
                throw RunnerError.invalidUICommand("Unsupported direct VM key: \(name)")
            }
            return key
        }
        let dimensions = try await dispatchKeyPlan(
            keys.map(\.inputEventPlan),
            timeout: timeout,
            operation: "key-sequence"
        )
        return successPayload(
            operation: "key-sequence",
            width: dimensions.width,
            height: dimensions.height
        ).merging([
            "keys": .array(names.map(JSONValue.string)),
            "count": .integer(Int64(names.count))
        ]) { _, new in new }
    }

    func typeText(
        _ text: String,
        replace: Bool,
        timeout: TimeInterval
    ) async throws -> [String: JSONValue] {
        var plans: [[HostDisplayInputEvent]] = []
        if replace {
            guard let selectAll = HostDisplayKey.lookup("cmd-a") else {
                throw VirtualizationPrivateHeadlessError(
                    .inputUnavailable,
                    detail: "The Command-A input plan could not be constructed."
                )
            }
            plans.append(selectAll.inputEventPlan)
        }
        for character in text {
            if let key = HostDisplayKey.lookup(character: character) {
                plans.append(key.inputEventPlan)
            } else {
                plans.append(Self.unicodeEventPlan(String(character)))
            }
        }
        let dimensions = try await dispatchKeyPlan(
            plans,
            timeout: timeout,
            operation: "type"
        )
        return successPayload(
            operation: "type",
            width: dimensions.width,
            height: dimensions.height
        ).merging([
            "characters": .integer(Int64(text.count)),
            "replace": .bool(replace)
        ]) { _, new in new }
    }

    func inputReadinessToken() throws -> HeadlessInputReadinessToken {
        try VirtualizationPrivateABIPreflight.validateRuntime()
        let resources = try keyboardResources()
        return .init(
            virtualMachineIdentity: ObjectIdentifier(virtualMachine.value),
            keyboardIdentity: ObjectIdentifier(resources.keyboard),
            hostBuild: Self.hostBuild
        )
    }

    func awaitInputReadiness(timeout: TimeInterval) async throws -> HeadlessInputReadinessToken {
        guard timeout > 0 else {
            throw VirtualizationPrivateHeadlessError(
                .inputUnavailable,
                detail: "Direct VM input readiness requires a positive timeout."
            )
        }
        let deadline = Date().addingTimeInterval(timeout)
        var lastTransientError: VirtualizationPrivateHeadlessError?
        while true {
            try Task.checkCancellation()
            do {
                return try inputReadinessToken()
            } catch let error as VirtualizationPrivateHeadlessError
                where Self.isTransientInputReadinessFailure(error)
            {
                lastTransientError = error
            }
            guard Date() < deadline else {
                throw lastTransientError ?? VirtualizationPrivateHeadlessError(
                    .inputUnavailable,
                    detail: "The running VM did not publish direct input resources before the deadline."
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func requireInputReadiness(_ token: HeadlessInputReadinessToken) throws {
        try VirtualizationPrivateABIPreflight.validateRuntime()
        let resources = try keyboardResources()
        guard token.virtualMachineIdentity == ObjectIdentifier(virtualMachine.value),
              token.keyboardIdentity == ObjectIdentifier(resources.keyboard),
              token.hostBuild == Self.hostBuild
        else {
            throw VirtualizationPrivateHeadlessError(
                .inputUnavailable,
                detail: "The direct VM input readiness identity changed."
            )
        }
    }

    static func isTransientCaptureFailure(_ error: Error) -> Bool {
        guard let error = error as? VirtualizationPrivateHeadlessError else { return false }
        return error.code == .displayNotReady
            || error.code == .frameTimeout
            || error.code == .frameInvalid
    }

    /// Recovery navigation may legitimately observe a blank framebuffer while
    /// macOS changes boot surfaces. Keep this stricter than the legacy first
    /// normal-boot predicate: only an explicitly identified blank frame can be
    /// retried; malformed dimensions/decoding and private ABI failures fail
    /// closed immediately.
    static func isTransientRecoveryCaptureFailure(_ error: Error) -> Bool {
        guard let error = error as? VirtualizationPrivateHeadlessError else { return false }
        return error.code == .displayNotReady
            || error.code == .frameTimeout
            || (error.code == .frameInvalid && error.isBlankFrame)
    }

    static func isTransientInputReadinessFailure(_ error: Error) -> Bool {
        guard let error = error as? VirtualizationPrivateHeadlessError else { return false }
        return error.code == .displayNotReady || error.code == .inputUnavailable
    }

    static func selectPointingDeviceIndex(
        configuredClassNames: [String],
        runtimeClassNames: [String]
    ) -> UInt32? {
        guard let index = configuredClassNames.indices.first(where: {
            configuredClassNames[$0] == "VZUSBScreenCoordinatePointingDeviceConfiguration"
                && $0 < runtimeClassNames.count
                && runtimeClassNames[$0] == "_VZScreenCoordinatePointingDevice"
        }), index <= Int(UInt32.max) else { return nil }
        return UInt32(index)
    }

    static func validateFrame(
        _ image: CGImage,
        expectedWidth: Int = displayWidth,
        expectedHeight: Int = displayHeight
    ) throws {
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The framebuffer dimensions do not match the configured display."
            )
        }
        let sampleWidth = 64
        let sampleHeight = 40
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The framebuffer sample could not be decoded."
            )
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        var hasVisiblePixel = false
        var hasNonBlackPixel = false
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[offset + 3] != 0 { hasVisiblePixel = true }
            if pixels[offset] > 2 || pixels[offset + 1] > 2 || pixels[offset + 2] > 2 {
                hasNonBlackPixel = true
            }
            if hasVisiblePixel && hasNonBlackPixel { return }
        }
        throw VirtualizationPrivateHeadlessError(
            .frameInvalid,
            detail: "The framebuffer was blank.",
            isBlankFrame: true
        )
    }

    static func convertScreenshotObject(_ imageObject: AnyObject?) throws -> CGImage {
        guard let imageObject else {
            throw VirtualizationPrivateHeadlessError(
                .frameInvalid,
                detail: "The framebuffer callback returned no image."
            )
        }
        if let nsImage = imageObject as? NSImage,
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        let cfObject = imageObject as CFTypeRef
        if CFGetTypeID(cfObject) == CGImage.typeID {
            return cfObject as! CGImage
        }
        throw VirtualizationPrivateHeadlessError(
            .frameInvalid,
            detail: "The framebuffer callback returned an unsupported image object."
        )
    }

    static func guestPoint(
        cliX: Double,
        cliY: Double,
        width: Int,
        height: Int
    ) -> NSPoint {
        let x = max(0, min(Double(width - 1), cliX))
        let y = max(0, min(Double(height - 1), cliY))
        return NSPoint(x: x, y: Double(height) - y)
    }

    private func captureFrame(timeout: TimeInterval) async throws -> CGImage {
        try VirtualizationPrivateABIPreflight.validateRuntime()
        let resources = try captureResources()
        let requestID = try framebufferCaptureState.beginRequest()
        do {
            try ensureFramebufferObserver(display: resources.display)
            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            while Date() < deadline {
                try Task.checkCancellation()
                if let result = framebufferCaptureState.takeResult(requestID: requestID) {
                    let image = try result.get().value
                    try Self.validateFrame(
                        image,
                        expectedWidth: resources.width,
                        expectedHeight: resources.height
                    )
                    return image
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw VirtualizationPrivateHeadlessError(
                .frameTimeout,
                detail: "The private framebuffer observer did not publish a frame before the deadline."
            )
        } catch {
            framebufferCaptureState.cancel(requestID: requestID)
            throw error
        }
    }

    private func ensureFramebufferObserver(display: VZGraphicsDisplay) throws {
        try queue.sync {
            try requireRunning()
            let displayIdentity = ObjectIdentifier(display)
            if let framebufferObserver, observedDisplayIdentity == displayIdentity {
                // Registration publishes the framebuffer's last full update.
                // Re-arm it for each request so a static Recovery screen is
                // capturable even when no damage event follows the request.
                try HeadlessFramebufferObserverRuntime.setDisplay(
                    nil,
                    on: framebufferObserver.value
                )
                try HeadlessFramebufferObserverRuntime.setDisplay(
                    display,
                    on: framebufferObserver.value
                )
                return
            }
            if let framebufferObserver {
                try HeadlessFramebufferObserverRuntime.setDisplay(
                    nil,
                    on: framebufferObserver.value
                )
            }
            let observer = try HeadlessFramebufferObserverRuntime.make(
                state: framebufferCaptureState
            )
            try HeadlessFramebufferObserverRuntime.setDisplay(display, on: observer)
            framebufferObserver = QueueConfined(value: observer)
            observedDisplayIdentity = displayIdentity
        }
    }

    static func awaitCallback<Value: Sendable>(
        timeout: TimeInterval,
        start: @escaping (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let timeoutNanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
        let gate = HeadlessAutomationCallbackGate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.begin(continuation)
                guard !Task.isCancelled else {
                    gate.finish(.failure(CancellationError()))
                    return
                }
                start { gate.finish($0) }
                Task { [gate] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    gate.finish(.failure(VirtualizationPrivateHeadlessError(
                        .frameTimeout,
                        detail: "The framebuffer callback did not complete before the deadline."
                    )))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private func captureResources() throws -> CaptureResources {
        try queue.sync {
            try requireRunning()
            let device = virtualMachine.value.graphicsDevices.first
            let display = device?.displays.first
            let width = display.map { Int($0.sizeInPixels.width.rounded()) }
            let height = display.map { Int($0.sizeInPixels.height.rounded()) }
            switch HeadlessDisplayResourceDisposition.classify(
                deviceClassName: device.map { NSStringFromClass(type(of: $0)) },
                displayClassName: display.map { NSStringFromClass(type(of: $0)) },
                width: width,
                height: height
            ) {
            case .notReady:
                throw VirtualizationPrivateHeadlessError(
                    .displayNotReady,
                    detail: "The running VM has not published its graphics display yet."
                )
            case .unavailable:
                throw VirtualizationPrivateHeadlessError(
                    .displayUnavailable,
                    detail: "The running VM display does not match the qualified Mac 1280x800 profile."
                )
            case .ready:
                guard let display, let width, let height else {
                    throw VirtualizationPrivateHeadlessError(
                        .displayUnavailable,
                        detail: "The validated VM display resources disappeared."
                    )
                }
                return .init(display: display, width: width, height: height)
            }
        }
    }

    private func keyboardResources() throws -> KeyboardResources {
        try queue.sync {
            try requireInputReady()
            let vmObject: AnyObject = virtualMachine.value
            guard let keyboards = Self.objectArray(vmObject, selectorName: "_keyboards"),
                  configuration.value.keyboards.map({ NSStringFromClass(type(of: $0)) })
                    == ["VZMacKeyboardConfiguration", "VZUSBKeyboardConfiguration"],
                  keyboards.count == configuration.value.keyboards.count,
                  let keyboard = keyboards.first,
                  NSStringFromClass(type(of: keyboard)) == "_VZKeyboard"
            else {
                throw VirtualizationPrivateHeadlessError(
                    .inputUnavailable,
                    detail: "The qualified virtual keyboard is unavailable."
                )
            }
            let dimensions = try inputDisplayDimensions()
            return .init(
                keyboard: keyboard,
                width: dimensions.width,
                height: dimensions.height
            )
        }
    }

    private func pointerResources() throws -> PointerResources {
        try queue.sync {
            try requireInputReady()
            let vmObject: AnyObject = virtualMachine.value
            guard let pointingDevices = Self.objectArray(
                vmObject,
                selectorName: "_pointingDevices"
            ) else {
                throw VirtualizationPrivateHeadlessError(
                    .inputUnavailable,
                    detail: "The VM pointing-device inventory is unavailable."
                )
            }
            let configuredClassNames = configuration.value.pointingDevices.map {
                NSStringFromClass(type(of: $0))
            }
            let runtimeClassNames = pointingDevices.map { NSStringFromClass(type(of: $0)) }
            guard configuredClassNames
                    == [
                        "VZMacTrackpadConfiguration",
                        "VZUSBScreenCoordinatePointingDeviceConfiguration"
                    ],
                  runtimeClassNames.count == configuredClassNames.count,
                  let pointingDeviceIndex = Self.selectPointingDeviceIndex(
                configuredClassNames: configuredClassNames,
                runtimeClassNames: runtimeClassNames
            ) else {
                throw VirtualizationPrivateHeadlessError(
                    .inputUnavailable,
                    detail: "The qualified USB screen-coordinate pointing device is unavailable."
                )
            }
            let dimensions = try inputDisplayDimensions()
            return .init(
                pointingDeviceIndex: pointingDeviceIndex,
                width: dimensions.width,
                height: dimensions.height
            )
        }
    }

    private func inputDisplayDimensions() throws -> (width: Int, height: Int) {
        let device = virtualMachine.value.graphicsDevices.first
        let display = device?.displays.first
        let width = display.map { Int($0.sizeInPixels.width.rounded()) }
        let height = display.map { Int($0.sizeInPixels.height.rounded()) }
        switch HeadlessDisplayResourceDisposition.classify(
            deviceClassName: device.map { NSStringFromClass(type(of: $0)) },
            displayClassName: display.map { NSStringFromClass(type(of: $0)) },
            width: width,
            height: height
        ) {
        case .notReady:
            throw VirtualizationPrivateHeadlessError(
                .displayNotReady,
                detail: "The running VM has not published its input display yet."
            )
        case .unavailable:
            throw VirtualizationPrivateHeadlessError(
                .displayUnavailable,
                detail: "The VM input display does not match the qualified Mac 1280x800 profile."
            )
        case .ready:
            guard let width, let height else {
                throw VirtualizationPrivateHeadlessError(
                    .displayUnavailable,
                    detail: "The validated VM input display disappeared."
                )
            }
            return (width, height)
        }
    }

    private func requireRunning() throws {
        guard virtualMachine.value.state == .running else {
            throw VirtualizationPrivateHeadlessError(
                .vmStateInvalid,
                detail: "Framebuffer and input SPI require a running VM."
            )
        }
    }

    private func requireInputReady() throws {
        try requireRunning()
        let selector = NSSelectorFromString("_shouldSendHIDReports")
        guard let method = class_getInstanceMethod(
            object_getClass(virtualMachine.value), selector
        ) else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The HID readiness selector disappeared after preflight."
            )
        }
        let function = unsafeBitCast(method_getImplementation(method), to: BoolGetterIMP.self)
        guard function(virtualMachine.value, selector) else {
            throw VirtualizationPrivateHeadlessError(
                .inputUnavailable,
                detail: "The running VM is not accepting HID reports."
            )
        }
    }

    private func dispatchKeyPlan(
        _ plans: [[HostDisplayInputEvent]],
        timeout: TimeInterval,
        operation: String
    ) async throws -> (width: Int, height: Int) {
        let budget = try HeadlessInputBudget(timeout: timeout, operation: operation)
        try budget.requireFullPlan(plans)
        try VirtualizationPrivateABIPreflight.validateRuntime()
        let resources = try keyboardResources()
        let eventChords = try plans.map { plan in
            try plan.map(Self.makeKeyEvent)
        }
        let delayPlans = plans.map { plan in
            plan.map { event in
                event.kind == .keyDown
                    ? HeadlessInputTiming.keyDownDwellNanoseconds
                    : HeadlessInputTiming.transitionGapNanoseconds
            }
        }
        _ = try await HeadlessInputEventDispatcher.dispatch(
            delayPlans: delayPlans,
            budget: budget,
            send: { chordIndex, eventIndex in
                let event = eventChords[chordIndex][eventIndex]
                try self.queue.sync {
                    try self.requireInputReady()
                    try Self.sendKeyEvent(event.object, to: resources.keyboard)
                }
            }
        )
        return (resources.width, resources.height)
    }

    private func sendPointerEvent(
        _ event: NSEvent,
        deviceIndex: UInt32,
        width: Int,
        height: Int
    ) throws {
        try queue.sync {
            try requireInputReady()
            try updatePointerCoordinateTransform(width: width, height: height)
            let selector = NSSelectorFromString("sendPointerNSEvent:pointingDeviceIndex:")
            guard let method = class_getInstanceMethod(
                object_getClass(virtualMachine.value), selector
            ) else {
                throw VirtualizationPrivateHeadlessError(
                    .privateABIMismatch,
                    detail: "The pointer selector disappeared after preflight."
                )
            }
            let function = unsafeBitCast(method_getImplementation(method), to: SendPointerIMP.self)
            function(virtualMachine.value, selector, event, deviceIndex)
        }
    }

    private func updatePointerCoordinateTransform(width: Int, height: Int) throws {
        let vmObject: AnyObject = virtualMachine.value
        let monitorSelector = NSSelectorFromString("_hidEventMonitor")
        guard let monitorMethod = class_getInstanceMethod(
            object_getClass(vmObject),
            monitorSelector
        ) else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The HID monitor selector disappeared after preflight."
            )
        }
        let getMonitor = unsafeBitCast(
            method_getImplementation(monitorMethod),
            to: ObjectGetterIMP.self
        )
        guard let monitor = getMonitor(vmObject, monitorSelector),
              let monitorClass = object_getClass(monitor),
              let filterIvar = class_getInstanceVariable(monitorClass, "_filter"),
              let translatorsIvar = class_getInstanceVariable(
                monitorClass,
                "_hasEventTranslators"
              ),
              let filter = object_getIvar(monitor, filterIvar) as AnyObject?
        else {
            throw VirtualizationPrivateHeadlessError(
                .inputUnavailable,
                detail: "The private HID coordinate filter is unavailable."
            )
        }
        let monitorPointer = Unmanaged.passUnretained(monitor).toOpaque()
        guard monitorPointer.advanced(by: ivar_getOffset(translatorsIvar))
                .load(as: UInt8.self) != 0
        else {
            throw VirtualizationPrivateHeadlessError(
                .inputUnavailable,
                detail: "The private HID event monitor is not ready for translated pointer reports."
            )
        }
        let updateSelector = NSSelectorFromString("updateCoordinateTransform:isFlipped:")
        guard let updateMethod = class_getInstanceMethod(
            object_getClass(filter),
            updateSelector
        ) else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The HID coordinate-transform selector disappeared after preflight."
            )
        }
        let update = unsafeBitCast(
            method_getImplementation(updateMethod),
            to: UpdatePointerTransformIMP.self
        )
        update(
            filter,
            updateSelector,
            CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            false
        )
    }

    private static func objectArray(
        _ receiver: AnyObject,
        selectorName: String
    ) -> [AnyObject]? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(object_getClass(receiver), selector) else {
            return nil
        }
        let function = unsafeBitCast(method_getImplementation(method), to: ObjectGetterIMP.self)
        guard let object = function(receiver, selector) else { return nil }
        return (object as? NSArray)?.compactMap { $0 as AnyObject }
    }

    private static func makeKeyEvent(_ input: HostDisplayInputEvent) throws -> PreparedKeyEvent {
        guard let event = NSEvent.keyEvent(
            with: input.kind.nsEventType,
            location: .zero,
            modifierFlags: input.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: input.characters,
            charactersIgnoringModifiers: input.charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: input.keyCode
        ) else {
            throw VirtualizationPrivateHeadlessError(
                .inputUnavailable,
                detail: "A direct keyboard event could not be constructed."
            )
        }
        guard let keyEventClass: AnyClass = NSClassFromString("_VZKeyEvent"),
              let allocated = class_createInstance(keyEventClass, 0),
              let method = class_getInstanceMethod(
                keyEventClass,
                NSSelectorFromString("initWithEvent:")
              )
        else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "A private keyboard event could not be allocated."
            )
        }
        let selector = NSSelectorFromString("initWithEvent:")
        let function = unsafeBitCast(method_getImplementation(method), to: KeyEventInitIMP.self)
        return .init(
            object: function(allocated as AnyObject, selector, event),
            kind: input.kind
        )
    }

    private static func sendKeyEvent(_ event: AnyObject, to keyboard: AnyObject) throws {
        let selector = NSSelectorFromString("sendKeyEvents:")
        guard let method = class_getInstanceMethod(object_getClass(keyboard), selector) else {
            throw VirtualizationPrivateHeadlessError(
                .privateABIMismatch,
                detail: "The keyboard-send selector disappeared after preflight."
            )
        }
        let function = unsafeBitCast(method_getImplementation(method), to: SendObjectsIMP.self)
        function(keyboard, selector, NSArray(object: event))
    }

    private static func unicodeEventPlan(_ text: String) -> [HostDisplayInputEvent] {
        [
            .init(
                kind: .keyDown,
                keyCode: 0,
                modifiers: [],
                characters: text,
                charactersIgnoringModifiers: text
            ),
            .init(
                kind: .keyUp,
                keyCode: 0,
                modifiers: [],
                characters: text,
                charactersIgnoringModifiers: text
            )
        ]
    }

    private func successPayload(
        operation: String,
        image: CGImage
    ) -> [String: JSONValue] {
        successPayload(operation: operation, width: image.width, height: image.height)
    }

    private func successPayload(
        operation: String,
        width: Int,
        height: Int
    ) -> [String: JSONValue] {
        [
            "ok": .bool(true),
            "schemaVersion": .integer(2),
            "operation": .string(operation),
            "backend": .string(Self.backendName),
            "hostBuild": .string(Self.hostBuild),
            "width": .integer(Int64(width)),
            "height": .integer(Int64(height))
        ]
    }
}
