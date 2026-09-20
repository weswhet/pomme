import CryptoKit
import Darwin
import Foundation

enum PommeProvisioningV2Route: String, Codable, Sendable { case virtualization }

enum PommeProvisioningV2RouteSelector {
    static func select(hostSupportsProvisioning: Bool, guestVersion: String) -> PommeProvisioningV2Route? {
        let parts = guestVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard hostSupportsProvisioning, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
              Int(parts[0]) == 27 else { return nil }
        return .virtualization
    }
}

enum PommeProvisioningV2Phase: String, Codable, CaseIterable, Sendable {
    case install, provisionGuest, bootstrapNormalAgent, verifyNormalAgent, restoreFinalState
}

struct PommeProvisioningV2Event: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case intent, receipt, failure }
    let kind: Kind
    let phase: PommeProvisioningV2Phase
    let attempt: UInt64
    let digest: String?

    init(kind: Kind, phase: PommeProvisioningV2Phase, attempt: UInt64, digest: String? = nil) {
        self.kind = kind
        self.phase = phase
        self.attempt = attempt
        self.digest = digest
    }
}

/// Schema 2 wraps the original immutable plan without changing its bytes or digest.
struct PommeProvisioningV2Journal: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    let schema: Int
    let generation: UInt64
    let plan: PommeProvisioningPlan
    let planDigest: String
    let route: PommeProvisioningV2Route
    let ownerReference: PommeOwnerCredentialReference?
    let startupVolumeGroupUUID: UUID?
    let events: [PommeProvisioningV2Event]
    let integrity: String

    fileprivate struct Unsigned: Codable {
        let schema: Int
        let generation: UInt64
        let plan: PommeProvisioningPlan
        let planDigest: String
        let route: PommeProvisioningV2Route
        let ownerReference: PommeOwnerCredentialReference?
        let startupVolumeGroupUUID: UUID?
        let events: [PommeProvisioningV2Event]
    }

    fileprivate var unsigned: Unsigned {
        .init(schema: schema, generation: generation, plan: plan, planDigest: planDigest,
              route: route, ownerReference: ownerReference, startupVolumeGroupUUID: startupVolumeGroupUUID, events: events)
    }
}

enum PommeProvisioningV2Error: Error, Equatable, Sendable {
    case invalidJournal, integrityFailure, generationFailure, unexpectedEvent
    case ownerReferenceRequired, startupVolumeGroupRequired, ownershipMismatch, ambiguousProvisionGuest
    case interruptedPhase(PommeProvisioningV2Phase), phaseFailed(PommeProvisioningV2Phase)
    case unsafeRepository
}

struct PommeProvisioningV2Signer: Sendable {
    private let key: SymmetricKey
    init(key: Data) throws {
        guard key.count >= 32 else { throw PommeProvisioningV2Error.integrityFailure }
        self.key = SymmetricKey(data: key)
    }

    func make(generation: UInt64, plan: PommeProvisioningPlan,
              ownerReference: PommeOwnerCredentialReference? = nil,
              startupVolumeGroupUUID: UUID? = nil,
              events: [PommeProvisioningV2Event]) throws -> PommeProvisioningV2Journal {
        let unsigned = PommeProvisioningV2Journal.Unsigned(schema: 2, generation: generation,
            plan: plan, planDigest: plan.digest, route: .virtualization,
            ownerReference: ownerReference, startupVolumeGroupUUID: startupVolumeGroupUUID, events: events)
        let integrity = Data(HMAC<SHA256>.authenticationCode(
            for: try PommeProvisioningCoding.encode(unsigned), using: key)).base64EncodedString()
        let journal = PommeProvisioningV2Journal(schema: 2, generation: generation,
            plan: plan, planDigest: plan.digest, route: .virtualization,
            ownerReference: ownerReference, startupVolumeGroupUUID: startupVolumeGroupUUID, events: events, integrity: integrity)
        try verify(journal)
        return journal
    }

    func verify(_ journal: PommeProvisioningV2Journal) throws {
        guard journal.schema == 2, journal.generation > 0, journal.planDigest == journal.plan.digest,
              let signature = Data(base64Encoded: journal.integrity),
              HMAC<SHA256>.isValidAuthenticationCode(signature,
                authenticating: try PommeProvisioningCoding.encode(journal.unsigned), using: key)
        else { throw PommeProvisioningV2Error.integrityFailure }
        try journal.plan.validate()
        guard PommeProvisioningV2RouteSelector.select(hostSupportsProvisioning: true,
            guestVersion: journal.plan.restore.version) == .virtualization
        else { throw PommeProvisioningV2Error.invalidJournal }
        if let reference = journal.ownerReference {
            guard reference.vmUUID == journal.plan.vm.uuid, reference.account == "pomme" else {
                throw PommeProvisioningV2Error.ownershipMismatch
            }
        }
        if journal.events.contains(where: { $0.phase != .install }), journal.ownerReference == nil {
            throw PommeProvisioningV2Error.ownerReferenceRequired
        }
        try PommeProvisioningV2Coordinator.validate(events: journal.events)
        let verified = journal.events.contains { $0.phase == .verifyNormalAgent && $0.kind == .receipt }
        guard verified == (journal.startupVolumeGroupUUID != nil) else {
            throw PommeProvisioningV2Error.startupVolumeGroupRequired
        }
    }
}

