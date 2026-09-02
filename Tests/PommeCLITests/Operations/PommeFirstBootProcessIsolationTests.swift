import Darwin
import Foundation
import Testing

@Suite("Pomme first normal boot process isolation", .serialized)
struct PommeFirstBootProcessIsolationTests {
    @Test("child grammar is exact and round trips immutable identity")
    func childGrammarRoundTrip() throws {
        try withBundle { bundle in
            let request = try makeRequest(bundle: bundle)

            #expect(
                try PommeFirstBootProcessRequest.parseChildArguments(
                    request.childArguments
                ) == request
            )
            #expect(
                try PommeFirstBootProcessRequest.parseChildArguments(
                    request.childArguments(role: .supervisor)
                ) == request
            )
            #expect(
                try PommeFirstBootProcessRequest.parseChildArguments(
                    ["create", "example"]
                ) == nil
            )
            #expect(throws: PommeFirstBootProcessError.invalidRequest) {
                _ = try PommeFirstBootProcessRequest.parseChildArguments(
                    request.childArguments + ["--unexpected"]
                )
            }
        }
    }

    @Test("receipt accepts only a matching closed success shape")
    func closedReceipt() throws {
        try withBundle { bundle in
            let request = try makeRequest(bundle: bundle)
            let receipt = PommeFirstBootProcessReceipt.success(
                request: request,
                barrier: .init(
                    setupAssistantSurfaceProven: true,
                    stableObservationCount: 2,
                    reconstructionCount: 1,
                    stoppedStateProven: true
                )
            )
            let encoded = try #require(receipt.encodedLine())

            #expect(
                PommeFirstBootProcessReceipt.decodeClosed(
                    encoded,
                    matching: request
                ) == receipt
            )

            let otherRequest = try PommeFirstBootProcessRequest(
                bundlePath: request.bundlePath,
                vmName: request.vmName,
                vmUUID: request.vmUUID,
                executableSHA256: request.executableSHA256,
                bundleIdentity: request.bundleIdentity,
                nonce: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                timeout: request.timeout
            )
            #expect(
                PommeFirstBootProcessReceipt.decodeClosed(
                    encoded,
                    matching: otherRequest
                ) == nil
            )

            var duplicate = Data(#"{"nonce":"11111111-1111-4111-8111-111111111111","#.utf8)
            duplicate.append(encoded.dropFirst())
            #expect(
                PommeFirstBootProcessReceipt.decodeClosed(
                    duplicate,
                    matching: request
                ) == nil
            )
        }
    }

    @Test("bundle identity binds name, canonical path, device, and inode")
    func bundleIdentity() throws {
        try withBundle { bundle in
            let first = try PommeFirstBootProcessIsolation.makeBundleIdentity(
                bundlePath: bundle.path,
                name: "process-isolation-test"
            )
            let second = try PommeFirstBootProcessIsolation.makeBundleIdentity(
                bundlePath: bundle.path,
                name: "process-isolation-test"
            )
            let differentName = try PommeFirstBootProcessIsolation.makeBundleIdentity(
                bundlePath: bundle.path,
                name: "process-isolation-other"
            )

            #expect(first == second)
            #expect(first != differentName)
            #expect(first.count == 64)

            let link = bundle.deletingLastPathComponent()
                .appendingPathComponent("bundle-link-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: bundle
            )
            defer { try? FileManager.default.removeItem(at: link) }
            #expect(throws: PommeFirstBootProcessError.identityRejected) {
                _ = try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: link.path,
                    name: "process-isolation-test"
                )
            }
        }
    }

    @Test("child refuses execution without the inherited mutation capability")
    func missingCapability() async throws {
        try await withBundle { bundle in
            let request = try makeRequest(bundle: bundle)
            let exitCode = await PommeFirstBootProcessIsolation.runChild(
                request: request
            ) {
                Issue.record("operation must not run without the inherited lease")
                return .init(
                    setupAssistantSurfaceProven: true,
                    stableObservationCount: 2,
                    reconstructionCount: 0,
                    stoppedStateProven: true
                )
            }
            #expect(exitCode == 64)
        }
    }

    @Test("inherited mutation capability must own the active flock")
    func activeLeaseOwnership() throws {
        let name = "process-lease-\(UUID().uuidString.lowercased())"
        let path = try VMBundleMutationLease.persistentLockPath(name: name)
        let unlocked = open(
            path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        #expect(unlocked >= 0)
        defer { if unlocked >= 0 { close(unlocked) } }
        #expect(fchmod(unlocked, 0o600) == 0)
        #expect(VMBundleMutationLease.isHeld(descriptor: unlocked, for: name))
        #expect(
            !VMBundleMutationLease.isActivelyHeld(
                descriptor: unlocked,
                for: name
            )
        )

        let lease = try VMBundleMutationLease.acquire(name: name)
        defer { lease.release() }
        let inherited = try lease.duplicateDescriptor()
        defer { close(inherited) }
        #expect(
            VMBundleMutationLease.isActivelyHeld(
                descriptor: inherited,
                for: name
            )
        )
    }

    @Test("parent transfers only fixed capabilities and exactly reaps a worker")
    func processBoundaryRoundTrip() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("isolated-worker")
            let fixture = #"""
            #!/bin/sh
            if [ ! -e /dev/fd/198 ] || [ ! -e /dev/fd/199 ] || [ ! -e /dev/fd/200 ] || [ ! -e /dev/fd/201 ]; then
              exit 70
            fi
            printf '{"bundleIdentity":"%s","executableSHA256":"%s","nonce":"%s","operation":"pomme-first-normal-boot","outcome":"success","reconstructionCount":0,"schemaVersion":1,"setupAssistantSurfaceProven":true,"stableObservationCount":2,"stoppedStateProven":true,"vmUUID":"%s"}\n' "${11}" "${9}" "${13}" "${7}" >&200
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let executableSHA256 = try PommeFirstBootProcessIsolation.executableDigest(
                at: executable
            )
            let vmName = "process-isolation-\(UUID().uuidString.lowercased())"
            let bundleIdentity = try PommeFirstBootProcessIsolation.makeBundleIdentity(
                bundlePath: bundle.path,
                name: vmName
            )
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "33333333-3333-4333-8333-333333333333",
                executableSHA256: executableSHA256,
                bundleIdentity: bundleIdentity,
                nonce: "44444444-4444-4444-8444-444444444444",
                timeout: 1
            )

            let receipt = try await VMBundleMutationLease.withLease(
                name: request.vmName
            ) { lease in
                try await PommeFirstBootProcessIsolation.run(
                    request: request,
                    lease: lease,
                    executableURL: executable
                )
            }

            #expect(receipt.outcome == .success)
            #expect(receipt.stableObservationCount == 2)
            #expect(receipt.stoppedStateProven)
        }
    }

    @Test("a reaped leader cannot leave a descendant or result writer behind")
    func descendantAfterLeaderExitIsContained() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("escaping-worker")
            let fixture = #"""
            #!/bin/sh
            printf '%s\n' "$(ps -o pgid= -p $$ | tr -d '[:space:]')" > "${3}/supervisor.pgid"
            sleep 30 200>&- &
            printf '%s\n' "$!" > "${3}/descendant.pid"
            printf '{"bundleIdentity":"%s","executableSHA256":"%s","nonce":"%s","operation":"pomme-first-normal-boot","outcome":"success","reconstructionCount":0,"schemaVersion":1,"setupAssistantSurfaceProven":true,"stableObservationCount":2,"stoppedStateProven":true,"vmUUID":"%s"}\n' "${11}" "${9}" "${13}" "${7}" >&200
            exit 0
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let vmName = "process-descendant-\(UUID().uuidString.lowercased())"
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "77777777-7777-4777-8777-777777777777",
                executableSHA256: try PommeFirstBootProcessIsolation.executableDigest(
                    at: executable
                ),
                bundleIdentity: try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: bundle.path,
                    name: vmName
                ),
                nonce: "88888888-8888-4888-8888-888888888888",
                timeout: 1
            )

            await #expect(throws: PommeFirstBootProcessError.containmentFailed) {
                _ = try await VMBundleMutationLease.withLease(
                    name: request.vmName
                ) { lease in
                    try await PommeFirstBootProcessIsolation.run(
                        request: request,
                        lease: lease,
                        executableURL: executable,
                        isolationTimeout: 1,
                        terminationGrace: 0.05
                    )
                }
            }

            let pidData = try Data(
                contentsOf: bundle.appendingPathComponent("supervisor.pgid")
            )
            let rawPID = try #require(String(data: pidData, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supervisorPGID = try #require(pid_t(rawPID))
            var groupGone = false
            for _ in 0..<500 {
                if processGroupIsAbsent(supervisorPGID) {
                    groupGone = true
                    break
                }
                usleep(10_000)
            }
            #expect(groupGone)
        }
    }

    @Test("a descendant-held result writer is bounded and group-contained")
    func descendantHeldResultWriterIsBounded() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("retained-result-writer")
            let fixture = #"""
            #!/bin/sh
            printf '%s\n' "$(ps -o pgid= -p $$ | tr -d '[:space:]')" > "${3}/supervisor.pgid"
            sleep 30 &
            printf '{"bundleIdentity":"%s","executableSHA256":"%s","nonce":"%s","operation":"pomme-first-normal-boot","outcome":"success","reconstructionCount":0,"schemaVersion":1,"setupAssistantSurfaceProven":true,"stableObservationCount":2,"stoppedStateProven":true,"vmUUID":"%s"}\n' "${11}" "${9}" "${13}" "${7}" >&200
            exit 0
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let vmName = "process-result-writer-\(UUID().uuidString.lowercased())"
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                executableSHA256: try PommeFirstBootProcessIsolation.executableDigest(
                    at: executable
                ),
                bundleIdentity: try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: bundle.path,
                    name: vmName
                ),
                nonce: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                timeout: 1
            )

            let started = ProcessInfo.processInfo.systemUptime
            await #expect(throws: PommeFirstBootProcessError.processTimedOut) {
                _ = try await VMBundleMutationLease.withLease(
                    name: request.vmName
                ) { lease in
                    try await PommeFirstBootProcessIsolation.run(
                        request: request,
                        lease: lease,
                        executableURL: executable,
                        isolationTimeout: 0.2,
                        terminationGrace: 0.05
                    )
                }
            }
            #expect(ProcessInfo.processInfo.systemUptime - started < 6)

            let pidData = try Data(
                contentsOf: bundle.appendingPathComponent("supervisor.pgid")
            )
            let rawPID = try #require(String(data: pidData, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supervisorPGID = try #require(pid_t(rawPID))
            #expect(processGroupIsAbsent(supervisorPGID))
        }
    }

    @Test("a liveness byte followed by EOF is contained and the supervisor group is reaped")
    func livenessProtocolViolationIsContained() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("invalid-liveness")
            let fixture = #"""
            #!/bin/sh
            printf '%s\n' "$(ps -o pgid= -p $$ | tr -d '[:space:]')" > "${3}/supervisor.pgid"
            printf 'x' >&201
            exec 201>&-
            printf '{"bundleIdentity":"%s","executableSHA256":"%s","nonce":"%s","operation":"pomme-first-normal-boot","outcome":"success","reconstructionCount":0,"schemaVersion":1,"setupAssistantSurfaceProven":true,"stableObservationCount":2,"stoppedStateProven":true,"vmUUID":"%s"}\n' "${11}" "${9}" "${13}" "${7}" >&200
            exit 0
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let vmName = "process-invalid-liveness-\(UUID().uuidString.lowercased())"
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                executableSHA256: try PommeFirstBootProcessIsolation.executableDigest(
                    at: executable
                ),
                bundleIdentity: try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: bundle.path,
                    name: vmName
                ),
                nonce: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                timeout: 1
            )

            await #expect(throws: PommeFirstBootProcessError.containmentFailed) {
                _ = try await VMBundleMutationLease.withLease(
                    name: request.vmName
                ) { lease in
                    try await PommeFirstBootProcessIsolation.run(
                        request: request,
                        lease: lease,
                        executableURL: executable,
                        isolationTimeout: 1,
                        terminationGrace: 0.05
                    )
                }
            }

            let pgidData = try Data(
                contentsOf: bundle.appendingPathComponent("supervisor.pgid")
            )
            let rawPGID = try #require(String(data: pgidData, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supervisorPGID = try #require(pid_t(rawPGID))
            #expect(processGroupIsAbsent(supervisorPGID))
        }
    }

    @Test("a continuously flooded liveness pipe is byte bounded and contained")
    func livenessProtocolFloodIsContained() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("flooded-liveness")
            let fixture = #"""
            #!/bin/sh
            printf '%s\n' "$(ps -o pgid= -p $$ | tr -d '[:space:]')" > "${3}/supervisor.pgid"
            while :; do printf 'x' >&201; done
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let vmName = "process-flooded-liveness-\(UUID().uuidString.lowercased())"
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
                executableSHA256: try PommeFirstBootProcessIsolation.executableDigest(
                    at: executable
                ),
                bundleIdentity: try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: bundle.path,
                    name: vmName
                ),
                nonce: "12121212-1212-4121-8121-121212121212",
                timeout: 1
            )

            let started = ProcessInfo.processInfo.systemUptime
            await #expect(throws: PommeFirstBootProcessError.processTimedOut) {
                _ = try await VMBundleMutationLease.withLease(
                    name: request.vmName
                ) { lease in
                    try await PommeFirstBootProcessIsolation.run(
                        request: request,
                        lease: lease,
                        executableURL: executable,
                        isolationTimeout: 0.2,
                        terminationGrace: 0.05
                    )
                }
            }
            #expect(ProcessInfo.processInfo.systemUptime - started < 6)

            let pgidData = try Data(
                contentsOf: bundle.appendingPathComponent("supervisor.pgid")
            )
            let rawPGID = try #require(String(data: pgidData, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supervisorPGID = try #require(pid_t(rawPGID))
            #expect(processGroupIsAbsent(supervisorPGID))
        }
    }

    @Test("abrupt parent cancellation closes liveness and contains the supervisor group")
    func cancellationContainsSupervisorGroup() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("cancelled-supervisor")
            let fixture = #"""
            #!/bin/sh
            printf '%s\n' "$(ps -o pgid= -p $$ | tr -d '[:space:]')" > "${3}/supervisor.pgid"
            trap '' TERM
            while :; do sleep 1; done
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let vmName = "process-cancel-\(UUID().uuidString.lowercased())"
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "99999999-9999-4999-8999-999999999999",
                executableSHA256: try PommeFirstBootProcessIsolation.executableDigest(
                    at: executable
                ),
                bundleIdentity: try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: bundle.path,
                    name: vmName
                ),
                nonce: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                timeout: 1
            )

            let task = Task {
                try await VMBundleMutationLease.withLease(
                    name: request.vmName
                ) { lease in
                    try await PommeFirstBootProcessIsolation.run(
                        request: request,
                        lease: lease,
                        executableURL: executable,
                        isolationTimeout: 10,
                        terminationGrace: 0.05
                    )
                }
            }
            let pidURL = bundle.appendingPathComponent("supervisor.pgid")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: pidURL.path))
            task.cancel()
            await #expect(throws: PommeFirstBootProcessError.processCancelled) {
                _ = try await task.value
            }

            let pidData = try Data(contentsOf: pidURL)
            let rawPID = try #require(String(data: pidData, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supervisorPGID = try #require(pid_t(rawPID))
            #expect(processGroupIsAbsent(supervisorPGID))
        }
    }

    @Test("timed-out worker group is terminated and the exact child is reaped")
    func timedOutWorkerIsContained() async throws {
        try await withBundle { bundle in
            let executable = bundle.appendingPathComponent("hanging-worker")
            let fixture = #"""
            #!/bin/sh
            printf '%s\n' "$(ps -o pgid= -p $$ | tr -d '[:space:]')" > "${3}/supervisor.pgid"
            trap '' TERM
            while :; do sleep 1; done
            """#
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(fixture.utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let vmName = "process-timeout-\(UUID().uuidString.lowercased())"
            let request = try PommeFirstBootProcessRequest(
                bundlePath: bundle.path,
                vmName: vmName,
                vmUUID: "55555555-5555-4555-8555-555555555555",
                executableSHA256: try PommeFirstBootProcessIsolation.executableDigest(
                    at: executable
                ),
                bundleIdentity: try PommeFirstBootProcessIsolation.makeBundleIdentity(
                    bundlePath: bundle.path,
                    name: vmName
                ),
                nonce: "66666666-6666-4666-8666-666666666666",
                timeout: 1
            )

            await #expect(throws: PommeFirstBootProcessError.processTimedOut) {
                _ = try await VMBundleMutationLease.withLease(
                    name: request.vmName
                ) { lease in
                    try await PommeFirstBootProcessIsolation.run(
                        request: request,
                        lease: lease,
                        executableURL: executable,
                        isolationTimeout: 1,
                        terminationGrace: 0.05
                    )
                }
            }

            let pidData = try Data(
                contentsOf: bundle.appendingPathComponent("supervisor.pgid")
            )
            let rawPID = try #require(String(data: pidData, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supervisorPGID = try #require(pid_t(rawPID))
            var groupGone = false
            for _ in 0..<500 {
                if processGroupIsAbsent(supervisorPGID) {
                    groupGone = true
                    break
                }
                usleep(10_000)
            }
            #expect(groupGone)
        }
    }

    @Test("process failures expose only stable redacted provisioning codes")
    func diagnosticCode() {
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeFirstBootProcessError.processTimedOut
            ) == "first_boot_process.timed_out"
        )
        #expect(
            PommeProvisioningFailureDiagnostic.code(
                for: PommeFirstBootProcessError.processCancelled
            ) == "first_boot_process.cancelled"
        )
    }

    private func makeRequest(bundle: URL) throws -> PommeFirstBootProcessRequest {
        let identity = try PommeFirstBootProcessIsolation.makeBundleIdentity(
            bundlePath: bundle.path,
            name: "process-isolation-test"
        )
        return try .init(
            bundlePath: bundle.path,
            vmName: "process-isolation-test",
            vmUUID: "11111111-1111-4111-8111-111111111111",
            executableSHA256: String(repeating: "a", count: 64),
            bundleIdentity: identity,
            nonce: "22222222-2222-4222-8222-222222222222",
            timeout: 30
        )
    }

    /// Capture `errno` immediately: Swift Testing's expression instrumentation
    /// may perform work between a `kill` call and a separately expanded errno
    /// comparison.
    private func processGroupIsAbsent(_ processGroup: pid_t) -> Bool {
        let probe = processGroupProbe(processGroup)
        return probe.result == -1 && probe.error == ESRCH
    }

    private func processGroupProbe(_ processGroup: pid_t) -> (result: Int32, error: Int32) {
        errno = 0
        let result = kill(-processGroup, 0)
        let error = errno
        return (result, error)
    }

    private func withBundle<T>(
        _ operation: (URL) throws -> T
    ) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-first-boot-process-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: url) }
        return try operation(url)
    }

    private func withBundle<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-first-boot-process-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: url) }
        return try await operation(url)
    }
}
