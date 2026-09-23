import Darwin
import Foundation
import OSLog

/// Connection-local fixed events; never includes frame contents or identities.
struct PommeAgentServeLoopTrace: Sendable {
    enum Event: String, CaseIterable, Sendable {
        case serveEntered, serveExited, readEntered, readReturned, readClosed, readFailed
        case frameReady, writeEntered, writeCompleted, writeFailed
        case decodedAuthenticate, decodedStart, decodedStatus, decodedSignal, decodedWait, decodedOutput
        case decodedOtherRequest, decodedStream, decodedInvalid
        case decodeEntered, decodeReturned, decodeFailed
        case startHandlerEntered, startHandlerReturned, startHandlerFailed
    }

    static func classification(_ frame: PommeAgentProtocol.Envelope?) -> Event {
        guard let frame else { return .decodedInvalid }
        if frame.kind == .stream { return .decodedStream }
        guard frame.kind == .request else { return .decodedInvalid }
        switch frame.operation {
        case "authenticate": return .decodedAuthenticate
        case "process.start": return .decodedStart
        case "process.status": return .decodedStatus
        case "process.signal": return .decodedSignal
        case "process.wait": return .decodedWait
        case "process.output": return .decodedOutput
        default: return .decodedOtherRequest
        }
    }

    typealias Sink = @Sendable (Event, Double) -> Void
    private static let logger = Logger(subsystem: "com.github.weswhet.pomme", category: "guest-serve-loop")
    private let started = ContinuousClock.now
    let sink: Sink

