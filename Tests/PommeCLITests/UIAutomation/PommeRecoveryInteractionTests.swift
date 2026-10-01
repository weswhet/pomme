import CoreGraphics
import Foundation
import Testing

@Suite("Recovery 27 LanguageChooser activation")
struct PommeRecoveryLanguageActivationTests {
  @Test("inactive English needs activation and two active observations before Return")
  func inactiveChooserDoesNotAcceptReturn() async throws {
    let inactive = try classifiedSelection(red: 70, green: 70, blue: 70)
    let active = try classifiedSelection(red: 0, green: 89, blue: 209)
    #expect(inactive == .languageEnglishInactive)
    #expect(active == .languageEnglishActive)
    let port = LanguageActivationPort(frames: [
      .startupOptions, .startupOptions, .startupIntermediate, .startupIntermediate,
      .startupIntermediate, .startupIntermediate, .startupOptionsActivated, .startupOptionsActivated,
      .startupOptionsActivated, .startupOptionsActivated, inactive, inactive,
      inactive, inactive, active, active,
      active, active, .recoveryUtilities, .recoveryUtilities,
    ])
    var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
    for _ in 0..<5 { try await interaction.advance(using: port) }
    #expect(await port.inputs == [.key(.right), .key(.right), .key(.return), .activateLanguageChooser, .key(.return)])
    #expect(await port.frameCount == 0)
  }

  @Test("already active chooser skips activation")
  func alreadyActiveSkipsClick() async throws {
    let port = LanguageActivationPort(frames: prefixFrames(post: .languageEnglishActive) + [
      .languageEnglishActive, .languageEnglishActive, .recoveryUtilities, .recoveryUtilities,
    ])
    var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
    for _ in 0..<4 { try await interaction.advance(using: port) }
    #expect(await port.inputs == [.key(.right), .key(.right), .key(.return), .key(.return)])
  }

