import CoreGraphics
import Foundation
import Testing

@Suite("Pomme first normal boot barrier", .serialized)
struct PommeFirstBootBarrierTests {
    @Test("requires two stable OCR-qualified observations and proves cleanup")
    func qualifiedObservationAndCleanup() async throws {
        let qualified = observation(
            width: 1280,
            height: 800,
            lines: [line("Select your country or region"), line("Continue")]
        )
        let wrongGeometry = observation(
            width: 1024,
            height: 768,
            lines: [line("Select your country or region"), line("Continue")]
        )
        let harness = BarrierHarness(plans: [
            .init(
                start: .complete,
                observations: [.sample(qualified), .sample(wrongGeometry), .sample(qualified), .sample(qualified)]
            )
        ])
        let barrier = PommeFirstBootBarrier(
            dependencies: .init(
                makeAttempt: { await harness.makeAttempt() },
                sleep: { _ in await Task.yield() }
            )
        )

        let receipt = try await barrier.run(timeout: 1)

        #expect(receipt.setupAssistantSurfaceProven)
        #expect(receipt.stableObservationCount == 2)
        #expect(receipt.reconstructionCount == 0)
        #expect(receipt.stoppedStateProven)
        #expect(await harness.attemptCount == 1)
        #expect(await harness.startCount == 1)
        #expect(await harness.stopCount == 1)
        #expect(await harness.observationCount == 4)
    }

    @Test("geometry alone and Recovery text never qualify Setup Assistant")
    func OCRQualificationIsNotGeometryOnly() throws {
        let geometryOnly = PommeFirstBootObservation.fromOCR(
            width: 1280,
            height: 800,
            lines: [line("Continue"), line("English")]
        )
        let recoveryText = PommeFirstBootObservation.fromOCR(
            width: 1280,
            height: 800,
            lines: [
                line("macOS Recovery"),
                line("Select your country or region"),
                line("Continue")
            ]
        )
        let qualified = PommeFirstBootObservation.fromOCR(
            width: 1280,
            height: 800,
            lines: [line("Choose your country or region"), line("Continue")]
        )

        #expect(!geometryOnly.setupAssistantReady)
        #expect(!recoveryText.setupAssistantReady)
        #expect(qualified.setupAssistantReady)
    }

