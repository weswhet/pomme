import Foundation
import Testing

@Suite("Pomme direct runtime UI controller")
struct PommeRuntimeUIControllerTests {
    @Test("rejects an unsupported key before touching the backend")
    func validatesKeysBeforeDispatch() async {
        let backend = RecordingDirectUIBackend()
        let controller = PommeRuntimeUIController(backend: backend)
        let request = PommeUIControlRequest(
            operation: .key,
            agentPayload: [
                "operation": .string("key"),
                "key": .string("raw-scan-code-999")
            ],
            timeout: 2,
            hostOutputPath: nil
        )

        await #expect(throws: RunnerError.self) {
            try await controller.perform(request)
        }
        #expect(backend.keyCalls == 0)
    }

    @Test("rejects a concurrent operation while a direct input is in flight")
    func serializesOperations() async throws {
        let backend = BlockingDirectUIBackend()
        let controller = PommeRuntimeUIController(backend: backend)
        let request = PommeUIControlRequest(
            operation: .key,
            agentPayload: [
                "operation": .string("key"),
                "key": .string("return")
            ],
            timeout: 2,
            hostOutputPath: nil
        )

        async let first = controller.perform(request)
        await backend.started.wait()
        await #expect(throws: RunnerError.self) {
            try await controller.perform(request)
        }
        await backend.release.signal()
        _ = try await first
    }
}

private actor UIContinuationGate {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct BlockingDirectUIBackend: PommeDirectUIBackend {
    let started = UIContinuationGate()
    let release = UIContinuationGate()
    private let calls = UICallCounter()

    func screenshot(to outputURL: URL, timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }

    func click(x: Double, y: Double, timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }

    func sendKey(name: String, timeout: TimeInterval) async throws -> [String: JSONValue] {
        if await calls.record() == 1 {
            await started.signal()
            await release.wait()
        }
        return ["ok": .bool(true)]
    }

    func sendKeySequence(names: [String], timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }

    func typeText(_ text: String, replace: Bool, timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }
}

private actor UICallCounter {
    private var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}

private final class RecordingDirectUIBackend: @unchecked Sendable, PommeDirectUIBackend {
    private let lock = NSLock()
    private var _keyCalls = 0

    var keyCalls: Int {
        lock.withLock { _keyCalls }
    }

    func screenshot(to outputURL: URL, timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }

    func click(x: Double, y: Double, timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }

    func sendKey(name: String, timeout: TimeInterval) async throws -> [String: JSONValue] {
        lock.withLock { _keyCalls += 1 }
        return [:]
    }

    func sendKeySequence(names: [String], timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }

    func typeText(_ text: String, replace: Bool, timeout: TimeInterval) async throws -> [String: JSONValue] {
        [:]
    }
}
