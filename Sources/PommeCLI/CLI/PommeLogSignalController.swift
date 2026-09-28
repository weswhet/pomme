import Darwin
import Dispatch
import Foundation

/// Converts SIGINT and SIGTERM into a request the log stream can clean up
/// before this process exits.
final class PommeLogSignalController: @unchecked Sendable {
    enum Reason: Equatable, Sendable {
        case interrupt
        case terminate

        var exitCode: Int32 {
            switch self {
            case .interrupt: 130
            case .terminate: 143
            }
        }
    }

    private let storage: PommeLogSignalStorage
    private let queue: DispatchQueue
    private let interruptSource: DispatchSourceSignal
    private let terminateSource: DispatchSourceSignal
    // SIG_DFL is a null function pointer; preserve it without implicitly
    // unwrapping Darwin.signal's optional return value.
    private let previousInterruptHandler: sig_t?
    private let previousTerminateHandler: sig_t?
    private let previousPipeHandler: sig_t?

    init() {
        let storage = PommeLogSignalStorage()
        let queue = DispatchQueue(label: "com.github.weswhet.pomme.log-signals")
        previousInterruptHandler = Darwin.signal(SIGINT, SIG_IGN)
        previousTerminateHandler = Darwin.signal(SIGTERM, SIG_IGN)
        // A closed downstream pipe must become EPIPE so the output callback
        // can ask the helper to reap the guest process before this CLI exits.
        previousPipeHandler = Darwin.signal(SIGPIPE, SIG_IGN)

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        interruptSource.setEventHandler { storage.record(.interrupt) }
        interruptSource.resume()
        self.interruptSource = interruptSource

        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        terminateSource.setEventHandler { storage.record(.terminate) }
        terminateSource.resume()
        self.terminateSource = terminateSource
        self.storage = storage
        self.queue = queue
    }

    deinit {
        interruptSource.cancel()
        terminateSource.cancel()
        queue.sync {}
        Darwin.signal(SIGINT, previousInterruptHandler)
        Darwin.signal(SIGTERM, previousTerminateHandler)
        Darwin.signal(SIGPIPE, previousPipeHandler)
    }

    var reason: Reason? {
        storage.reason
    }

    var cancellationRequested: Bool { reason != nil }
}

private final class PommeLogSignalStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReason: PommeLogSignalController.Reason?

    var reason: PommeLogSignalController.Reason? {
        lock.lock()
        defer { lock.unlock() }
        return storedReason
    }

    func record(_ reason: PommeLogSignalController.Reason) {
        lock.lock()
        defer { lock.unlock() }
        if storedReason == nil { storedReason = reason }
    }
}

/// Writes each guest log frame directly to its matching host stream.
final class PommeLogOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var outputFailed = false
    private var stderrBytesWritten = 0

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outputFailed
    }

    var wroteToStderr: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stderrBytesWritten > 0
    }

    /// Distinguishes a signal interrupting backpressure from a broken output pipe.
    struct Cancelled: Error {}

    func write(
        _ data: Data,
        to descriptor: Int32,
        shouldCancel: () -> Bool = { false }
    ) throws {
        do {
            let originalFlags = fcntl(descriptor, F_GETFL)
            guard originalFlags >= 0 else { try throwPOSIX("guest log output flags") }
            guard fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                try throwPOSIX("guest log output nonblocking mode")
            }

            func restoreFlags() throws {
                while fcntl(descriptor, F_SETFL, originalFlags) != 0 {
                    if errno == EINTR { continue }
                    try throwPOSIX("restore guest log output flags")
                }
            }

            do {
                try writeNonblocking(data, to: descriptor, shouldCancel: shouldCancel)
            } catch {
                try restoreFlags()
                throw error
            }
            try restoreFlags()
        } catch is Cancelled {
            throw Cancelled()
        } catch {
            lock.lock()
            outputFailed = true
            lock.unlock()
            throw error
        }
    }

    private func writeNonblocking(
        _ data: Data,
        to descriptor: Int32,
        shouldCancel: () -> Bool
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if shouldCancel() { throw Cancelled() }
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                    if descriptor == STDERR_FILENO {
                        lock.lock()
                        stderrBytesWritten += count
                        lock.unlock()
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    // A full pipe must not prevent the client from sending
                    // cancellation and receiving the helper's cleanup receipt.
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let result = Darwin.poll(&pollDescriptor, 1, 25)
                    if result < 0, errno != EINTR {
                        try throwPOSIX("wait for guest log output")
                    }
                } else if count == 0 {
                    throw POSIXError(.EIO)
                } else {
                    try throwPOSIX("guest log output")
                }
            }
        }
    }
}