  @Test("27 Options may enter stable Utilities directly and complete the menu route")
  func optionsAdvancesDirectlyToUtilities() async throws {
    let menuEvents = PommeRecoveryNavigationRoute.experimentalLanguageActivation.eventTrace.dropFirst(5)
    let port = LanguageActivationPort(frames: prefixFrames(post: .recoveryUtilities)
      + menuEvents.flatMap { [$0.preEventFrame, $0.preEventFrame, $0.postEventFrame, $0.postEventFrame] })
    var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
    for _ in 0..<(3 + menuEvents.count) { try await interaction.advance(using: port) }
    #expect(await port.inputs == [
      .key(.right), .key(.right), .key(.return), .key(.controlF2),
      .key(.right), .key(.right), .key(.right), .key(.right), .key(.down), .key(.shiftCommandT),
    ])
    #expect(await port.frameCount == 0)
  }

  @Test("Options requires stable known postconditions and never replays on failure")
  func directUtilitiesRequiresStableProof() async throws {
    for pair: [PommeRecoveryFrame] in [
      [.recoveryUtilities, .languageEnglishActive], [.recoveryUtilities, .unknown], [.unknown, .unknown],
    ] {
      let port = LanguageActivationPort(frames: Array(prefixFrames(post: .recoveryUtilities).dropLast(2)) + pair)
      var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
      for _ in 0..<2 { try await interaction.advance(using: port) }
      for _ in 0..<2 {
        await #expect(throws: PommeRecoveryInteractionError.recoveryCleanupRequired(.recoveryCleanupRequired)) {
          try await interaction.advance(using: port)
        }
      }
      #expect(await port.inputs == [.key(.right), .key(.right), .key(.return)])
    }
  }

  @Test("a non-27 experimental build does not inherit the direct Utilities branch")
  func otherMajorVersionRejectsDirectUtilities() async throws {
    let port = LanguageActivationPort(frames: prefixFrames(post: .recoveryUtilities))
    let neighbor = try evidence(version: "26.6.2", build: "25G84")
    #expect(try PommeRecoveryProfileSelector.inputForAttempt(for: neighbor).route == .reviewedMenus)
    var interaction = try PommeTahoeRecoveryInteraction(evidence: neighbor)
    for _ in 0..<2 { try await interaction.advance(using: port) }
    await #expect(throws: PommeRecoveryInteractionError.recoveryCleanupRequired(.recoveryCleanupRequired)) {
      try await interaction.advance(using: port)
    }
    #expect(await port.inputs == [.key(.right), .key(.right), .key(.return)])
  }

  @Test("lost focus or unknown selection immediately before Return emits no Return")
  func staleActiveProofCannotAuthorizeReturn() async throws {
    for frame in [PommeRecoveryFrame.languageEnglishInactive, .languageEnglish, .unknown] {
      let port = LanguageActivationPort(frames: prefixFrames(post: .languageEnglishActive) + [frame, frame])
      var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
      for _ in 0..<3 { try await interaction.advance(using: port) }
      await #expect(throws: PommeRecoveryInteractionError.noInputDelivered(.noInputDelivered)) {
        try await interaction.advance(using: port)
      }
      #expect(await port.inputs == [.key(.right), .key(.right), .key(.return)])
    }
  }

  @Test("a key receipt cannot acknowledge a click")
  func activationRequiresMatchingReceipt() throws {
    var input = try PommeRecoveryProfileSelector.inputForAttempt(for: evidence())
    for event in input.route.eventTrace.prefix(3) {
      let action = try input.authorizeInput(preEventFrames: [event.preEventFrame, event.preEventFrame])
      try input.commit(.init(input: action, deliveredEventCount: 1),
                       postEventFrames: [event.postEventFrame, event.postEventFrame])
    }
    #expect(try input.authorizeInput(preEventFrames: [.languageEnglishInactive, .languageEnglishInactive])
            == .activateLanguageChooser)
    #expect(throws: PommeTahoeReviewedInputError.invalidReceipt) {
      try input.commit(.init(key: .return, deliveredEventCount: 1),
                       postEventFrames: [.languageEnglishActive, .languageEnglishActive])
    }
    #expect(throws: PommeTahoeReviewedInputError.inputOutstanding) {
      try input.authorizeInput(preEventFrames: [.languageEnglishActive, .languageEnglishActive])
    }
  }

  @Test("activation may advance to Utilities but never causes an extra Return")
  func activationAdvancesToUtilities() async throws {
    let port = LanguageActivationPort(frames: prefixFrames(post: .languageEnglishInactive) + [
      .languageEnglishInactive, .languageEnglishInactive, .recoveryUtilities, .recoveryUtilities,
      .recoveryUtilities, .recoveryUtilities, .applicationMenu, .applicationMenu,
    ])
    var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
    for _ in 0..<5 { try await interaction.advance(using: port) }
    #expect(await port.inputs.suffix(2) == [.activateLanguageChooser, .key(.controlF2)])
  }

  @Test("unstable activation proof or uncertain click cannot be retried")
  func activationFailureRequiresCleanup() async throws {
    for uncertain in [false, true] {
      let port = LanguageActivationPort(frames: prefixFrames(post: .languageEnglishInactive) + [
        .languageEnglishInactive, .languageEnglishInactive, .languageEnglishActive, .languageEnglishInactive,
      ], failActivation: uncertain)
      var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence())
      for _ in 0..<3 { try await interaction.advance(using: port) }
      for _ in 0..<2 {
        await #expect(throws: PommeRecoveryInteractionError.recoveryCleanupRequired(.recoveryCleanupRequired)) {
          try await interaction.advance(using: port)
        }
      }
      #expect(await port.inputs == [.key(.right), .key(.right), .key(.return), .activateLanguageChooser])
    }
  }

  @Test("a highlight without English geometry and a selected row cannot authorize navigation")
  func rejectsUnprovenSelection() throws {
    #expect(try classifiedSelection(red: 31, green: 31, blue: 31) == .unknown)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, englishY: 367) == .unknown)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, fraction: 0.1) == .unknown)
    #expect(try classifiedSelection(red: 70, green: 70, blue: 70, context: .unproven) == .unknown)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, context: .optionsActivated) == .languageEnglish)
  }

  @Test("observed OCR confidence requires complete selection proof and rejects weaker text")
  func selectionConfidenceBoundary() throws {
    #expect(try classifiedSelection(red: 70, green: 70, blue: 70, englishConfidence: 0.5)
            == .languageEnglishInactive)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, englishConfidence: 0.5)
            == .languageEnglishActive)
    #expect(try classifiedSelection(red: 70, green: 70, blue: 70, englishConfidence: 0.49) == .unknown)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, englishConfidence: 0.49) == .unknown)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, englishY: 367,
                                   englishConfidence: 0.5) == .unknown)
    #expect(try classifiedSelection(red: 0, green: 89, blue: 209, fraction: 0.1,
                                   englishConfidence: 0.5) == .unknown)
  }

  private func evidence(
    version: String = "27.0", build: String = "26A428"
  ) throws -> PommeRecoveryProfileEvidence {
    let descriptor = try PommeRecoveryProfileSelector.descriptor(version: version, build: build)
    return .init(build: .experimental(version: version, build: build), locale: .english,
                 geometry: .pixels1280x800, privateHostABI: .qualifiedRecoveryInputV1,
                 manifestHash: .experimentalProfile(descriptor.digest), ownership: .verified)
  }

  private func prefixFrames(post: PommeRecoveryFrame) -> [PommeRecoveryFrame] {
    [.startupOptions, .startupOptions, .startupIntermediate, .startupIntermediate,
     .startupIntermediate, .startupIntermediate, .startupOptionsActivated, .startupOptionsActivated,
     .startupOptionsActivated, .startupOptionsActivated, post, post]
  }

  private func classifiedSelection(
    red: UInt8, green: UInt8, blue: UInt8, englishY: CGFloat = 336, fraction: Double = 1,
    englishConfidence: Double = 1,
    context: PommeRecoveryFrameClassificationContext = .experimental27LanguageChooser
  ) throws -> PommeRecoveryFrame {
    // Entirely synthetic pixels, with a top-left row layout; no VM artifacts.
    var bytes = [UInt8](repeating: 31, count: 1280 * 800 * 4)
    for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
    for y in 330..<355 {
      for x in 508..<(508 + Int(246 * fraction)) {
        let offset = (y * 1280 + x) * 4
        bytes[offset] = red; bytes[offset + 1] = green; bytes[offset + 2] = blue
      }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: 1280, height: 800, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let lines: [SettingsAIOCRLine] = [
      .init(text: "Language", confidence: 1, rect: .init(x: 580, y: 282, width: 120, height: 25)),
      .init(text: "English", confidence: englishConfidence, rect: .init(x: 618, y: englishY, width: 44, height: 14)),
      .init(text: "By using this software, you agree to the terms of the software license agreement", confidence: 1,
            rect: .init(x: 270, y: 722, width: 740, height: 28)),
    ]
    return PommeRecoveryFrameClassifier.classify(image: image, lines: lines, context: context)
  }
}