    func emit(_ event: Event) {
        let savedErrno = errno
        defer { errno = savedErrno }
        let elapsed = started.duration(to: .now).components
        sink(event, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }

    static func guestLog(_ event: Event, _ elapsed: Double) {
        logger.notice("[DEBUG-guest-serve-loop-20260923] \(event.rawValue, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
    }
}

/// Temporary closed-surface diagnostics. Elapsed times are local to one
/// exchange, not a cross-host clock or a request identity.
struct PommeSignalBoundaryTrace: Sendable {
    enum Event: String, CaseIterable, Sendable {
        case guestSignalDecoded, guestSignalRejectedReplay, guestSignalRejectedAuthenticationRequired
        case guestSignalRejectedExpired, guestSignalRejectedOther
        case guestHandlerEntered, guestPerformReturned, guestPerformFailed
        case guestStreamsEntered, guestStreamsReturned, guestStreamsFailed
        case guestStreamWriteEntered, guestStreamWritten, guestStreamWriteFailed
        case guestResponseWriteEntered, guestResponseWritten, guestResponseWriteFailed
        case guestStatusHandlerEntered, guestStatusPerformReturned, guestStatusPerformFailed
        case guestStatusStreamsEntered, guestStatusStreamsReturned, guestStatusStreamsFailed
        case guestStatusStreamWriteEntered, guestStatusStreamWritten, guestStatusStreamWriteFailed
        case guestStatusResponseWriteEntered, guestStatusResponseWritten, guestStatusResponseWriteFailed
        case hostExchangeAdmitted, hostWriteCompleted, hostResponseReceived
        case hostWriteFailed, hostResponseFailed

        fileprivate var statusEvent: Self {
            switch self {
            case .guestHandlerEntered: .guestStatusHandlerEntered
            case .guestPerformReturned: .guestStatusPerformReturned
            case .guestPerformFailed: .guestStatusPerformFailed
            case .guestStreamsEntered: .guestStatusStreamsEntered
            case .guestStreamsReturned: .guestStatusStreamsReturned
            case .guestStreamsFailed: .guestStatusStreamsFailed
            case .guestStreamWriteEntered: .guestStatusStreamWriteEntered
            case .guestStreamWritten: .guestStatusStreamWritten
            case .guestStreamWriteFailed: .guestStatusStreamWriteFailed
            case .guestResponseWriteEntered: .guestStatusResponseWriteEntered
            case .guestResponseWritten: .guestStatusResponseWritten
            case .guestResponseWriteFailed: .guestStatusResponseWriteFailed
            default: self
            }
        }
    }

    typealias Sink = @Sendable (Event, Double) -> Void
    private static let logger = Logger(subsystem: "com.github.weswhet.pomme", category: "signal-boundary")
    private let started = ContinuousClock.now
    let sink: Sink
    private let isStatus: Bool

    init(sink: @escaping Sink, isStatus: Bool = false) {
        self.sink = sink
        self.isStatus = isStatus
    }

    func emit(_ event: Event) {
        let elapsed = started.duration(to: .now).components
        sink(isStatus ? event.statusEvent : event,
             Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }

    static func message(_ event: Event, elapsedMilliseconds: Double) -> String {
        "[DEBUG-signal-boundary-20260922] \(event.rawValue) elapsedMs=\(elapsedMilliseconds)"
    }

    static func guestLog(_ event: Event, _ elapsed: Double) {
        logger.notice("\(message(event, elapsedMilliseconds: elapsed), privacy: .public)")
    }

    static func hostLog(_ event: Event, _ elapsed: Double) {
        PommeCore.log(message(event, elapsedMilliseconds: elapsed))
    }
}

/// Closed desktop-start events with elapsed time local to this exchange.
struct PommeDesktopStartBoundaryTrace: Sendable {
    enum Event: String, CaseIterable, Sendable {
        case exchangeAdmitted, writeCompleted, writeFailed, responseReceived, responseFailed
        case responseReadNoBytes, responseReadPartialFrame, responseReadCompleteFrame, responseReadStreamFrames
        case requestDecoded, requestRejected, requestAccepted, handlerEntered, performReturned, performFailed
        case streamsEntered, streamsReturned, streamsFailed
        case streamWriteEntered, streamWritten, streamWriteFailed
        case responseWriteEntered, responseWritten, responseWriteFailed
    }

    typealias Sink = @Sendable (Event, Double) -> Void
    private static let logger = Logger(subsystem: "com.github.weswhet.pomme", category: "desktop-start-boundary")
    private let started = ContinuousClock.now
    let sink: Sink

    static func admits(_ request: PommeAgentProtocol.Envelope) -> Bool {
        request.kind == .request && request.operation == "process.start"
            && request.payload.objectValue.map(PommeForegroundExecution.isDesktopProofPayload) == true
    }

    func emit(_ event: Event) {
        let elapsed = started.duration(to: .now).components
        sink(event, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }

    static func message(_ event: Event, elapsedMilliseconds: Double) -> String {
        "[DEBUG-desktop-start-boundary-20260923] \(event.rawValue) elapsedMs=\(elapsedMilliseconds)"
    }

    static func guestLog(_ event: Event, _ elapsed: Double) {
        logger.notice("\(message(event, elapsedMilliseconds: elapsed), privacy: .public)")
    }

    static func hostLog(_ event: Event, _ elapsed: Double) {
        PommeCore.log(message(event, elapsedMilliseconds: elapsed))
    }
}

/// Guest-side entrypoint for the launchd daemon.  The host publishes the
/// VSOCK service; this process uses the same guest-to-host connection shape as
/// the baseline runtime and never exposes an unauthenticated listening port.
enum PommeAgentDaemon {
    typealias RecoveryCleanup = @Sendable () throws -> Void
    typealias RecoveryCleanupFactory = @Sendable (
        _ options: Options,
        _ executablePath: String,
        _ owner: uid_t,
        _ group: gid_t
    ) throws -> RecoveryCleanup

    struct Options: Sendable, Equatable {
        let port: UInt32
        let tokenFile: String
        let expectedSHA256: String
        let role: PommeAgentRole
        let oneShotExpiry: Date?
        let vmBinding: String?
        let sessionBinding: String?
        let requestFile: String?
        /// Normal mode has no operation restriction. Recovery mode always
        /// carries one immutable allowlisted operation, so a launcher for one
        /// request cannot be reused for another command.
        let allowedOperation: String?
        /// Terminal Recovery is a distinct authority. Its admission expires
        /// before first authentication, then the credential is retained only
        /// in memory for this boot and can authenticate reconnects.
        let terminalAuthority: Bool
    }

    enum Exit: Int32 { case success = 0, invalidArguments = 64, integrity = 65, credential = 66, transport = 69 }

    /// Parses only the daemon grammar.  A caller such as PommeBootstrap should
    /// invoke this when `--pomme-agent` is present and return its exit value.
    static func run(
        arguments: [String],
        executablePath: String = CommandLine.arguments.first ?? PommeAgentInstall.executable,
        recoveryOwner: uid_t = 0,
        recoveryGroup: gid_t = 0,
        recoveryCleanupFactory: RecoveryCleanupFactory = {
            try recoveryWorkspaceCleanup(
                options: $0,
                executablePath: $1,
                owner: $2,
                group: $3
            )
        }
    ) -> Int32 {
        do {
            let options = try parse(arguments: arguments)
            // Install the exact-workspace cleanup guard immediately after
            // parsing. Every subsequent validation can fail after a
            // launcher has already created guest artifacts, so the guard must
            // exist before digest, token, or request-file validation.
            let oneShotCleanup = try recoveryCleanupFactory(
                options,
                executablePath,
                recoveryOwner,
                recoveryGroup
            )
            defer {
                if options.role == .recovery { try? oneShotCleanup() }
            }
            guard try PommeAgentFileTransaction.sha256(URL(fileURLWithPath: executablePath)) == options.expectedSHA256 else { return Exit.integrity.rawValue }
            // Recovery credentials are descriptor-backed one-shot material.
            // Consume the exact file before opening the host connection; a
            // reconnect or process restart therefore cannot replay it.
            let token = try readToken(
                at: options.tokenFile,
                consume: options.role == .recovery,
                expectedOwner: recoveryOwner,
                expectedGroup: recoveryGroup
            )
            if let requestFile = options.requestFile {
                try validateRequestFile(
                    at: requestFile,
                    expectedOperation: options.allowedOperation,
                    expectedVMID: options.vmBinding,
                    expectedSessionID: options.sessionBinding,
                    expectedPort: options.port,
                    expectedDigest: options.expectedSHA256
                )
            }
            var terminalAdmissionAuthenticated = false
            let agent = try PommeAgent(
                role: options.role,
                executableSHA256: options.expectedSHA256,
                authority: options.terminalAuthority ? .recoveryTerminal : .standard
            )
            while true {
                let descriptor = try connectToHost(port: options.port)
                let lifetime: PommeAgentConnection.CredentialLifetime = options.terminalAuthority
                    ? .bootSession
                    : (options.role == .recovery ? .oneShot : .persistent)
                let connection = try PommeAgentConnection(token: token, lifetime: lifetime,
                                                          expiresAt: terminalAdmissionAuthenticated ? nil : options.oneShotExpiry,
                                                          vmBinding: options.vmBinding, sessionBinding: options.sessionBinding)
                blocking {
                    await serve(
                        descriptor: descriptor,
                        connection: connection,
                        agent: agent,
                        allowedOperation: options.allowedOperation,
                        terminalAuthority: options.terminalAuthority,
                        oneShotCleanup: oneShotCleanup
                    )
                }
                if options.terminalAuthority && connection.isAuthenticated {
                    // The short-lived credential gates only first admission.
                    // Once this daemon has authenticated, reconnects during
                    // the same Recovery boot use the in-memory boot-session
                    // authority even if the original deadline has elapsed.
                    terminalAdmissionAuthenticated = true
                }
                _ = Darwin.close(descriptor)
                if options.role == .recovery && !options.terminalAuthority {
                    try oneShotCleanup()
                    return Exit.success.rawValue
                }
            }
        } catch let error as PommeAgentDaemonError {
            return error.exit.rawValue
        } catch {
            return Exit.transport.rawValue
        }
    }

    static func parse(arguments: [String]) throws -> Options {
        guard arguments.first == "--pomme-agent" else { throw PommeAgentDaemonError(.invalidArguments) }
        guard arguments.count >= 2, let port = UInt32(arguments[1]) else { throw PommeAgentDaemonError(.invalidArguments) }
        var values: [String: String] = [:]; var index = 2
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--token-file", "--expected-sha256", "--role", "--one-shot-expiry", "--vm-id", "--session-id", "--operation", "--request-file"].contains(flag), index + 1 < arguments.count, values[flag] == nil else { throw PommeAgentDaemonError(.invalidArguments) }
            values[flag] = arguments[index + 1]; index += 2
        }
        guard let token = values["--token-file"], token.hasPrefix("/"),
              let digest = values["--expected-sha256"] else { throw PommeAgentDaemonError(.invalidArguments) }
        let role: PommeAgentRole
        switch values["--role"] ?? "normal" { case "normal": role = .persistent; case "recovery": role = .recovery; default: throw PommeAgentDaemonError(.invalidArguments) }
        let expiry = try values["--one-shot-expiry"].map { text -> Date in guard let seconds = TimeInterval(text), seconds > Date().timeIntervalSince1970 else { throw PommeAgentDaemonError(.invalidArguments) }; return Date(timeIntervalSince1970: seconds) }
        let vmBinding = try values["--vm-id"].map(Self.canonicalUUID)
        let sessionBinding = try values["--session-id"].map(Self.canonicalUUID)
        let allowedOperation: String?
        let terminalAuthority: Bool
        switch (role, port) {
        case (.persistent, Constants.pommeAgentPort):
            guard expiry == nil, vmBinding == nil, sessionBinding == nil, values["--operation"] == nil, values["--request-file"] == nil else { throw PommeAgentDaemonError(.invalidArguments) }
            allowedOperation = nil
            terminalAuthority = false
        case (.recovery, Constants.pommeRecoverySessionPort):
            // The bootstrap listener can only install the persistent agent.
            guard expiry != nil, vmBinding != nil, sessionBinding != nil,
                  values["--operation"] == PommeRecoveryOperation.installAgent.wireName,
                  values["--request-file"].map({ $0.hasPrefix("/") }) == true
            else { throw PommeAgentDaemonError(.invalidArguments) }
            allowedOperation = PommeRecoveryOperation.installAgent.wireName
            terminalAuthority = false
        case (.recovery, Constants.pommeRecoveryRuntimePort):
            guard expiry != nil, vmBinding != nil, sessionBinding != nil,
                  let operation = values["--operation"],
                  values["--request-file"].map({ $0.hasPrefix("/") }) == true
            else { throw PommeAgentDaemonError(.invalidArguments) }
            allowedOperation = operation
            let isTerminal = operation == PommeRecoveryOperation.terminalSession.wireName
            guard isTerminal || Self.recoverySecurityOperations.contains(operation) else {
                throw PommeAgentDaemonError(.invalidArguments)
            }
            terminalAuthority = isTerminal
        default:
            throw PommeAgentDaemonError(.invalidArguments)
        }
        do { return try .init(port: port, tokenFile: token, expectedSHA256: PommeAgentAuthentication.normalized(digest), role: role, oneShotExpiry: expiry, vmBinding: vmBinding, sessionBinding: sessionBinding, requestFile: values["--request-file"], allowedOperation: allowedOperation, terminalAuthority: terminalAuthority) }
        catch { throw PommeAgentDaemonError(.invalidArguments) }
    }

    private static let recoverySecurityOperations: Set<String> = [
        "sip.status", "sip.disable", "sip.enable",
        "amfi.status", "amfi.disable", "amfi.enable"
    ]

    private static func canonicalUUID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw PommeAgentDaemonError(.invalidArguments)
        }
        return value
    }

    private static func validateRequestFile(
        at path: String,
        expectedOperation: String?,
        expectedVMID: String?,
        expectedSessionID: String?,
        expectedPort: UInt32,
        expectedDigest: String
    ) throws {
        guard let expectedOperation, let expectedVMID, let expectedSessionID,
              let expectedVM = UUID(uuidString: expectedVMID),
              let expectedSession = UUID(uuidString: expectedSessionID),
              path.hasPrefix("/"), !path.contains("\0")
        else { throw PommeAgentDaemonError(.invalidArguments) }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PommeAgentDaemonError(.invalidArguments) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              info.st_gid == 0,
              info.st_mode & 0o077 == 0,
              info.st_size > 0,
              info.st_size <= 64 * 1024
        else { throw PommeAgentDaemonError(.invalidArguments) }
        var data = Data(capacity: Int(info.st_size))
        var bytes = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard data.count + count <= 64 * 1024 else { throw PommeAgentDaemonError(.invalidArguments) }
                data.append(contentsOf: bytes.prefix(Int(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw PommeAgentDaemonError(.invalidArguments)
            }
        }
        do {
            let request = try JSONDecoder().decode(PommeRecoverySessionRequest.self, from: data)
            guard request.isWellFormed,
                  request.operation == expectedOperation,
                  request.listenerPort == expectedPort,
                  request.vmUUID == expectedVM,
                  request.requestID == expectedSession,
                  request.executableSHA256 == expectedDigest
            else { throw PommeAgentDaemonError(.invalidArguments) }
        } catch let error as PommeAgentDaemonError {
            throw error
        } catch {
            throw PommeAgentDaemonError(.invalidArguments)
        }
    }

    private static func recoveryWorkspaceCleanup(
        options: Options,
        executablePath: String,
        owner: uid_t,
        group: gid_t
    ) throws -> RecoveryCleanup {
        guard options.role == .recovery else { return {} }
        guard let sessionBinding = options.sessionBinding,
              let requestFile = options.requestFile,
              UUID(uuidString: sessionBinding)?.uuidString.lowercased() == sessionBinding
        else { throw PommeAgentDaemonError(.invalidArguments) }

        let expectedWorkspace = "/private/var/tmp/pomme-recovery-\(sessionBinding)"
        let expectedExecutable = "\(expectedWorkspace)/\(PommeRecoveryArtifactNames.executable)"
        let expectedRequest = "\(expectedWorkspace)/\(PommeRecoveryArtifactNames.request)"
        let expectedCredential = "\(expectedWorkspace)/\(PommeRecoveryArtifactNames.credential)"
        // Validate lexical identity without resolving existing symlinks. The
        // Recovery staging root is intentionally addressed as
        // /private/var/tmp; on macOS, standardizedFileURL resolves the
        // existing /private alias to /var/tmp and would reject the exact
        // request-bound spelling before digest validation. The exact-string
        // guards below still reject dot components and aliases, while the
        // descriptor-backed cleanup performs the no-follow filesystem check.
        let executable = URL(fileURLWithPath: executablePath).standardized
        let request = URL(fileURLWithPath: requestFile).standardized
        let credential = URL(fileURLWithPath: options.tokenFile).standardized
        let workspace = URL(fileURLWithPath: expectedWorkspace, isDirectory: true)
        guard executable.path == executablePath,
              request.path == requestFile,
              credential.path == options.tokenFile,
              executablePath == expectedExecutable,
              requestFile == expectedRequest,
              options.tokenFile == expectedCredential,
              let requestID = UUID(uuidString: sessionBinding)
        else { throw PommeAgentDaemonError(.invalidArguments) }

        return {
            try PommeAgentFileTransaction.removeRecoveryWorkspace(
                workspace,
                requestID: requestID,
                owner: owner,
                group: group
            )
        }
    }

    /// One authenticated connection.  A malformed or over-limit frame is a
    /// hard close; the buffer limit is checked before appending any allocation.
    static func serve(
        descriptor: Int32,
        connection: PommeAgentConnection,
        agent: PommeAgent,
        allowedOperation: String? = nil,
        terminalAuthority: Bool = false,
        signalTraceSink: PommeSignalBoundaryTrace.Sink? = nil,
        desktopStartTraceSink: PommeDesktopStartBoundaryTrace.Sink? = nil,
        serveLoopTraceSink: PommeAgentServeLoopTrace.Sink? = nil,
        oneShotCleanup: @escaping @Sendable () throws -> Void = {}
    ) async {
        let normalScope = agent.role == .persistent && allowedOperation == nil && !terminalAuthority
        let serveTrace = normalScope
            ? PommeAgentServeLoopTrace(sink: serveLoopTraceSink ?? PommeAgentServeLoopTrace.guestLog) : nil
        serveTrace?.emit(.serveEntered)
        defer { serveTrace?.emit(.serveExited) }
        defer { connection.resetForReconnect() }
        func writeFrame(_ data: Data) -> Bool {
            serveTrace?.emit(.writeEntered)
            let written = writeAll(descriptor: descriptor, data: data)
            serveTrace?.emit(written ? .writeCompleted : .writeFailed)
            return written
        }
        var noSigPipe: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return }
        var buffer = Data(); var scratch = [UInt8](repeating: 0, count: 4096)
        var operationConsumed = false
        while true {
            serveTrace?.emit(.readEntered)
            let count = Darwin.read(descriptor, &scratch, scratch.count)
            serveTrace?.emit(.readReturned)
            guard count > 0 else {
                serveTrace?.emit(count == 0 ? .readClosed : .readFailed)
                return
            }
            let received = scratch.prefix(count)
            guard buffer.count + received.count <= PommeAgentProtocol.maximumFrameBytes else { return }
            buffer.append(contentsOf: received)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                serveTrace?.emit(.frameReady)
                guard !line.isEmpty, line.count < PommeAgentProtocol.maximumFrameBytes else { return }
                // One fixed classification before authentication/actor admission.
                // Logging adds observer latency; absence is not proof of a stall.
                serveTrace?.emit(.decodeEntered)
                let decoded = try? PommeAgentProtocol.decode(line)
                serveTrace?.emit(decoded == nil ? .decodeFailed : .decodeReturned)
                serveTrace?.emit(PommeAgentServeLoopTrace.classification(decoded))
                if let envelope = decoded, envelope.kind == .stream {
                    guard !terminalAuthority, connection.permitsStream,
                          let jobID = streamJobID(envelope),
                          let frames = try? await routeStream(envelope, agent: agent)
                    else { return }
                    for frame in frames {
                        guard let encoded = try? PommeAgentProtocol.encode(frame.envelope()),
                              writeFrame(encoded)
                        else { return }
                    }
                    // A stream mutation with no output still needs a
                    // correlated completion delimiter.  The response is
                    // emitted only after acceptStream and all bounded output
                    // frames have completed.
                    let acknowledgement = PommeAgentProtocol.Envelope.response(
                        to: envelope,
                        result: .object(["jobID": .string(jobID.uuidString.lowercased())])
                    )
                    guard let encoded = try? PommeAgentProtocol.encode(acknowledgement),
                          writeFrame(encoded)
                    else { return }
                    continue
                }
                let request = decoded
                let desktopStartTrace = normalScope && request.map(PommeDesktopStartBoundaryTrace.admits) == true
                    ? PommeDesktopStartBoundaryTrace(sink: desktopStartTraceSink ?? PommeDesktopStartBoundaryTrace.guestLog)
                    : nil
                desktopStartTrace?.emit(.requestDecoded)
                if let request,
                   request.kind == .request,
                   request.operation != "authenticate" {
                    // A wrong operation is a policy violation, not an
                    // invitation to probe the Recovery agent. Return only a
                    // redacted protocol error, then close the descriptor.
                    let permitted = terminalAuthority
                        ? request.operation == "agent.describe"
                            || request.operation == "agent.health"
                            || request.operation.hasPrefix("terminal.")
                        : allowedOperation == nil || request.operation == allowedOperation
                    guard permitted, !operationConsumed
                    else {
                        let response = await connection.receive(line) { _ in throw PommeAgentOperationError.unsupported }
                        guard !response.isEmpty, writeFrame(response) else { return }
                        return
                    }
                }
                var signalTrace: PommeSignalBoundaryTrace?
                if normalScope, request?.kind == .request, request?.operation == "process.signal" {
                    // Fixed decoded/admission events contain no request data,
                    // including when the connection has not authenticated.
                    signalTrace = PommeSignalBoundaryTrace(sink: signalTraceSink ?? PommeSignalBoundaryTrace.guestLog)
                    signalTrace?.emit(.guestSignalDecoded)
                }
                var handlerEntered = false
                let response = await connection.receive(line) { request in
                    // receive invokes this handler only after authentication
                    // and credential/replay checks. Recovery never opts in.
                    desktopStartTrace?.emit(.requestAccepted)
                    desktopStartTrace?.emit(.handlerEntered)
                    if normalScope, request.kind == .request, request.operation == "process.status" {
                        signalTrace = PommeSignalBoundaryTrace(
                            sink: signalTraceSink ?? PommeSignalBoundaryTrace.guestLog, isStatus: true)
                    }
                    handlerEntered = true
                    let isStart = request.kind == .request && request.operation == "process.start"
                    if isStart { serveTrace?.emit(.startHandlerEntered) }
                    signalTrace?.emit(.guestHandlerEntered)
                    do {
                        let result = try await agent.performAsynchronously(request)
                        if isStart { serveTrace?.emit(.startHandlerReturned) }
                        desktopStartTrace?.emit(.performReturned)
                        signalTrace?.emit(.guestPerformReturned)
                        if allowedOperation != nil && !terminalAuthority { try oneShotCleanup() }
                        return result
                    } catch {
                        if isStart { serveTrace?.emit(.startHandlerFailed) }
                        desktopStartTrace?.emit(.performFailed)
                        signalTrace?.emit(.guestPerformFailed)
                        if allowedOperation != nil && !terminalAuthority { try? oneShotCleanup() }
                        throw error
                    }
                }
                if !handlerEntered { desktopStartTrace?.emit(.requestRejected) }
                if signalTrace != nil, !handlerEntered {
                    let rejection: PommeSignalBoundaryTrace.Event
                    switch (try? decodeResponse(response))?.error?.code {
                    case "replayed-request": rejection = .guestSignalRejectedReplay
                    case "authentication-required": rejection = .guestSignalRejectedAuthenticationRequired
                    case "credential-expired": rejection = .guestSignalRejectedExpired
                    default: rejection = .guestSignalRejectedOther
                    }
                    signalTrace?.emit(rejection)
                }
                // Process output is part of the same request exchange.  The
                // correlated response is the host-side delimiter, so drain
                // successful normal process operations before publishing it.
                // In particular, do not call streamEvents for an
                // unauthenticated or failed request: neither is permitted to
                // observe a job's output.
                if allowedOperation == nil || terminalAuthority,
                   let request,
                   let responseEnvelope = try? decodeResponse(response),
                   responseEnvelope.ok == true,
                   let jobID = processJobID(request: request, response: responseEnvelope) {
                    signalTrace?.emit(.guestStreamsEntered)
                    desktopStartTrace?.emit(.streamsEntered)
                    let events = try? await processEvents(
                        request: request,
                        jobID: jobID,
                        agent: agent
                    )
                    signalTrace?.emit(events == nil ? .guestStreamsFailed : .guestStreamsReturned)
                    desktopStartTrace?.emit(events == nil ? .streamsFailed : .streamsReturned)
                    for event in events ?? [] {
                        let frame = PommeAgentJobStreamFrame(jobID: jobID, frame: event)
                        signalTrace?.emit(.guestStreamWriteEntered)
                        desktopStartTrace?.emit(.streamWriteEntered)
                        guard let encoded = try? PommeAgentProtocol.encode(frame.envelope()),
                              writeFrame(encoded)
                        else {
                            signalTrace?.emit(.guestStreamWriteFailed)
                            desktopStartTrace?.emit(.streamWriteFailed)
                            return
                        }
                        signalTrace?.emit(.guestStreamWritten)
                        desktopStartTrace?.emit(.streamWritten)
                    }
                }
                signalTrace?.emit(.guestResponseWriteEntered)
                desktopStartTrace?.emit(.responseWriteEntered)
                guard !response.isEmpty, writeFrame(response) else {
                    signalTrace?.emit(.guestResponseWriteFailed)
                    desktopStartTrace?.emit(.responseWriteFailed)
                    return
                }
                signalTrace?.emit(.guestResponseWritten)
                desktopStartTrace?.emit(.responseWritten)
                if let request,
                   request.kind == .request,
                   request.operation != "authenticate",
                   allowedOperation != nil && !terminalAuthority {
                    // Count failed operations too. An operation may have
                    // partially mutated guest state before producing its
                    // correlated error, so retrying is never safe.
                    operationConsumed = true
                    return
                }
            }
        }
    }

