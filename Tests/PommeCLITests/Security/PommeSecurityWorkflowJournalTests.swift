import Foundation
import Darwin
import Testing

@Suite("Security workflow journal", .serialized)
struct PommeSecurityWorkflowJournalTests {
    @Test("Writes every intent and receipt durably without serializing a secret")
    func durableWorkflow() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }

        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var journal = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            lease: lease
        )
        journal = try store.recordOwnerIntent(
            journal,
            accountUsername: "pomme",
            ownerPreparation: .new,
            lease: lease
        )
        let reference = try PommeOwnerCredentialReference(
            identity: identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        journal = try store.setCredential(journal, credential: reference, lease: lease)
        journal = try store.advance(journal, to: .credentialStored, lease: lease)
        journal = try store.advance(journal, to: .accountCreationIntent, lease: lease)
        journal = try store.recordOwnerVerified(
            journal,
            generatedUID: fixture.generatedUID,
            lease: lease
        )
        journal = try store.advance(journal, to: .accountCreationVerified, lease: lease)
        journal = try store.advance(journal, to: .autologinIntent, lease: lease)
        journal = try store.advance(journal, to: .autologinVerified, lease: lease)
        journal = try store.bind(journal, volumeVUID: "vuid-1", lease: lease)
        journal = try store.advance(journal, to: .securityMutationIntent, lease: lease)
        journal = try store.advance(journal, to: .securityMutationVerified, lease: lease)
        journal = try store.advance(journal, to: .normalBootVerified, lease: lease)
        journal = try store.advance(journal, to: .restorationPending, lease: lease)
        journal = try store.advance(journal, to: .restorationComplete, lease: lease)

        let loaded = try store.load(matching: journal.identity, lease: lease)
        #expect(loaded == journal)
        #expect(loaded.phase == .restorationComplete)
        #expect(loaded.normalBootVerified)
        #expect(!loaded.noMutationNeeded)
        let bytes = try Data(contentsOf: store.journalURL)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("super-secret-owner-password"))
        #expect(!text.contains("password"))
        #expect(text.contains("pomme"))
        #expect(text.lowercased().contains(fixture.generatedUID.uuidString.lowercased()))
    }

    @Test("A failed durable write can be retried and keeps the request redacted")
    func durableFailureRetry() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let failing = PommeSecurityWorkflowJournalStore(
            bundleURL: fixture.bundleURL,
            atomicWriter: { _, _ in
                throw PommeSecurityWorkflowJournalError.durabilityFailure(
                    operation: "file",
                    code: EIO
                )
            }
        )
        #expect(throws: PommeSecurityWorkflowJournalError.self) {
            try failing.begin(
                operation: .amfiEnable,
                identity: identity,
                originalRunState: .stopped,
                requestedFinalState: .normal,
                lease: lease
            )
        }
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let journal = try store.begin(
            operation: .amfiEnable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .normal,
            lease: lease
        )
        #expect(journal.generation == 1)
        #expect(try store.loadIfPresent(lease: lease) == journal)
    }

    @Test("Preflight intent durably retains the original state without a success receipt")
    func preflightIntentAndRejectionAreNoEffect() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)

        let intent = try store.begin(
            operation: .amfiDisable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            lease: lease,
            preflight: true
        )
        #expect(intent.phase == .preflightIntent)
        #expect(intent.originalRunState == .running(.normal))
        #expect(intent.owner == nil)
        #expect(intent.credential == nil)
        #expect(!intent.normalBootVerified)
        #expect(!intent.noMutationNeeded)

        let rejected = try store.advance(intent, to: .preflightRejected, lease: lease)
        #expect(rejected.phase == .preflightRejected)
        #expect(rejected.originalRunState == .running(.normal))
        #expect(!rejected.normalBootVerified)
        #expect(!rejected.noMutationNeeded)
        #expect(throws: PommeSecurityWorkflowJournalError.self) {
            try store.completeWithoutMutation(rejected, lease: lease)
        }
    }

    @Test("A preflight rejection can be replaced by a new operation after restoration")
    func preflightRejectionIsTerminalForBegin() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let intent = try store.begin(
            operation: .amfiEnable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .normal,
            lease: lease,
            preflight: true
        )
        _ = try store.advance(intent, to: .preflightRejected, lease: lease)

        let next = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        #expect(next.phase == .credentialPending)
        #expect(next.operation == .sipDisable)
        #expect(next.originalRunState == .stopped)
        #expect(!next.normalBootVerified)
        #expect(!next.noMutationNeeded)
    }

    @Test("An unfinished preflight remains the same cursor and conflicts across operations")
    func preflightIntentResumesAndConflicts() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let intent = try store.begin(
            operation: .amfiDisable,
            identity: identity,
            originalRunState: .paused(previousBootMode: .normal),
            requestedFinalState: .previous,
            lease: lease,
            preflight: true
        )

        let resumed = try store.begin(
            operation: .amfiDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .previous,
            lease: lease,
            preflight: true
        )
        #expect(resumed == intent)
        #expect(throws: PommeSecurityWorkflowJournalError.conflictingOperation) {
            try store.begin(
                operation: .sipEnable,
                identity: identity,
                originalRunState: .stopped,
                requestedFinalState: .previous,
                lease: lease
            )
        }
    }

    @Test("A failed preflight rejection write retains the intent cursor")
    func preflightRejectionDurabilityFailureRetainsIntent() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let intent = try store.begin(
            operation: .amfiDisable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            lease: lease,
            preflight: true
        )
        let failing = PommeSecurityWorkflowJournalStore(
            bundleURL: fixture.bundleURL,
            atomicWriter: { _, _ in
                throw PommeSecurityWorkflowJournalError.durabilityFailure(
                    operation: "preflight-rejection", code: EIO
                )
            }
        )

        #expect(throws: PommeSecurityWorkflowJournalError.self) {
            try failing.advance(intent, to: .preflightRejected, lease: lease)
        }
        #expect(try store.load(lease: lease) == intent)
    }

    @Test("A new preflight cursor cannot carry fresh owner or credential metadata")
    func freshPreflightRejectsOwnerReferences() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let reference = try PommeOwnerCredentialReference(
            identity: identity, account: "pomme", generatedUID: fixture.generatedUID
        )

        #expect(throws: PommeSecurityWorkflowJournalError.immutableRequestMismatch) {
            try PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL).begin(
                operation: .amfiEnable,
                identity: identity,
                originalRunState: .stopped,
                requestedFinalState: .stopped,
                credential: reference,
                lease: lease,
                preflight: true
            )
        }
    }

    @Test("Preflight phases reject tampered fresh-owner activity")
    func preflightPhaseRejectsFreshOwnerMetadata() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let identity = try fixture.identity()
        let owner = try PommeSecurityWorkflowOwnerRecord(
            accountUsername: "pomme",
            ownerPreparation: .new,
            generatedUID: fixture.generatedUID
        )
        let reference = try PommeOwnerCredentialReference(
            identity: identity, account: "pomme", generatedUID: fixture.generatedUID
        )

        #expect(throws: PommeSecurityWorkflowJournalError.malformed) {
            try PommeSecurityWorkflowJournal(
                generation: 1,
                identity: identity,
                operation: .amfiDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                credential: reference,
                phase: .preflightIntent,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                owner: owner
            )
        }
    }

    @Test("A completed owner's references survive a new preflight cursor")
    func preflightRetainsCompletedOwnerReferences() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let reference = try PommeOwnerCredentialReference(
            identity: identity, account: "pomme", generatedUID: fixture.generatedUID
        )
        var journal = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        journal = try store.recordOwnerIntent(
            journal, accountUsername: "pomme", ownerPreparation: .new, lease: lease
        )
        journal = try store.setCredential(journal, credential: reference, lease: lease)
        journal = try store.advance(journal, to: .credentialStored, lease: lease)
        journal = try store.advance(journal, to: .accountCreationIntent, lease: lease)
        journal = try store.recordOwnerVerified(
            journal, generatedUID: fixture.generatedUID, lease: lease
        )
        journal = try store.advance(journal, to: .accountCreationVerified, lease: lease)
        journal = try store.advance(journal, to: .autologinIntent, lease: lease)
        journal = try store.advance(journal, to: .autologinVerified, lease: lease)
        journal = try store.advance(journal, to: .securityMutationIntent, lease: lease)
        journal = try store.advance(journal, to: .securityMutationVerified, lease: lease)
        journal = try store.advance(journal, to: .normalBootVerified, lease: lease)
        journal = try store.advance(journal, to: .restorationPending, lease: lease)
        journal = try store.advance(journal, to: .restorationComplete, lease: lease)

        let preflight = try store.begin(
            operation: .amfiEnable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .normal,
            lease: lease,
            preflight: true
        )
        #expect(preflight.phase == .preflightIntent)
        #expect(preflight.credential == reference)
        #expect(preflight.owner?.accountUsername == "pomme")
        #expect(preflight.owner?.ownerPreparation == .existing)
        #expect(preflight.generatedUID == fixture.generatedUID)
        #expect(!preflight.normalBootVerified)
        #expect(!preflight.noMutationNeeded)
    }

    @Test(
        "A failed phase boundary leaves the prior durable phase and retries",
        arguments: JournalBoundary.allCases
    )
    fileprivate func phaseBoundaryFailureRetry(_ boundary: JournalBoundary) throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var journal = try journalBeforeBoundary(boundary, fixture: fixture, store: store, lease: lease)
        let failing = PommeSecurityWorkflowJournalStore(
            bundleURL: fixture.bundleURL,
            atomicWriter: { _, _ in
                throw PommeSecurityWorkflowJournalError.durabilityFailure(
                    operation: "boundary",
                    code: EIO
                )
            }
        )

        #expect(throws: PommeSecurityWorkflowJournalError.self) {
            try failing.advance(journal, to: boundary.phase, lease: lease)
        }
        #expect(try store.load(lease: lease) == journal)

        journal = try store.advance(journal, to: boundary.phase, lease: lease)
        #expect(journal.phase == boundary.phase)
        #expect(try store.load(lease: lease) == journal)
    }

    @Test("Retries ignore a changed observed run state but reject identity and operation conflicts")
    func identityAndConflicts() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let first = try store.begin(
            operation: .sipEnable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            lease: lease
        )
        let retry = try store.begin(
            operation: .sipEnable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        #expect(retry == first)
        #expect(throws: PommeSecurityWorkflowJournalError.immutableRequestMismatch) {
            try store.begin(
                operation: .sipEnable,
                identity: identity,
                originalRunState: .stopped,
                requestedFinalState: .normal,
                lease: lease
            )
        }
        #expect(throws: PommeSecurityWorkflowJournalError.conflictingOperation) {
            try store.begin(
                operation: .sipDisable,
                identity: identity,
                originalRunState: .stopped,
                requestedFinalState: .stopped,
                lease: lease
            )
        }
        let wrongIdentity = try PommeSecurityWorkflowIdentity(
            vmName: fixture.vmName,
            vmUUID: UUID(),
            machineIdentifierSHA256: identity.machineIdentifierSHA256,
            diskImageFileResourceID: identity.diskImageFileResourceID,
            startupVolumeGroupUUID: identity.startupVolumeGroupUUID,
            immutableProvisioningPlanDigest: identity.immutableProvisioningPlanDigest
        )
        #expect(throws: PommeSecurityWorkflowJournalError.identityMismatch) {
            try store.begin(
                operation: .sipEnable,
                identity: wrongIdentity,
                originalRunState: .stopped,
                requestedFinalState: .stopped,
                lease: lease
            )
        }
    }

    @Test("No-op completion records a receipt without requiring an owner or VUID")
    func noMutationCompletion() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        let pending = try store.begin(
            operation: .amfiDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        let complete = try store.completeWithoutMutation(pending, lease: lease)
        #expect(complete.phase == .restorationComplete)
        #expect(complete.credential == nil)
        #expect(complete.owner == nil)
        #expect(!complete.normalBootVerified)
        #expect(complete.noMutationNeeded)
    }

    @Test("A completed opposite operation retains the provisioned credential reference")
    func completedOperationRetention() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var first = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        let reference = try PommeOwnerCredentialReference(
            identity: identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        first = try store.setCredential(first, credential: reference, lease: lease)
        let completed = try store.completeWithoutMutation(first, lease: lease)
        let next = try store.begin(
            operation: .sipEnable,
            identity: identity,
            originalRunState: .running(.normal),
            requestedFinalState: .normal,
            lease: lease
        )
        #expect(next.phase == .credentialPending)
        #expect(next.credential == reference)
        #expect(next.generation == completed.generation + 1)
        #expect(next.originalRunState == .running(.normal))
    }

    @Test("Owner and credential references cannot be cross-bound")
    func ownerCredentialBindingIsImmutable() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var journal = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        journal = try store.recordOwnerIntent(
            journal,
            accountUsername: "pomme",
            ownerPreparation: .new,
            lease: lease
        )

        let foreignAccount = try PommeOwnerCredentialReference(
            identity: identity,
            account: "alice"
        )
        #expect(throws: PommeSecurityWorkflowJournalError.immutableRequestMismatch) {
            try store.setCredential(journal, credential: foreignAccount, lease: lease)
        }

        let reference = try PommeOwnerCredentialReference(
            identity: identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        )
        journal = try store.setCredential(journal, credential: reference, lease: lease)
        journal = try store.advance(journal, to: .credentialStored, lease: lease)
        journal = try store.advance(journal, to: .accountCreationIntent, lease: lease)

        #expect(throws: PommeSecurityWorkflowJournalError.immutableRequestMismatch) {
            try store.recordOwnerVerified(
                journal,
                generatedUID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
                lease: lease
            )
        }
        #expect(try store.load(lease: lease) == journal)
    }

    @Test("Recording an owner rejects a previously persisted foreign account")
    func ownerIntentRejectsCredentialAccountMismatch() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var journal = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        let foreignAccount = try PommeOwnerCredentialReference(
            identity: identity,
            account: "alice"
        )
        journal = try store.setCredential(journal, credential: foreignAccount, lease: lease)
        #expect(throws: PommeSecurityWorkflowJournalError.immutableRequestMismatch) {
            try store.recordOwnerIntent(
                journal,
                accountUsername: "pomme",
                ownerPreparation: .new,
                lease: lease
            )
        }
        #expect(try store.load(lease: lease) == journal)
    }

    @Test("Loading rejects a tampered owner credential binding")
    func loadRejectsCrossBoundOwnerCredential() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var journal = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        journal = try store.recordOwnerIntent(
            journal,
            accountUsername: "pomme",
            ownerPreparation: .new,
            lease: lease
        )
        journal = try store.setCredential(
            journal,
            credential: try PommeOwnerCredentialReference(
                identity: identity,
                account: "pomme"
            ),
            lease: lease
        )
        try rewriteJournal(store) { root in
            guard var owner = root["owner"] as? [String: Any] else {
                throw POSIXTestError()
            }
            owner["accountUsername"] = "alice"
            root["owner"] = owner
        }
        #expect(throws: PommeSecurityWorkflowJournalError.malformed) {
            try store.load(lease: lease)
        }
    }

    @Test("Loading rejects a tampered GeneratedUID binding")
    func loadRejectsCrossBoundGeneratedUID() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
        defer { lease.release() }
        let identity = try fixture.identity()
        let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
        var journal = try store.begin(
            operation: .sipDisable,
            identity: identity,
            originalRunState: .stopped,
            requestedFinalState: .stopped,
            lease: lease
        )
        journal = try store.recordOwnerIntent(
            journal,
            accountUsername: "pomme",
            ownerPreparation: .new,
            lease: lease
        )
        journal = try store.setCredential(
            journal,
            credential: try PommeOwnerCredentialReference(
                identity: identity,
                account: "pomme",
                generatedUID: fixture.generatedUID
            ),
            lease: lease
        )
        journal = try store.advance(journal, to: .credentialStored, lease: lease)
        journal = try store.advance(journal, to: .accountCreationIntent, lease: lease)
        journal = try store.recordOwnerVerified(
            journal,
            generatedUID: fixture.generatedUID,
            lease: lease
        )
        try rewriteJournal(store) { root in
            guard var owner = root["owner"] as? [String: Any] else {
                throw POSIXTestError()
            }
            owner["generatedUID"] = UUID(
                uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
            )!.uuidString
            root["owner"] = owner
        }
        #expect(throws: PommeSecurityWorkflowJournalError.malformed) {
            try store.load(lease: lease)
        }
    }

    @Test("Loading rejects inconsistent durable receipt phases")
    func receiptStateIsClosed() throws {
        let variants: [(phase: String, normalBootVerified: Bool, noMutationNeeded: Bool)] = [
            ("credentialPending", true, false),
            ("normalBootVerified", false, false),
            ("noMutationVerified", false, false),
            ("restorationPending", false, false),
            ("restorationComplete", true, true),
        ]

        for variant in variants {
            let fixture = try JournalFixture()
            defer { fixture.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
            defer { lease.release() }
            let identity = try fixture.identity()
            let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
            _ = try store.begin(
                operation: .sipDisable,
                identity: identity,
                originalRunState: .stopped,
                requestedFinalState: .stopped,
                lease: lease
            )
            try rewriteJournal(store) { root in
                root["phase"] = variant.phase
                root["normalBootVerified"] = variant.normalBootVerified
                root["noMutationNeeded"] = variant.noMutationNeeded
            }
            #expect(throws: PommeSecurityWorkflowJournalError.malformed) {
                try store.load(lease: lease)
            }
        }
    }
}