private actor LanguageActivationPort: PommeRecoveryKeyboardPort {
  var frames: [PommeRecoveryFrame]
  let failActivation: Bool
  private(set) var inputs: [PommeRecoveryNavigationInput] = []
  var frameCount: Int { frames.count }
  init(frames: [PommeRecoveryFrame], failActivation: Bool = false) {
    self.frames = frames; self.failActivation = failActivation
  }
  func nextRecoveryFrame() throws -> PommeRecoveryFrame {
    guard !frames.isEmpty else { throw RecoveryPortError.depleted }
    return frames.removeFirst()
  }
  func deliverRecoveryKey(_ key: PommeRecoveryVirtualKey) throws -> PommeRecoveryDurableInputReceipt {
    try deliverRecoveryInput(.key(key))
  }
  func deliverRecoveryInput(_ input: PommeRecoveryNavigationInput) throws -> PommeRecoveryDurableInputReceipt {
    inputs.append(input)
    if failActivation && input == .activateLanguageChooser { throw RecoveryPortError.submissionFailed }
    return .init(input: input, deliveredEventCount: 1)
  }
}

@Suite("Pomme Tahoe Recovery interaction driver")
struct PommeRecoveryInteractionTests {
  @Test("one advance samples two stable frames around exactly one receipt")
  func singleAdvanceUsesOneReceipt() async throws {
    let port = RecoveryPort(
      frames: [.startupOptions, .startupOptions, .startupIntermediate, .startupIntermediate],
      receipts: [.init(key: .right, deliveredEventCount: 1)]
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let signal = try await interaction.advance(using: port)

    #expect(signal == .inputCommitted)
    #expect(await port.deliveredKeys == [.right])
    #expect(await port.remainingFrameCount == 0)
  }

  @Test("one advance requests one explicit pair before and after its receipt")
  func singleAdvanceUsesExplicitPairs() async throws {
    let port = RecoveryPairPort(
      preEventFrame: .startupOptions,
      postEventFrame: .startupIntermediate,
      receipt: .init(key: .right, deliveredEventCount: 1)
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let signal = try await interaction.advance(using: port)

    #expect(signal == .inputCommitted)
    #expect(await port.pairRequestCount == 2)
    #expect(await port.deliveredKeys == [.right])
  }

  @Test("only the reviewed Tahoe sequence reaches terminal proof")
  func reviewedSequenceReachesTerminalProof() async throws {
    let transitions = tahoeTransitions
    let frames = transitions.flatMap { pre, _, post in [pre, pre, post, post] }
    let receipts = transitions.map { _, key, _ in
      PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
    }
    let port = RecoveryPort(frames: frames, receipts: receipts)
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)
    var signal: PommeRecoveryInteractionCleanupSignal = .noInputDelivered

    while !interaction.isComplete {
      signal = try await interaction.advance(using: port)
    }

    #expect(signal == .terminalVerified)
    #expect(await port.deliveredKeys == transitions.map { $0.1 })
    #expect(await port.remainingFrameCount == 0)
  }

  @Test("the live-proven experimental identity uses the direct observed trace")
  func experimentalSequenceReachesTerminalProof() async throws {
    let transitions = try PommeRecoveryNavigationRoute.directTerminal.eventTrace.map {
      ($0.preEventFrame, try #require($0.key), $0.postEventFrame)
    }
    let frames = transitions.flatMap { pre, _, post in [pre, pre, post, post] }
    let receipts = transitions.map { _, key, _ in
      PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
    }
    let port = RecoveryPort(frames: frames, receipts: receipts)
    var interaction = try PommeTahoeRecoveryInteraction(evidence: experimentalEvidence)
    var signal: PommeRecoveryInteractionCleanupSignal = .noInputDelivered

    while !interaction.isComplete {
      signal = try await interaction.advance(using: port)
    }

    #expect(signal == .terminalVerified)
    #expect(await port.deliveredKeys == transitions.map { $0.1 })
    #expect(await port.remainingFrameCount == 0)
  }

  @Test("an unknown experimental screen emits no input")
  func experimentalUnknownScreenEmitsNoInput() async throws {
    let port = RecoveryPort(
      frames: [.unknown, .unknown],
      receipts: [.init(key: .right, deliveredEventCount: 1)]
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: experimentalEvidence)

    await #expect(
      throws: PommeRecoveryInteractionError.noInputDelivered(.noInputDelivered)
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys.isEmpty)
  }

  @Test("unstable experimental screens emit no input")
  func experimentalUnstableScreenEmitsNoInput() async throws {
    let port = RecoveryPort(
      frames: [.startupOptions, .startupIntermediate],
      receipts: [.init(key: .right, deliveredEventCount: 1)]
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: experimentalEvidence)

    await #expect(
      throws: PommeRecoveryInteractionError.noInputDelivered(.noInputDelivered)
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys.isEmpty)
  }

