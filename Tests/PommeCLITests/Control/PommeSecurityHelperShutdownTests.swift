import Darwin
import Foundation
import Testing

@Suite("Pomme security helper shutdown")
struct PommeSecurityHelperShutdownTests {
    @Test("a normal stop keeps the exit signal held until the response hook")
    func normalClientReleasesExitAfterResponseHook() async throws {
        let socket = temporarySocketURL()
        let signal = ExitSignal()
        let log = EventLog()
        let responseRead = AsyncReleaseLatch()
        let hookRelease = AsyncReleaseLatch()
        let afterRead = AsyncReleaseLatch()
        let afterRelease = AsyncReleaseLatch()
        let exitReleased = AsyncReleaseLatch()
        let exitWaiter = Task {
            await signal.wait()
            exitReleased.release()
        }
        defer {
            responseRead.release()
            hookRelease.release()
        }

        let server = PommeControlServer(
            socketURL: socket,
            afterResponse: { request, response in
                guard case .lifecycle(.stop, _) = request else { return }
                log.append(response.ok ? "after-response-started-ok" : "after-response-started-error")
                _ = await responseRead.wait()
                log.append("after-response-after-read")
                afterRead.release()
                _ = await hookRelease.wait()
                await signal.endExitHold()
                log.append("after-response-released")
                afterRelease.release()
            }
        ) { request in
            guard case .lifecycle(.stop, _) = request else { return "ERROR unexpected command" }
            log.append("handler-started")
            await signal.beginExitHold()
            await signal.requestExit()
            log.append("handler-finished")
            return #"{"ok":true,"operation":"stop","hostExitCode":0}"#
        }
        try server.start()
        defer { server.stop() }

        let client = PommeControlSocketClient(identity: .init(socketPath: socket.path, pid: 42, startedAt: "test"))
        let result = try client.send(.init(command: "stop"))
        #expect(result.objectValue?["ok"] == .bool(true))
        log.append("response-read")
        responseRead.release()

        guard await afterRead.wait(timeout: 2) else {
            Issue.record("afterResponse did not run after the response write")
            hookRelease.release()
            _ = await afterRelease.wait(timeout: 2)
            await signal.endExitHold()
            await signal.requestExit()
            _ = await exitWaiter.value
            return
        }

        let events = log.snapshot()
        guard let handlerFinished = events.firstIndex(of: "handler-finished"),
              let responseReceived = events.firstIndex(of: "response-read"),
              let callbackAfterRead = events.firstIndex(of: "after-response-after-read")
        else {
            Issue.record("shutdown event trace was incomplete: \(events)")
            hookRelease.release()
            await signal.endExitHold()
            await signal.requestExit()
            _ = await exitWaiter.value
            return
        }
        #expect(handlerFinished < responseReceived)
        #expect(responseReceived < callbackAfterRead)
        #expect(events.contains("after-response-started-ok"))
        #expect(!exitReleased.isReleased)

        hookRelease.release()
        #expect(await afterRelease.wait(timeout: 2))
        _ = await exitWaiter.value
        #expect(exitReleased.isReleased)
        #expect(log.snapshot().contains("after-response-released"))
    }

