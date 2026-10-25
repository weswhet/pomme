import Foundation
import Testing

@Suite("VM mutation lease context")
struct VMBundleMutationLeaseContextTests {
    @Test("Synchronous inherited scopes preserve and restore the exact lease")
    func synchronousScope() throws {
        let name = "pomme-agent-lease-" + UUID().uuidString.lowercased()
        #expect(VMBundleMutationLease.current == nil)
        try VMBundleMutationLease.withLease(name: name) { lease in
            #expect(try VMBundleMutationLease.requireCurrent(name: name) === lease)
            try VMBundleMutationLease.withLease(name: name, inherited: lease) { inherited in
                let current = try VMBundleMutationLease.requireCurrent(name: name)
                #expect(current === inherited)
            }
            #expect(try VMBundleMutationLease.requireCurrent(name: name) === lease)
            #expect(throws: VMBundleMutationLease.Error.invalidScope(name: name + "-other")) {
                try VMBundleMutationLease.requireCurrent(name: name + "-other")
            }
        }
        #expect(VMBundleMutationLease.current == nil)
    }

    @Test("Async lease context survives suspension and rejects a released capability")
    func asynchronousScope() async throws {
        let name = "pomme-agent-lease-" + UUID().uuidString.lowercased()
        try await VMBundleMutationLease.withLease(name: name) { lease in
            await Task.yield()
            #expect(try VMBundleMutationLease.requireCurrent(name: name) === lease)
            try await VMBundleMutationLease.withLease(name: name, inherited: lease) { inherited in
                await Task.yield()
                let current = try VMBundleMutationLease.requireCurrent(name: name)
                #expect(current === inherited)
            }
            lease.release()
            #expect(throws: VMBundleMutationLease.Error.invalidScope(name: name)) {
                try VMBundleMutationLease.requireCurrent(name: name)
            }
        }
        #expect(VMBundleMutationLease.current == nil)
    }

    @Test("Image bridge forwards cancellation to its detached operation")
    func cancelledBridge() async {
        let task = Task.detached {
            try PommeExperimentalRecoveryActivation.synchronously {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled image bridge unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Detached image bridge requires explicit lease capture and forwards failures")
    func detachedBridge() throws {
        let name = "pomme-agent-lease-" + UUID().uuidString.lowercased()
        try VMBundleMutationLease.withLease(name: name) { lease in
            let valid = try PommeExperimentalRecoveryActivation.synchronously {
                #expect(VMBundleMutationLease.current == nil)
                return lease.validates(name: name)
            }
            #expect(valid)
            #expect(throws: VMBundleMutationLease.Error.invalidScope(name: name)) {
                try PommeExperimentalRecoveryActivation.synchronously { () async throws -> Bool in
                    throw VMBundleMutationLease.Error.invalidScope(name: name)
                }
            }
        }
    }
}