  @Test("an observation timeout before input stays a closed no-input failure")
  func observationTimeoutBeforeInputDoesNotDeliver() async throws {
    let port = RecoveryPort(
      frames: [],
      receipts: [.init(key: .right, deliveredEventCount: 1)],
      timeoutAfterExhaustion: .startupOptions
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    await #expect(
      throws: PommeRecoveryInteractionError.observationTimedOut(.noInputDelivered)
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys.isEmpty)
  }

  @Test("an observation timeout after input requires cleanup and never replays")
  func observationTimeoutAfterInputDoesNotReplay() async throws {
    let port = RecoveryPort(
      frames: [.startupOptions, .startupOptions],
      receipts: [.init(key: .right, deliveredEventCount: 1)],
      timeoutAfterExhaustion: .startupIntermediate
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    await #expect(
      throws: PommeRecoveryInteractionError.observationTimedOut(
        .recoveryCleanupRequired
      )
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys == [.right])

    await #expect(
      throws: PommeRecoveryInteractionError.recoveryCleanupRequired(
        .recoveryCleanupRequired
      )
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys == [.right])
  }

  @Test("capability is proven and prompt cleared before one launcher submission")
  func terminalLauncherFlow() async throws {
    let transitions = tahoeTransitions
    let frames = transitions.flatMap { pre, _, post in [pre, pre, post, post] }
    let receipts = transitions.map { _, key, _ in
      PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
    }
    let probe = PommeRecoveryVirtioFSCapabilityProbe(
      command: "/bin/echo POMME_PROBE",
      marker: "POMME_PROBE"
    )
    let port = RecoveryTerminalPort(frames: frames, receipts: receipts, markerResults: [true])
    let milestones = RecoveryMilestoneRecorder()
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let disposition = await interaction.driveToTerminalAndLaunch(
      using: port,
      capabilityProbes: [probe],
      launcherCommand: "/bin/echo POMME_READY",
      onMilestone: { await milestones.record($0) }
    )

    #expect(disposition == .terminalLauncherSubmitted)
    #expect(await port.launcherCount == 1)
    #expect(await port.submittedLines == [probe.command, "/bin/echo POMME_READY"])
    #expect(await port.verifiedMarkers == [probe.marker])
    #expect(await port.clearCount == 1)
    #expect(await port.observationsClearedBeforeLauncher)
    #expect(await port.preparedRoutes == [.reviewedMenus])
    #expect(await milestones.values == [
      .navigationStarted,
      .recoveryLoading,
      .utilitiesOpening,
      .terminalLaunching,
      .terminalVerified,
      .capabilityProbeSubmitted,
      .capabilityProbeVerified,
      .launcherSubmitted,
    ])
  }

  @Test("missing capability marker fails before the mutating launcher")
  func capabilityProbeFailureIsPreMutation() async throws {
    let transitions = tahoeTransitions
    let frames = transitions.flatMap { pre, _, post in [pre, pre, post, post] }
    let receipts = transitions.map { _, key, _ in
      PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
    }
    let probe = PommeRecoveryVirtioFSCapabilityProbe(
      command: "/bin/echo POMME_PROBE",
      marker: "POMME_PROBE"
    )
    let port = RecoveryTerminalPort(frames: frames, receipts: receipts, markerResults: [false])
    let milestones = RecoveryMilestoneRecorder()
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let disposition = await interaction.driveToTerminalAndLaunch(
      using: port,
      capabilityProbes: [probe],
      launcherCommand: "/bin/echo POMME_READY",
      onMilestone: { await milestones.record($0) }
    )

    #expect(disposition == .terminalProofFailed)
    #expect(await port.submittedLines == [probe.command])
    #expect(await port.launcherCount == 0)
    #expect(await port.clearCount == 0)
    #expect(await milestones.values.last == .capabilityProbeRejected)
  }

  @Test("expired launcher authority fails after proof but before mutation")
  func launcherAuthorityIsCheckedImmediatelyBeforeSubmission() async throws {
    let transitions = tahoeTransitions
    let frames = transitions.flatMap { pre, _, post in [pre, pre, post, post] }
    let receipts = transitions.map { _, key, _ in
      PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
    }
    let probe = PommeRecoveryVirtioFSCapabilityProbe(
      command: "/bin/echo POMME_PROBE",
      marker: "POMME_PROBE"
    )
    let port = RecoveryTerminalPort(frames: frames, receipts: receipts, markerResults: [true])
    let milestones = RecoveryMilestoneRecorder()
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let disposition = await interaction.driveToTerminalAndLaunch(
      using: port,
      capabilityProbes: [probe],
      launcherCommand: "/bin/echo POMME_READY",
      authorizeLauncherSubmission: { throw LauncherAuthorityProbe.expired },
      onMilestone: { await milestones.record($0) }
    )

    #expect(disposition == .recoveryCleanupRequired)
    #expect(await port.submittedLines == [probe.command])
    #expect(await port.launcherCount == 0)
    #expect(await port.clearCount == 1)
    #expect(await milestones.values.last == .launcherAuthorizationRejected)
  }

  @Test("an uncertain launcher submission is never retried")
  func uncertainLauncherSubmissionIsOneShot() async throws {
    let transitions = tahoeTransitions
    let frames = transitions.flatMap { pre, _, post in [pre, pre, post, post] }
    let receipts = transitions.map { _, key, _ in
      PommeRecoveryDurableInputReceipt(key: key, deliveredEventCount: 1)
    }
    let probe = PommeRecoveryVirtioFSCapabilityProbe(
      command: "/bin/echo POMME_PROBE",
      marker: "POMME_PROBE"
    )
    let port = RecoveryTerminalPort(
      frames: frames,
      receipts: receipts,
      markerResults: [true],
      failSubmission: 2
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let disposition = await interaction.driveToTerminalAndLaunch(
      using: port,
      capabilityProbes: [probe],
      launcherCommand: "/bin/echo POMME_READY"
    )

    #expect(disposition == .recoveryCleanupRequired)
    #expect(await port.submittedLines == [probe.command, "/bin/echo POMME_READY"])
    #expect(await port.launcherCount == 1)
  }

  @Test("unsafe launcher input is rejected before any Recovery event")
  func unsafeLauncherIsPreflightOnly() async throws {
    let probe = PommeRecoveryVirtioFSCapabilityProbe(
      command: "/bin/echo POMME_PROBE",
      marker: "POMME_PROBE"
    )
    let port = RecoveryTerminalPort(frames: [], receipts: [], markerResults: [])
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    let disposition = await interaction.driveToTerminalAndLaunch(
      using: port,
      capabilityProbes: [probe],
      launcherCommand: "echo unsafe\nsecond-command"
    )

    #expect(disposition == .noInputDelivered)
    #expect(await port.deliveredKeys.isEmpty)
    #expect(await port.launcherCount == 0)
  }

  @Test("legal language text needs Options-activated context")
  func languageLegalSurfaceIsContextBound() throws {
    let lines = [
      ocrLine("Language"),
      ocrLine("English"),
      ocrLine("By using this software, you agree to the terms of the software license agreement"),
    ]
    let observation = RecoveryUIObservation(lines: lines)
    let image = try makeClassifierImage()

    #expect(observation.isAmbiguousLanguageOrLegalSurface)
    #expect(!observation.hasExplicitRecoveryLanguageAnchor)
    #expect(
      PommeRecoveryFrameClassifier.classify(
        image: image,
        lines: lines,
        context: .optionsActivated
      ) == .languageEnglish
    )
    #expect(
      PommeRecoveryFrameClassifier.classify(
        image: image,
        lines: lines,
        context: .unproven
      ) == .unknown
    )
  }

  @Test("Sequoia Recovery Utilities anchor classifies without language context")
  func sequoiaUtilitiesAnchorClassifies() throws {
    let image = try makeClassifierImage()
    let lines = [ocrLine("Reinstall macOS Sequoia")]

    #expect(
      PommeRecoveryFrameClassifier.classify(
        image: image,
        lines: lines,
        context: .unproven
      ) == .recoveryUtilities
    )
  }

  @Test("launcher preflight permits only direct keyboard characters")
  func keyboardSafeLauncherPreflight() {
    #expect(PommeRecoveryTerminalCommand.isKeyboardSafe("/bin/echo POMME_READY"))
    #expect(!PommeRecoveryTerminalCommand.isKeyboardSafe("echo POMME_READY\nrm -rf /"))
    #expect(PommeRecoveryTerminalCommand.isSafeMarker("POMME_READY"))
    #expect(!PommeRecoveryTerminalCommand.isSafeMarker("POMME_READY\n"))
  }

  @Test("a malformed receipt never causes a replacement input")
  func malformedReceiptRequiresCleanupWithoutRetry() async throws {
    let port = RecoveryPort(
      frames: [.startupOptions, .startupOptions],
      receipts: [.init(key: .right, deliveredEventCount: 2)]
    )
    var interaction = try PommeTahoeRecoveryInteraction(evidence: tahoeEvidence)

    await #expect(
      throws: PommeRecoveryInteractionError.recoveryCleanupRequired(
        .recoveryCleanupRequired
      )
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys == [.right])

    await #expect(
      throws: PommeRecoveryInteractionError.recoveryCleanupRequired(
        .recoveryCleanupRequired
      )
    ) {
      _ = try await interaction.advance(using: port)
    }
    #expect(await port.deliveredKeys == [.right])
  }

  @Test("unqualified profiles cannot construct a delivery driver")
  func qualificationFailsClosed() {
    let unknownABI = PommeRecoveryProfileEvidence(
      build: .tahoe2660Build25G72,
      locale: .english,
      geometry: .pixels1280x800,
      privateHostABI: .unknown,
      manifestHash: .tahoe2660Build25G72,
      ownership: .verified
    )
    #expect(throws: PommeRecoveryInteractionError.incompleteQualification) {
      _ = try PommeTahoeRecoveryInteraction(evidence: unknownABI)
    }
  }

  @Test("cancellation before observation emits no input and a closed cleanup signal")
  func cancellationBeforeObservation() async throws {
    let port = RecoveryPort(frames: [], receipts: [])
    let evidence = tahoeEvidence
    let task = Task<PommeRecoveryInteractionCleanupSignal, Error> {
      withUnsafeCurrentTask { $0?.cancel() }
      var interaction = try PommeTahoeRecoveryInteraction(evidence: evidence)
      return try await interaction.advance(using: port)
    }

    await #expect(
      throws: PommeRecoveryInteractionError.noInputDelivered(
        .noInputDelivered
      )
    ) {
      _ = try await task.value
    }
    #expect(await port.deliveredKeys.isEmpty)
  }

  @Test("normal boot readiness is display-only and needs two qualified frames")
  func normalBootDisplayGate() throws {
    var gate = PommeDisplayOnlyNormalBootGate()
    #expect(try gate.observe(.present(width: 1280, height: 800)) == nil)
    #expect(try gate.observe(.present(width: 1280, height: 800)) == .init(width: 1280, height: 800))

    #expect(throws: PommeDisplayOnlyNormalBootError.unqualifiedGeometry) {
      _ = try gate.observe(.present(width: 1280, height: 799))
    }
    #expect(try gate.observe(.present(width: 1280, height: 800)) == nil)
    #expect(throws: PommeDisplayOnlyNormalBootError.displayUnavailable) {
      _ = try gate.observe(.unavailable)
    }
    #expect(try gate.observe(.present(width: 1280, height: 800)) == nil)
  }

  private var tahoeEvidence: PommeRecoveryProfileEvidence {
    .init(
      build: .tahoe2660Build25G72,
      locale: .english,
      geometry: .pixels1280x800,
      privateHostABI: .qualifiedRecoveryInputV1,
      manifestHash: .tahoe2660Build25G72,
      ownership: .verified
    )
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

  private var tahoeTransitions: [(PommeRecoveryFrame, PommeRecoveryVirtualKey, PommeRecoveryFrame)]
  {
    [
      (.startupOptions, .right, .startupIntermediate),
      (.startupIntermediate, .right, .startupOptionsActivated),
      (.startupOptionsActivated, .return, .languageEnglish),
      (.languageEnglish, .return, .recoveryUtilities),
      (.recoveryUtilities, .controlF2, .applicationMenu),
      (.applicationMenu, .right, .recoveryMenu),
      (.recoveryMenu, .right, .fileMenu),
      (.fileMenu, .right, .editMenu),
      (.editMenu, .right, .utilitiesMenu),
      (.utilitiesMenu, .down, .terminalMenuItem),
      (.terminalMenuItem, .shiftCommandT, .terminal),
    ]
  }

  private func ocrLine(_ text: String) -> SettingsAIOCRLine {
    .init(text: text, confidence: 1, rect: .init(x: 0, y: 0, width: 1, height: 1))
  }

  private func makeClassifierImage() throws -> CGImage {
    let width = Int(VirtualizationPrivateHeadlessBackend.displayWidth)
    let height = Int(VirtualizationPrivateHeadlessBackend.displayHeight)
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try #require(context.makeImage())
  }
}

