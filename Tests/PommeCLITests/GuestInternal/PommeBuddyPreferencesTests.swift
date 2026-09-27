import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Guest Buddy preferences")
struct PommeBuddyPreferencesTests {
    @Test("Diagnostics establish owner validation before writes and redact output")
    func diagnostics() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.writeFailure = true; $0.writeError = "secret-token\nprivate content" }
        await PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies).run()
        let events = fixture.state.withLock { $0.diagnostics }
        let found = events.firstIndex { $0.event == "owner-found" }
        let write = events.firstIndex { $0.event == "command-launch" && $0.fields["operation"] == "write" }
        #expect(found != nil && write != nil && found! < write!)
        #expect(events.contains { $0.event == "owner-revalidated" && $0.fields["operation"] == "write" && $0.fields["uid"] == "501" })
        #expect(events.contains { $0.event == "command-result" && $0.fields["operation"] == "write" && $0.fields["stderr_class"] == "unknown-redacted" && $0.fields["exit_code"] == "9" })
        #expect(events.allSatisfy { !$0.message.contains("secret-token") && !$0.message.contains("private content") && $0.message.utf8.count < 2048 })
        #expect(events.allSatisfy { $0.fields["boot"] != nil && $0.fields["run_id"] != nil && $0.fields["daemon_pid"] != nil })
    }

    @Test("Waiting logs state changes and a bounded heartbeat")
    func waitingDiagnostics() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.absentQueries = 65; $0.absentHomes = 2 }
        await PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies).run()
        let waiting = fixture.state.withLock { $0.diagnostics.filter { $0.event == "owner-waiting" } }
        #expect(waiting.filter { $0.fields["state"] == "account-absent" }.count == 3)
        #expect(waiting.filter { $0.fields["state"] == "home-absent" }.count == 1)
    }

    @Test("Only exact bounded stderr messages are classified")
    func stderrClassification() {
        let classify: (String) -> String = {
            PommeBuddyPreferencesDiagnostic.stderrClassification($0, domain: "com.apple.SetupAssistant", key: "LastSeenBuddyBuildVersion")
        }
        #expect(classify("sudo: a password is required\n") == "sudo-password-required")
        #expect(classify("2026-09-27 12:00:00.123 defaults[123:456] Could not write domain com.apple.SetupAssistant; exiting") == "defaults-write-domain-failed")
        #expect(classify("Could not write domain private.domain; exiting") == "unknown-redacted")
        #expect(classify("sudo: a password is required\nsecret") == "unknown-redacted")
        #expect(classify(String(repeating: "secret", count: 1000)) == "unknown-redacted")
    }

    @Test("Account and home appearance are polled without a login dependency")
    func waitsForOwner() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.absentQueries = 2; $0.absentHomes = 1 }
        let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        await engine.run()
        let status = await engine.status()
        #expect(status?.outcome == "succeeded")
        #expect(status?.owner == BuddyFixture.owner)
        fixture.state.withLock {
            #expect($0.sleeps == 3)
            #expect($0.writes.count == 2)
            #expect($0.saved.contains { $0.stage == "waitingForOwner" && $0.owner == nil })
        }
    }

    @Test("Matching typed values do not write; the detected build replaces older builds")
    func matchingAndNewBuild() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.values = ["LastSeenBuddyBuildVersion": ("string", "26A999"), "MiniBuddyLaunch": ("boolean", "0")] }
        await PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies).run()
        #expect(fixture.state.withLock { $0.writes.isEmpty })
        fixture.state.withLock { $0.boot = UUID().uuidString; $0.build = "27B123" }
        let next = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        await next.run()
        #expect(await next.status()?.buildVersion == "27B123")
        #expect(fixture.state.withLock { $0.writes == ["LastSeenBuddyBuildVersion"] })
    }

    @Test("Malformed account identities fail before preference commands")
    func invalidIdentity() async {
        for owner in [
            PommeBuddyPreferencesOwner(account: "other", uid: 501, generatedUID: UUID().uuidString, homeDirectory: "/Users/pomme"),
            PommeBuddyPreferencesOwner(account: "pomme", uid: 0, generatedUID: UUID().uuidString, homeDirectory: "/Users/pomme"),
            PommeBuddyPreferencesOwner(account: "pomme", uid: 501, generatedUID: "invalid", homeDirectory: "/Users/pomme"),
            PommeBuddyPreferencesOwner(account: "pomme", uid: 501, generatedUID: UUID().uuidString, homeDirectory: "/tmp/pomme")
        ] {
            let fixture = BuddyFixture()
            fixture.state.withLock { $0.owner = owner }
            let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await engine.run()
            #expect(await engine.status()?.error?.code == "invalid-owner")
            #expect(fixture.state.withLock { $0.writes.isEmpty })
        }
    }

    @Test("Directory errors fail instead of polling")
    func directoryFailure() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.ownerError = true }
        let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        await engine.run()
        #expect(await engine.status()?.outcome == "failed")
        #expect(fixture.state.withLock { $0.sleeps == 0 && $0.writes.isEmpty })
    }

    @Test("Wrong types and malformed boolean values stop maintenance")
    func strictTypes() async {
        for value in [("string", "false"), ("boolean", "false"), ("integer", "0")] {
            let fixture = BuddyFixture()
            fixture.state.withLock {
                $0.values = ["LastSeenBuddyBuildVersion": ("string", "26A999"), "MiniBuddyLaunch": value]
            }
            let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await engine.run()
            #expect(await engine.status()?.outcome == "failed")
            #expect(fixture.state.withLock { $0.writes.isEmpty })
        }
    }

    @Test("Command failures and readback failures stop before the next key")
    func failedWrites() async {
        for corruptReadback in [false, true] {
            let fixture = BuddyFixture()
            fixture.state.withLock { $0.writeFailure = !corruptReadback; $0.corruptReadback = corruptReadback }
            let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await engine.run()
            #expect(await engine.status()?.outcome == "failed")
            #expect(await engine.status()?.error?.code == (corruptReadback ? "preference-readback-mismatch" : "preference-write-failed"))
            #expect(fixture.state.withLock { $0.writes == ["LastSeenBuddyBuildVersion"] })
        }
    }

    @Test("A completed or failed receipt prevents daemon restart writes")
    func restartDoesNotReplay() async {
        for fails in [false, true] {
            let fixture = BuddyFixture()
            fixture.state.withLock { $0.writeFailure = fails }
            let first = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await first.run()
            let commandCount = fixture.state.withLock { $0.commands.count }
            let second = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await second.run()
            let firstStatus = await first.status()
            let secondStatus = await second.status()
            #expect(firstStatus == secondStatus)
            #expect(fixture.state.withLock { $0.commands.count == commandCount })
        }
    }

    @Test("Interrupted attempts fail without replay; waiting receipts resume")
    func interruptedAttempt() async {
        for outcome in ["waiting", "running"] {
            let fixture = BuddyFixture()
            fixture.state.withLock {
                $0.receipt = .init(bootSessionUUID: $0.boot, productVersion: "27.0", buildVersion: $0.build,
                                  owner: outcome == "running" ? BuddyFixture.owner : nil,
                                  stage: outcome == "running" ? "maintainingBuild" : "waitingForOwner", outcome: outcome)
            }
            let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await engine.run()
            #expect(await engine.status()?.outcome == (outcome == "running" ? "failed" : "succeeded"))
            if outcome == "running" {
                #expect(await engine.status()?.error?.code == "interrupted-attempt")
                #expect(fixture.state.withLock { $0.commands.isEmpty })
            }
        }
    }

    @Test("Status alone does not initiate an attempt")
    func statusIsReadOnly() async throws {
        let fixture = BuddyFixture()
        let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        #expect(await engine.status() == nil)
        #expect(try await engine.statusPayload() == .object(["initializing": .bool(true)]))
        #expect(fixture.state.withLock { $0.commands.isEmpty && $0.saved.isEmpty })
    }

    @Test("Replacing an owner between preference commands fails closed")
    func ownerReplacement() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.replaceAfterWrite = true }
        let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        await engine.run()
        #expect(await engine.status()?.error?.code == "owner-changed")
        #expect(fixture.state.withLock { $0.writes.count == 1 })
    }

    @Test("Unrelated and extended missing-key messages are rejected")
    func missingDiagnostics() async {
        for message in ["The domain/default pair of (other, other) does not exist", "Domain com.apple.SetupAssistant does not exist\nextra", "permission does not exist"] {
            let fixture = BuddyFixture()
            fixture.state.withLock { $0.missingMessage = message }
            let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await engine.run()
            #expect(await engine.status()?.outcome == "failed")
            #expect(fixture.state.withLock { $0.writes.isEmpty })
        }
    }

    @Test("Malformed detected builds and nonempty write output are failures")
    func strictCommandResults() async {
        for malformedBuild in [false, true] {
            let fixture = BuddyFixture()
            fixture.state.withLock {
                if malformedBuild { $0.build = "not-a-build" } else { $0.writeOutput = "unexpected" }
            }
            let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
            await engine.run()
            #expect(await engine.status()?.outcome == "failed")
            #expect(await engine.status()?.error?.code == (malformedBuild ? "os-detection-failed" : "preference-write-failed"))
        }
    }

    @Test("Malformed terminal receipts fail without preference writes")
    func malformedReceipt() async {
        let fixture = BuddyFixture()
        fixture.state.withLock {
            $0.receipt = .init(bootSessionUUID: $0.boot, stage: "complete", outcome: "succeeded")
        }
        let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        await engine.run()
        #expect(await engine.status()?.error?.code == "invalid-receipt")
        #expect(fixture.state.withLock { $0.commands.isEmpty })
    }

    @Test("An undurable running receipt prevents preference commands")
    func receiptFailure() async {
        let fixture = BuddyFixture()
        fixture.state.withLock { $0.failRunningSave = true }
        let engine = PommeBuddyPreferencesMaintenance(dependencies: fixture.dependencies)
        await engine.run()
        #expect(await engine.status()?.outcome == "failed")
        #expect(fixture.state.withLock { $0.writes.isEmpty })
    }
}