enum PommeProvisioningV2Coordinator {
    static func validate(events: [PommeProvisioningV2Event]) throws {
        var index = 0
        var attempt: UInt64 = 0
        var pending: PommeProvisioningV2Event?
        for event in events {
            guard index < PommeProvisioningV2Phase.allCases.count,
                  event.phase == PommeProvisioningV2Phase.allCases[index], event.attempt > 0,
                  event.digest.map(PommeProvisioningDigest.isSHA256) ?? true else {
                throw PommeProvisioningV2Error.unexpectedEvent
            }
            switch event.kind {
            case .intent:
                guard pending == nil, attempt < UInt64.max, event.attempt == attempt + 1,
                      event.digest == nil else { throw PommeProvisioningV2Error.unexpectedEvent }
                pending = event
                attempt = event.attempt
            case .receipt, .failure:
                guard pending?.attempt == event.attempt, event.digest != nil else {
                    throw PommeProvisioningV2Error.unexpectedEvent
                }
                pending = nil
                if event.kind == .receipt { index += 1; attempt = 0 }
            }
        }
    }

    static func nextPhase(in journal: PommeProvisioningV2Journal) throws -> (phase: PommeProvisioningV2Phase, attempt: UInt64)? {
        try validate(events: journal.events)
        if let pending = journal.events.last, pending.kind == .intent {
            return (pending.phase, pending.attempt)
        }
        let completed = journal.events.filter { $0.kind == .receipt }.count
        guard completed < PommeProvisioningV2Phase.allCases.count else { return nil }
        let phase = PommeProvisioningV2Phase.allCases[completed]
        let attempt = journal.events.last.flatMap { $0.phase == phase ? $0.attempt : nil } ?? 0
        guard attempt < UInt64.max else { throw PommeProvisioningV2Error.generationFailure }
        return (phase, attempt + 1)
    }
}

protocol PommeProvisioningV2JournalRepository: Sendable {
    func create(_ journal: PommeProvisioningV2Journal) throws
    func load() throws -> PommeProvisioningV2Journal
    func commit(_ journal: PommeProvisioningV2Journal, replacing generation: UInt64) throws
}

/// Caller supplies a dedicated schema-2 path and durable high-water storage.
/// No schema-1 file is read or migrated here.
struct PommeFileProvisioningV2JournalRepository: PommeProvisioningV2JournalRepository {
    let journalURL: URL
    let signer: PommeProvisioningV2Signer
    let loadHighWater: @Sendable () throws -> UInt64
    let advanceHighWater: @Sendable (UInt64, UInt64) throws -> Void

    func create(_ journal: PommeProvisioningV2Journal) throws {
        guard journal.generation == 1, try loadHighWater() == 0 else {
            throw PommeProvisioningV2Error.generationFailure
        }
        try signer.verify(journal)
        try write(journal, createOnly: true)
        try advanceHighWater(0, 1)
    }

    func load() throws -> PommeProvisioningV2Journal {
        let fd = open(journalURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PommeProvisioningV2Error.unsafeRepository }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try validateFile(fd)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 4 * 1024 * 1024 else { throw PommeProvisioningV2Error.invalidJournal }
        let journal = try JSONDecoder().decode(PommeProvisioningV2Journal.self, from: data)
        try signer.verify(journal)
        let highWater = try loadHighWater()
        if journal.generation != highWater {
            // The atomic journal publication precedes the independent durable
            // high-water update. Only that single interrupted write is recoverable.
            guard highWater < UInt64.max, journal.generation == highWater + 1 else {
                throw PommeProvisioningV2Error.generationFailure
            }
            try advanceHighWater(highWater, journal.generation)
            guard try loadHighWater() == journal.generation else {
                throw PommeProvisioningV2Error.generationFailure
            }
        }
        return journal
    }

    func commit(_ journal: PommeProvisioningV2Journal, replacing generation: UInt64) throws {
        let current = try load()
        guard generation < UInt64.max, current.generation == generation,
              journal.generation == generation + 1, journal.plan == current.plan,
              journal.events.starts(with: current.events),
              Self.allowsReferenceTransition(from: current, to: journal),
              Self.allowsVolumeGroupTransition(from: current, to: journal)
        else { throw PommeProvisioningV2Error.generationFailure }
        try signer.verify(journal)
        try write(journal, createOnly: false)
        try advanceHighWater(generation, journal.generation)
    }