private actor RecoveryPort: PommeRecoveryKeyboardPort {
  private var frames: [PommeRecoveryFrame]
  private var receipts: [PommeRecoveryDurableInputReceipt]
  private let timeoutAfterExhaustion: PommeRecoveryFrame?
  private(set) var deliveredKeys: [PommeRecoveryVirtualKey] = []

  init(
    frames: [PommeRecoveryFrame],
    receipts: [PommeRecoveryDurableInputReceipt],
    timeoutAfterExhaustion: PommeRecoveryFrame? = nil
  ) {
    self.frames = frames
    self.receipts = receipts
    self.timeoutAfterExhaustion = timeoutAfterExhaustion
  }

  func nextRecoveryFrame() throws -> PommeRecoveryFrame {
    if frames.isEmpty, let expected = timeoutAfterExhaustion {
      throw PommeRecoveryVirtualizationPortError.observationTimedOut(expected)
    }
    guard !frames.isEmpty else { throw RecoveryPortError.depleted }
    return frames.removeFirst()
  }

  func deliverRecoveryKey(_ key: PommeRecoveryVirtualKey) throws -> PommeRecoveryDurableInputReceipt
  {
    deliveredKeys.append(key)
    guard !receipts.isEmpty else { throw RecoveryPortError.depleted }
    return receipts.removeFirst()
  }

  var remainingFrameCount: Int { frames.count }
}

