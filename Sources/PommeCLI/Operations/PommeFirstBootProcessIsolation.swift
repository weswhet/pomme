import CryptoKit
import Darwin
import Foundation

/// Immutable public identity for the short-lived, process-isolated first
/// normal boot worker. Capability is carried only by fixed inherited file
/// descriptors and is never serialized into this request.
struct PommeFirstBootProcessRequest: Equatable, Sendable {
    static let operation = "pomme-first-normal-boot"
    static let supervisorFlag = "--pomme-first-boot-supervisor"
    static let workerFlag = "--pomme-first-boot-worker"
    static let childFlag = workerFlag

    let bundlePath: String
    let vmName: String
    let vmUUID: String
    let executableSHA256: String
    let bundleIdentity: String
    let nonce: String
    let timeout: TimeInterval

    init(
        bundlePath: String,
        vmName: String,
        vmUUID: String,
        executableSHA256: String,
        bundleIdentity: String,
        nonce: String,
        timeout: TimeInterval
    ) throws {
        guard bundlePath.hasPrefix("/"),
              URL(fileURLWithPath: bundlePath).standardizedFileURL.path == bundlePath,
              URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().standardizedFileURL.path
                == bundlePath,
              (try? validateVMName(vmName)) == vmName,
              UUID(uuidString: vmUUID)?.uuidString.lowercased() == vmUUID,
              Self.isCanonicalDigest(executableSHA256),
              Self.isCanonicalDigest(bundleIdentity),
              UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
              timeout.isFinite,
              timeout > 0,
              timeout <= 600
        else { throw PommeFirstBootProcessError.invalidRequest }
        self.bundlePath = bundlePath
        self.vmName = vmName
        self.vmUUID = vmUUID
        self.executableSHA256 = executableSHA256
        self.bundleIdentity = bundleIdentity
        self.nonce = nonce
        self.timeout = timeout
    }

    var childArguments: [String] {
        childArguments(role: .worker)
    }

    func childArguments(role: PommeFirstBootProcessRole) -> [String] {
        [
            role.flag,
            "--bundle", bundlePath,
            "--name", vmName,
            "--vm-uuid", vmUUID,
            "--executable-sha256", executableSHA256,
            "--bundle-identity", bundleIdentity,
            "--nonce", nonce,
            "--timeout", String(timeout)
        ]
    }

    static func parseChildArguments(_ arguments: [String]) throws -> Self? {
        guard PommeFirstBootProcessRole(arguments.first) != nil else { return nil }
        guard arguments.count == 15,
              arguments[1] == "--bundle",
              arguments[3] == "--name",
              arguments[5] == "--vm-uuid",
              arguments[7] == "--executable-sha256",
              arguments[9] == "--bundle-identity",
              arguments[11] == "--nonce",
              arguments[13] == "--timeout",
              let timeout = TimeInterval(arguments[14])
        else { throw PommeFirstBootProcessError.invalidRequest }
        return try .init(
            bundlePath: arguments[2],
            vmName: arguments[4],
            vmUUID: arguments[6],
            executableSHA256: arguments[8],
            bundleIdentity: arguments[10],
            nonce: arguments[12],
            timeout: timeout
        )
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }
    }
}

enum PommeFirstBootProcessRole: Equatable, Sendable {
    case supervisor
    case worker

    init?(_ flag: String?) {
        switch flag {
        case PommeFirstBootProcessRequest.supervisorFlag: self = .supervisor
        case PommeFirstBootProcessRequest.workerFlag: self = .worker
        default: return nil
        }
    }

    var flag: String {
        switch self {
        case .supervisor: PommeFirstBootProcessRequest.supervisorFlag
        case .worker: PommeFirstBootProcessRequest.workerFlag
        }
    }
}

enum PommeFirstBootProcessError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case capabilityRejected
    case identityRejected
    case spawnFailed
    case processCancelled
    case processTimedOut
    case processFailed
    case invalidReceipt
    case containmentFailed

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Pomme rejected the isolated first-boot request."
        case .capabilityRejected: "Pomme rejected the isolated first-boot capability."
        case .identityRejected: "Pomme rejected isolated first-boot identity evidence."
        case .spawnFailed: "Pomme could not start the isolated first-boot worker."
        case .processCancelled: "Pomme contained a cancelled isolated first-boot worker."
        case .processTimedOut: "Pomme contained a timed-out isolated first-boot worker."
        case .processFailed: "Pomme's isolated first-boot worker failed."
        case .invalidReceipt: "Pomme rejected the isolated first-boot receipt."
        case .containmentFailed: "Pomme could not prove isolated first-boot process containment."
        }
    }
}