private func rewriteJournal(
    _ store: PommeSecurityWorkflowJournalStore,
    mutate: (inout [String: Any]) throws -> Void
) throws {
    let data = try Data(contentsOf: store.journalURL)
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw POSIXTestError()
    }
    try mutate(&root)
    let rewritten = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    try rewritten.write(to: store.journalURL)
    guard chmod(store.journalURL.path, 0o600) == 0 else { throw POSIXTestError() }
}

private enum JournalBoundary: String, CaseIterable, Sendable {
    case noMutationVerified
    case credentialStored
    case accountCreationIntent
    case accountCreationVerified
    case autologinIntent
    case autologinVerified
    case securityMutationIntent
    case securityMutationVerified
    case normalBootVerified
    case restorationPending
    case restorationComplete

    var phase: PommeSecurityWorkflowPhase {
        switch self {
        case .noMutationVerified: .noMutationVerified
        case .credentialStored: .credentialStored
        case .accountCreationIntent: .accountCreationIntent
        case .accountCreationVerified: .accountCreationVerified
        case .autologinIntent: .autologinIntent
        case .autologinVerified: .autologinVerified
        case .securityMutationIntent: .securityMutationIntent
        case .securityMutationVerified: .securityMutationVerified
        case .normalBootVerified: .normalBootVerified
        case .restorationPending: .restorationPending
        case .restorationComplete: .restorationComplete
        }
    }
}

