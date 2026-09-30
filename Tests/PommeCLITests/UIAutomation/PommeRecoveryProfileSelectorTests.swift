import Testing

@Suite("Pomme reviewed Recovery input")
struct PommeRecoveryProfileSelectorTests {
    @Test("every macOS 27 LanguageChooser requires a separate activation event")
    func languageChooserActivationRoute() throws {
        for (version, build) in [
            ("27.0", "26A428"), ("27.0.0", "26A428"), ("27.0.1", "26A434"),
            ("27.0", "26A429"), ("27.1", "26B100"), ("27.10.2", "26K50"),
        ] {
            let descriptor = try PommeRecoveryProfileSelector.descriptor(version: version, build: build)
            let input = try PommeRecoveryProfileSelector.inputForAttempt(for: .init(
                build: .experimental(version: version, build: build), locale: .english,
                geometry: .pixels1280x800, privateHostABI: .qualifiedRecoveryInputV1,
                manifestHash: .experimentalProfile(descriptor.digest), ownership: .verified
            ))
            #expect(input.route.eventTrace.count == 12)
            #expect(input.route == .experimentalLanguageActivation)
        }
    }

    @Test("other major versions do not inherit the activation click")
    func languageActivationIsLimitedToMacOS27() throws {
        for (version, build) in [("26.6.2", "25G83"), ("26.6.2", "25G84"), ("28.0", "27A100"), ("127.0", "26A428")] {
            let descriptor = try PommeRecoveryProfileSelector.descriptor(version: version, build: build)
            let input = try PommeRecoveryProfileSelector.inputForAttempt(for: .init(
                build: .experimental(version: version, build: build), locale: .english,
                geometry: .pixels1280x800, privateHostABI: .qualifiedRecoveryInputV1,
                manifestHash: .experimentalProfile(descriptor.digest), ownership: .verified
            ))
            #expect(!input.route.eventTrace.contains { $0.input == .activateLanguageChooser })
        }
    }

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
        #expect(input.route == .directTerminal)
        #expect(input.route.keys == [.right, .right, .return, .return, .shiftCommandT])
    }

    @Test("the experimental Sequoia Utilities branch completes without a language Return")
    func experimentalSequoiaUtilitiesBranch() throws {
        var input = try PommeRecoveryProfileSelector.inputForAttempt(
            for: experimentalSequoiaEvidence
        )
        #expect(input.route == .experimentalMenusOptionalLanguage)

        let trace = input.route.eventTrace
        for event in trace.prefix(2) {
            let key = try input.authorize(
                preEventFrames: [event.preEventFrame, event.preEventFrame]
            )
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [event.postEventFrame, event.postEventFrame]
            )
        }

        let optionsKey = try input.authorize(
            preEventFrames: [.startupOptionsActivated, .startupOptionsActivated]
        )
        #expect(optionsKey == .return)
        try input.commit(
            .init(key: optionsKey, deliveredEventCount: 1),
            postEventFrames: [.recoveryUtilities, .recoveryUtilities]
        )

        #expect(input.committedInputCount == 3)
        for event in trace.dropFirst(4) {
            let key = try input.authorize(
                preEventFrames: [event.preEventFrame, event.preEventFrame]
            )
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [event.postEventFrame, event.postEventFrame]
            )
        }
        #expect(input.isComplete)
        #expect(input.committedInputCount == trace.count - 1)
    }

    @Test("the experimental Sequoia language path retains the recorded Return")
    func experimentalSequoiaLanguagePathCompletes() throws {
        var input = try PommeRecoveryProfileSelector.inputForAttempt(
            for: experimentalSequoiaEvidence
        )
        for event in input.route.eventTrace {
            let key = try input.authorize(
                preEventFrames: [event.preEventFrame, event.preEventFrame]
            )
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [event.postEventFrame, event.postEventFrame]
            )
        }
        #expect(input.isComplete)
    }

    @Test("the experimental Sequoia branch rejects mixed Utilities and language observations")
    func experimentalSequoiaMixedPostFramesAreRejected() throws {
        var input = PommeTahoeReviewedInput(route: .experimentalMenusOptionalLanguage)
        let trace = input.route.eventTrace
        for event in trace.prefix(2) {
            let key = try input.authorize(
                preEventFrames: [event.preEventFrame, event.preEventFrame]
            )
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [event.postEventFrame, event.postEventFrame]
            )
        }
        let key = try input.authorize(
            preEventFrames: [.startupOptionsActivated, .startupOptionsActivated]
        )
        #expect(throws: PommeTahoeReviewedInputError.unstablePostEventFrames) {
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [.recoveryUtilities, .languageEnglish]
            )
        }
        #expect(throws: PommeTahoeReviewedInputError.inputOutstanding) {
            _ = try input.authorize(
                preEventFrames: [.recoveryUtilities, .recoveryUtilities]
            )
        }
    }

    @Test("only the live-qualified experimental identity selects direct Terminal")
    func routeSelectionKeepsOtherIdentitiesReviewed() throws {
        let reviewed = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: tahoeEvidence)
        #expect(reviewed.route == .reviewedMenus)

        let otherExperimental = try PommeRecoveryProfileSelector.inputForAttempt(
            for: otherExperimentalEvidence
        )
        #expect(otherExperimental.route == .reviewedMenus)
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

    @Test("the direct Terminal route completes its five event trace")
    func directTerminalRouteSucceeds() throws {
        let route = PommeRecoveryNavigationRoute.directTerminal
        var input = PommeTahoeReviewedInput(route: route)

        #expect(input.route == route)
        #expect(route.keys == [.right, .right, .return, .return, .shiftCommandT])
        #expect(route.eventTrace.count == 5)

        for event in route.eventTrace {
            let key = try input.authorize(
                preEventFrames: [event.preEventFrame, event.preEventFrame]
            )
            #expect(key == event.key)
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [event.postEventFrame, event.postEventFrame]
            )
        }

        #expect(input.isComplete)
        #expect(input.committedInputCount == 5)
    }

    @Test("the experimental direct Terminal route accepts Utilities without Language Chooser")
    func directTerminalUtilitiesBranch() throws {
        var input = try PommeRecoveryProfileSelector.inputForAttempt(for: experimentalEvidence)
        #expect(input.route == .directTerminal)
        let trace = input.route.eventTrace

        for event in trace.prefix(2) {
            let key = try input.authorize(
                preEventFrames: [event.preEventFrame, event.preEventFrame]
            )
            try input.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [event.postEventFrame, event.postEventFrame]
            )
        }

        let key = try input.authorize(
            preEventFrames: [.startupOptionsActivated, .startupOptionsActivated]
        )
        #expect(key == .return)
        try input.commit(
            .init(key: key, deliveredEventCount: 1),
            postEventFrames: [.recoveryUtilities, .recoveryUtilities]
        )
        #expect(input.committedInputCount == 3)

        let terminalKey = try input.authorize(
            preEventFrames: [.recoveryUtilities, .recoveryUtilities]
        )
        #expect(terminalKey == .shiftCommandT)
        try input.commit(
            .init(key: terminalKey, deliveredEventCount: 1),
            postEventFrames: [.terminal, .terminal]
        )
        #expect(input.isComplete)
        #expect(input.committedInputCount == 4)
    }

    @Test("the direct Terminal route rejects wrong pre and post frames")
    func directTerminalRouteRejectsWrongFrames() throws {
        var preInput = PommeTahoeReviewedInput(route: .directTerminal)
        #expect(throws: PommeTahoeReviewedInputError.unexpectedPreEventFrame) {
            _ = try preInput.authorize(
                preEventFrames: [.recoveryUtilities, .recoveryUtilities]
            )
        }

        var postInput = PommeTahoeReviewedInput(route: .directTerminal)
        let key = try postInput.authorize(
            preEventFrames: [.startupOptions, .startupOptions]
        )
        #expect(key == .right)
        #expect(throws: PommeTahoeReviewedInputError.unexpectedPostEventFrame) {
            try postInput.commit(
                .init(key: key, deliveredEventCount: 1),
                postEventFrames: [.startupOptionsActivated, .startupOptionsActivated]
            )
        }
        #expect(postInput.committedInputCount == 0)
    }

    @Test("a committed direct receipt cannot be replayed")
    func directReceiptCannotReplay() throws {
        let event = PommeRecoveryNavigationRoute.directTerminal.eventTrace[0]
        var input = PommeTahoeReviewedInput(route: .directTerminal)
        let key = try input.authorize(
            preEventFrames: [event.preEventFrame, event.preEventFrame]
        )
        let receipt = PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
        let postFrames = [event.postEventFrame, event.postEventFrame]

        try input.commit(receipt, postEventFrames: postFrames)
        #expect(input.committedInputCount == 1)
        #expect(throws: PommeTahoeReviewedInputError.invalidReceipt) {
            try input.commit(receipt, postEventFrames: postFrames)
        }
        #expect(input.committedInputCount == 1)
    }

    @Test("reviewed Tahoe selection remains on the reviewed menu route")
    func reviewedSelectionRemainsUnchanged() throws {
        let input = try PommeRecoveryProfileSelector.reviewedTahoeInput(for: tahoeEvidence)
        #expect(input.route == .reviewedMenus)
        #expect(input.route.keys == [
            .right, .right, .return, .return, .controlF2,
            .right, .right, .right, .right, .down, .shiftCommandT,
        ])
        #expect(input.route.eventTrace.count == 11)
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

    private var otherExperimentalEvidence: PommeRecoveryProfileEvidence {
        let descriptor = try! PommeRecoveryProfileSelector.descriptor(
            version: "26.6.2",
            build: "25G84"
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

    private var experimentalSequoiaEvidence: PommeRecoveryProfileEvidence {
        let descriptor = try! PommeRecoveryProfileSelector.descriptor(
            version: "15.6.1",
            build: "24G90"
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