    private static let processOperations: Set<String> = [
        "process.start", "process.status", "process.signal", "process.output", "process.wait"
    ]

    private static func processEvents(
        request: PommeAgentProtocol.Envelope,
        jobID: UUID,
        agent: PommeAgent
    ) async throws -> [PommeAgentStreamFrame] {
        switch request.operation {
        case "process.output", "process.wait":
            return try await agent.retainedLogEvents(jobID: jobID, requestID: request.requestID)
        default:
            return try await agent.streamEvents(jobID: jobID, requestID: request.requestID)
        }
    }

    private static func decodeResponse(_ data: Data) throws -> PommeAgentProtocol.Envelope {
        guard data.last == 0x0A else { throw PommeAgentProtocol.Error.invalidResponse }
        return try PommeAgentProtocol.decode(Data(data.dropLast()))
    }

    private static func processJobID(
        request: PommeAgentProtocol.Envelope,
        response: PommeAgentProtocol.Envelope
    ) -> UUID? {
        guard request.kind == .request,
              processOperations.contains(request.operation),
              response.kind == .response,
              response.ok == true
        else { return nil }

        let responseText = response.result?.objectValue?["jobID"]?.stringValue
        let requestText = request.payload.objectValue?["jobID"]?.stringValue
        return [responseText, requestText]
            .compactMap { $0 }
            .compactMap { UUID(uuidString: $0) }
            .first
    }

