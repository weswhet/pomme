import Foundation

struct ManagedVMLifecycle: Sendable {
    let status: @Sendable (String) throws -> PommeOperationResult
    let boot: @Sendable (String, BootMode) throws -> PommeOperationResult
    let stop: @Sendable (String, Bool) throws -> PommeOperationResult
    let pause: @Sendable (String) throws -> PommeOperationResult
    let resume: @Sendable (String) throws -> PommeOperationResult
    let restart: @Sendable (String, BootMode?) throws -> PommeOperationResult
    let destroy: @Sendable (String) throws -> PommeOperationResult
    let inspect: @Sendable (String) throws -> PommeOperationResult
}

struct ManagedVMSnapshots: Sendable {
    let list: @Sendable (String) throws -> [VMSnapshotRecord]
    let create: @Sendable (String, String) throws -> PommeOperationResult
    let restore: @Sendable (String, String, Bool) throws -> PommeOperationResult
    let delete: @Sendable (String, String) throws -> PommeOperationResult
}

struct GuestOperations: Sendable {
    let request: @Sendable (String, GuestCLIRequest, String) throws -> PommeOperationResult
    let execute: @Sendable (String, GuestCommandRequest) throws -> PommeOperationResult
    let ui: @Sendable (String, GuestUIRequest) throws -> PommeOperationResult
}

struct VMSecurity: Sendable {
    let sip: @Sendable (String, SIPAction, VMFinalState, Bool) async throws -> PommeOperationResult
    let amfi: @Sendable (String, AMFIAction, VMFinalState, Bool) async throws -> PommeOperationResult
    let mdmEnroll: @Sendable (String, String, String?, TimeInterval) async throws -> PommeOperationResult
    let mdmApprove: @Sendable (String, String, TimeInterval) async throws -> PommeOperationResult
}

struct PommeEnvironment: Sendable {
    let lifecycle: ManagedVMLifecycle
    let snapshots: ManagedVMSnapshots
    let guest: GuestOperations
    let security: VMSecurity

    static func live() -> Self {
        .init(
            lifecycle: .init(
                status: PommeApplication.status,
                boot: { try PommeApplication.boot(name: $0, mode: $1) },
                stop: { try PommeApplication.stop(name: $0, force: $1) },
                pause: { try PommeApplication.pause(name: $0) },
                resume: { try PommeApplication.resume(name: $0) },
                restart: { try PommeApplication.restart(name: $0, mode: $1) },
                destroy: PommeApplication.destroy,
                inspect: PommeApplication.detailedInspect
            ),
            snapshots: .init(
                list: PommeApplication.snapshotsList,
                create: PommeApplication.snapshotCreate,
                restore: { try PommeApplication.snapshotRestore(name: $0, snapshot: $1, allowDrift: $2) },
                delete: PommeApplication.snapshotDelete
            ),
            guest: .init(
                request: { try PommeApplication.guestRequest(name: $0, request: $1, title: $2) },
                execute: { try PommeApplication.foregroundCommand(name: $0, request: $1) },
                ui: { try PommeApplication.ui(name: $0, request: $1) }
            ),
            security: .init(
                sip: { try await PommeApplication.sipWorkflow(name: $0, action: $1, finalState: $2, force: $3) },
                amfi: { try await PommeApplication.amfiWorkflow(name: $0, action: $1, finalState: $2, force: $3) },
                mdmEnroll: {
                    try await PommeApplication.mdmEnroll(name: $0, profilePath: $1, guestPath: $2, timeout: $3)
                },
                mdmApprove: {
                    try await PommeApplication.mdmApprove(name: $0, profileIdentifier: $1, timeout: $2)
                }
            )
        )
    }
}