    @Test("initial Language/legal readiness is closed over reviewed anchors")
    func languageLegalQualification() {
        let qualified = PommeFirstBootObservation.fromOCR(
            width: 1280,
            height: 800,
            lines: [
                line("Language"),
                line("English (US)"),
                line("By using this software"),
                line("Software License Agreement"),
                line("https://www.apple.com/legal/sla/")
            ]
        )
        let urlMissedByOCR = PommeFirstBootObservation.fromOCR(
            width: 1280,
            height: 800,
            lines: [
                line("Language"), line("English"),
                line("By using this software"), line("license agreement")
            ]
        )
        let whitespaceWrappedURL = PommeFirstBootObservation.fromOCR(
            width: 1280,
            height: 800,
            lines: [
                line("Language"), line("English"),
                line("By using this software"), line("license agreement"),
                line("https : / / www . apple . com / legal / sla /"),
            ]
        )
        #expect(qualified.setupAssistantReady)
        #expect(urlMissedByOCR.setupAssistantReady)
        #expect(whitespaceWrappedURL.setupAssistantReady)

        let rejectedLines = [
            ["Language", "English"],
            ["Language", "English", "license agreement"],
            ["Language", "English", "By using this software"],
            ["Language", "English", "By using this software", "license agreement", "macOS Recovery"],
            ["Language", "English", "By using this software", "license agreement", "macOS Installer"],
            ["Language", "English", "By using this software", "license agreement", "macOS Installation"],
            ["Language", "English", "By using this software", "license agreement", "http://www.apple.com/legal/sla/"],
            ["Language", "English", "By using this software", "license agreement", "https://example.com/legal/sla/"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/other/"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla/extra"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com.evil.example/legal/sla/"],
            ["Language", "English", "By using this software", "license agreement", "evilhttps://www.apple.com/legal/sla/"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla?evil"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla#evil"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla:evil"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla,evil"],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla]evil"],
            ["Language", "English", "By using this software", "license agreement", #"https://www.apple.com/legal/sla\evil"#],
            ["Language", "English", "By using this software", "license agreement", "https://www.apple.com/legal/sla;evil"],
            ["Language", "English", "By using this software", "license agreement", "ftp://https://www.apple.com/legal/sla/"],
            ["Language", "English", "By using this software", "license agreement", "ftp://.https://www.apple.com/legal/sla/"],
            ["Language", "English", "By using this software", "license agreement", "ftp:///https://www.apple.com/legal/sla/"],
            [
                "Language", "English", "By using this software", "license agreement",
                "https://www.apple.com/legal/sla/", "https://example.com/legal/sla/",
            ],
            ["https://www.apple.com/legal/sla/"],
        ]
        for texts in rejectedLines {
            let observation = PommeFirstBootObservation.fromOCR(
                width: 1280,
                height: 800,
                lines: texts.map(line)
            )
            #expect(!observation.setupAssistantReady)
        }
    }

    @Test("country and Language/legal frames must stabilize independently")
    func distinctReadinessSurfacesDoNotCombine() async throws {
        let country = observation(
            width: 1280,
            height: 800,
            lines: [line("Select your country or region"), line("Continue")]
        )
        let language = observation(
            width: 1280,
            height: 800,
            lines: [
                line("Language"), line("English"),
                line("By using this software"), line("license agreement")
            ]
        )
        let harness = BarrierHarness(plans: [
            .init(
                start: .complete,
                observations: [.sample(country), .sample(language), .sample(country), .sample(country)]
            )
        ])
        let barrier = PommeFirstBootBarrier(
            dependencies: .init(
                makeAttempt: { await harness.makeAttempt() },
                sleep: { _ in await Task.yield() }
            )
        )

        let receipt = try await barrier.run(timeout: 1)

        #expect(receipt.setupAssistantSurfaceProven)
        #expect(receipt.stableObservationCount == 2)
        #expect(await harness.observationCount == 4)
    }

    @Test("a timed-out stopped start gets exactly one fresh reconstruction")
    func boundedReconstructionRetry() async throws {
        let qualified = observation(
            width: 1280,
            height: 800,
            lines: [line("Select your country or region"), line("Continue")]
        )
        let harness = BarrierHarness(plans: [
            .init(start: .timeout(stopped: true), observations: []),
            .init(start: .complete, observations: [.sample(qualified), .sample(qualified)])
        ])
        let barrier = PommeFirstBootBarrier(
            dependencies: .init(
                makeAttempt: { await harness.makeAttempt() },
                sleep: { _ in await Task.yield() }
            )
        )

        let receipt = try await barrier.run(timeout: 0.05)

        #expect(receipt.reconstructionCount == 1)
        #expect(receipt.stableObservationCount == 2)
        #expect(await harness.attemptCount == 2)
        #expect(await harness.startCount == 2)
        #expect(await harness.stopCount == 1)
    }

    @Test("observation timeout still reaps the running attempt")
    func observationTimeoutCleansUp() async {
        let harness = BarrierHarness(plans: [
            .init(
                start: .complete,
                observations: [.sample(.init(width: 1280, height: 800, setupAssistantCountryOrRegion: false))]
            )
        ])
        let barrier = PommeFirstBootBarrier(
            dependencies: .init(
                makeAttempt: { await harness.makeAttempt() },
                sleep: { _ in await Task.yield() }
            )
        )

        await #expect(throws: PommeFirstBootBarrierError.setupAssistantNotObserved) {
            _ = try await barrier.run(timeout: 0.05)
        }
        #expect(await harness.startCount == 1)
        #expect(await harness.stopCount == 1)
        #expect(await harness.state == .stopped)
    }

    @Test("cancellation cleans up without allowing a late start callback to continue")
    func cancellationAndLateCallback() async {
        let harness = BarrierHarness(plans: [
            .init(start: .never, observations: [])
        ])
        let barrier = PommeFirstBootBarrier(
            dependencies: .init(
                makeAttempt: { await harness.makeAttempt() },
                sleep: { _ in await Task.yield() }
            )
        )
        let task = Task {
            try await barrier.run(timeout: 1)
        }
        for _ in 0..<100 {
            if await harness.startCount > 0 { break }
            await Task.yield()
        }
        #expect(await harness.startCount == 1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await harness.stopCount == 1)
        #expect(await harness.state == .stopped)
    }

