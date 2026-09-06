import Darwin
import Foundation
import Testing

@Suite("Pomme private PTY runner")
struct PommePrivatePTYRunnerTests: Sendable {
    private let jobID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let startRequestID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    @Test("delivers initial prompt output and sends the secret only afterward")
    func initialPromptGatesPrivateInput() async throws {
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("Password:".utf8))]
            ),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("ready".utf8))]
                ),
                .init(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    streamFrames: [frame(stream: .exit)]
                )
            ]
        )
        let collector = FrameCollector()
        let validation = ValidationRecorder()

        let result = try await PommePrivatePTYRunner.run(
            command: .sysadminctlSecureTokenOn(owner: "owner"),
            secret: "pw",
            promptTimeout: 1,
            processTimeout: 2,
            transport: .init(
                perform: { operation, payload in
                    try await transport.perform(operation: operation, payload: payload)
                },
                sendStream: { jobID, stream, data, signal in
                    try await transport.sendStream(jobID: jobID, stream: stream, data: data, signal: signal)
                },
                validateSession: {
                    await validation.mark()
                }
            ),
            onFrames: { values in
                await collector.append(values)
            }
        )

        #expect(await validation.wasCalled)
        #expect(result.result.objectValue?["promptSatisfied"] == .bool(true))
        #expect(result.result.objectValue?["exited"] == .bool(true))
        #expect(await collector.frames.contains { $0.frame.data == Data("Password:".utf8) })
        #expect(await transport.streamCalls.map(\.stream) == [.stdin])
        #expect(await transport.streamCalls.first?.data == Data("pw\n".utf8))
        #expect(await transport.operations == ["process.start", "process.status", "process.status"])
        let payload = await transport.startPayload
        #expect(payload?.objectValue?["pty"] == .bool(true))
        #expect(payload?.objectValue?["detached"] == .bool(false))
        #expect(payload?.objectValue?["stdinDataBase64"] == nil)
        let encoded = try JSONEncoder().encode(payload)
        #expect(String(decoding: encoded, as: UTF8.self).contains("pw") == false)
    }

    @Test("constructs a closed Setup Assistant asuser autologin command")
    func setupAssistantAutologinCommandShape() {
        let direct = PommePrivatePTYRunner.Command.sysadminctlAutologin(owner: "pomme")
        #expect(direct.path == "/usr/sbin/sysadminctl")
        #expect(direct.autologinOwner == "pomme")
        #expect(direct.autologinSetupAssistantUserID == nil)

        let wrapped = PommePrivatePTYRunner.Command.sysadminctlAutologin(
            owner: "pomme", setupAssistantUserID: 248)
        #expect(wrapped.path == "/bin/launchctl")
        #expect(wrapped.arguments == [
            "asuser", "248", "/usr/sbin/sysadminctl",
            "-adminUser", "pomme", "-adminPassword", "-",
            "-autologin", "set", "-userName", "pomme", "-password", "-",
        ])
        #expect(wrapped.autologinOwner == "pomme")
        #expect(wrapped.autologinSetupAssistantUserID == 248)
        #expect(wrapped.isSysadminctlAutologin)
    }

    @Test("rejects malformed launchctl autologin forms before secret delivery")
    func malformedSetupAssistantAutologinFailsBeforeSecretProvider() async throws {
        let native = [
            "-adminUser", "pomme", "-adminPassword", "-",
            "-autologin", "set", "-userName", "pomme", "-password", "-",
        ]
        let invalidCommands: [PommePrivatePTYRunner.Command] = [
            .init(path: "/bin/launchctl", arguments: ["bsexec", "248", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["asuser", "0", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["asuser", "249", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["asuser", "0248", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["asuser", "-248", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["bsexec", "0", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["bsexec", "042", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["bsexec", "-42", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["bsexec", "42", "/usr/sbin/sysadminctl"] + native + ["extra"]),
            .init(path: "/bin/launchctl", arguments: ["bsexec", "42", "/usr/bin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: [
                "bsexec", "42", "/usr/sbin/sysadminctl",
                "-adminUser", "pomme", "-adminPassword", "-",
                "-autologin", "set", "-userName", "other", "-password", "-",
            ]),
            .init(path: "/bin/launchctl", arguments: [
                "bsexec", "42", "/usr/sbin/sysadminctl",
                "-adminUser", "pomme", "-adminPassword", "literal-value",
                "-autologin", "set", "-userName", "pomme", "-password", "-",
            ]),
            .init(path: "/usr/bin/sysadminctl", arguments: native),
            .init(path: "/usr/bin/launchctl", arguments: ["bsexec", "42", "/usr/sbin/sysadminctl"] + native),
            .init(path: "/bin/launchctl", arguments: ["asuser", "42", "/usr/sbin/sysadminctl"] + native),
            .sysadminctlAutologin(owner: "pomme", setupAssistantUserID: 249),
        ]

        for command in invalidCommands {
            let transport = PrivatePTYTransport(
                start: .init(requestID: startRequestID, result: started(), streamFrames: []),
                statuses: []
            )
            let provider = SecretProviderRecorder(value: "pw")
            do {
                _ = try await PommePrivatePTYRunner.run(
                    command: command,
                    secretProvider: { await provider.next() },
                    prompt: .sysadminctlPassword(for: "pomme"),
                    promptTimeout: 1,
                    processTimeout: 2,
                    transport: transport.transport()
                )
                Issue.record("Expected malformed wrapper to be rejected.")
            } catch let error as PommePrivatePTYRunner.Error {
                #expect(error == .invalidCommand)
            } catch {
                Issue.record("Unexpected wrapper validation error: \(error)")
            }
            #expect(await provider.calls == 0)
            #expect(await transport.operations.isEmpty)
        }
    }

    @Test("does not send input before a later prompt frame")
    func delayedPromptGatesInput() async throws {
        let transport = PrivatePTYTransport(
            start: .init(requestID: startRequestID, result: started(), streamFrames: []),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("Password:".utf8))]
                ),
                .init(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    streamFrames: [frame(stream: .exit)]
                )
            ]
        )

        _ = try await PommePrivatePTYRunner.run(
            command: .init(path: "/usr/sbin/sysadminctl", arguments: ["-password", "-"]),
            secret: "pw",
            promptTimeout: 1,
            processTimeout: 2,
            transport: transport.transport()
        )

        #expect(await transport.streamCalls.map(\.stream) == [.stdin])
        #expect(await transport.operations == ["process.start", "process.status", "process.status"])
    }

    @Test("owner-bound sysadminctl prompt accepts only the requested account")
    func ownerBoundPrompt() async throws {
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("Enter password for owner :".utf8))]
            ),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    streamFrames: [frame(stream: .exit)]
                )
            ]
        )

        _ = try await PommePrivatePTYRunner.run(
            command: .sysadminctlSecureTokenOn(owner: "owner"),
            secret: "pw",
            prompt: .sysadminctlPassword(for: "owner"),
            promptTimeout: 1,
            processTimeout: 2,
            transport: transport.transport()
        )
        #expect(await transport.streamCalls.map(\.stream) == [.stdin])
        #expect(await transport.streamCalls.first?.data == Data("pw\n".utf8))
    }

    @Test("autologin reuses one secret for two split exact-owner prompts")
    func autologinUsesOneSecretForTwoPrompts() async throws {
        let owner = "pomme"
        let command = PommePrivatePTYRunner.Command.sysadminctlAutologin(
            owner: owner, setupAssistantUserID: 248)
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [
                    frame(stream: .stdout, data: Data("User pass".utf8)),
                    frame(stream: .stdout, data: Data("word:".utf8))
                ]
            ),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("Enter password for pomme ".utf8))]
                ),
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data(":".utf8))]
                ),
                .init(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    streamFrames: [frame(stream: .exit)]
                )
            ]
        )
        let provider = SecretProviderRecorder(value: "pw")

        _ = try await PommePrivatePTYRunner.run(
            command: command,
            secretProvider: { await provider.next() },
            prompt: .sysadminctlPassword(for: owner),
            promptTimeout: 1,
            processTimeout: 2,
            transport: transport.transport()
        )

        #expect(await provider.calls == 1)
        #expect(await transport.streamCalls.map(\.stream) == [.stdin, .stdin])
        #expect(await transport.streamCalls.map(\.data) == [Data("pw\n".utf8), Data("pw\n".utf8)])
        let payload = await transport.startPayload
        #expect(payload?.objectValue?["path"] == .string("/bin/launchctl"))
        #expect(command.autologinSetupAssistantUserID == 248)
        let encoded = try JSONEncoder().encode(payload)
        #expect(String(decoding: encoded, as: UTF8.self).contains("pw") == false)
    }

    @Test("default sysadminctl policy still rejects a second prompt")
    func defaultPromptPolicyRemainsSingleUse() async throws {
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("User password:".utf8))]
            ),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("Enter password for owner :".utf8))]
                )
            ]
        )
        await transport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlSecureTokenOn(owner: "owner"),
                secret: "pw",
                prompt: .sysadminctlPassword(for: "owner"),
                promptTimeout: 1,
                processTimeout: 2,
                transport: transport.transport()
            )
            Issue.record("Expected the default one-prompt policy to reject the second prompt.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .repeatedPrompt)
            #expect(error.errorDescription?.contains("pw") == false)
        }
        #expect(await transport.streamCalls.map(\.stream) == [.stdin, .signal])
    }

    @Test("autologin rejects a third or mismatched-owner prompt")
    func autologinRejectsThirdOrMismatchedOwnerPrompt() async throws {
        let owner = "pomme"
        let thirdPromptTransport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("User password:".utf8))]
            ),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("Enter password for pomme :".utf8))]
                ),
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("Enter password for pomme :".utf8))]
                )
            ]
        )
        await thirdPromptTransport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlAutologin(owner: owner),
                secret: "pw",
                prompt: .sysadminctlPassword(for: owner),
                promptTimeout: 1,
                processTimeout: 2,
                transport: thirdPromptTransport.transport()
            )
            Issue.record("Expected the third prompt to be rejected.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .repeatedPrompt)
            #expect(error.errorDescription?.contains("pw") == false)
        }
        #expect(await thirdPromptTransport.streamCalls.map(\.stream) == [.stdin, .stdin, .signal])

        let mismatchedTransport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("User password:".utf8))]
            ),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: false),
                    streamFrames: [frame(stream: .stdout, data: Data("Enter password for other :".utf8))]
                )
            ]
        )
        await mismatchedTransport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlAutologin(owner: owner),
                secret: "pw",
                prompt: .sysadminctlPassword(for: owner),
                promptTimeout: 1,
                processTimeout: 2,
                transport: mismatchedTransport.transport()
            )
            Issue.record("Expected a mismatched owner prompt to be rejected.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .unsafePrompt)
            #expect(error.errorDescription?.contains("pw") == false)
        }
        #expect(await mismatchedTransport.streamCalls.map(\.stream) == [.stdin, .signal])
    }

    @Test("cancellation cleans up a running private PTY")
    func cancellationCleansUp() async throws {
        let transport = PrivatePTYTransport(
            start: .init(requestID: startRequestID, result: started(), streamFrames: []),
            statuses: []
        )
        await transport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )
        let task = Task {
            do {
                _ = try await PommePrivatePTYRunner.run(
                    command: .sysadminctlSecureTokenOn(owner: "owner"),
                    secret: "pw",
                    promptTimeout: 5,
                    processTimeout: 5,
                    transport: transport.transport()
                )
                return PommePrivatePTYRunner.Error.invalidCompletion
            } catch let error as PommePrivatePTYRunner.Error {
                return error
            } catch {
                return PommePrivatePTYRunner.Error.transportFailure
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(await transport.streamCalls.map(\.stream) == [.signal])
    }

    @Test("does not mistake failed-password output for an interactive prompt")
    func failedPasswordTextDoesNotAuthorizeInput() async throws {
        let transport = PrivatePTYTransport(
            start: .init(requestID: startRequestID, result: started(), streamFrames: []),
            statuses: [
                .init(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 1),
                    streamFrames: [
                        frame(stream: .stdout, data: Data("Failed password:".utf8)),
                        frame(stream: .exit)
                    ]
                )
            ]
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlSecureTokenOn(owner: "owner"),
                secret: "pw",
                promptTimeout: 1,
                processTimeout: 2,
                transport: transport.transport()
            )
            Issue.record("Expected missing-prompt rejection.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .promptMissing)
        }
        #expect(await transport.streamCalls.isEmpty)
    }

    @Test("refuses an unsafe prompt and verifies cleanup")
    func unsafePromptTerminatesJob() async throws {
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("Username:".utf8))]
            ),
            statuses: []
        )
        await transport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlSecureTokenOn(owner: "owner"),
                secret: "pw",
                promptTimeout: 1,
                processTimeout: 2,
                transport: transport.transport()
            )
            Issue.record("Expected unsafe prompt rejection.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .unsafePrompt)
        }

        #expect(await transport.streamCalls.map(\.stream) == [.signal])
        #expect(await transport.streamCalls.first?.signal == SIGTERM)
        #expect(await transport.operations.contains("process.status"))
    }

    @Test("refuses an echoed secret before forwarding or retaining it")
    func echoedSecretIsRejected() async throws {
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(),
                streamFrames: [frame(stream: .stdout, data: Data("Password:".utf8))]
            ),
            statuses: []
        )
        await transport.setInputResult([
            frame(stream: .stdout, data: Data("pw".utf8))
        ])
        await transport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )
        let collector = FrameCollector()

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlSecureTokenOn(owner: "owner"),
                secret: "pw",
                promptTimeout: 1,
                processTimeout: 2,
                transport: transport.transport(),
                onFrames: { values in await collector.append(values) }
            )
            Issue.record("Expected echoed secret rejection.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .secretEchoed)
        }

        #expect(await collector.frames.contains { $0.frame.data == Data("Password:".utf8) })
        #expect(await collector.frames.contains { $0.frame.data == Data("pw".utf8) } == false)
        #expect(await transport.streamCalls.map(\.stream) == [.stdin, .signal])
    }

    @Test("times out waiting for a prompt and kills a job that ignores TERM")
    func promptTimeoutUsesBoundedCleanup() async throws {
        let transport = PrivatePTYTransport(
            start: .init(requestID: startRequestID, result: started(), streamFrames: []),
            statuses: []
        )
        await transport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 9),
                streamFrames: [frame(stream: .exit, signal: 9)]
            )
        )
        await transport.setIgnoreTerm(true)

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlSecureTokenOn(owner: "owner"),
                secret: "pw",
                promptTimeout: 0.03,
                processTimeout: 1,
                transport: transport.transport()
            )
            Issue.record("Expected prompt timeout.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .promptTimedOut)
        }

        #expect(await transport.streamCalls.map(\.stream) == [.signal, .signal])
        #expect(await transport.streamCalls.map(\.signal) == [SIGTERM, SIGKILL])
    }

    @Test("rejects a command that already contains the secret")
    func secretNeverEntersCommand() async throws {
        let transport = PrivatePTYTransport(
            start: .init(requestID: startRequestID, result: started(), streamFrames: []),
            statuses: []
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .init(path: "/bin/echo", arguments: ["pw"]),
                secret: "pw",
                transport: transport.transport()
            )
            Issue.record("Expected command secret rejection.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .secretInCommand)
        }
        #expect(await transport.operations.isEmpty)
        #expect(await transport.streamCalls.isEmpty)
    }

    @Test("refuses a PTY without an explicit echo-disabled proof")
    func echoProofIsRequiredBeforeInput() async throws {
        let transport = PrivatePTYTransport(
            start: .init(
                requestID: startRequestID,
                result: started(echoDisabled: false),
                streamFrames: []
            ),
            statuses: []
        )
        await transport.setCleanupResult(
            .init(
                requestID: UUID(),
                result: status(exited: true, signal: 15),
                streamFrames: [frame(stream: .exit, signal: 15)]
            )
        )

        do {
            _ = try await PommePrivatePTYRunner.run(
                command: .sysadminctlSecureTokenOn(owner: "owner"),
                secret: "pw",
                promptTimeout: 1,
                processTimeout: 2,
                transport: transport.transport()
            )
            Issue.record("Expected echo proof rejection.")
        } catch let error as PommePrivatePTYRunner.Error {
            #expect(error == .invalidCompletion)
        }
        #expect(await transport.streamCalls.map(\.stream) == [.signal])
        #expect(await transport.streamCalls.first?.data == nil)
    }

    private func started(echoDisabled: Bool = true) -> JSONValue {
        .object([
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(false),
            "ptyEchoDisabled": .bool(echoDisabled)
        ])
    }

    private func status(exited: Bool, exitCode: Int64? = nil, signal: Int64? = nil) -> JSONValue {
        var values: [String: JSONValue] = [
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(exited)
        ]
        if let exitCode { values["exitCode"] = .integer(exitCode) }
        if let signal { values["signal"] = .integer(signal) }
        return .object(values)
    }

    private func frame(
        stream: PommeAgentProtocol.Stream,
        data: Data? = nil,
        signal: Int32? = nil
    ) -> PommeAgentJobStreamFrame {
        try! .init(jobID: jobID, frame: .init(requestID: UUID(), stream: stream, data: data, signal: signal))
    }
}