private actor RecoveryPairPort: PommeRecoveryKeyboardPort {
  private let preEventFrame: PommeRecoveryFrame
  private let postEventFrame: PommeRecoveryFrame
  private let receipt: PommeRecoveryDurableInputReceipt
  private var pairPhase = 0
  private(set) var pairRequestCount = 0
  private(set) var deliveredKeys: [PommeRecoveryVirtualKey] = []

  init(
    preEventFrame: PommeRecoveryFrame,
    postEventFrame: PommeRecoveryFrame,
    receipt: PommeRecoveryDurableInputReceipt
  ) {
    self.preEventFrame = preEventFrame
    self.postEventFrame = postEventFrame
    self.receipt = receipt
  }

  func nextRecoveryFrame() async throws -> PommeRecoveryFrame {
    throw RecoveryPortError.depleted
  }

  func nextRecoveryFramePair() async throws -> [PommeRecoveryFrame] {
    pairRequestCount += 1
    defer { pairPhase += 1 }
    switch pairPhase {
    case 0: return [preEventFrame, preEventFrame]
    case 1: return [postEventFrame, postEventFrame]
    default: throw RecoveryPortError.depleted
    }
  }

  func deliverRecoveryKey(
    _ key: PommeRecoveryVirtualKey
  ) async throws -> PommeRecoveryDurableInputReceipt {
    deliveredKeys.append(key)
    return receipt
  }
}