@Suite("Buddy native command runner")
struct PommeBuddyPreferencesCommandTests {
    @Test("Native diagnostics identify the spawned launcher without output content")
    func nativeDiagnostics() async throws {
        let events = Mutex<[PommeBuddyPreferencesDiagnostic]>([])
        let command = try #require(PommeBuddyPreferencesDependencies.live.instrumentedCommand)
        let result = try await command("/bin/sh", ["-c", "printf 'secret'; exit 7"], { event in
            events.withLock { $0.append(event) }
        })
        #expect(result.status == 7)
        events.withLock {
            #expect($0.map(\.event) == ["command-spawned", "command-reaped"])
            #expect($0.first?.fields["launcher_pid"] == $0.last?.fields["launcher_pid"])
            #expect(Int32($0.first?.fields["launcher_pid"] ?? "") ?? 0 > 1)
            #expect($0.last?.fields["exit_code"] == "7")
            #expect($0.last?.fields["stdout_bytes"] == "6")
            #expect($0.allSatisfy { !$0.message.contains("secret") })
        }
    }

    @Test("Captures stdout, stderr, and a nonzero exit separately")
    func capturesOutput() async throws {
        let result = try await PommeBuddyPreferencesDependencies.live.command(
            "/bin/sh", ["-c", "printf 'standard output'; printf 'standard error' >&2; exit 7"])
        #expect(result.stdout == "standard output")
        #expect(result.stderr == "standard error")
        #expect(result.status == 7)
    }

