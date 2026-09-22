import Darwin
import Foundation

/// Runs one password-gated process through the authenticated guest-agent PTY
/// stream.  The command is started once, output is observed until an explicit
/// prompt appears, and the secret is sent only in a subsequent stream frame.
///
/// This type deliberately has no VM or control-socket dependency.  Callers
/// bind the transport closures to one already-authenticated agent session and
/// perform any role, protocol, and executable-digest checks before invoking
/// `run`.
enum PommePrivatePTYRunner {
    static let maximumTimeout: TimeInterval = 300
    static let defaultPromptTimeout: TimeInterval = 15
    static let defaultProcessTimeout: TimeInterval = 120
    static let cleanupTimeout: TimeInterval = 3
    static let maximumPromptTranscriptBytes = 64 * 1024
    static let maximumBufferedOutputBytes = 64 * 1024

    typealias Perform = @Sendable (String, JSONValue) async throws -> PommeAgentCorrelatedResult
    typealias SendStream = @Sendable (UUID, PommeAgentProtocol.Stream, Data?, Int32?) async throws -> [PommeAgentJobStreamFrame]
    typealias FrameHandler = @Sendable ([PommeAgentJobStreamFrame]) async throws -> Void
    typealias SecretProvider = @Sendable () async throws -> String
    typealias ValidateSession = @Sendable () async throws -> Void

    /// Closures in one transport must be bound to the same authenticated
    /// session.  A caller that needs a security pin supplies `validateSession`
    /// to check the captured session before process.start.
    struct Transport: Sendable {
        let perform: Perform
        let sendStream: SendStream
        let validateSession: ValidateSession

        init(
            perform: @escaping Perform,
            sendStream: @escaping SendStream,
            validateSession: @escaping ValidateSession
        ) {
            self.perform = perform
            self.sendStream = sendStream
            self.validateSession = validateSession
        }
    }

    struct Command: Equatable, Sendable {
        private static let allowedSetupAssistantUserID: UInt32 = 248

        let path: String
        let arguments: [String]

        init(path: String, arguments: [String] = []) {
            self.path = path
            self.arguments = arguments
        }

        /// The owner-preparation command used by SIP/AMFI workflows.  The
        /// password marker is an argument understood by sysadminctl; the
        /// password value itself is supplied later through the PTY stream.
        static func sysadminctlSecureTokenOn(owner: String) -> Self {
            .init(
                path: "/usr/sbin/sysadminctl",
                arguments: ["-secureTokenOn", owner, "-password", "-"]
            )
        }

        /// The only command form allowed to request two password prompts.
        /// Both prompts authenticate the same account: the explicit admin
        /// account and the autologin target must be identical, and both
        /// password values must be PTY markers (`-`).
        static func sysadminctlAutologin(owner: String) -> Self {
            .init(
                path: "/usr/sbin/sysadminctl",
                arguments: sysadminctlAutologinArguments(owner: owner)
            )
        }

        /// Runs the exact same native autologin command as the fixed Aqua
        /// Setup Assistant user. `asuser` changes the login-session context;
        /// the closed parser accepts only the known Setup Assistant UID 248.
        /// An arbitrary UID therefore remains an invalid command and is
        /// rejected before process.start or secret delivery.
        static func sysadminctlAutologin(owner: String, setupAssistantUserID: UInt32) -> Self {
            .init(
                path: "/bin/launchctl",
                arguments: [
                    "asuser", String(setupAssistantUserID), "/usr/sbin/sysadminctl",
                ] + sysadminctlAutologinArguments(owner: owner)
            )
        }

        var autologinOwner: String? {
            Self.parseAutologin(path: path, arguments: arguments)?.owner
        }

        /// Returns the fixed Setup Assistant UID only for the exact `asuser`
        /// invocation. Invalid, alternate, or direct forms intentionally
        /// return nil so callers cannot mistake an unverified process for the
        /// context anchor.
        var autologinSetupAssistantUserID: UInt32? {
            Self.parseAutologin(path: path, arguments: arguments)?.setupAssistantUserID
        }