    static func allowsReferenceTransition(from current: PommeProvisioningV2Journal, to next: PommeProvisioningV2Journal) -> Bool {
        guard let old = current.ownerReference else { return true }
        if old == next.ownerReference { return true }
        guard let new = next.ownerReference,
              current.events.last?.phase == .verifyNormalAgent, current.events.last?.kind == .intent,
              next.events.count == current.events.count + 1,
              next.events.last?.phase == .verifyNormalAgent, next.events.last?.kind == .receipt
        else { return false }
        return PommeProvisioningV2Verification.allowsEnrichment(from: old, to: new)
    }

    static func allowsVolumeGroupTransition(from current: PommeProvisioningV2Journal, to next: PommeProvisioningV2Journal) -> Bool {
        if current.startupVolumeGroupUUID == next.startupVolumeGroupUUID { return true }
        return current.startupVolumeGroupUUID == nil && next.startupVolumeGroupUUID != nil
            && current.events.last?.phase == .verifyNormalAgent && current.events.last?.kind == .intent
            && next.events.count == current.events.count + 1
            && next.events.last?.phase == .verifyNormalAgent && next.events.last?.kind == .receipt
    }

    private func validateFile(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1, status.st_size <= 4 * 1024 * 1024 else {
            throw PommeProvisioningV2Error.unsafeRepository
        }
    }

    private func write(_ journal: PommeProvisioningV2Journal, createOnly: Bool) throws {
        let parent = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw PommeProvisioningV2Error.unsafeRepository }
        defer { close(directory) }
        var status = stat()
        guard fstat(directory, &status) == 0, status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o700 else { throw PommeProvisioningV2Error.unsafeRepository }
        let name = journalURL.lastPathComponent
        let temporary = ".\(name).\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PommeProvisioningV2Error.unsafeRepository }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try validateFile(fd)
        let data = try PommeProvisioningCoding.encode(journal)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PommeProvisioningV2Error.unsafeRepository }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw PommeProvisioningV2Error.unsafeRepository }
        if createOnly {
            guard linkat(directory, temporary, directory, name, 0) == 0 else {
                throw PommeProvisioningV2Error.generationFailure
            }
            guard unlinkat(directory, temporary, 0) == 0 else { throw PommeProvisioningV2Error.unsafeRepository }
        } else {
            guard renameat(directory, temporary, directory, name) == 0 else {
                throw PommeProvisioningV2Error.unsafeRepository
            }
        }
        guard fsync(directory) == 0 else { throw PommeProvisioningV2Error.unsafeRepository }
    }
}

struct PommeProvisioningV2Verification: Sendable {
    let receiptDigest: String
    let ownerReference: PommeOwnerCredentialReference?
    let startupVolumeGroupUUID: UUID?

    init(receiptDigest: String, ownerReference: PommeOwnerCredentialReference? = nil,
         startupVolumeGroupUUID: UUID? = nil) {
        self.receiptDigest = receiptDigest
        self.ownerReference = ownerReference
        self.startupVolumeGroupUUID = startupVolumeGroupUUID
    }

    static func allowsEnrichment(from old: PommeOwnerCredentialReference, to new: PommeOwnerCredentialReference) -> Bool {
        old.generatedUID == nil && new.generatedUID != nil
            && old.vmUUID == new.vmUUID
            && old.machineIdentifierSHA256 == new.machineIdentifierSHA256
            && old.diskImageFileResourceID == new.diskImageFileResourceID
            && old.account == new.account && old.service == new.service
            && old.ownershipMarker == new.ownershipMarker
    }
}

struct PommeProvisioningV2Effects: Sendable {
    let verifyOwnership: @Sendable (PommeVMOwnership) async throws -> PommeVMOwnership
    /// Idempotently retrieves or creates the one scoped Keychain item before boot intent.
    let prepareOwnerReference: @Sendable (PommeProvisioningPlan) async throws -> PommeOwnerCredentialReference
    let install: @Sendable (PommeProvisioningPlan) async throws -> String
    let provisionGuest: @Sendable (PommeProvisioningPlan) async throws -> String
    let bootstrapNormalAgent: @Sendable (PommeProvisioningPlan) async throws -> String
    let verifyNormalAgent: @Sendable (PommeProvisioningPlan) async throws -> PommeProvisioningV2Verification
    let restoreFinalState: @Sendable (PommeProvisioningPlan) async throws -> String
    /// Missing integration is conservative. Only a verified absence of the
    /// durable dispatch marker permits retrying a first-boot intent.
    var provisionGuestWasDispatched: @Sendable (PommeProvisioningPlan) throws -> Bool = { _ in true }
}