/// Closed child-to-parent receipt. It contains only immutable identities and
/// content-free barrier evidence; screenshots and OCR strings never cross the
/// process boundary.
struct PommeFirstBootProcessReceipt: Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumBytes = 4_096

    enum Outcome: String, Sendable { case success, failure }

    let outcome: Outcome
    let nonce: String
    let vmUUID: String
    let executableSHA256: String
    let bundleIdentity: String
    let setupAssistantSurfaceProven: Bool
    let stableObservationCount: Int
    let reconstructionCount: Int
    let stoppedStateProven: Bool

    static func success(
        request: PommeFirstBootProcessRequest,
        barrier: PommeFirstBootReceipt
    ) -> Self {
        .init(
            outcome: .success,
            nonce: request.nonce,
            vmUUID: request.vmUUID,
            executableSHA256: request.executableSHA256,
            bundleIdentity: request.bundleIdentity,
            setupAssistantSurfaceProven: barrier.setupAssistantSurfaceProven,
            stableObservationCount: barrier.stableObservationCount,
            reconstructionCount: barrier.reconstructionCount,
            stoppedStateProven: barrier.stoppedStateProven
        )
    }

    static func failure(request: PommeFirstBootProcessRequest) -> Self {
        .init(
            outcome: .failure,
            nonce: request.nonce,
            vmUUID: request.vmUUID,
            executableSHA256: request.executableSHA256,
            bundleIdentity: request.bundleIdentity,
            setupAssistantSurfaceProven: false,
            stableObservationCount: 0,
            reconstructionCount: 0,
            stoppedStateProven: false
        )
    }

    func encodedLine() -> Data? {
        let object: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "operation": PommeFirstBootProcessRequest.operation,
            "outcome": outcome.rawValue,
            "nonce": nonce,
            "vmUUID": vmUUID,
            "executableSHA256": executableSHA256,
            "bundleIdentity": bundleIdentity,
            "setupAssistantSurfaceProven": setupAssistantSurfaceProven,
            "stableObservationCount": stableObservationCount,
            "reconstructionCount": reconstructionCount,
            "stoppedStateProven": stoppedStateProven
        ]
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), data.count + 1 <= Self.maximumBytes else { return nil }
        data.append(0x0a)
        return data
    }

    static func decodeClosed(
        _ data: Data,
        matching request: PommeFirstBootProcessRequest
    ) -> Self? {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              data.last == 0x0a,
              !data.dropLast().contains(0x0a),
              !data.dropLast().contains(0x0d),
              !data.contains(0x5c),
              !hasDuplicateKeys(data),
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = object as? [String: Any],
              Set(value.keys) == Set(keys),
              value["schemaVersion"] as? Int == schemaVersion,
              value["operation"] as? String == PommeFirstBootProcessRequest.operation,
              let rawOutcome = value["outcome"] as? String,
              let outcome = Outcome(rawValue: rawOutcome),
              value["nonce"] as? String == request.nonce,
              value["vmUUID"] as? String == request.vmUUID,
              value["executableSHA256"] as? String == request.executableSHA256,
              value["bundleIdentity"] as? String == request.bundleIdentity,
              let setupAssistantSurfaceProven = value["setupAssistantSurfaceProven"] as? Bool,
              let stableObservationCount = value["stableObservationCount"] as? Int,
              let reconstructionCount = value["reconstructionCount"] as? Int,
              let stoppedStateProven = value["stoppedStateProven"] as? Bool,
              stableObservationCount >= 0,
              reconstructionCount >= 0,
              reconstructionCount <= 1
        else { return nil }

        switch outcome {
        case .success:
            guard setupAssistantSurfaceProven,
                  stableObservationCount >= PommeFirstBootBarrier.requiredStableObservations,
                  stoppedStateProven
            else { return nil }
        case .failure:
            guard !setupAssistantSurfaceProven,
                  stableObservationCount == 0,
                  reconstructionCount == 0,
                  !stoppedStateProven
            else { return nil }
        }
        return .init(
            outcome: outcome,
            nonce: request.nonce,
            vmUUID: request.vmUUID,
            executableSHA256: request.executableSHA256,
            bundleIdentity: request.bundleIdentity,
            setupAssistantSurfaceProven: setupAssistantSurfaceProven,
            stableObservationCount: stableObservationCount,
            reconstructionCount: reconstructionCount,
            stoppedStateProven: stoppedStateProven
        )
    }

    private static let keys = [
        "schemaVersion", "operation", "outcome", "nonce", "vmUUID",
        "executableSHA256", "bundleIdentity", "setupAssistantSurfaceProven",
        "stableObservationCount", "reconstructionCount", "stoppedStateProven"
    ]

    private static func hasDuplicateKeys(_ data: Data) -> Bool {
        let source = String(decoding: data, as: UTF8.self)
        return keys.contains { key in
            source.components(separatedBy: "\"\(key)\"").count > 2
        }
    }
}

