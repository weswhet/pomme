import Darwin
import Foundation

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
            let agent = try PommeAgent(role: options.role, executableSHA256: options.expectedSHA256)
            while true {
                let descriptor = try connectToHost(port: options.port)
                let connection = try PommeAgentConnection(token: token, lifetime: options.role == .recovery ? .oneShot : .persistent,
                                                          expiresAt: options.oneShotExpiry, vmBinding: options.vmBinding, sessionBinding: options.sessionBinding)
                blocking {
                    await serve(
                        descriptor: descriptor,
                        connection: connection,
                        agent: agent,
                        allowedOperation: options.allowedOperation,
                        oneShotCleanup: oneShotCleanup
                    )
                }
                _ = Darwin.close(descriptor)
                if options.role == .recovery {
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
        switch (role, port) {
        case (.persistent, Constants.pommeAgentPort):
            guard expiry == nil, vmBinding == nil, sessionBinding == nil, values["--operation"] == nil, values["--request-file"] == nil else { throw PommeAgentDaemonError(.invalidArguments) }
            allowedOperation = nil
        case (.recovery, Constants.pommeRecoverySessionPort):
            // The bootstrap listener can only install the persistent agent.
            guard expiry != nil, vmBinding != nil, sessionBinding != nil,
                  values["--operation"] == PommeRecoveryOperation.installAgent.wireName,
                  values["--request-file"].map({ $0.hasPrefix("/") }) == true
            else { throw PommeAgentDaemonError(.invalidArguments) }
            allowedOperation = PommeRecoveryOperation.installAgent.wireName
        case (.recovery, Constants.pommeRecoveryRuntimePort):
            // Security operations are request-bound and closed; do not allow
            // a generic Recovery process on the runtime listener.
            guard expiry != nil, vmBinding != nil, sessionBinding != nil,
                  let operation = values["--operation"], Self.recoverySecurityOperations.contains(operation),
                  values["--request-file"].map({ $0.hasPrefix("/") }) == true
            else { throw PommeAgentDaemonError(.invalidArguments) }
            allowedOperation = operation
        default:
            throw PommeAgentDaemonError(.invalidArguments)
        }
        do { return try .init(port: port, tokenFile: token, expectedSHA256: PommeAgentAuthentication.normalized(digest), role: role, oneShotExpiry: expiry, vmBinding: vmBinding, sessionBinding: sessionBinding, requestFile: values["--request-file"], allowedOperation: allowedOperation) }
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
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        let request = URL(fileURLWithPath: requestFile).standardizedFileURL
        let credential = URL(fileURLWithPath: options.tokenFile).standardizedFileURL
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
        oneShotCleanup: @escaping @Sendable () throws -> Void = {}
    ) async {
        defer { connection.resetForReconnect() }
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
            let count = Darwin.read(descriptor, &scratch, scratch.count)
            guard count > 0 else { return }
            let received = scratch.prefix(count)
            guard buffer.count + received.count <= PommeAgentProtocol.maximumFrameBytes else { return }
            buffer.append(contentsOf: received)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard !line.isEmpty, line.count < PommeAgentProtocol.maximumFrameBytes else { return }
                if let envelope = try? PommeAgentProtocol.decode(line), envelope.kind == .stream {
                    guard connection.permitsStream, let frames = try? await routeStream(envelope, agent: agent) else { return }
                    for frame in frames { guard let encoded = try? PommeAgentProtocol.encode(frame.envelope()), writeAll(descriptor: descriptor, data: encoded) else { return } }
                    continue
                }
                let request = try? PommeAgentProtocol.decode(line)
                if let request,
                   request.kind == .request,
                   request.operation != "authenticate" {
                    // A wrong operation is a policy violation, not an
                    // invitation to probe the Recovery agent. Return only a
                    // redacted protocol error, then close the descriptor.
                    guard allowedOperation == nil || request.operation == allowedOperation,
                          !operationConsumed
                    else {
                        let response = await connection.receive(line) { _ in throw PommeAgentOperationError.unsupported }
                        guard !response.isEmpty, writeAll(descriptor: descriptor, data: response) else { return }
                        return
                    }
                }
                let response = await connection.receive(line) { request in
                    do {
                        let result = try await agent.perform(request)
                        if allowedOperation != nil { try oneShotCleanup() }
                        return result
                    } catch {
                        if allowedOperation != nil { try? oneShotCleanup() }
                        throw error
                    }
                }
                guard !response.isEmpty, writeAll(descriptor: descriptor, data: response) else { return }
                if let request,
                   request.kind == .request,
                   request.operation != "authenticate",
                   allowedOperation != nil {
                    // Count failed operations too. An operation may have
                    // partially mutated guest state before producing its
                    // correlated error, so retrying is never safe.
                    operationConsumed = true
                    return
                }
                if let request = try? PommeAgentProtocol.decode(line),
                   let jobText = request.payload.objectValue?["jobID"]?.stringValue,
                   let jobID = UUID(uuidString: jobText),
                   let events = try? await agent.streamEvents(jobID: jobID, requestID: request.requestID) {
                    for event in events { let frame = PommeAgentJobStreamFrame(jobID: jobID, frame: event); guard let encoded = try? PommeAgentProtocol.encode(frame.envelope()), writeAll(descriptor: descriptor, data: encoded) else { return } }
                }
            }
        }
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