    @Test("start timeout policy rejects a transitioning VM and a second retry")
    func timeoutPolicyIsBounded() {
        #expect(
            PommeFirstBootStartTimeoutPolicy.action(
                state: .transitioning,
                retryCount: 0
            ) == .failClosed
        )
        #expect(
            PommeFirstBootStartTimeoutPolicy.action(
                state: .stopped,
                retryCount: 0
            ) == .reconstructRetry
        )
        #expect(
            PommeFirstBootStartTimeoutPolicy.action(
                state: .stopped,
                retryCount: 1
            ) == .failClosed
        )
    }

    private func line(_ text: String) -> SettingsAIOCRLine {
        .init(text: text, confidence: 0.99, rect: CGRect(x: 10, y: 10, width: 300, height: 24))
    }

    private func observation(
        width: Int,
        height: Int,
        lines: [SettingsAIOCRLine]
    ) -> PommeFirstBootObservation {
        .fromOCR(width: width, height: height, lines: lines)
    }
}

private actor BarrierHarness {
    enum Start: Sendable {
        case complete
        case never
        case timeout(stopped: Bool)
        case failure
    }

    enum Observation: Sendable {
        case sample(PommeFirstBootObservation)
        case unavailable
        case failure
    }

    struct Plan: Sendable {
        let start: Start
        let observations: [Observation]
    }

    private let plans: [Plan]
    private var nextPlan = 0
    private var currentStates: [Int: PommeFirstBootCleanupState] = [:]
    private var observationIndexes: [Int: Int] = [:]
    private(set) var attemptCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var observationCount = 0

    init(plans: [Plan]) {
        self.plans = plans
    }

    var state: PommeFirstBootCleanupState {
        currentStates[attemptCount - 1] ?? .stopped
    }

    func makeAttempt() -> PommeFirstBootAttempt {
        let index = nextPlan
        nextPlan += 1
        attemptCount += 1
        let plan = plans[min(index, plans.count - 1)]
        switch plan.start {
        case .complete:
            currentStates[index] = .stoppable
        case .never:
            currentStates[index] = .stoppable
        case .timeout(let stopped):
            currentStates[index] = stopped ? .stopped : .transitioning
        case .failure:
            currentStates[index] = .stopped
        }
        observationIndexes[index] = 0

        return .init(
            startNormal: { completion in
                Task {
                    await self.start(index: index, plan: plan.start, completion: completion)
                }
            },
            stopNormal: { completion in
                Task {
                    await self.stop(index: index, completion: completion)
                }
            },
            observe: {
                try await self.observe(index: index, plan: plan.observations)
            },
            cleanupState: {
                await self.currentStates[index] ?? .stopped
            }
        )
    }

    private func start(
        index: Int,
        plan: Start,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        startCount += 1
        switch plan {
        case .complete:
            currentStates[index] = .stoppable
            completion(nil)
        case .never:
            currentStates[index] = .stoppable
        case .timeout(let stopped):
            currentStates[index] = stopped ? .stopped : .transitioning
        case .failure:
            currentStates[index] = .stopped
            completion(TestLifecycleError.failed)
        }
    }

    private func stop(
        index: Int,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        stopCount += 1
        currentStates[index] = .stopped
        completion(nil)
    }

    private func observe(
        index: Int,
        plan: [Observation]
    ) throws -> PommeFirstBootObservation {
        observationCount += 1
        let offset = observationIndexes[index] ?? 0
        observationIndexes[index] = offset + 1
        let observation = plan.isEmpty ? nil : plan[min(offset, plan.count - 1)]
        switch observation {
        case .sample(let value):
            return value
        case .unavailable:
            throw PommeFirstBootObservationError.displayUnavailable
        case .failure:
            throw PommeFirstBootObservationError.recognitionFailed
        case nil:
            return .init(width: 1280, height: 800, setupAssistantCountryOrRegion: false)
        }
    }
}

private enum TestLifecycleError: Error, Sendable {
    case failed
}