        var isSysadminctlAutologin: Bool {
            if path.hasSuffix("/sysadminctl") {
                return arguments.contains("-autologin")
            }
            // Treat every launchctl/sysadminctl-shaped invocation as
            // autologin-like, even when malformed, so it fails closed before
            // a secret provider can be called. The exact parser above is the
            // only accepted wrapper form.
            if path == "/bin/launchctl" || path.hasSuffix("/launchctl") {
                return arguments.contains("/usr/sbin/sysadminctl")
                    || arguments.contains("-autologin")
            }
            return arguments.contains("/usr/sbin/sysadminctl")
                && arguments.contains("-autologin")
        }

        func maximumPromptCount(for prompt: Prompt) -> Int {
            guard let owner = autologinOwner,
                  prompt == .sysadminctlPassword(for: owner)
            else { return 1 }
            return 2
        }

        var startPayload: JSONValue {
            .object([
                "path": .string(path),
                "arguments": .array(arguments.map(JSONValue.string)),
                "pty": .bool(true),
                "detached": .bool(false)
            ])
        }

        private static func sysadminctlAutologinArguments(owner: String) -> [String] {
            [
                "-adminUser", owner, "-adminPassword", "-",
                "-autologin", "set", "-userName", owner, "-password", "-"
            ]
        }

        private static func parseAutologin(
            path: String, arguments: [String]
        ) -> (owner: String, setupAssistantUserID: UInt32?)? {
            let nativeArguments: [String]
            let setupAssistantUserID: UInt32?
            if path == "/usr/sbin/sysadminctl" {
                guard arguments.count == 10 else { return nil }
                nativeArguments = arguments
                setupAssistantUserID = nil
            } else {
                guard path == "/bin/launchctl", arguments.count == 13,
                      arguments[0] == "asuser",
                      arguments[1] == String(Self.allowedSetupAssistantUserID),
                      arguments[2] == "/usr/sbin/sysadminctl"
                else { return nil }
                nativeArguments = Array(arguments.dropFirst(3))
                setupAssistantUserID = Self.allowedSetupAssistantUserID
            }
            guard nativeArguments.count == 10,
                  nativeArguments[0] == "-adminUser",
                  nativeArguments[2] == "-adminPassword", nativeArguments[3] == "-",
                  nativeArguments[4] == "-autologin", nativeArguments[5] == "set",
                  nativeArguments[6] == "-userName", nativeArguments[8] == "-password",
                  nativeArguments[9] == "-",
                  nativeArguments[1] == nativeArguments[7],
                  nativeArguments[1].range(
                    of: "^[A-Za-z_][A-Za-z0-9_.-]{0,127}$",
                    options: .regularExpression
                  ) != nil
            else { return nil }
            return (nativeArguments[1], setupAssistantUserID)
        }
    }

    /// Prompt matching is intentionally explicit.  The default recognizes the
    /// sysadminctl password prompt and rejects prompts that could ask for a
    /// different credential or recovery factor.
    struct Prompt: Equatable, Sendable {
        let passwordMarker: String
        let additionalPasswordMarkers: [String]
        let unsafeMarkers: [String]
        private let knownOwner: String?

        init(
            passwordMarker: String = "password:",
            additionalPasswordMarkers: [String] = [],
            unsafeMarkers: [String] = [
                "username:",
                "user name:",
                "authorized user:",
                "owner username:",
                "recovery key",
                "authentication token",
                "verification code:",
                "one-time code:",
                "otp:"
            ],
            knownOwner: String? = nil
        ) {
            self.passwordMarker = passwordMarker
            self.additionalPasswordMarkers = additionalPasswordMarkers
            self.unsafeMarkers = unsafeMarkers
            self.knownOwner = knownOwner
        }

        static let sysadminctlPassword = Self()

