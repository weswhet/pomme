import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Keystore initializer maintenance")
struct PommeKeystoreInitMaintenanceTests {
    private static let boot = "11111111-1111-1111-1111-111111111111"
    private static let vmDisk = UInt32(MNT_LOCAL)

    private final class Recorder: Sendable {
        let saved = Mutex<[PommeKeystoreInitStatus]>([])
        let runs = Mutex(0)
    }

    private func engine(
        recorder: Recorder,
        major: Int = 27,
        flags: UInt32 = vmDisk,
        enforced: Int32? = 0,
        previous: PommeKeystoreInitStatus? = nil,
        exit: Int32 = 0,
        initializeError: (any Error)? = nil,
        saveError: (any Error)? = nil
    ) -> PommeKeystoreInitMaintenance {
        .init(dependencies: .init(
            bootSessionUUID: { Self.boot },
            majorVersion: { major },
            rootMountFlags: { flags },
            launchConstraintsEnforced: { enforced },
            initialize: {
                recorder.runs.withLock { $0 += 1 }
                if let initializeError { throw initializeError }
                return exit
            },
            load: { previous },
            save: { status in
                if let saveError { throw saveError }
                recorder.saved.withLock { $0.append(status) }
            },
            log: { _, _ in }
        ))
    }

    @Test("A macOS 27 VM disk with launch constraints off runs the initializer once")
    func runsOnAffectedGuest() async throws {
        let recorder = Recorder()
        let maintenance = engine(recorder: recorder)
        await maintenance.run()
        await maintenance.run()
        #expect(recorder.runs.withLock { $0 } == 1)
        #expect(recorder.saved.withLock { $0.map(\.outcome) } == ["running", "succeeded"])
        #expect(await maintenance.status() == .init(bootSessionUUID: Self.boot, outcome: "succeeded", exitStatus: 0))
        let payload = try await maintenance.statusPayload()
        #expect(payload.objectValue?["outcome"] == .string("succeeded"))
    }

    @Test("Guests launchd already serves, or SIP blocks, are skipped without running",
          arguments: [
            (26, UInt32(MNT_LOCAL), Int32?(0), "unaffected-os"),
            (27, UInt32(MNT_LOCAL | MNT_REMOVABLE), Int32?(0), "boot-volume-external"),
            (27, UInt32(0), Int32?(0), "boot-volume-external"),
            (27, UInt32(MNT_LOCAL), Int32?(1), "launch-constraints-enforced"),
          ])
    func skipsUnaffectedGuests(major: Int, flags: UInt32, enforced: Int32?, reason: String) async {
        let recorder = Recorder()
        let maintenance = engine(recorder: recorder, major: major, flags: flags, enforced: enforced)
        await maintenance.run()
        #expect(recorder.runs.withLock { $0 } == 0)
        #expect(await maintenance.status() == .init(bootSessionUUID: Self.boot, outcome: "skipped", reason: reason))
    }

    @Test("An unreadable launch-constraint sysctl doesn't stop the initializer")
    func missingSysctlStillRuns() async {
        let recorder = Recorder()
        await engine(recorder: recorder, enforced: nil).run()
        #expect(recorder.runs.withLock { $0 } == 1)
    }

