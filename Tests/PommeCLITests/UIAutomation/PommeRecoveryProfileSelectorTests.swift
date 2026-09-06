import Testing

@Suite("Pomme reviewed Recovery input")
struct PommeRecoveryProfileSelectorTests {
    @Test("the sole selector returns only exact reviewed descriptors")
    func exactDescriptors() throws {
        #expect(try PommeRecoveryProfileSelector.reviewedDescriptor(for: tahoeEvidence) ==
            .tahoe2660Build25G72English1280x800)
        #expect(try PommeRecoveryProfileSelector.reviewedDescriptor(for: sequoiaEvidence) ==
            .sequoia1561Build24G90English1280x800PendingReview)
    }

    @Test("the exact new identity can use the bounded experimental input gate")
    func experimentalIdentityCanAttemptInput() throws {
        let descriptor = try PommeRecoveryProfileSelector.descriptor(
            version: "26.6.2",
            build: "25G83"
        )
        #expect(descriptor.version == "26.6.2")
        #expect(descriptor.build == "25G83")
        #expect(descriptor.qualification == .experimental)

        let input = try PommeRecoveryProfileSelector.inputForAttempt(for: experimentalEvidence)
        #expect(input.committedInputCount == 0)
    }

    @Test("experimental evidence never claims a reviewed descriptor or record")
    func experimentalStaysOutOfReviewedAPIs() {
        #expect(throws: PommeRecoveryInputQualificationError.unsupportedBuild) {
            _ = try PommeRecoveryProfileSelector.reviewedDescriptor(for: experimentalEvidence)
        }
        #expect(throws: PommeRecoveryInputQualificationError.unsupportedBuild) {
            _ = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: experimentalEvidence)
        }
    }

    @Test("each unknown qualification fact prevents input authorization")
    func mismatchesFailBeforeInput() {
        let mismatches: [PommeRecoveryProfileEvidence] = [
            replacing(tahoeEvidence, build: .unknown),
            replacing(tahoeEvidence, locale: .unknown),
            replacing(tahoeEvidence, geometry: .unknown),
            replacing(tahoeEvidence, privateHostABI: .unknown),
            replacing(tahoeEvidence, manifestHash: .unknown),
            replacing(tahoeEvidence, ownership: .unknown)
        ]
        for evidence in mismatches {
            #expect(throws: (any Error).self) {
                _ = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: evidence)
            }
        }
    }

    @Test("experimental input requires identity, digest, and every non-version gate")
    func experimentalMismatchesFailBeforeInput() {
        let mismatches: [(PommeRecoveryProfileEvidence, PommeRecoveryInputQualificationError)] = [
            (
                replacing(
                    experimentalEvidence,
                    build: .experimental(version: "26.6.2", build: "25G84")
                ),
                .manifestHashMismatch
            ),
            (
                replacing(
                    experimentalEvidence,
                    build: .experimental(version: "", build: "")
                ),
                .unsupportedBuild
            ),
            (
                replacing(
                    experimentalEvidence,
                    manifestHash: .experimentalProfile("bad-experimental-digest")
                ),
                .manifestHashMismatch
            ),
            (replacing(experimentalEvidence, locale: .unknown), .unsupportedLocale),
            (replacing(experimentalEvidence, geometry: .unknown), .unsupportedGeometry),
            (
                replacing(experimentalEvidence, privateHostABI: .unknown),
                .unqualifiedPrivateHostABI
            ),
            (replacing(experimentalEvidence, ownership: .unknown), .ownershipUnverified),
            (replacing(experimentalEvidence, build: .unknown), .unsupportedBuild),
        ]

        for (evidence, error) in mismatches {
            #expect(throws: error) {
                _ = try PommeRecoveryProfileSelector.inputForAttempt(for: evidence)
            }
        }
    }

    @Test("Tahoe requires two stable pre frames, one receipt, and two stable post frames")
    func receiptAndStabilityContract() throws {
        var input = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: tahoeEvidence)
        #expect(throws: PommeTahoeReviewedInputError.unstablePreEventFrames) {
            _ = try input.authorize(preEventFrames: [.startupOptions])
        }
        let key = try input.authorize(preEventFrames: [.startupOptions, .startupOptions])
        #expect(key == .right)
        #expect(throws: PommeTahoeReviewedInputError.invalidReceipt) {
            try input.commit(
                .init(key: key, deliveredEventCount: 2),
                postEventFrames: [.startupIntermediate, .startupIntermediate]
            )
        }
        #expect(throws: PommeTahoeReviewedInputError.unstablePostEventFrames) {
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [.startupIntermediate]
            )
        }
        try input.commit(
            .init(key: key, deliveredEventCount: 1),
            postEventFrames: [.startupIntermediate, .startupIntermediate]
        )
        #expect(input.committedInputCount == 1)
    }

    @Test("Sequoia record is pending and never yields an input contract")
    func sequoiaStaysReferenceOnly() throws {
        let descriptor = try PommeRecoveryProfileSelector.reviewedDescriptor(for: sequoiaEvidence)
        #expect(descriptor.reviewedRecordDigest == SequoiaRecoveryReference.pendingReviewDigest)
        #expect(descriptor.reviewedRecordDigest.count == 64)
        #expect(!SequoiaRecoveryReference.productionInputEnabled)
        #expect(throws: PommeRecoveryInputQualificationError.externallyPendingReview(
            SequoiaRecoveryReference.pendingReviewDigest
        )) {
            _ = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: sequoiaEvidence)
        }
        #expect(throws: SequoiaRecoveryReferenceError.pendingExternalReview(
            SequoiaRecoveryReference.pendingReviewDigest
        )) {
            try PommeRecoveryProfileSelector.sequoiaInputIsUnavailable()
        }
    }

    private var tahoeEvidence: PommeRecoveryProfileEvidence {
        .init(build: .tahoe2660Build25G72, locale: .english, geometry: .pixels1280x800,
              privateHostABI: .qualifiedRecoveryInputV1, manifestHash: .tahoe2660Build25G72,
              ownership: .verified)
    }

    private var sequoiaEvidence: PommeRecoveryProfileEvidence {
        .init(build: .sequoia1561Build24G90, locale: .english, geometry: .pixels1280x800,
              privateHostABI: .qualifiedRecoveryInputV1, manifestHash: .sequoia1561Build24G90,
              ownership: .verified)
    }

    private var experimentalEvidence: PommeRecoveryProfileEvidence {
        let descriptor = try! PommeRecoveryProfileSelector.descriptor(
            version: "26.6.2",
            build: "25G83"
        )
        return .init(
            build: .experimental(version: descriptor.version, build: descriptor.build),
            locale: .english,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .experimentalProfile(descriptor.digest),
            ownership: .verified
        )
    }

    private func replacing(
        _ evidence: PommeRecoveryProfileEvidence,
        build: PommeRecoveryBuild? = nil,
        locale: PommeRecoveryLocale? = nil,
        geometry: PommeRecoveryGeometry? = nil,
        privateHostABI: PommeRecoveryPrivateHostABI? = nil,
        manifestHash: PommeRecoveryManifestHash? = nil,
        ownership: PommeRecoveryOwnership? = nil
    ) -> PommeRecoveryProfileEvidence {
        .init(build: build ?? evidence.build, locale: locale ?? evidence.locale,
              geometry: geometry ?? evidence.geometry,
              privateHostABI: privateHostABI ?? evidence.privateHostABI,
              manifestHash: manifestHash ?? evidence.manifestHash,
              ownership: ownership ?? evidence.ownership)
    }
}