struct PommeProvisioningV2Orchestrator: Sendable {
    let signer: PommeProvisioningV2Signer
    let repository: any PommeProvisioningV2JournalRepository
    let effects: PommeProvisioningV2Effects

    func start(_ plan: PommeProvisioningPlan) async throws {
        try repository.create(signer.make(generation: 1, plan: plan, events: []))
        try await resume(expectedPlan: plan)
    }

    func resume(expectedPlan: PommeProvisioningPlan? = nil) async throws {
        var journal = try repository.load()
        try signer.verify(journal)
        guard expectedPlan == nil || expectedPlan == journal.plan else { throw PommeProvisioningError.invalidPlan }
        if journal.events.contains(where: { $0.phase == .provisionGuest && $0.kind == .intent }),
           !journal.events.contains(where: { $0.phase == .provisionGuest && $0.kind == .receipt }),
           try effects.provisionGuestWasDispatched(journal.plan) {
            throw PommeProvisioningV2Error.ambiguousProvisionGuest
        }
        guard try await effects.verifyOwnership(journal.plan.vm) == journal.plan.vm else {
            throw PommeProvisioningV2Error.ownershipMismatch
        }
        while let next = try PommeProvisioningV2Coordinator.nextPhase(in: journal) {
            if journal.events.last?.kind == .intent {
                guard next.phase == .provisionGuest || next.phase == .bootstrapNormalAgent || next.phase == .verifyNormalAgent || next.phase == .restoreFinalState else {
                    throw PommeProvisioningV2Error.interruptedPhase(next.phase)
                }
            } else {
                var reference = journal.ownerReference
                if next.phase == .provisionGuest, reference == nil {
                    reference = try await effects.prepareOwnerReference(journal.plan)
                }
                journal = try commit(journal, reference: reference, event: .init(kind: .intent,
                    phase: next.phase, attempt: next.attempt))
            }
            let receipt: String
            var verifiedReference = journal.ownerReference
            var verifiedVolumeGroup = journal.startupVolumeGroupUUID
            do {
                if next.phase == .verifyNormalAgent {
                    let verification = try await effects.verifyNormalAgent(journal.plan)
                    receipt = verification.receiptDigest
                    guard let group = verification.startupVolumeGroupUUID,
                          verifiedVolumeGroup == nil || verifiedVolumeGroup == group else {
                        throw PommeProvisioningV2Error.startupVolumeGroupRequired
                    }
                    verifiedVolumeGroup = group
                    if let enriched = verification.ownerReference {
                        guard let old = journal.ownerReference,
                              old == enriched || PommeProvisioningV2Verification.allowsEnrichment(from: old, to: enriched)
                        else { throw PommeProvisioningV2Error.ownershipMismatch }
                        verifiedReference = enriched
                    }
                } else {
                    receipt = try await effect(next.phase, plan: journal.plan)
                }
                guard PommeProvisioningDigest.isSHA256(receipt) else { throw PommeProvisioningV2Error.phaseFailed(next.phase) }
            } catch {
                // Hash only a fixed redacted category, never exception text containing secrets.
                _ = try commit(journal, reference: journal.ownerReference, event: .init(kind: .failure,
                    phase: next.phase, attempt: next.attempt,
                    digest: PommeProvisioningDigest.sha256(Data("phase-failed".utf8))))
                throw PommeProvisioningV2Error.phaseFailed(next.phase)
            }
            journal = try commit(journal, reference: verifiedReference, startupVolumeGroupUUID: verifiedVolumeGroup, event: .init(kind: .receipt,
                phase: next.phase, attempt: next.attempt, digest: receipt))
        }
    }

    private func commit(_ journal: PommeProvisioningV2Journal, reference: PommeOwnerCredentialReference?,
                        startupVolumeGroupUUID: UUID? = nil,
                        event: PommeProvisioningV2Event) throws -> PommeProvisioningV2Journal {
        guard journal.generation < UInt64.max else { throw PommeProvisioningV2Error.generationFailure }
        let updated = try signer.make(generation: journal.generation + 1, plan: journal.plan,
                                      ownerReference: reference,
                                      startupVolumeGroupUUID: startupVolumeGroupUUID ?? journal.startupVolumeGroupUUID,
                                      events: journal.events + [event])
        try repository.commit(updated, replacing: journal.generation)
        return updated
    }

    private func effect(_ phase: PommeProvisioningV2Phase, plan: PommeProvisioningPlan) async throws -> String {
        switch phase {
        case .install: try await effects.install(plan)
        case .provisionGuest: try await effects.provisionGuest(plan)
        case .bootstrapNormalAgent: try await effects.bootstrapNormalAgent(plan)
        case .verifyNormalAgent: throw PommeProvisioningV2Error.unexpectedEvent
        case .restoreFinalState: try await effects.restoreFinalState(plan)
        }
    }
}