private func journalBeforeBoundary(
    _ boundary: JournalBoundary,
    fixture: JournalFixture,
    store: PommeSecurityWorkflowJournalStore,
    lease: VMBundleMutationLease
) throws -> PommeSecurityWorkflowJournal {
    let identity = try fixture.identity()
    var journal = try store.begin(
        operation: .sipDisable,
        identity: identity,
        originalRunState: .stopped,
        requestedFinalState: .normal,
        lease: lease
    )
    if boundary == .noMutationVerified {
        return journal
    }

    journal = try store.recordOwnerIntent(
        journal,
        accountUsername: "pomme",
        ownerPreparation: .new,
        lease: lease
    )
    journal = try store.setCredential(
        journal,
        credential: try PommeOwnerCredentialReference(
            identity: identity,
            account: "pomme",
            generatedUID: fixture.generatedUID
        ),
        lease: lease
    )
    if boundary == .credentialStored { return journal }

    journal = try store.advance(journal, to: .credentialStored, lease: lease)
    if boundary == .accountCreationIntent { return journal }

    journal = try store.advance(journal, to: .accountCreationIntent, lease: lease)
    journal = try store.recordOwnerVerified(
        journal,
        generatedUID: fixture.generatedUID,
        lease: lease
    )
    if boundary == .accountCreationVerified { return journal }

    journal = try store.advance(journal, to: .accountCreationVerified, lease: lease)
    if boundary == .autologinIntent { return journal }

    journal = try store.advance(journal, to: .autologinIntent, lease: lease)
    if boundary == .autologinVerified { return journal }

    journal = try store.advance(journal, to: .autologinVerified, lease: lease)
    if boundary == .securityMutationIntent { return journal }

    journal = try store.advance(journal, to: .securityMutationIntent, lease: lease)
    if boundary == .securityMutationVerified { return journal }

    journal = try store.advance(journal, to: .securityMutationVerified, lease: lease)
    if boundary == .normalBootVerified { return journal }

    journal = try store.advance(journal, to: .normalBootVerified, lease: lease)
    if boundary == .restorationPending { return journal }

    journal = try store.advance(journal, to: .restorationPending, lease: lease)
    return journal
}

private struct JournalFixture {
    let bundleURL: URL
    let vmName: String
    let generatedUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    init() throws {
        bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-security-journal-\(UUID().uuidString)", isDirectory: true)
        vmName = "journal-\(UUID().uuidString.prefix(12))"
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
        guard chmod(bundleURL.path, 0o700) == 0 else {
            throw POSIXTestError()
        }
    }

    func identity() throws -> PommeSecurityWorkflowIdentity {
        try PommeSecurityWorkflowIdentity(
            vmName: vmName,
            vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            machineIdentifierSHA256: String(repeating: "a", count: 64),
            diskImageFileResourceID: "1:2",
            startupVolumeGroupUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            volumeVUID: "vuid-1",
            immutableProvisioningPlanDigest: String(repeating: "b", count: 64)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}

private struct POSIXTestError: Error {}