    @Test("A signal exit is rejected")
    func rejectsSignal() async {
        do {
            _ = try await PommeBuddyPreferencesDependencies.live.command(
                "/bin/sh", ["-c", "kill -TERM $$"])
            Issue.record("Expected a signal failure")
        } catch let failure as PommeBuddyPreferencesFailure {
            #expect(failure.code == "command-signal")
            #expect(failure.numericCode == Int(SIGTERM))
        } catch {
            Issue.record("Unexpected runner error: \(error)")
        }
    }

    @Test("An output limit stops an unbounded producer")
    func limitsOutput() async {
        let start = ContinuousClock.now
        do {
            _ = try await PommeBuddyPreferencesDependencies.live.command(
                "/bin/sh", ["-c", "while :; do printf '0123456789012345678901234567890123456789012345678901234567890123456789'; done"])
            Issue.record("Expected an output limit failure")
        } catch let failure as PommeBuddyPreferencesFailure {
            #expect(failure.code == "command-output-limit")
        } catch {
            Issue.record("Unexpected runner error: \(error)")
        }
        #expect(start.duration(to: .now) < .seconds(10))
    }

    @Test("The timeout kills the shell and its child process group")
    func timeoutKillsProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-buddy-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let record = directory.appendingPathComponent("processes")
        defer {
            try? FileManager.default.removeItem(at: record)
            try? FileManager.default.removeItem(at: directory)
        }
        let start = ContinuousClock.now
        do {
            _ = try await PommeBuddyPreferencesDependencies.live.command(
                "/bin/sh", ["-c", "/bin/sleep 60 & child=$!; printf '%s %s' \"$$\" \"$child\" > \"$1\"; wait", "buddy-test", record.path])
            Issue.record("Expected a timeout failure")
        } catch let failure as PommeBuddyPreferencesFailure {
            #expect(failure.code == "command-timeout")
        }
        #expect(start.duration(to: .now) < .seconds(20))
        let pids = try String(contentsOf: record, encoding: .utf8)
            .split(separator: " ").compactMap { Int32($0) }
        try #require(pids.count == 2 && pids.allSatisfy { $0 > 1 })
        // launchd may need a moment to reap the orphaned sleep after the group kill.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pids.contains(where: { kill($0, 0) == 0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for pid in pids {
            let result = kill(pid, 0)
            #expect(result == -1 && errno == ESRCH)
            // Contain a regression to these exact fixture processes.
            if result == 0 { _ = kill(pid, SIGKILL) }
        }
    }
}