    private static func streamJobID(_ envelope: PommeAgentProtocol.Envelope) -> UUID? {
        guard let text = envelope.payload.objectValue?["jobID"]?.stringValue else { return nil }
        return UUID(uuidString: text)
    }

    private static func routeStream(_ envelope: PommeAgentProtocol.Envelope, agent: PommeAgent) async throws -> [PommeAgentJobStreamFrame] {
        guard let values = envelope.payload.objectValue,
              let streamName = values["stream"]?.stringValue,
              let stream = PommeAgentProtocol.Stream(rawValue: streamName),
              let jobText = values["jobID"]?.stringValue, let jobID = UUID(uuidString: jobText) else { throw PommeAgentProtocol.Error.invalidStream }
        let data = try values["dataBase64"].flatMap { value -> Data? in guard let text = value.stringValue else { throw PommeAgentProtocol.Error.invalidStream }; guard let decoded = Data(base64Encoded: text) else { throw PommeAgentProtocol.Error.invalidStream }; return decoded }
        let dimensions: (columns: Int, rows: Int)?
        if stream == .resize, case .integer(let columns)? = values["columns"], case .integer(let rows)? = values["rows"], let columnInt = Int(exactly: columns), let rowInt = Int(exactly: rows) { dimensions = (columnInt, rowInt) } else { dimensions = nil }
        let signal: Int32?
        if case .integer(let raw)? = values["signal"], let parsed = Int32(exactly: raw) { signal = parsed } else { signal = nil }
        return try await agent.acceptStream(.init(requestID: envelope.requestID, stream: stream, data: data, dimensions: dimensions, signal: signal), jobID: jobID).map { .init(jobID: jobID, frame: $0) }
    }

