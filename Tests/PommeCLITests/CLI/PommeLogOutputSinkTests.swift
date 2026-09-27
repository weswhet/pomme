import Darwin
import Dispatch
import Foundation
import Testing

@Suite("Guest log output backpressure")
struct PommeLogOutputSinkTests {
    @Test("Cancellation interrupts an undrained pipe and restores descriptor flags")
    func cancelledBlockedWrite() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let writer = descriptors[1]
        let originalFlags = fcntl(writer, F_GETFL)
        try #require(originalFlags >= 0)
        try #require(originalFlags & O_NONBLOCK == 0)
        let cancellation = CancellationFlag()
        let sink = PommeLogOutputSink()
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            cancellation.request()
        }

        #expect(throws: PommeLogOutputSink.Cancelled.self) {
            try sink.write(
                Data(repeating: 0x61, count: 4 * 1024 * 1024),
                to: writer,
                shouldCancel: { cancellation.requested }
            )
        }

        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(!sink.failed)
        #expect(fcntl(writer, F_GETFL) & O_NONBLOCK == originalFlags & O_NONBLOCK)
    }

    @Test("A broken pipe remains an output failure and restores flags")
    func brokenPipeRestoresFlags() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        let writer = descriptors[1]
        defer { close(writer) }
        close(descriptors[0])
        // Keep this test local to the descriptor; do not change process signals.
        try #require(fcntl(writer, F_SETNOSIGPIPE, 1) == 0)
        let originalFlags = fcntl(writer, F_GETFL)
        let sink = PommeLogOutputSink()
        #expect(throws: (any Error).self) {
            try sink.write(Data("record\n".utf8), to: writer)
        }
        #expect(sink.failed)
        #expect(fcntl(writer, F_GETFL) & O_NONBLOCK == originalFlags & O_NONBLOCK)
    }

    @Test("A successful write preserves existing nonblocking flags")
    func successfulWriteRestoresFlags() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let writer = descriptors[1]
        let flags = fcntl(writer, F_GETFL) | O_NONBLOCK
        try #require(fcntl(writer, F_SETFL, flags) == 0)
        let sink = PommeLogOutputSink()
        try sink.write(Data("record\n".utf8), to: writer)
        #expect(!sink.failed)
        #expect(fcntl(writer, F_GETFL) & O_NONBLOCK == flags & O_NONBLOCK)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var requested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func request() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}