private final class BuddyFixture: Sendable {
    static let owner = PommeBuddyPreferencesOwner(account: "pomme", uid: 501,
                                                 generatedUID: "08E1A855-1082-48D6-943D-6834E28BE2BD", homeDirectory: "/Users/pomme")
    struct State {
        var boot = "D1B4455D-1492-4C85-A233-E6E18D6AB852"
        var build = "26A999"
        var owner = BuddyFixture.owner
        var absentQueries = 0
        var absentHomes = 0
        var ownerError = false
        var writeFailure = false
        var writeError = "failure"
        var diagnostics: [PommeBuddyPreferencesDiagnostic] = []
        var corruptReadback = false
        var replaceAfterWrite = false
        var failRunningSave = false
        var missingMessage: String?
        var writeOutput = ""
        var sleeps = 0
        var values: [String: (String, String)] = [:]
        var writes: [String] = []
        var commands: [[String]] = []
        var receipt: PommeBuddyPreferencesStatus?
        var saved: [PommeBuddyPreferencesStatus] = []
    }
    let state = Mutex(State())

    var dependencies: PommeBuddyPreferencesDependencies {
        .init(bootSessionUUID: { self.state.withLock { $0.boot } }, owner: {
            try self.state.withLock {
                if $0.ownerError { throw PommeBuddyPreferencesFailure(code: "directory-query", numericCode: 7) }
                if $0.absentQueries > 0 { $0.absentQueries -= 1; return nil }
                return $0.owner
            }
        }, homeExists: { _ in self.state.withLock {
            if $0.absentHomes > 0 { $0.absentHomes -= 1; return false }
            return true
        } }, command: { path, args in
            self.state.withLock { state in
                state.commands.append([path] + args)
                if path == "/usr/bin/sw_vers" {
                    return .init(status: 0, stdout: args == ["-buildVersion"] ? state.build : "27.0", stderr: "")
                }
                #expect(path == "/usr/bin/sudo")
                #expect(Array(args.prefix(5)) == ["-n", "-H", "-u", "pomme", "/usr/bin/defaults"])
                let operation = args[5], key = args[7]
                if operation == "write" {
                    #expect(state.receipt?.outcome == "running")
                    state.writes.append(key)
                    if state.writeFailure { return .init(status: 9, stdout: "", stderr: state.writeError) }
                    state.values[key] = (args[8] == "-bool" ? "boolean" : "string", state.corruptReadback ? "26A888" : (args[8] == "-bool" ? "0" : args[9]))
                    if state.replaceAfterWrite { state.owner.generatedUID = UUID().uuidString }
                    return .init(status: 0, stdout: state.writeOutput, stderr: "")
                }
                guard let value = state.values[key] else {
                    return .init(status: 1, stdout: "", stderr: state.missingMessage ?? "The domain/default pair of (\(args[6]), \(key)) does not exist")
                }
                return .init(status: 0, stdout: operation == "read-type" ? "Type is \(value.0)\n" : value.1 + "\n", stderr: "")
            }
        }, load: { self.state.withLock { $0.receipt } }, save: { receipt in
            try self.state.withLock {
                if $0.failRunningSave && receipt.outcome == "running" { throw PommeBuddyPreferencesFailure(code: "receipt-save", numericCode: 5) }
                $0.receipt = receipt
                $0.saved.append(receipt)
            }
        }, sleep: { self.state.withLock { $0.sleeps += 1 } },
           diagnostic: { event in self.state.withLock { $0.diagnostics.append(event) } },
           uptime: { self.state.withLock { Double($0.sleeps * 2) } })
    }
}