    @Test("A nonzero exit or a spawn failure is recorded as failed")
    func failures() async {
        let exited = Recorder()
        let nonzero = engine(recorder: exited, exit: 9)
        await nonzero.run()
        #expect(await nonzero.status() == .init(bootSessionUUID: Self.boot, outcome: "failed",
                                                reason: "exit-status", exitStatus: 9))
        let spawned = Recorder()
        let timedOut = engine(recorder: spawned,
                              initializeError: PommeBuddyPreferencesFailure(code: "command-timeout", numericCode: nil))
        await timedOut.run()
        #expect(await timedOut.status() == .init(bootSessionUUID: Self.boot, outcome: "failed", reason: "command-timeout"))
    }

    @Test("A receipt from this boot is reused, and an interrupted run is never repeated")
    func sameBootReceipt() async {
        let finished = Recorder()
        let done = PommeKeystoreInitStatus(bootSessionUUID: Self.boot, outcome: "succeeded", exitStatus: 0)
        let reused = engine(recorder: finished, previous: done)
        await reused.run()
        #expect(finished.runs.withLock { $0 } == 0)
        #expect(await reused.status() == done)

        let interrupted = Recorder()
        let running = engine(recorder: interrupted,
                             previous: .init(bootSessionUUID: Self.boot, outcome: "running"))
        await running.run()
        #expect(interrupted.runs.withLock { $0 } == 0)
        #expect(await running.status() == .init(bootSessionUUID: Self.boot, outcome: "failed", reason: "interrupted-attempt"))
        #expect(interrupted.saved.withLock { $0.map(\.reason) } == ["interrupted-attempt"])
    }

    @Test("A receipt from an earlier boot doesn't stop this boot's run")
    func earlierBootReceipt() async {
        let recorder = Recorder()
        let previous = PommeKeystoreInitStatus(bootSessionUUID: "22222222-2222-2222-2222-222222222222", outcome: "succeeded")
        await engine(recorder: recorder, previous: previous).run()
        #expect(recorder.runs.withLock { $0 } == 1)
    }

    @Test("The initializer doesn't run unless its running receipt is durable")
    func receiptMustPrecedeRun() async {
        let recorder = Recorder()
        let maintenance = engine(recorder: recorder,
                                 saveError: PommeBuddyPreferencesFailure(code: "receipt-commit", numericCode: 5))
        await maintenance.run()
        #expect(recorder.runs.withLock { $0 } == 0)
        #expect(await maintenance.status()?.reason == "receipt-commit")
    }

    @Test("The agent serves the receipt only from the persistent role")
    func statusOperation() async throws {
        let token = String(repeating: "a", count: 64)
        let request = PommeAgentProtocol.Envelope.request(operation: PommeAgent.keystoreInitStatusOperation)
        let pending = try PommeAgent(role: .persistent, executableSHA256: token)
        #expect(try await pending.performAsynchronously(request) == .object(["initializing": .bool(true)]))
        let recorder = Recorder()
        let maintenance = engine(recorder: recorder)
        await maintenance.run()
        let agent = try PommeAgent(role: .persistent, executableSHA256: token, keystoreInit: maintenance)
        #expect(try await agent.performAsynchronously(request).objectValue?["outcome"] == .string("succeeded"))
        await #expect(throws: PommeAgentOperationError.self) {
            try await agent.performAsynchronously(.request(operation: PommeAgent.keystoreInitStatusOperation,
                                                           payload: .object(["run": .bool(true)])))
        }
        let recovery = try PommeAgent(role: .recovery, executableSHA256: token)
        await #expect(throws: PommeAgentOperationError.self) { try await recovery.performAsynchronously(request) }
        #expect(PommeAgent.persistentCapabilities.contains(PommeAgent.keystoreInitStatusOperation))
        #expect(!PommeAgent.recoveryCapabilities.contains(PommeAgent.keystoreInitStatusOperation))
        #expect(PommeAgentDaemon.startKeystoreInit(role: .recovery, maintenance: maintenance) == nil)
    }

    @Test("The host maps receipts to push-identity states")
    func hostReport() {
        #expect(PommeKeystoreInitReport(.object(["initializing": .bool(true)])).state == "pending")
        #expect(PommeKeystoreInitReport(.object(["bootSessionUUID": .string(Self.boot), "outcome": .string("succeeded"),
                                                 "exitStatus": .number(0)])).state == "prepared")
        let skipped = PommeKeystoreInitReport(.object(["bootSessionUUID": .string(Self.boot), "outcome": .string("skipped"),
                                                       "reason": .string("launch-constraints-enforced")]))
        #expect(skipped == .init(state: "skipped", reason: "launch-constraints-enforced"))
        #expect(skipped.summary == "was skipped because SIP is enabled")
        let unsafe = PommeKeystoreInitReport(.object(["bootSessionUUID": .string(Self.boot), "outcome": .string("failed"),
                                                      "reason": .string("$(rm -rf /)")]))
        #expect(unsafe == .init(state: "failed", reason: nil))
        #expect(PommeKeystoreInitReport(.object(["outcome": .string("other")])).state == "unavailable")
        #expect(PommeKeystoreInitReport(.string("x")).state == "unavailable")
    }
}