    @Test("a disconnected stop still runs the response hook and releases the exit signal")
    func disconnectedClientRunsResponseHook() async throws {
        let socket = temporarySocketURL()
        let signal = ExitSignal()
        let log = EventLog()
        let handlerRelease = AsyncReleaseLatch()
        let handlerFinished = AsyncReleaseLatch()
        let afterResponseStarted = AsyncReleaseLatch()
        let hookRelease = AsyncReleaseLatch()
        let afterRelease = AsyncReleaseLatch()
        let exitReleased = AsyncReleaseLatch()
        let exitWaiter = Task {
            await signal.wait()
            exitReleased.release()
        }
        defer {
            handlerRelease.release()
            hookRelease.release()
        }

        let server = PommeControlServer(
            socketURL: socket,
            afterResponse: { request, response in
                guard case .lifecycle(.stop, _) = request else { return }
                log.append(response.ok ? "after-response-started-ok" : "after-response-started-error")
                afterResponseStarted.release()
                _ = await hookRelease.wait()
                await signal.endExitHold()
                log.append("after-response-released")
                afterRelease.release()
            }
        ) { request in
            guard case .lifecycle(.stop, _) = request else { return "ERROR unexpected command" }
            log.append("handler-started")
            await signal.beginExitHold()
            await signal.requestExit()
            log.append("handler-finished")
            handlerFinished.release()
            _ = await handlerRelease.wait()
            return #"{"ok":true,"operation":"stop","hostExitCode":0}"#
        }
        try server.start()
        defer { server.stop() }

        var clientFD = try connect(socket)
        defer {
            if clientFD >= 0 { _ = Darwin.close(clientFD) }
        }
        let request = PommeControlRequest(command: "stop")
        try ControlWireCodec.writeFrame(try ControlWireCodec.encodeLine(request), to: clientFD)
        guard await handlerFinished.wait(timeout: 2) else {
            Issue.record("the stop handler did not reach its response gate")
            handlerRelease.release()
            await signal.endExitHold()
            await signal.requestExit()
            _ = await exitWaiter.value
            return
        }

        var socketLinger = linger(l_onoff: 1, l_linger: 0)
        let lingerResult = withUnsafeMutablePointer(to: &socketLinger) {
            Darwin.setsockopt(clientFD, SOL_SOCKET, SO_LINGER, $0, socklen_t(MemoryLayout<linger>.size))
        }
        #expect(lingerResult == 0)
        _ = Darwin.close(clientFD)
        clientFD = -1
        log.append("client-closed")
        handlerRelease.release()

        guard await afterResponseStarted.wait(timeout: 2) else {
            Issue.record("afterResponse did not run after the disconnected response write attempt")
            hookRelease.release()
            await signal.endExitHold()
            await signal.requestExit()
            _ = await exitWaiter.value
            return
        }
        let events = log.snapshot()
        guard let handlerDone = events.firstIndex(of: "handler-finished"),
              let callbackStarted = events.firstIndex(of: "after-response-started-ok")
        else {
            Issue.record("disconnected shutdown event trace was incomplete: \(events)")
            hookRelease.release()
            await signal.endExitHold()
            await signal.requestExit()
            _ = await exitWaiter.value
            return
        }
        #expect(handlerDone < callbackStarted)
        #expect(events.contains("client-closed"))
        #expect(!exitReleased.isReleased)

        hookRelease.release()
        #expect(await afterRelease.wait(timeout: 2))
        _ = await exitWaiter.value
        #expect(exitReleased.isReleased)
        #expect(log.snapshot().contains("after-response-released"))
    }

    private func connect(_ socket: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try throwPOSIX("socket") }
        do {
            try withUnixSocketAddress(path: socket.path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { try throwPOSIX("connect") }
            }
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private func temporarySocketURL() -> URL {
        let nonce = UUID().uuidString.prefix(12).lowercased()
        return URL(fileURLWithPath: "/tmp/pomme-security-shutdown-\(nonce).sock")
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private final class AsyncReleaseLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

        func wait(timeout: TimeInterval? = nil) async -> Bool {
            let token = UUID()
            return await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                waiters[token] = continuation
                lock.unlock()

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                        expire(token)
                    }
                }
            }
        }

        func release() {
            lock.lock()
            guard !released else {
                lock.unlock()
                return
            }
            released = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            lock.unlock()
            continuations.forEach { $0.resume(returning: true) }
        }

        var isReleased: Bool {
            lock.lock()
            defer { lock.unlock() }
            return released
        }

        private func expire(_ token: UUID) {
            lock.lock()
            let continuation = waiters.removeValue(forKey: token)
            lock.unlock()
            continuation?.resume(returning: false)
        }
    }
}
