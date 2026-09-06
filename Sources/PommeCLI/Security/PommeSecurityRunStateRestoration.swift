import Foundation

/// Restores a VM run-state snapshot through injected lifecycle effects.
///
/// A mode change always proves the VM stopped before starting the new mode.
/// The helper deliberately keeps effect errors throwable by the caller while
/// mapping an unsuccessful state proof to the closed workflow error.
enum PommeSecurityRunStateRestoration {
    static func restore(
        desired: VMRunStateSnapshot,
        observe: @escaping @Sendable () async throws -> VMRunStateSnapshot,
        stop: @escaping @Sendable () async throws -> Void,
        start: @escaping @Sendable (VMRunStateSnapshot) async throws -> Void
    ) async throws {
        let observed = try await observe()
        if observed == desired { return }

        if observed != .stopped {
            try await stop()
            guard try await observe() == .stopped else {
                throw PommeSecurityWorkflowError.restorationIncomplete
            }
        }

        if desired == .stopped { return }

        try await start(desired)
        guard try await observe() == desired else {
            throw PommeSecurityWorkflowError.restorationIncomplete
        }
    }
}
