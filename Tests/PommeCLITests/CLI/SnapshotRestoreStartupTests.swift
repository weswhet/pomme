import Foundation
import Testing

@Suite("Named snapshot restore startup")
struct SnapshotRestoreStartupTests {
    @Test("Transient control status is tolerated until VZ restore is paused in normal mode")
    func transientStatusEventuallyReachesPausedNormal() throws {
        var statuses: [[String: Any]] = [
            ["vmState": "notRunning", "bootMode": "normal", "helperRunning": true],
            ["vmState": "starting", "bootMode": "normal", "helperRunning": true],
            ["vmState": "paused", "bootMode": "normal", "helperRunning": true]
        ]
        let clock = SnapshotRestoreStartupClock()

        let terminal = try PommeCore.waitForRequiredSnapshotRestorePausedNormal(
            helperPID: 4242,
            timeout: 1,
            helperIsRunning: { true },
            pollStatus: { statuses.removeFirst() },
            now: { clock.now },
            sleep: { interval in clock.advance(interval) }
        )

        #expect(terminal["vmState"] as? String == "paused")
        #expect(terminal["bootMode"] as? String == BootMode.normal.rawValue)
        #expect(statuses.isEmpty)
    }

    @Test("A wrong final state fails closed when the bounded wait expires")
    func wrongFinalStateTimesOut() {
        let clock = SnapshotRestoreStartupClock()

        do {
            _ = try PommeCore.waitForRequiredSnapshotRestorePausedNormal(
                helperPID: 4242,
                timeout: 0.5,
                pollInterval: 0.25,
                helperIsRunning: { true },
                pollStatus: { ["vmState": "paused", "bootMode": "recovery", "helperRunning": true] },
                now: { clock.now },
                sleep: { interval in clock.advance(interval) }
            )
            Issue.record("Expected the wrong boot mode to fail closed.")
        } catch let error as PommeCore.RequiredSnapshotRestoreStartupError {
            guard case let .timedOut(pid, lastObservation) = error else {
                Issue.record("Expected a timeout, got \(error.localizedDescription)")
                return
            }
            #expect(pid == 4242)
            #expect(lastObservation.contains("vmState=paused"))
            #expect(lastObservation.contains("bootMode=recovery"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Helper exit during restore fails without waiting for the timeout")
    func helperExitFailsImmediately() {
        do {
            _ = try PommeCore.waitForRequiredSnapshotRestorePausedNormal(
                helperPID: 4242,
                timeout: 30,
                helperIsRunning: { false },
                pollStatus: { ["vmState": "paused", "bootMode": "normal"] }
            )
            Issue.record("Expected a stopped helper to fail closed.")
        } catch let error as PommeCore.RequiredSnapshotRestoreStartupError {
            guard case let .helperExited(pid, lastObservation) = error else {
                Issue.record("Expected helper-exited, got \(error.localizedDescription)")
                return
            }
            #expect(pid == 4242)
            #expect(lastObservation == "no control status received")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private final class SnapshotRestoreStartupClock {
    private var value = Date(timeIntervalSince1970: 0)

    var now: Date { value }

    func advance(_ interval: TimeInterval) {
        value = value.addingTimeInterval(interval)
    }
}