        /// sysadminctl's prompt includes the target account in some builds.
        /// Keep those markers closed over the requested owner so output for a
        /// different account can never authorize a password write.
        static func sysadminctlPassword(for owner: String) -> Self {
            guard owner.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                return .init(passwordMarker: "__invalid_sysadminctl_prompt__")
            }
            return .init(
                passwordMarker: "user password:",
                additionalPasswordMarkers: [
                    "enter password for \(owner) :",
                    "enter password for \(owner):"
                ],
                knownOwner: owner.lowercased()
            )
        }

        enum Observation: Equatable, Sendable {
            case none
            case password
            case unsafe
        }

        func observe(_ transcript: Data) -> Observation {
            let normalized = String(decoding: transcript, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "\n")
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return .none }

            // An unsafe prompt wins if a command emits more than one kind of
            // credential request in one output batch.
            for marker in unsafeMarkers where Self.matches(marker, in: normalized) {
                return .unsafe
            }
            if let knownOwner, Self.matchesMismatchedOwnerPrompt(in: normalized, expected: knownOwner) {
                return .unsafe
            }
            let passwordMarkers = [passwordMarker] + additionalPasswordMarkers
            return passwordMarkers.contains(where: { Self.matches($0, in: normalized) }) ? .password : .none
        }

        private static func matchesMismatchedOwnerPrompt(in text: String, expected: String) -> Bool {
            let line = text.split(separator: "\n", omittingEmptySubsequences: true)
                .last.map(String.init) ?? text
            let prefix = "enter password for "
            guard line.hasPrefix(prefix), line.hasSuffix(":") else { return false }
            let owner = String(line.dropFirst(prefix.count).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty else { return false }
            return owner != expected
        }

        private static func matches(_ marker: String, in text: String) -> Bool {
            let normalizedMarker = marker
                .replacingOccurrences(of: "\r", with: "\n")
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMarker.isEmpty else { return false }
            if !normalizedMarker.hasSuffix(":") {
                return text.contains(normalizedMarker)
            }
            if normalizedMarker == "password:" {
                let line = text.split(separator: "\n", omittingEmptySubsequences: true)
                    .last.map(String.init) ?? text
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate == "password:"
                    || candidate == "enter password:"
                    || candidate == "please enter password:"
                    || (candidate.hasPrefix("password for user ") && candidate.hasSuffix(":"))
            }
            guard text.hasSuffix(normalizedMarker) else { return false }
            let prefix = text.dropLast(normalizedMarker.count)
            return prefix.isEmpty || prefix.last?.isWhitespace == true
        }
    }

    enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case invalidCommand
        case invalidSecret
        case secretInCommand
        case invalidPrompt
        case invalidTimeout
        case invalidCompletion
        case unrelatedJobFrame
        case unsafePrompt
        case promptTimedOut
        case promptMissing
        case processExitedBeforePrompt
        case repeatedPrompt
        case secretEchoed
        case promptOutputLimit
        case processTimedOut
        case cancelled
        case transportFailure
        case cleanupUnverified

        var errorDescription: String? {
            switch self {
            case .invalidCommand: "Private PTY command is invalid."
            case .invalidSecret: "Private PTY secret is invalid."
            case .secretInCommand: "Private PTY command contains the secret."
            case .invalidPrompt: "Private PTY prompt policy is invalid."
            case .invalidTimeout: "Private PTY timeout is invalid."
            case .invalidCompletion: "Private PTY process completion is invalid."
            case .unrelatedJobFrame: "Private PTY output belongs to another job."
            case .unsafePrompt: "Private PTY produced an unsafe credential prompt."
            case .promptTimedOut: "Private PTY password prompt timed out."
            case .promptMissing: "Private PTY exited without the required password prompt."
            case .processExitedBeforePrompt: "Private PTY exited before its password prompt could be answered."
            case .repeatedPrompt: "Private PTY requested more prompts than permitted."
            case .secretEchoed: "Private PTY echoed the secret; the operation was refused."
            case .promptOutputLimit: "Private PTY prompt output exceeded the bounded limit."
            case .processTimedOut: "Private PTY process timed out."
            case .cancelled: "Private PTY process was cancelled."
            case .transportFailure: "Private PTY transport failed."
            case .cleanupUnverified: "Private PTY process cleanup could not be verified."
            }
        }
    }

    /// Execute one command through a pinned, authenticated stream transport.
    /// The secret is never included in the process-start payload. It is sent
    /// after the configured prompt appears. The host control stream supplies
    /// one raw secret frame; only the closed autologin command may reuse that
    /// same validated secret for one additional prompt.
    static func run(
        command: Command,
        secret: String,
        prompt: Prompt = .sysadminctlPassword,
        promptTimeout: TimeInterval = defaultPromptTimeout,
        processTimeout: TimeInterval = defaultProcessTimeout,
        transport: Transport,
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        try await run(
            command: command,
            secret: secret,
            prompt: prompt,
            promptTimeout: promptTimeout,
            processTimeout: processTimeout,
            transport: transport,
            clock: ContinuousClock(),
            onFrames: onFrames
        )
    }

    static func run<C: Clock>(
        command: Command,
        secret: String,
        prompt: Prompt = .sysadminctlPassword,
        promptTimeout: TimeInterval = defaultPromptTimeout,
        processTimeout: TimeInterval = defaultProcessTimeout,
        transport: Transport,
        clock: C,
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult where C.Duration == Duration {
        try validate(command: command, prompt: prompt, promptTimeout: promptTimeout, processTimeout: processTimeout)
        try validateSecret(secret, command: command, prompt: prompt)
        return try await run(
            command: command, secretProvider: { secret }, prompt: prompt,
            promptTimeout: promptTimeout, processTimeout: processTimeout,
            transport: transport, clock: clock, onFrames: onFrames
        )
    }

    /// Variant used by a host-control stream.  The provider is invoked only
    /// after the guest has emitted the explicit password prompt, which lets a
    /// control client deliver the secret over the already-open private stream
    /// without putting it in the start request.
    static func run(
        command: Command,
        secretProvider: @escaping SecretProvider,
        prompt: Prompt = .sysadminctlPassword,
        promptTimeout: TimeInterval = defaultPromptTimeout,
        processTimeout: TimeInterval = defaultProcessTimeout,
        transport: Transport,
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        try await run(
            command: command, secretProvider: secretProvider, prompt: prompt,
            promptTimeout: promptTimeout, processTimeout: processTimeout,
            transport: transport, clock: ContinuousClock(), onFrames: onFrames
        )
    }

    static func run<C: Clock>(
        command: Command,
        secretProvider: @escaping SecretProvider,
        prompt: Prompt = .sysadminctlPassword,
        promptTimeout: TimeInterval = defaultPromptTimeout,
        processTimeout: TimeInterval = defaultProcessTimeout,
        transport: Transport,
        clock: C,
        onFrames: FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult where C.Duration == Duration {
        try validate(command: command, prompt: prompt, promptTimeout: promptTimeout, processTimeout: processTimeout)
        let maximumPromptCount = command.maximumPromptCount(for: prompt)
        if command.autologinOwner != nil,
           prompt != .sysadminctlPassword(for: command.autologinOwner ?? "") {
            throw Error.invalidPrompt
        }
        try await transport.validateSession()

        let started: PommeAgentCorrelatedResult
        do {
            // This is the only start exchange.  In particular, no input or
            // environment field is added here, so a password cannot reach the
            // process-start payload or an agent journal.
            started = try await transport.perform("process.start", command.startPayload)
        } catch {
            // The secret has not crossed the transport. Preserve the agent's
            // typed failure for callers that need to distinguish auth errors.
            throw error
        }

        guard let startedValues = started.result.objectValue,
              let jobText = startedValues["jobID"]?.stringValue,
              let jobID = UUID(uuidString: jobText),
              startedValues["exited"] == .bool(false)
        else { throw Error.invalidCompletion }

        guard startedValues["ptyEchoDisabled"] == .bool(true) else {
            var rejectedState = OutputState(
                jobID: jobID, prompt: prompt, maximumPromptCount: maximumPromptCount)
            try await cleanup(
                jobID: jobID,
                secret: Data(),
                state: &rejectedState,
                transport: transport,
                onFrames: nil
            )
            throw Error.invalidCompletion
        }

        let promptDeadline = clock.now.advanced(by: .seconds(promptTimeout))
        let processDeadline = clock.now.advanced(by: .seconds(processTimeout))
        var state = OutputState(
            jobID: jobID, prompt: prompt, maximumPromptCount: maximumPromptCount)
        var terminal = startedValues
        var passwordSent = false
        var cleanupRequired = true
        var secretBytes = Data()
        var secretLine = Data()
        defer {
            secretLine.resetBytes(in: 0..<secretLine.count)
            secretBytes.resetBytes(in: 0..<secretBytes.count)
        }

        do {
            try await state.accept(started.streamFrames, secret: Data(), passwordSent: false, onFrames: onFrames)
            if state.promptObservation == .unsafe { throw Error.unsafePrompt }
            if state.promptObservation == .password {
                let secret = try await validatedSecret(
                    from: secretProvider,
                    command: command,
                    prompt: prompt
                )
                secretBytes = Data(secret.utf8)
                secretLine = secretBytes
                secretLine.append(0x0A)
                try await sendSecret(
                    jobID: jobID,
                    secretLine: secretLine,
                    state: &state,
                    transport: transport,
                    onFrames: onFrames,
                    processIsExited: terminal["exited"] == .bool(true)
                )
                passwordSent = true
                while state.promptObservation == .password {
                    try await sendSecret(
                        jobID: jobID,
                        secretLine: secretLine,
                        state: &state,
                        transport: transport,
                        onFrames: onFrames,
                        processIsExited: terminal["exited"] == .bool(true)
                    )
                }
            }

            while true {
                try checkpoint(clock: clock, deadline: processDeadline, timeoutError: .processTimedOut)
                if !passwordSent {
                    guard clock.now < promptDeadline else { throw Error.promptTimedOut }
                }

                let status: PommeAgentCorrelatedResult
                do {
                    status = try await transport.perform(
                        "process.status",
                        .object(["jobID": .string(jobID.uuidString.lowercased())])
                    )
                } catch {
                    throw passwordSent ? Error.transportFailure : mapTransportError(error)
                }
                guard let values = status.result.objectValue,
                      let rawID = values["jobID"]?.stringValue,
                      UUID(uuidString: rawID) == jobID,
                      values["exited"] != nil
                else { throw Error.invalidCompletion }
                terminal.merge(values) { _, current in current }
                try await state.accept(status.streamFrames, secret: secretBytes, passwordSent: passwordSent, onFrames: onFrames)
                switch state.promptObservation {
                case .unsafe: throw Error.unsafePrompt
                case .password:
                    guard terminal["exited"] != .bool(true) else {
                        throw Error.processExitedBeforePrompt
                    }
                    if !passwordSent {
                        let secret = try await validatedSecret(
                            from: secretProvider,
                            command: command,
                            prompt: prompt
                        )
                        secretBytes = Data(secret.utf8)
                        secretLine = secretBytes
                        secretLine.append(0x0A)
                        passwordSent = true
                    }
                    while state.promptObservation == .password {
                        try await sendSecret(
                            jobID: jobID,
                            secretLine: secretLine,
                            state: &state,
                            transport: transport,
                            onFrames: onFrames,
                            processIsExited: terminal["exited"] == .bool(true)
                        )
                    }
                case .none: break
                }

                if terminal["exited"] == .bool(true), state.receivedExit {
                    guard passwordSent else { throw Error.promptMissing }
                    try validateTerminal(terminal)
                    cleanupRequired = false
                    return state.result(requestID: started.requestID, terminal: terminal, promptSatisfied: passwordSent)
                }
                try await sleepUntilNextPoll(clock: clock, deadline: processDeadline)
            }
        } catch is CancellationError {
            if cleanupRequired {
                try await cleanup(
                    jobID: jobID,
                    secret: secretBytes,
                    state: &state,
                    transport: transport,
                    onFrames: onFrames
                )
            }
            throw Error.cancelled
        } catch let error as Error {
            let verifiedExited = terminal["exited"] == .bool(true) && state.receivedExit
            if cleanupRequired && !verifiedExited {
                try await cleanup(
                    jobID: jobID,
                    secret: secretBytes,
                    state: &state,
                    transport: transport,
                    onFrames: onFrames
                )
            }
            throw error
        } catch {
            let verifiedExited = terminal["exited"] == .bool(true) && state.receivedExit
            if cleanupRequired && !verifiedExited {
                try await cleanup(
                    jobID: jobID,
                    secret: secretBytes,
                    state: &state,
                    transport: transport,
                    onFrames: onFrames
                )
            }
            throw Error.transportFailure
        }
    }

    private static func validate(
        command: Command,
        prompt: Prompt,
        promptTimeout: TimeInterval,
        processTimeout: TimeInterval
    ) throws {
        guard command.path.hasPrefix("/"), !command.path.contains("\0"),
              command.arguments.allSatisfy({ !$0.contains("\0") })
        else { throw Error.invalidCommand }
        guard !command.isSysadminctlAutologin || command.autologinOwner != nil else {
            throw Error.invalidCommand
        }
        guard !prompt.passwordMarker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.additionalPasswordMarkers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              prompt.unsafeMarkers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !prompt.passwordMarker.contains("\0"),
              prompt.additionalPasswordMarkers.allSatisfy({ !$0.contains("\0") }),
              prompt.unsafeMarkers.allSatisfy({ !$0.contains("\0") })
        else { throw Error.invalidPrompt }
        guard promptTimeout.isFinite, promptTimeout > 0, promptTimeout <= maximumTimeout,
              processTimeout.isFinite, processTimeout > 0, processTimeout <= maximumTimeout,
              promptTimeout <= processTimeout
        else { throw Error.invalidTimeout }
        guard try PommeAgentProtocol.encode(
            .request(operation: "process.start", payload: command.startPayload)
        ).count <= PommeAgentProtocol.maximumFrameBytes else { throw Error.invalidCommand }
    }

    private static func validatedSecret(
        from provider: SecretProvider,
        command: Command,
        prompt: Prompt
    ) async throws -> String {
        let secret: String
        do {
            secret = try await provider()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.transportFailure
        }
        try validateSecret(secret, command: command, prompt: prompt)
        return secret
    }

    private static func validateSecret(_ secret: String, command: Command, prompt: Prompt) throws {
        guard !secret.isEmpty,
              secret.utf8.count <= PommeAgentProtocol.maximumStreamChunkBytes,
              !secret.contains("\0"),
              !secret.contains("\n"),
              !secret.contains("\r")
        else { throw Error.invalidSecret }
        guard !command.path.contains(secret),
              !command.arguments.contains(where: { $0.contains(secret) })
        else { throw Error.secretInCommand }
        guard !prompt.passwordMarker.contains(secret),
              prompt.additionalPasswordMarkers.allSatisfy({ !$0.contains(secret) }),
              prompt.unsafeMarkers.allSatisfy({ !$0.contains(secret) })
        else { throw Error.invalidPrompt }
    }

    private static func sendSecret(
        jobID: UUID,
        secretLine: Data,
        state: inout OutputState,
        transport: Transport,
        onFrames: FrameHandler?,
        processIsExited: Bool
    ) async throws {
        guard !processIsExited else { throw Error.processExitedBeforePrompt }
        let frames: [PommeAgentJobStreamFrame]
        do {
            frames = try await transport.sendStream(jobID, .stdin, secretLine, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.transportFailure
        }
        try await state.accept(frames, secret: Data(secretLine.dropLast()), passwordSent: true, onFrames: onFrames)
        if state.promptObservation == .unsafe { throw Error.unsafePrompt }
    }

    private static func cleanup(
        jobID: UUID,
        secret: Data,
        state: inout OutputState,
        transport: Transport,
        onFrames: FrameHandler?
    ) async throws {
        var exited = state.receivedExit
        let clock = ContinuousClock()
        let cleanupDeadline = clock.now.advanced(by: .seconds(cleanupTimeout))
        // Reserve time for a forced kill and a verified terminal status. A
        // process that ignores TERM must not consume the whole cleanup budget
        // before KILL is attempted.
        let termDeadline = clock.now.advanced(by: .seconds(min(1, cleanupTimeout / 2)))

        func signal(_ value: Int32) async throws {
            let frames = try await transport.sendStream(jobID, .signal, nil, value)
            // Cleanup must not forward a frame containing an echoed secret.
            // `accept` scans before invoking the callback and the error is
            // converted to cleanup failure below.
            try await state.accept(frames, secret: secret, passwordSent: true, onFrames: onFrames)
            exited = exited || state.receivedExit
        }

        do {
            try await signal(SIGTERM)
            while !exited && clock.now < termDeadline {
                let status = try await transport.perform(
                    "process.status",
                    .object(["jobID": .string(jobID.uuidString.lowercased())])
                )
                guard let values = status.result.objectValue,
                      let rawID = values["jobID"]?.stringValue,
                      UUID(uuidString: rawID) == jobID,
                      values["exited"] != nil
                else { throw Error.invalidCompletion }
                try await state.accept(status.streamFrames, secret: secret, passwordSent: true, onFrames: onFrames)
                exited = values["exited"] == .bool(true) && state.receivedExit
                if !exited { try? await Task.sleep(for: .milliseconds(25)) }
            }
            if !exited {
                try await signal(SIGKILL)
                while !exited && clock.now < cleanupDeadline {
                    let status = try await transport.perform(
                        "process.status",
                        .object(["jobID": .string(jobID.uuidString.lowercased())])
                    )
                    guard let values = status.result.objectValue,
                          let rawID = values["jobID"]?.stringValue,
                          UUID(uuidString: rawID) == jobID,
                          values["exited"] != nil
                    else { throw Error.invalidCompletion }
                    try await state.accept(status.streamFrames, secret: secret, passwordSent: true, onFrames: onFrames)
                    exited = values["exited"] == .bool(true) && state.receivedExit
                    if !exited { try? await Task.sleep(for: .milliseconds(25)) }
                }
            }
        } catch is CancellationError {
            throw Error.cleanupUnverified
        } catch {
            throw Error.cleanupUnverified
        }
        guard exited else { throw Error.cleanupUnverified }
    }

    private static func mapTransportError(_ error: Swift.Error) -> Error {
        if error is CancellationError { return .cancelled }
        if let error = error as? Error { return error }
        return .transportFailure
    }

    private static func checkpoint<C: Clock>(
        clock: C,
        deadline: C.Instant,
        timeoutError: Error
    ) throws {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw timeoutError }
    }

    private static func sleepUntilNextPoll<C: Clock>(clock: C, deadline: C.Instant) async throws where C.Duration == Duration {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        try await clock.sleep(for: min(.milliseconds(25), remaining))
    }

    private static func validateTerminal(_ values: [String: JSONValue]) throws {
        if case .integer(let code)? = values["exitCode"], (0...255).contains(code), values["signal"] == nil { return }
        if case .integer(let signal)? = values["signal"], (1...127).contains(signal), values["exitCode"] == nil { return }
        throw Error.invalidCompletion
    }

    private struct OutputState {
        let jobID: UUID
        let prompt: Prompt
        let maximumPromptCount: Int
        var promptObservation: Prompt.Observation = .none
        var promptCount = 0
        var promptTranscript = Data()
        var promptDetectionTranscript = Data()
        var postPromptTranscript = Data()
        var receivedExit = false
        var frames: [PommeAgentJobStreamFrame] = []
        var stdoutBytes = 0
        var stderrBytes = 0
        var stdoutTruncated = false
        var stderrTruncated = false

        init(jobID: UUID, prompt: Prompt, maximumPromptCount: Int) {
            self.jobID = jobID
            self.prompt = prompt
            self.maximumPromptCount = maximumPromptCount
        }

        mutating func accept(
            _ values: [PommeAgentJobStreamFrame],
            secret: Data,
            passwordSent: Bool,
            onFrames: FrameHandler?
        ) async throws {
            guard values.allSatisfy({ $0.jobID == jobID }) else { throw Error.unrelatedJobFrame }
            guard values.allSatisfy({ [.stdout, .stderr, .exit].contains($0.frame.stream) }) else {
                throw Error.invalidCompletion
            }

            promptObservation = .none
            var observation = Prompt.Observation.none
            for value in values {
                switch value.frame.stream {
                case .stdout, .stderr:
                    let data = value.frame.data ?? Data()
                    if !passwordSent {
                        guard promptTranscript.count + data.count <= maximumPromptTranscriptBytes else {
                            throw Error.promptOutputLimit
                        }
                        promptTranscript.append(data)
                        promptDetectionTranscript.append(data)
                        switch prompt.observe(promptTranscript) {
                        case .unsafe: observation = .unsafe
                        case .password where observation != .unsafe:
                            promptCount += 1
                            guard promptCount <= maximumPromptCount else {
                                throw Error.repeatedPrompt
                            }
                            observation = .password
                            promptDetectionTranscript.removeAll(keepingCapacity: true)
                        case .none: break
                        case .password: break
                        }
                    } else if !data.isEmpty {
                        // Keep only a bounded tail after the secret is sent so
                        // additional prompts split across frames stay within
                        // the same prompt policy.
                        postPromptTranscript = Data(
                            (postPromptTranscript + data).suffix(maximumPromptTranscriptBytes)
                        )
                        if !secret.isEmpty && postPromptTranscript.range(of: secret) != nil {
                            throw Error.secretEchoed
                        }
                        promptDetectionTranscript.append(data)
                        if promptDetectionTranscript.count > maximumPromptTranscriptBytes {
                            promptDetectionTranscript = Data(
                                promptDetectionTranscript.suffix(maximumPromptTranscriptBytes)
                            )
                        }
                        switch prompt.observe(promptDetectionTranscript) {
                        case .unsafe: observation = .unsafe
                        case .password where observation != .unsafe:
                            promptCount += 1
                            guard promptCount <= maximumPromptCount else {
                                throw Error.repeatedPrompt
                            }
                            observation = .password
                            promptDetectionTranscript.removeAll(keepingCapacity: true)
                        case .none: break
                        case .password: break
                        }
                    }
                case .exit:
                    receivedExit = true
                default: break
                }
            }
            if observation == .unsafe { promptObservation = .unsafe }
            else if observation == .password { promptObservation = .password }

            if let onFrames, !values.isEmpty {
                try await onFrames(values)
                return
            }
            for value in values {
                if value.frame.stream == .exit {
                    if !frames.contains(where: { $0.frame.stream == .exit }) { frames.append(value) }
                    continue
                }
                let data = value.frame.data ?? Data()
                let isStdout = value.frame.stream == .stdout
                let used = isStdout ? stdoutBytes : stderrBytes
                let remaining = max(0, maximumBufferedOutputBytes - used)
                let retained = Data(data.prefix(remaining))
                if retained.count != data.count {
                    if isStdout { stdoutTruncated = true } else { stderrTruncated = true }
                }
                if !retained.isEmpty, frames.count < 128 {
                    frames.append(try .init(jobID: jobID, frame: .init(
                        requestID: value.frame.requestID,
                        stream: value.frame.stream,
                        data: retained
                    )))
                    if isStdout { stdoutBytes += retained.count } else { stderrBytes += retained.count }
                }
            }
        }

        func result(requestID: UUID, terminal: [String: JSONValue], promptSatisfied: Bool) -> PommeAgentCorrelatedResult {
            var values = terminal
            values["outputComplete"] = .bool(receivedExit)
            values["promptSatisfied"] = .bool(promptSatisfied)
            values["stdoutTruncated"] = .bool(stdoutTruncated)
            values["stderrTruncated"] = .bool(stderrTruncated)
            return .init(requestID: requestID, result: .object(values), streamFrames: frames)
        }
    }
}