private enum RecoveryPortError: Error {
  case depleted
  case submissionFailed
}

private enum LauncherAuthorityProbe: Error {
  case expired
}

private actor RecoveryTerminalPort: PommeRecoveryTerminalPort {
  private var frames: [PommeRecoveryFrame]
  private var receipts: [PommeRecoveryDurableInputReceipt]
  private var markerResults: [Bool]
  private let failSubmission: Int?
  private(set) var deliveredKeys: [PommeRecoveryVirtualKey] = []
  private(set) var submittedLines: [String] = []
  private(set) var verifiedMarkers: [String] = []
  private(set) var clearCount = 0
  private(set) var preparedRoutes: [PommeRecoveryNavigationRoute] = []
  private var observationsCleared = false
  private(set) var observationsClearedBeforeLauncher = false

  func prepareRecoveryNavigation(route: PommeRecoveryNavigationRoute) {
    preparedRoutes.append(route)
  }

  func clearRecoveryObservations() { observationsCleared = true }

  init(
    frames: [PommeRecoveryFrame],
    receipts: [PommeRecoveryDurableInputReceipt],
    markerResults: [Bool],
    failSubmission: Int? = nil
  ) {
    self.frames = frames
    self.receipts = receipts
    self.markerResults = markerResults
    self.failSubmission = failSubmission
  }

  func nextRecoveryFrame() throws -> PommeRecoveryFrame {
    guard !frames.isEmpty else { throw RecoveryPortError.depleted }
    return frames.removeFirst()
  }

  func deliverRecoveryKey(
    _ key: PommeRecoveryVirtualKey
  ) throws -> PommeRecoveryDurableInputReceipt {
    deliveredKeys.append(key)
    guard !receipts.isEmpty else { throw RecoveryPortError.depleted }
    return receipts.removeFirst()
  }

  func submitTerminalLine(_ command: String) throws {
    if !submittedLines.isEmpty {
      observationsClearedBeforeLauncher = observationsCleared
    }
    submittedLines.append(command)
    if submittedLines.count == failSubmission { throw RecoveryPortError.submissionFailed }
  }

  func terminalMarkerIsVerified(_ marker: String) -> Bool {
    verifiedMarkers.append(marker)
    guard !markerResults.isEmpty else { return false }
    return markerResults.removeFirst()
  }

  func clearTerminalLine() { clearCount += 1 }

  var launcherCount: Int { max(0, submittedLines.count - 1) }
}

