import Foundation
import Testing

@Suite("Pomme Recovery contained interaction")
struct PommeRecoveryContainedInteractionTests {
    @Test("The sensitive-frame gate is one-way and stores frames only in memory")
    func sensitiveGate() async {
        let gate = PommeRecoverySensitiveFrameGate()
        #expect(await gate.capture(Data([1, 2, 3])))
        let before = await gate.evidence()
        #expect(before.enabled)
        #expect(before.hasFrame)
        await gate.disableAndClear()
        #expect(!(await gate.capture(Data([4, 5, 6]))))
        let after = await gate.evidence()
        #expect(!after.enabled)
        #expect(!after.hasFrame)
    }

    @Test("Contained interaction disables capture before sensitive input")
    func sensitiveInputBoundary() async throws {
        let navigation = NavigationMock(observations: [
            .init(lines: ["Enter Password"]),
            .init(lines: ["Reinstall macOS"])
        ])
        let interaction = PommeRecoveryContainedInteraction(
            navigation: navigation,
            now: { Date(timeIntervalSince1970: 100) },
            sleep: { _ in }
        )
        let evidence = try await interaction.run(
            timeout: 10,
            secret: "temporary-secret"
        )
        #expect(evidence.sensitiveInputAccepted)
        #expect(evidence.captureDisabledBeforeSensitiveInput)
        #expect(evidence.contained)
        #expect(await navigation.typed == ["temporary-secret"])
    }

    @Test("Unknown Recovery surfaces receive no input")
    func unknownSurface() async throws {
        let navigation = NavigationMock(observations: [
            .init(lines: ["Unexpected Setup Surface"])
        ])
        let clock = AdvancingClock(Date(timeIntervalSince1970: 200))
        let interaction = PommeRecoveryContainedInteraction(
            navigation: navigation,
            now: {
                clock.advance(by: 20)
                return clock.value
            },
            sleep: { _ in }
        )
        await #expect(throws: PommeRecoverySessionError.invalidLifecycle) {
            try await interaction.run(timeout: 1)
        }
        #expect(await navigation.inputCount == 0)
    }
}

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var value: Date { lock.withLock { date } }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

private actor NavigationMock: PommeRecoveryNavigationPort {
    var observations: [PommeRecoveryScreenObservation]
    private(set) var typed: [String] = []
    private(set) var inputCount = 0

    init(observations: [PommeRecoveryScreenObservation]) {
        self.observations = observations
    }

    func observe() async throws -> PommeRecoveryScreenObservation {
        if observations.count > 1 { return observations.removeFirst() }
        return observations.first ?? .init(lines: [])
    }

    func click(target: String) async throws {
        inputCount += 1
    }

    func sendKey(_ key: String) async throws {
        inputCount += 1
    }

    func typeText(_ text: String) async throws {
        inputCount += 1
        typed.append(text)
    }
}