private final class PommeFirstBootCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

/// POSIX process boundary between the display-only first normal boot and the
/// subsequent Recovery VM. Recovery may begin only after worker-descendant EOF,
/// exact supervisor/worker reaping, and a closed receipt prove the VZ attempt
/// stopped.
enum PommeFirstBootProcessIsolation {
    static let inheritedLeaseDescriptor: Int32 = 198
    static let parentLivenessDescriptor: Int32 = 199
    static let workerResultDescriptor: Int32 = 200
    static let descendantLivenessDescriptor: Int32 = 201
    static let workerDescendantLivenessDescriptor: Int32 = 202
    /// The liveness protocol has no valid payload.  Keep the read itself
    /// bounded so an untrusted descendant cannot make the observer spin
    /// forever by continuously writing bytes.
    private static let supervisorLivenessReadLimit = 64
    /// After SIGKILL, drain at most one protocol frame's worth of already
    /// buffered invalid bytes. EOF then proves that no escaped descendant
    /// still owns the liveness writer; a larger buffer fails closed.
    private static let supervisorLivenessDrainLimit = 256 * 1_024

    static func makeBundleIdentity(bundlePath: String, name: String) throws -> String {
        let url = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard url.path == bundlePath,
              url.resolvingSymlinksInPath().standardizedFileURL == url,
              (try? validateVMName(name)) == name
        else { throw PommeFirstBootProcessError.identityRejected }
        var info = stat()
        guard lstat(bundlePath, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid()
        else { throw PommeFirstBootProcessError.identityRejected }
        let material = "\(name)\n\(bundlePath)\n\(info.st_dev)\n\(info.st_ino)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func executableDigest(at url: URL) throws -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == url.standardizedFileURL.path else {
            throw PommeFirstBootProcessError.identityRejected
        }
        let data: Data
        do { data = try Data(contentsOf: canonical, options: .mappedIfSafe) }
        catch { throw PommeFirstBootProcessError.identityRejected }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func run(
        request: PommeFirstBootProcessRequest,
        lease: VMBundleMutationLease,
        executableURL: URL,
        isolationTimeout: TimeInterval? = nil,
        terminationGrace: TimeInterval = 5
    ) async throws -> PommeFirstBootProcessReceipt {
        guard isolationTimeout.map({ $0.isFinite && $0 > 0 }) ?? true,
              terminationGrace.isFinite,
              terminationGrace > 0
        else { throw PommeFirstBootProcessError.invalidRequest }
        let cancellation = PommeFirstBootCancellationSignal()
        return try await withTaskCancellationHandler(operation: {
            let task = Task.detached(priority: .userInitiated) {
                try runWithSupervisor(
                    request: request,
                    lease: lease,
                    executableURL: executableURL,
                    isolationTimeout: isolationTimeout,
                    terminationGrace: terminationGrace,
                    cancellation: cancellation
                )
            }
            // Cancellation becomes a parent-liveness EOF. This await returns
            // only after the supervisor group is contained and exactly reaped.
            return try await task.value
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// Hidden intermediate process. It owns the only child allowed to create
    /// first-boot Virtualization objects and contains that child if the public
    /// CLI disappears. The supervisor itself never constructs a VM object.
    static func runSupervisor(request: PommeFirstBootProcessRequest) -> Int32 {
        runSupervisorProcess(request: request)
    }

    static func runChild(
        request: PommeFirstBootProcessRequest,
        operation: @escaping @Sendable () async throws -> PommeFirstBootReceipt
    ) async -> Int32 {
        guard VMBundleMutationLease.isActivelyHeld(
            descriptor: inheritedLeaseDescriptor,
            for: request.vmName
        ), descriptorIsOpen(workerResultDescriptor),
           descriptorIsOpen(descendantLivenessDescriptor),
           descriptorIsOpen(workerDescendantLivenessDescriptor),
           setCloseOnExec(inheritedLeaseDescriptor),
           setCloseOnExec(workerResultDescriptor)
        else { return 64 }
        do {
            guard try makeBundleIdentity(
                bundlePath: request.bundlePath,
                name: request.vmName
            ) == request.bundleIdentity,
                  try currentExecutableDigest() == request.executableSHA256
            else { return 65 }
        } catch { return 65 }

        let receipt: PommeFirstBootProcessReceipt
        let exitCode: Int32
        do {
            receipt = .success(request: request, barrier: try await operation())
            exitCode = 0
        } catch {
            receipt = .failure(request: request)
            exitCode = 1
        }
        guard let data = receipt.encodedLine(),
              writeAll(workerResultDescriptor, data: data)
        else { return 66 }
        return exitCode
    }

    private static func spawnSource(from descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 256)
        guard duplicate >= 0 else { throw PommeFirstBootProcessError.spawnFailed }
        return duplicate
    }

    private static func currentExecutableDigest() throws -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { throw PommeFirstBootProcessError.identityRejected }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw PommeFirstBootProcessError.identityRejected
        }
        let path = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return try executableDigest(
            at: URL(fileURLWithPath: path).resolvingSymlinksInPath()
        )
    }

    private enum LeaderReapState: Equatable {
        case running
        case reaped
        case unprovable
    }

    private static func reapLeaderIfExited(
        _ pid: pid_t,
        status: inout Int32
    ) -> LeaderReapState {
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return .reaped }
            if waited == 0 { return .running }
            if waited < 0, errno == EINTR { continue }
            return .unprovable
        }
    }

    private static func readBounded(
        _ descriptor: Int32,
        maximumBytes: Int,
        deadline: TimeInterval
    ) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForReadable(descriptor, deadline: deadline) else {
                    throw PommeFirstBootProcessError.containmentFailed
                }
                continue
            }
            guard count >= 0 else {
                throw PommeFirstBootProcessError.invalidReceipt
            }
            if count == 0 { break }
            guard output.count + count <= maximumBytes else {
                throw PommeFirstBootProcessError.invalidReceipt
            }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    private static func waitForReadable(
        _ descriptor: Int32,
        deadline: TimeInterval
    ) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var item = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let milliseconds = Int32(min(remaining * 1_000, 50).rounded(.up))
            let result = poll(&item, 1, max(milliseconds, 1))
            if result > 0 {
                return item.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0
            }
            if result < 0, errno == EINTR { continue }
            if result < 0 { return false }
        }
    }

    private static func descriptorIsOpen(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_GETFD) >= 0
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func writeAll(_ descriptor: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let count = write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func closeIfOpen(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    private static func exitedNormally(_ status: Int32) -> Bool {
        status & 0x7f == 0
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }
}

private extension PommeFirstBootProcessIsolation {
    struct SupervisorPipeObservation {
        var eof = false
        var protocolViolation = false
        var failed = false

        var isCleanEOF: Bool { eof && !protocolViolation && !failed }
    }

    static func runWithSupervisor(
        request: PommeFirstBootProcessRequest,
        lease: VMBundleMutationLease,
        executableURL: URL,
        isolationTimeout: TimeInterval?,
        terminationGrace: TimeInterval,
        cancellation: PommeFirstBootCancellationSignal
    ) throws -> PommeFirstBootProcessReceipt {
        guard lease.validates(name: request.vmName) else {
            throw PommeFirstBootProcessError.capabilityRejected
        }
        guard try makeBundleIdentity(
            bundlePath: request.bundlePath,
            name: request.vmName
        ) == request.bundleIdentity,
              try executableDigest(at: executableURL) == request.executableSHA256
        else { throw PommeFirstBootProcessError.identityRejected }
        guard !cancellation.isCancelled else {
            throw PommeFirstBootProcessError.processCancelled
        }

        var resultPipe = [Int32](repeating: -1, count: 2)
        var parentPipe = [Int32](repeating: -1, count: 2)
        var descendantPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&resultPipe) == 0 else {
            throw PommeFirstBootProcessError.spawnFailed
        }
        guard pipe(&parentPipe) == 0 else {
            close(resultPipe[0]); close(resultPipe[1])
            throw PommeFirstBootProcessError.spawnFailed
        }
        guard pipe(&descendantPipe) == 0 else {
            close(resultPipe[0]); close(resultPipe[1])
            close(parentPipe[0]); close(parentPipe[1])
            throw PommeFirstBootProcessError.spawnFailed
        }

        var resultReader = resultPipe[0]
        var resultWriter = resultPipe[1]
        var parentReader = parentPipe[0]
        var parentWriter = parentPipe[1]
        var descendantReader = descendantPipe[0]
        var descendantWriter = descendantPipe[1]
        defer {
            closeIfOpen(&resultReader)
            closeIfOpen(&resultWriter)
            closeIfOpen(&parentReader)
            closeIfOpen(&parentWriter)
            closeIfOpen(&descendantReader)
            closeIfOpen(&descendantWriter)
        }
        guard setNonBlocking(resultReader), setNonBlocking(descendantReader) else {
            throw PommeFirstBootProcessError.spawnFailed
        }

        var leaseDescriptor = try lease.duplicateDescriptor()
        defer { closeIfOpen(&leaseDescriptor) }
        let supervisor = try spawnIsolatedProcess(
            role: .supervisor,
            request: request,
            executableURL: executableURL,
            leaseDescriptor: leaseDescriptor,
            parentDescriptor: parentReader,
            resultDescriptor: resultWriter,
            descendantDescriptor: descendantWriter,
            workerDescendantDescriptor: nil,
            createProcessGroup: true
        )
        closeIfOpen(&leaseDescriptor)
        closeIfOpen(&resultWriter)
        closeIfOpen(&parentReader)
        closeIfOpen(&descendantWriter)

        let deadline = ProcessInfo.processInfo.systemUptime
            + (isolationTimeout ?? processTimeout(for: request))
        var stopError: PommeFirstBootProcessError?
        while true {
            if cancellation.isCancelled {
                stopError = .processCancelled
                break
            }
            if pipeReachedEOF(resultReader) { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stopError = .processTimedOut
                break
            }
            usleep(20_000)
        }
        if cancellation.isCancelled { stopError = .processCancelled }
        closeIfOpen(&parentWriter)

        var status: Int32 = 0
        if let stopError {
            let cooperativeDeadline = ProcessInfo.processInfo.systemUptime
                + terminationGrace + 2
            while !pipeReachedEOF(resultReader),
                  ProcessInfo.processInfo.systemUptime < cooperativeDeadline {
                usleep(20_000)
            }
            let observation = observeSupervisorPipeEOF(
                descendantReader,
                deadline: cooperativeDeadline
            )
            if !pipeReachedEOF(resultReader) || !observation.isCleanEOF {
                guard terminateSupervisorGroup(
                    supervisor,
                    status: &status,
                    descendantDescriptor: descendantReader,
                    priorObservation: observation,
                    grace: terminationGrace
                ) else { throw PommeFirstBootProcessError.containmentFailed }
            } else {
                guard reapExactOwnedProcess(
                    supervisor,
                    status: &status,
                    deadline: ProcessInfo.processInfo.systemUptime
                        + max(terminationGrace, 1)
                ), waitForProcessGroupAbsenceWithoutSignalling(
                    supervisor,
                    deadline: ProcessInfo.processInfo.systemUptime
                        + max(terminationGrace, 1)
                ) else { throw PommeFirstBootProcessError.containmentFailed }
            }
            throw stopError
        }

        let observation = observeSupervisorPipeEOF(
            descendantReader,
            deadline: ProcessInfo.processInfo.systemUptime + terminationGrace
        )
        guard observation.isCleanEOF else {
            guard terminateSupervisorGroup(
                supervisor,
                status: &status,
                descendantDescriptor: descendantReader,
                priorObservation: observation,
                grace: terminationGrace
            ) else { throw PommeFirstBootProcessError.containmentFailed }
            throw PommeFirstBootProcessError.containmentFailed
        }
        guard reapExactOwnedProcess(
            supervisor,
            status: &status,
            deadline: ProcessInfo.processInfo.systemUptime + max(terminationGrace, 1)
        ), waitForProcessGroupAbsenceWithoutSignalling(
            supervisor,
            deadline: ProcessInfo.processInfo.systemUptime + max(terminationGrace, 1)
        ) else { throw PommeFirstBootProcessError.containmentFailed }

        let output = try readBounded(
            resultReader,
            maximumBytes: PommeFirstBootProcessReceipt.maximumBytes,
            deadline: ProcessInfo.processInfo.systemUptime + terminationGrace
        )
        guard exitedNormally(status), exitCode(status) == 0 else {
            throw PommeFirstBootProcessError.processFailed
        }
        guard let receipt = PommeFirstBootProcessReceipt.decodeClosed(
            output,
            matching: request
        ), receipt.outcome == .success else {
            throw PommeFirstBootProcessError.invalidReceipt
        }
        guard !cancellation.isCancelled else {
            throw PommeFirstBootProcessError.processCancelled
        }
        return receipt
    }

    static func runSupervisorProcess(
        request: PommeFirstBootProcessRequest
    ) -> Int32 {
        guard VMBundleMutationLease.isActivelyHeld(
            descriptor: inheritedLeaseDescriptor,
            for: request.vmName
        ), descriptorIsOpen(parentLivenessDescriptor),
           descriptorIsOpen(workerResultDescriptor),
           descriptorIsOpen(descendantLivenessDescriptor),
           setCloseOnExec(inheritedLeaseDescriptor),
           setCloseOnExec(parentLivenessDescriptor),
           setCloseOnExec(workerResultDescriptor),
           setNonBlocking(parentLivenessDescriptor)
        else { return 64 }
        _ = signal(SIGPIPE, SIG_IGN)

        let executableURL: URL
        do {
            executableURL = try currentExecutableURL()
            guard try makeBundleIdentity(
                bundlePath: request.bundlePath,
                name: request.vmName
            ) == request.bundleIdentity,
                  try executableDigest(at: executableURL) == request.executableSHA256
            else { return 65 }
        } catch { return 65 }

        do {
            return try superviseWorker(
                request: request,
                executableURL: executableURL
            )
        } catch {
            return writeSupervisorFailure(request: request)
        }
    }

    static func superviseWorker(
        request: PommeFirstBootProcessRequest,
        executableURL: URL
    ) throws -> Int32 {
        var resultPipe = [Int32](repeating: -1, count: 2)
        var livenessPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&resultPipe) == 0 else {
            throw PommeFirstBootProcessError.spawnFailed
        }
        guard pipe(&livenessPipe) == 0 else {
            close(resultPipe[0]); close(resultPipe[1])
            throw PommeFirstBootProcessError.spawnFailed
        }
        var resultReader = resultPipe[0]
        var resultWriter = resultPipe[1]
        var livenessReader = livenessPipe[0]
        var livenessWriter = livenessPipe[1]
        defer {
            closeIfOpen(&resultReader)
            closeIfOpen(&resultWriter)
            closeIfOpen(&livenessReader)
            closeIfOpen(&livenessWriter)
        }
        guard setNonBlocking(resultReader), setNonBlocking(livenessReader) else {
            throw PommeFirstBootProcessError.spawnFailed
        }

        let worker = try spawnIsolatedProcess(
            role: .worker,
            request: request,
            executableURL: executableURL,
            leaseDescriptor: inheritedLeaseDescriptor,
            parentDescriptor: nil,
            resultDescriptor: resultWriter,
            descendantDescriptor: descendantLivenessDescriptor,
            workerDescendantDescriptor: livenessWriter,
            createProcessGroup: false
        )
        closeIfOpen(&resultWriter)
        closeIfOpen(&livenessWriter)

        let deadline = ProcessInfo.processInfo.systemUptime
            + processTimeout(for: request)
        var status: Int32 = 0
        var leaderState = LeaderReapState.running
        var parentDied = false
        while leaderState == .running {
            leaderState = reapLeaderIfExited(worker, status: &status)
            if leaderState != .running { break }
            if parentLivenessIsBroken() {
                parentDied = true
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(20_000)
        }

        if leaderState == .unprovable { killCurrentProcessGroup() }
        if parentDied || leaderState == .running {
            containWorkerGroupFromSupervisor(
                worker,
                status: &status,
                leaderAlreadyReaped: false,
                descendantDescriptor: livenessReader,
                grace: 5
            )
            return parentDied ? 125 : writeSupervisorFailure(request: request)
        }

        let observation = observeSupervisorPipeEOF(
            livenessReader,
            deadline: ProcessInfo.processInfo.systemUptime + 5
        )
        guard observation.isCleanEOF else {
            containWorkerGroupFromSupervisor(
                worker,
                status: &status,
                leaderAlreadyReaped: true,
                descendantDescriptor: livenessReader,
                priorObservation: observation,
                grace: 5
            )
            return writeSupervisorFailure(request: request)
        }

        let output = try readBounded(
            resultReader,
            maximumBytes: PommeFirstBootProcessReceipt.maximumBytes,
            deadline: ProcessInfo.processInfo.systemUptime + 5
        )
        guard let receipt = PommeFirstBootProcessReceipt.decodeClosed(
            output,
            matching: request
        ) else { return writeSupervisorFailure(request: request) }
        let validExit: Bool
        switch receipt.outcome {
        case .success:
            validExit = exitedNormally(status) && exitCode(status) == 0
        case .failure:
            validExit = !exitedNormally(status) || exitCode(status) != 0
        }
        guard validExit, writeAll(workerResultDescriptor, data: output) else {
            return 1
        }
        return receipt.outcome == .success ? 0 : 1
    }

    static func writeSupervisorFailure(
        request: PommeFirstBootProcessRequest
    ) -> Int32 {
        if let data = PommeFirstBootProcessReceipt.failure(request: request).encodedLine() {
            _ = writeAll(workerResultDescriptor, data: data)
        }
        return 1
    }

    static func spawnIsolatedProcess(
        role: PommeFirstBootProcessRole,
        request: PommeFirstBootProcessRequest,
        executableURL: URL,
        leaseDescriptor: Int32,
        parentDescriptor: Int32?,
        resultDescriptor: Int32,
        descendantDescriptor: Int32,
        workerDescendantDescriptor: Int32?,
        createProcessGroup: Bool
    ) throws -> pid_t {
        guard (role == .supervisor) == (parentDescriptor != nil),
              (role == .worker) == (workerDescendantDescriptor != nil)
        else { throw PommeFirstBootProcessError.spawnFailed }

        var leaseSource: Int32 = -1
        var resultSource: Int32 = -1
        var descendantSource: Int32 = -1
        var parentSource: Int32 = -1
        var workerDescendantSource: Int32 = -1
        var nullSource: Int32 = -1
        defer {
            closeIfOpen(&leaseSource)
            closeIfOpen(&resultSource)
            closeIfOpen(&descendantSource)
            closeIfOpen(&parentSource)
            closeIfOpen(&workerDescendantSource)
            closeIfOpen(&nullSource)
        }
        leaseSource = try spawnSource(from: leaseDescriptor)
        resultSource = try spawnSource(from: resultDescriptor)
        descendantSource = try spawnSource(from: descendantDescriptor)
        if let parentDescriptor {
            parentSource = try spawnSource(from: parentDescriptor)
        }
        if let workerDescendantDescriptor {
            workerDescendantSource = try spawnSource(from: workerDescendantDescriptor)
        }
        let nullDescriptor = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            throw PommeFirstBootProcessError.spawnFailed
        }
        defer { close(nullDescriptor) }
        nullSource = try spawnSource(from: nullDescriptor)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw PommeFirstBootProcessError.spawnFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw PommeFirstBootProcessError.spawnFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        let processGroup: pid_t = createProcessGroup ? 0 : getpgrp()
        let parentActionOK = parentSource < 0
            || posix_spawn_file_actions_adddup2(
                &actions,
                parentSource,
                parentLivenessDescriptor
            ) == 0
        let workerActionOK = workerDescendantSource < 0
            || posix_spawn_file_actions_adddup2(
                &actions,
                workerDescendantSource,
                workerDescendantLivenessDescriptor
            ) == 0
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, processGroup) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullSource, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullSource, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullSource, STDERR_FILENO) == 0,
              posix_spawn_file_actions_adddup2(
                &actions,
                leaseSource,
                inheritedLeaseDescriptor
              ) == 0,
              posix_spawn_file_actions_adddup2(
                &actions,
                resultSource,
                workerResultDescriptor
              ) == 0,
              posix_spawn_file_actions_adddup2(
                &actions,
                descendantSource,
                descendantLivenessDescriptor
              ) == 0,
              parentActionOK,
              workerActionOK
        else { throw PommeFirstBootProcessError.spawnFailed }

        let executable = executableURL.standardizedFileURL.path
        let arguments = [executable] + request.childArguments(role: role)
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.dropLast().forEach { free($0) } }
        var environment = [strdup("PATH=/usr/bin:/bin"), strdup("LANG=C"), nil]
        defer { environment.dropLast().forEach { free($0) } }

        var pid: pid_t = 0
        let spawnCode = executable.withCString { path in
            posix_spawn(&pid, path, &actions, &attributes, &argv, &environment)
        }
        guard spawnCode == 0, pid > 0 else {
            throw PommeFirstBootProcessError.spawnFailed
        }
        return pid
    }

    static func terminateSupervisorGroup(
        _ supervisor: pid_t,
        status: inout Int32,
        descendantDescriptor: Int32,
        priorObservation: SupervisorPipeObservation = .init(),
        grace: TimeInterval
    ) -> Bool {
        // Signal results are advisory. Darwin may report EPERM for a process
        // group whose only remaining member is our unreaped zombie leader.
        // The authoritative containment proof is the exact waitpid followed
        // by observing that the process group no longer exists.
        _ = kill(-supervisor, SIGTERM)
        let observation = observeSupervisorPipeEOF(
            descendantDescriptor,
            deadline: ProcessInfo.processInfo.systemUptime + grace,
            prior: priorObservation
        )
        // A liveness byte is a protocol violation even if it was followed by
        // EOF.  Force-kill the owned process group in that case: TERM alone
        // is not a containment proof when a worker descendant can ignore it.
        let mustForceKill = priorObservation.protocolViolation
            || priorObservation.failed
            || observation.protocolViolation
            || observation.failed
        let finalObservation: SupervisorPipeObservation
        if !observation.eof || mustForceKill {
            _ = kill(-supervisor, SIGKILL)
            finalObservation = observeSupervisorPipeEOF(
                descendantDescriptor,
                deadline: ProcessInfo.processInfo.systemUptime + max(grace, 1),
                prior: observation,
                maximumBytes: supervisorLivenessDrainLimit,
                returnOnProtocolViolation: false
            )
        } else {
            finalObservation = observation
        }
        // A malformed liveness stream is already a terminal protocol error,
        // but it must not short-circuit cleanup.  Reap the exact supervisor
        // first and then prove its process group is gone before reporting
        // containment success to the caller (which still returns the public
        // protocol/containment failure).
        guard reapExactOwnedProcess(
                  supervisor,
                  status: &status,
                  deadline: ProcessInfo.processInfo.systemUptime + max(grace, 1)
              ),
              waitForProcessGroupAbsenceWithoutSignalling(
                  supervisor,
                  deadline: ProcessInfo.processInfo.systemUptime + max(grace, 1)
              ),
              finalObservation.eof
        else { return false }
        return true
    }

    static func containWorkerGroupFromSupervisor(
        _ worker: pid_t,
        status: inout Int32,
        leaderAlreadyReaped: Bool,
        descendantDescriptor: Int32,
        priorObservation: SupervisorPipeObservation = .init(),
        grace: TimeInterval
    ) {
        _ = signal(SIGTERM, SIG_IGN)
        if kill(-getpgrp(), SIGTERM) != 0, errno != ESRCH {
            killCurrentProcessGroup()
        }

        var leaderState: LeaderReapState = leaderAlreadyReaped
            ? .reaped
            : .running
        let termDeadline = ProcessInfo.processInfo.systemUptime + grace
        while leaderState == .running,
              ProcessInfo.processInfo.systemUptime < termDeadline {
            leaderState = reapLeaderIfExited(worker, status: &status)
            if leaderState == .running { usleep(20_000) }
        }
        if leaderState == .running {
            if kill(worker, SIGKILL) != 0, errno != ESRCH {
                killCurrentProcessGroup()
            }
            let killDeadline = ProcessInfo.processInfo.systemUptime + max(grace, 1)
            while leaderState == .running,
                  ProcessInfo.processInfo.systemUptime < killDeadline {
                leaderState = reapLeaderIfExited(worker, status: &status)
                if leaderState == .running { usleep(20_000) }
            }
        }
        guard leaderState == .reaped else { killCurrentProcessGroup() }

        let observation = observeSupervisorPipeEOF(
            descendantDescriptor,
            deadline: ProcessInfo.processInfo.systemUptime + max(grace, 1),
            prior: priorObservation
        )
        guard observation.isCleanEOF else { killCurrentProcessGroup() }
    }

    static func observeSupervisorPipeEOF(
        _ descriptor: Int32,
        deadline: TimeInterval,
        prior: SupervisorPipeObservation = .init(),
        maximumBytes: Int = supervisorLivenessReadLimit,
        returnOnProtocolViolation: Bool = true
    ) -> SupervisorPipeObservation {
        var observation = prior
        var observedBytes = 0
        var bytes = [UInt8](repeating: 0, count: min(maximumBytes, 4_096))
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                observation.failed = true
                return observation
            }
            let count = read(descriptor, &bytes, bytes.count)
            if count == 0 {
                observation.eof = true
                return observation
            }
            if count > 0 {
                observation.protocolViolation = true
                observedBytes += count
                guard observedBytes <= maximumBytes else {
                    observation.failed = true
                    return observation
                }
                // Before termination, one invalid byte is sufficient to
                // revoke the protocol. After SIGKILL, bounded draining must
                // continue through queued bytes to obtain the EOF proof.
                if returnOnProtocolViolation { return observation }
                continue
            }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                observation.failed = true
                return observation
            }
            guard waitForReadable(descriptor, deadline: deadline) else {
                observation.failed = true
                return observation
            }
        }
    }

    static func parentLivenessIsBroken() -> Bool {
        var item = pollfd(
            fd: parentLivenessDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let polled = poll(&item, 1, 0)
        guard polled > 0 else { return polled < 0 && errno != EINTR }
        guard item.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 else {
            return false
        }
        var byte: UInt8 = 0
        _ = read(parentLivenessDescriptor, &byte, 1)
        // The protocol carries no bytes. EOF, data, or a poll error all revoke
        // the parent's liveness capability.
        return true
    }

    static func pipeReachedEOF(_ descriptor: Int32) -> Bool {
        var item = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let polled = poll(&item, 1, 0)
        return polled > 0 && item.revents & Int16(POLLHUP) != 0
    }

    static func reapExactOwnedProcess(
        _ pid: pid_t,
        status: inout Int32,
        deadline: TimeInterval
    ) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            switch reapLeaderIfExited(pid, status: &status) {
            case .reaped: return true
            case .unprovable: return false
            case .running: usleep(20_000)
            }
        }
        return false
    }

    static func waitForProcessGroupAbsenceWithoutSignalling(
        _ processGroup: pid_t,
        deadline: TimeInterval
    ) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if kill(-processGroup, 0) == -1, errno == ESRCH { return true }
            usleep(20_000)
        }
        return kill(-processGroup, 0) == -1 && errno == ESRCH
    }

    static func currentExecutableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            throw PommeFirstBootProcessError.identityRejected
        }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw PommeFirstBootProcessError.identityRejected
        }
        let path = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    static func killCurrentProcessGroup() -> Never {
        _ = kill(-getpgrp(), SIGKILL)
        _exit(125)
    }

    static func processTimeout(
        for request: PommeFirstBootProcessRequest
    ) -> TimeInterval {
        max(30, request.timeout * 2 + 240)
    }
}