    /// Reads a root-owned token through an O_NOFOLLOW descriptor and, for a
    /// Recovery launch, unlinks that exact pathname before any host connect.
    /// The token never enters a diagnostic or an error value.
    static func readToken(
        at path: String,
        consume: Bool = false,
        expectedOwner: uid_t = 0,
        expectedGroup: gid_t = 0
    ) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw PommeAgentDaemonError(.credential) }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PommeAgentDaemonError(.credential) }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedOwner,
              info.st_gid == expectedGroup,
              info.st_mode & 0o077 == 0,
              info.st_size > 0,
              info.st_size <= 4 * 1024
        else { throw PommeAgentDaemonError(.credential) }

        var data = Data(capacity: Int(info.st_size))
        var bytes = [UInt8](repeating: 0, count: 512)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard data.count + count <= 4 * 1024 else { throw PommeAgentDaemonError(.credential) }
                data.append(contentsOf: bytes.prefix(Int(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw PommeAgentDaemonError(.credential)
            }
        }

        let token: String
        do {
            token = try PommeAgentAuthentication.normalized(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw PommeAgentDaemonError(.credential)
        }

        if consume {
            // The staging share is private and immutable. Still verify that
            // the pathname names the descriptor we read before unlinking it.
            var current = stat()
            guard lstat(path, &current) == 0,
                  current.st_dev == info.st_dev,
                  current.st_ino == info.st_ino,
                  unlink(path) == 0
            else { throw PommeAgentDaemonError(.credential) }
        }
        return token
    }

    private static func connectToHost(port: UInt32) throws -> Int32 {
        let descriptor = Darwin.socket(AF_VSOCK, SOCK_STREAM, 0); guard descriptor >= 0 else { throw PommeAgentDaemonError(.transport) }
        var address = sockaddr_vm(); address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size); address.svm_family = sa_family_t(AF_VSOCK); address.svm_port = port; address.svm_cid = 2
        guard withUnsafePointer(to: &address, { pointer in Darwin.connect(descriptor, UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_vm>.size)) }) == 0 else { _ = Darwin.close(descriptor); throw PommeAgentDaemonError(.transport) }
        return descriptor
    }

    private static func writeAll(descriptor: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in var offset = 0; while offset < bytes.count { let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset); guard count > 0 else { return false }; offset += count }; return true }
    }

    private static func blocking(_ work: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0); Task { await work(); semaphore.signal() }; semaphore.wait()
    }
}

private struct PommeAgentDaemonError: Error { let exit: PommeAgentDaemon.Exit; init(_ exit: PommeAgentDaemon.Exit) { self.exit = exit } }