private actor RecoveryMilestoneRecorder {
  private(set) var values: [PommeRecoveryInteractionMilestone] = []

  func record(_ milestone: PommeRecoveryInteractionMilestone) {
    values.append(milestone)
  }
}

@Suite("Recovery navigation progress milestones")
struct PommeRecoveryNavigationMilestoneTests {
  @Test("only the inputs that start a long guest transition are named")
  func milestonesBeforeLongTransitions() {
    typealias Interaction = PommeTahoeRecoveryInteraction
    #expect(Interaction.milestone(before: .key(.return), preEventFrame: .startupOptionsActivated) == .recoveryLoading)
    #expect(Interaction.milestone(before: .key(.return), preEventFrame: .languageEnglish) == .utilitiesOpening)
    #expect(Interaction.milestone(before: .key(.return), preEventFrame: .languageEnglishActive) == .utilitiesOpening)
    #expect(Interaction.milestone(before: .key(.shiftCommandT), preEventFrame: .terminalMenuItem) == .terminalLaunching)
    #expect(Interaction.milestone(before: .key(.shiftCommandT), preEventFrame: .recoveryUtilities) == .terminalLaunching)
    #expect(Interaction.milestone(before: .key(.right), preEventFrame: .startupOptions) == nil)
    #expect(Interaction.milestone(before: .activateLanguageChooser, preEventFrame: .languageEnglishInactive) == nil)
    #expect(Interaction.milestone(before: .key(.return), preEventFrame: .languageEnglishInactive) == nil)
  }
}
