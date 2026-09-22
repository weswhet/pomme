import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Retains private, full-resolution Recovery navigation evidence only when a
/// caller explicitly enables it. The recorder owns a unique attempt directory
/// and never returns frame pixels or OCR text to the workflow layer.
///
/// Capture failures are diagnostics, not input authorization failures. A
/// cancellation remains an operation failure so no key can be delivered after
/// cancellation is observed.
actor PommeRecoveryNavigationScreenshotRecorder {
  typealias Capture = @Sendable (TimeInterval) async throws -> CGImage
  typealias Clock = @Sendable () -> Date

  static let captureTimeout: TimeInterval = 2

  private let capture: Capture
  private let clock: Clock
  private let log: @Sendable (String) -> Void
  private let fileManager: FileManager
  private let temporaryDirectory: URL
  private let vmName: String
  private var directoryURL: URL?
  private var attemptedDirectoryCreation = false
  private var sequence = 0
  private var isEnabled = true
  private var files: [URL] = []
  private var warningMessages: [String] = []

  init(
    vmName: String,
    capture: @escaping Capture,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    fileManager: FileManager = .default,
    clock: @escaping Clock = Date.init,
    log: @escaping @Sendable (String) -> Void = { PommeCore.log($0) }
  ) {
    self.capture = capture
    self.fileManager = fileManager
    self.temporaryDirectory = temporaryDirectory
    self.vmName = vmName
    self.clock = clock
    self.log = log
  }

  func directory() -> URL? { directoryURL }

  func savedFiles() -> [URL] { files }

  /// Closed host-side diagnostic categories for CLI stderr rendering. Never
  /// include an underlying error, pixel content, OCR text, or guest data.
  func warnings() -> [String] { warningMessages }

  /// The Terminal prompt is a hard boundary: no Terminal command, launcher,
  /// or resulting guest output is captured after this point.
  func disable() { isEnabled = false }

  func captureNavigation(
    from startingFrame: PommeRecoveryFrame,
    key: PommeRecoveryVirtualKey,
    expectedDestinations: [PommeRecoveryFrame]
  ) async throws {
    try await captureNavigation(from: startingFrame, input: .key(key), expectedDestinations: expectedDestinations)
  }

  func captureNavigation(
    from startingFrame: PommeRecoveryFrame,
    input: PommeRecoveryNavigationInput,
    expectedDestinations: [PommeRecoveryFrame]
  ) async throws {
    let destinations = expectedDestinations.map(Self.frameName).joined(separator: "-or-")
    let label = "\(Self.frameName(startingFrame))_\(Self.inputName(input))_to_\(destinations)"
    try await capture(label: label)
  }

  func captureTimeout(awaiting expectedFrames: [PommeRecoveryFrame]) async throws {
    let names = expectedFrames.map(Self.frameName).joined(separator: "-or-")
    try await capture(label: "timeout-awaiting-\(names)")
  }

  /// The exact navigation-input ordering used by the virtualization port.
  /// Keeping this small sequence independent of the private VZ backend gives
  /// tests a way to prove that debug evidence never moves before readiness or
  /// after the one HID delivery.
  nonisolated static func captureBeforeNavigationInput(
    recorder: PommeRecoveryNavigationScreenshotRecorder?,
    from startingFrame: PommeRecoveryFrame,
    key: PommeRecoveryVirtualKey,
    expectedDestinations: [PommeRecoveryFrame],
    awaitInputReadiness: @escaping @Sendable () async throws -> Void,
    reproveAfterCapture: @escaping @Sendable () async throws -> Void = {},
    deliver: @escaping @Sendable () async throws -> Void
  ) async throws {
    try await captureBeforeNavigationInput(
      recorder: recorder, from: startingFrame, input: .key(key), expectedDestinations: expectedDestinations,
      awaitInputReadiness: awaitInputReadiness, reproveAfterCapture: reproveAfterCapture, deliver: deliver
    )
  }

  nonisolated static func captureBeforeNavigationInput(
    recorder: PommeRecoveryNavigationScreenshotRecorder?,
    from startingFrame: PommeRecoveryFrame,
    input: PommeRecoveryNavigationInput,
    expectedDestinations: [PommeRecoveryFrame],
    awaitInputReadiness: @escaping @Sendable () async throws -> Void,
    reproveAfterCapture: @escaping @Sendable () async throws -> Void = {},
    deliver: @escaping @Sendable () async throws -> Void
  ) async throws {
    try await awaitInputReadiness()
    try Task.checkCancellation()
    if let recorder {
      try await recorder.captureNavigation(
        from: startingFrame,
        input: input,
        expectedDestinations: expectedDestinations
      )
      // Debug capture can itself take up to two seconds. Re-prove the closed
      // pre-event frame after it completes so enabling diagnostics never
      // relaxes Recovery's stable-frame input requirement.
      try await reproveAfterCapture()
    }
    try Task.checkCancellation()
    try await deliver()
  }

  private func capture(label: String) async throws {
    guard isEnabled, let directoryURL = ensureDirectory() else { return }
    sequence += 1
    let captureSequence = sequence
    let destination = directoryURL.appendingPathComponent(
      Self.fileName(sequence: captureSequence, date: clock(), label: label),
      isDirectory: false
    )
    let image: CGImage
    do {
      try Task.checkCancellation()
      // One bounded capture only. A failed capture/encode/write is deliberately
      // not retried because navigation must retain its existing timing.
      image = try await capture(Self.captureTimeout)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      warn("Recovery debug screenshot capture failed; continuing navigation.")
      return
    }
    try Task.checkCancellation()

    let png: Data
    do {
      png = try encodePNG(image)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      warn("Recovery debug screenshot PNG encoding failed; continuing navigation.")
      return
    }
    try Task.checkCancellation()

    do {
      try writePNG(png, to: destination)
    } catch PommeRecoveryNavigationScreenshotError.partialCleanupFailed {
      if Task.isCancelled { throw CancellationError() }
      warn("Recovery debug screenshot partial-file cleanup failed; inspect the screenshot directory.")
      return
    } catch PommeRecoveryNavigationScreenshotError.invalidPublishedFile {
      if Task.isCancelled { throw CancellationError() }
      warn("Recovery debug screenshot published-file validation failed; inspect the screenshot directory.")
      return
    } catch {
      if Task.isCancelled { throw CancellationError() }
      warn("Recovery debug screenshot write failed; continuing navigation.")
      return
    }
    files.append(destination)
    log("Recovery debug screenshot saved: \(destination.path)")
    // Retain/announce a complete image even when cancellation arrived during
    // synchronous encoding or publication; the caller still checks before it
    // can send a key.
    try Task.checkCancellation()
  }

  /// Lazily creating this directory ensures ordinary dry runs and workflows
  /// which construct a port but never navigate create no diagnostic files.
  private func ensureDirectory() -> URL? {
    if let directoryURL { return directoryURL }
    guard !attemptedDirectoryCreation else { return nil }
    attemptedDirectoryCreation = true
    let candidate = temporaryDirectory.appendingPathComponent(
      Self.directoryName(vmName: vmName, date: clock()),
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(
        at: candidate,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
      try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: candidate.path)
      guard Self.isPrivateDirectory(candidate) else {
        throw PommeRecoveryNavigationScreenshotError.writeFailed
      }
      directoryURL = candidate
      log("Recovery debug screenshots: \(candidate.path)")
      return candidate
    } catch {
      warn("Recovery debug screenshot directory creation failed; continuing without screenshots.")
      return nil
    }
  }

  private func encodePNG(_ image: CGImage) throws -> Data {
    let mutableData = NSMutableData()
    guard let imageDestination = CGImageDestinationCreateWithData(
      mutableData,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw PommeRecoveryNavigationScreenshotError.encodingFailed
    }
    CGImageDestinationAddImage(imageDestination, image, nil)
    guard CGImageDestinationFinalize(imageDestination) else {
      throw PommeRecoveryNavigationScreenshotError.encodingFailed
    }
    return mutableData as Data
  }

  private func warn(_ message: String) {
    warningMessages.append(message)
    log("Warning: \(message)")
  }

  private func writePNG(_ png: Data, to destination: URL) throws {
    let partial = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).partial",
      isDirectory: false
    )
    guard fileManager.createFile(
      atPath: partial.path,
      contents: nil,
      attributes: [.posixPermissions: NSNumber(value: 0o600)]
    ) else {
      throw PommeRecoveryNavigationScreenshotError.writeFailed
    }
    var published = false
    do {
      try png.write(to: partial, options: [])
      try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: partial.path)
      guard Self.isPrivateRegularFile(partial) else {
        throw PommeRecoveryNavigationScreenshotError.writeFailed
      }
      guard Darwin.rename(partial.path, destination.path) == 0 else {
        throw PommeRecoveryNavigationScreenshotError.writeFailed
      }
      published = true
      guard Self.isPrivateRegularFile(destination) else {
        // The exact published path is ours only when it still has the secure
        // regular-file shape. Remove that known-safe case; never expand a
        // cleanup operation onto an unvalidated replacement.
        if Self.isOwnedRegularFile(destination) {
          do {
            try fileManager.removeItem(at: destination)
          } catch {
            throw PommeRecoveryNavigationScreenshotError.partialCleanupFailed
          }
        }
        throw PommeRecoveryNavigationScreenshotError.invalidPublishedFile
      }
    } catch {
      guard !published else { throw error }
      // Prior to rename only this exact, freshly-created partial path can be
      // removed. A failed cleanup is surfaced rather than silently hidden.
      guard fileManager.fileExists(atPath: partial.path) else { throw error }
      guard Self.isPrivateRegularFile(partial) else {
        throw PommeRecoveryNavigationScreenshotError.partialCleanupFailed
      }
      do {
        try fileManager.removeItem(at: partial)
      } catch {
        throw PommeRecoveryNavigationScreenshotError.partialCleanupFailed
      }
      throw error
    }
  }

  private static func directoryName(vmName: String, date: Date) -> String {
    "pomme-recovery-debug-\(safeComponent(vmName, fallback: "vm"))-\(timestamp(date))-\(UUID().uuidString.lowercased())"
  }

  private static func fileName(sequence: Int, date: Date, label: String) -> String {
    String(format: "%04d", sequence) + "_\(timestamp(date))_\(safeComponent(label, fallback: "capture")).png"
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
  }

  private static func safeComponent(_ value: String, fallback: String) -> String {
    let bytes = value.utf8.map { byte -> Character in
      switch byte {
      case 48...57, 65...90, 97...122, 45, 95:
        Character(UnicodeScalar(byte))
      default:
        "-"
      }
    }
    let sanitized = String(bytes).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return sanitized.isEmpty ? fallback : sanitized
  }

  private static func isPrivateDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
      && info.st_uid == geteuid()
      && info.st_mode & S_IFMT == S_IFDIR
      && info.st_mode & 0o777 == 0o700
  }

  private static func isPrivateRegularFile(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
      && info.st_uid == geteuid()
      && info.st_mode & S_IFMT == S_IFREG
      && info.st_mode & 0o777 == 0o600
  }

  private static func isOwnedRegularFile(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
      && info.st_uid == geteuid()
      && info.st_mode & S_IFMT == S_IFREG
  }

  private static func frameName(_ frame: PommeRecoveryFrame) -> String {
    switch frame {
    case .startupOptions: "startupOptions"
    case .startupIntermediate: "startupIntermediate"
    case .startupOptionsActivated: "startupOptionsActivated"
    case .languageEnglish: "languageEnglish"
    case .languageEnglishInactive: "languageEnglishInactive"
    case .languageEnglishActive: "languageEnglishActive"
    case .recoveryUtilities: "recoveryUtilities"
    case .applicationMenu: "applicationMenu"
    case .recoveryMenu: "recoveryMenu"
    case .fileMenu: "fileMenu"
    case .editMenu: "editMenu"
    case .utilitiesMenu: "utilitiesMenu"
    case .terminalMenuItem: "terminalMenuItem"
    case .terminal: "terminal"
    case .unknown: "unknown"
    }
  }

  private static func keyName(_ key: PommeRecoveryVirtualKey) -> String {
    switch key {
    case .controlF2: "control-f2"
    case .right: "right"
    case .down: "down"
    case .return: "return"
    case .shiftCommandT: "shift-command-t"
    }
  }

  private static func inputName(_ input: PommeRecoveryNavigationInput) -> String {
    switch input {
    case .key(let key): keyName(key)
    case .activateLanguageChooser: "activate-language-chooser"
    }
  }
}

private enum PommeRecoveryNavigationScreenshotError: Error, Sendable {
  case encodingFailed
  case writeFailed
  case partialCleanupFailed
  case invalidPublishedFile
}