private actor FrameCollector {
    private(set) var frames: [PommeAgentJobStreamFrame] = []

    func append(_ values: [PommeAgentJobStreamFrame]) { frames.append(contentsOf: values) }
}

private actor ValidationRecorder {
    private(set) var wasCalled = false

    func mark() { wasCalled = true }
}

private actor SecretProviderRecorder {
    private let value: String
    private(set) var calls = 0

    init(value: String) {
        self.value = value
    }

    func next() -> String {
        calls += 1
        return value
    }
}

private actor PrivatePTYTransport {
    struct StreamCall: Sendable {
        let jobID: UUID
        let stream: PommeAgentProtocol.Stream
        let data: Data?
        let signal: Int32?
    }

    let start: PommeAgentCorrelatedResult
    let statuses: [PommeAgentCorrelatedResult]
    private var statusIndex = 0
    private var inputResult: [PommeAgentJobStreamFrame] = []
    private var cleanupResult: PommeAgentCorrelatedResult?
    private var ignoreTerm = false
    private(set) var operations: [String] = []
    private(set) var streamCalls: [StreamCall] = []
    private(set) var startPayload: JSONValue?

    init(start: PommeAgentCorrelatedResult, statuses: [PommeAgentCorrelatedResult]) {
        self.start = start
        self.statuses = statuses
    }

    nonisolated func transport() -> PommePrivatePTYRunner.Transport {
        .init(
            perform: { operation, payload in
                try await self.perform(operation: operation, payload: payload)
            },
            sendStream: { jobID, stream, data, signal in
                try await self.sendStream(jobID: jobID, stream: stream, data: data, signal: signal)
            },
            validateSession: {}
        )
    }

    func perform(operation: String, payload: JSONValue) -> PommeAgentCorrelatedResult {
        operations.append(operation)
        switch operation {
        case "process.start":
            startPayload = payload
            return start
        case "process.status":
            if let cleanupResult, streamCalls.last?.stream == .signal {
                if ignoreTerm, streamCalls.last?.signal == SIGTERM {
                    // Keep reporting a live process until the runner sends
                    // SIGKILL; this verifies the escalation path.
                    return .init(
                        requestID: UUID(),
                        result: .object([
                            "jobID": .string(start.result.objectValue!["jobID"]!.stringValue!),
                            "pid": .integer(42),
                            "detached": .bool(false),
                            "exited": .bool(false)
                        ]),
                        streamFrames: []
                    )
                }
                return cleanupResult
            }
            if statusIndex < statuses.count {
                defer { statusIndex += 1 }
                return statuses[statusIndex]
            }
            return .init(
                requestID: UUID(),
                result: .object([
                    "jobID": .string(start.result.objectValue!["jobID"]!.stringValue!),
                    "pid": .integer(42),
                    "detached": .bool(false),
                    "exited": .bool(false)
                ]),
                streamFrames: []
            )
        default:
            return .init(requestID: UUID(), result: .object([:]), streamFrames: [])
        }
    }

    func sendStream(
        jobID: UUID,
        stream: PommeAgentProtocol.Stream,
        data: Data?,
        signal: Int32?
    ) -> [PommeAgentJobStreamFrame] {
        streamCalls.append(.init(jobID: jobID, stream: stream, data: data, signal: signal))
        switch stream {
        case .stdin: return inputResult
        case .signal: return []
        default: return []
        }
    }

    func setInputResult(_ frames: [PommeAgentJobStreamFrame]) { inputResult = frames }
    func setCleanupResult(_ result: PommeAgentCorrelatedResult) { cleanupResult = result }
    func setIgnoreTerm(_ value: Bool) { ignoreTerm = value }
}
