import Darwin
import Foundation

/// A plain-language description of an operating-system or framework error.
/// It keeps the error's domain and number so a maintainer can look them up,
/// and picks the Pomme code that best describes the failure.
struct SystemErrorDescription: Equatable, Sendable {
    let pommeCode: PommeErrorCode
    let message: String
    let hint: String?
    let domain: String
    let code: String

    static let virtualizationDomain = "VZErrorDomain"

    /// The domains these translators understand, so a Swift error bridged
    /// to `NSError` is never mistaken for one of them.
    static let knownDomains: Set<String> = [
        virtualizationDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain, NSCocoaErrorDomain
    ]

    static func isBridgedSystemError(_ error: any Error) -> Bool {
        error is POSIXError || error is URLError || error is CocoaError
            || knownDomains.contains((error as NSError).domain)
    }

    init(pommeCode: PommeErrorCode, message: String, hint: String? = nil, domain: String, code: String) {
        self.pommeCode = pommeCode
        self.message = message
        self.hint = hint
        self.domain = domain
        self.code = code
    }

    init?(_ error: any Error) {
        if error is CancellationError {
            self.init(pommeCode: .operationCancelled, message: "The operation was cancelled.", domain: "Swift.CancellationError", code: "cancelled")
            return
        }
        if let decoding = error as? DecodingError {
            self = Self.decoding(decoding)
            return
        }
        guard type(of: error) is NSError.Type || Self.isBridgedSystemError(error) else { return nil }
        let bridged = error as NSError
        switch bridged.domain {
        case Self.virtualizationDomain:
            self = Self.virtualization(code: bridged.code, fallback: bridged.localizedDescription)
        case NSPOSIXErrorDomain:
            self = Self.posix(Int32(truncatingIfNeeded: bridged.code))
        case NSOSStatusErrorDomain:
            self = Self.osStatus(OSStatus(truncatingIfNeeded: bridged.code))
        case NSURLErrorDomain:
            self = Self.url(code: bridged.code, fallback: bridged.localizedDescription)
        case NSCocoaErrorDomain:
            self = Self.cocoa(bridged)
        default:
            self.init(
                pommeCode: .systemError,
                message: Self.sentence(bridged.localizedDescription),
                domain: bridged.domain,
                code: String(bridged.code)
            )
        }
    }

    /// A clause for the end of a wrapping message, such as
    /// `the disk is out of space (VZErrorDomain 8)`.
    var clause: String {
        let lowered = Self.lowercasingFirstWord(message.hasSuffix(".") ? String(message.dropLast()) : message)
        return "\(lowered) (\(domain) \(code))"
    }

    // MARK: Virtualization.framework

    static func virtualization(code: Int, fallback: String = "") -> Self {
        let (pommeCode, message, hint): (PommeErrorCode, String, String?) = switch code {
        case 1: (.virtualizationError, "Virtualization.framework had an internal error.", nil)
        case 2: (.vmConfigurationInvalid, "The VM's configuration isn't valid on this Mac.", "Run `pomme inspect NAME` to check its CPU, memory, and disk settings.")
        case 3: (.vmStateInvalid, "The VM isn't in a state that allows this operation.", "Run `pomme status NAME` to see its state.")
        case 4: (.vmStateInvalid, "The VM can't change to the requested state from its current state.", "Run `pomme status NAME` to see its state.")
        case 5: (.vmDiskImageInvalid, "The VM's disk image isn't valid or couldn't be opened.", nil)
        case 6: (.vmLimitReached, "This Mac is already running as many macOS VMs as Virtualization.framework allows.", "Stop another VM with `pomme stop NAME`, then retry.")
        case 7: (.networkError, "A network error occurred.", nil)
        case 8: (.hostDiskFull, "The disk is out of space.", "Free space on the volume that holds your VMs, then retry.")
        case 9: (.operationCancelled, "The operation was cancelled.", nil)
        case 10: (.virtualizationUnsupported, "This Mac doesn't support the requested virtualization feature.", nil)
        case 11: (.vmSaveFailed, "Saving the VM's state failed.", nil)
        case 12: (.vmSaveFailed, "Restoring the VM's saved state failed.", nil)
        case 10001: (.restoreImageInvalid, "The restore image catalog couldn't be loaded.", "Check the network connection, then retry.")
        case 10002: (.restoreImageInvalid, "The restore image catalog isn't valid.", nil)
        case 10003: (.restoreImageInvalid, "The restore image catalog has no image that this Mac supports.", nil)
        case 10004: (.restoreImageInvalid, "The restore image couldn't be loaded.", "Download the image again with `pomme ipsw`, then retry.")
        case 10005: (.restoreImageInvalid, "The restore image isn't valid.", "Download the image again with `pomme ipsw`, then retry.")
        case 10006: (.hostUpdateRequired, "Installing this restore image requires a software update on this Mac.", "Install the available updates in System Settings > General > Software Update, then retry.")
        case 10007: (.macosInstallFailed, "The macOS installation failed.", nil)
        case 20001, 20002: (.virtualizationError, "The network block device connection failed.", nil)
        case 30001...30004: (.virtualizationError, "A USB device operation failed.", nil)
        case 40001: (.invalidRequest, "The guest provisioning full name isn't valid.", nil)
        case 40002: (.invalidRequest, "The guest provisioning account name isn't valid.", nil)
        case 40003: (.invalidRequest, "The guest provisioning account credential isn't valid.", nil)
        case 50001, 50002: (.virtualizationError, "An EFI variable operation failed.", nil)
        default: (.virtualizationError, fallback.isEmpty ? "Virtualization.framework reported an error." : sentence(fallback), nil)
        }
        return .init(pommeCode: pommeCode, message: message, hint: hint, domain: virtualizationDomain, code: String(code))
    }

    // MARK: POSIX

    static func posix(_ number: Int32) -> Self {
        let text = String(cString: strerror(number))
        let pommeCode: PommeErrorCode = switch number {
        case ENOSPC, EDQUOT: .hostDiskFull
        case EACCES, EPERM: .permissionDenied
        case ENOENT: .fileNotFound
        case ETIMEDOUT: .timedOut
        default: .systemCallFailed
        }
        return .init(pommeCode: pommeCode, message: text + ".", domain: NSPOSIXErrorDomain, code: String(number))
    }

    // MARK: OSStatus

    static func osStatus(_ status: OSStatus) -> Self {
        .init(pommeCode: .keychainError, message: sentence(securityErrorMessage(status)), domain: NSOSStatusErrorDomain, code: String(status))
    }

    // MARK: URL loading

    static func url(code: Int, fallback: String) -> Self {
        let message: String = switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet: "This Mac isn't connected to the internet."
        case .timedOut: "The network request timed out."
        case .cannotFindHost, .dnsLookupFailed: "The server's host name couldn't be resolved."
        case .cannotConnectToHost: "The server refused the connection."
        case .networkConnectionLost: "The network connection was lost."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "A secure connection to the server couldn't be established."
        case .cancelled: "The network request was cancelled."
        case .badServerResponse: "The server returned an invalid response."
        default: fallback.isEmpty ? "The network request failed." : sentence(fallback)
        }
        return .init(
            pommeCode: .networkError,
            message: message,
            hint: "Check the network connection, then retry.",
            domain: NSURLErrorDomain,
            code: String(code)
        )
    }

    // MARK: Cocoa file errors

    static func cocoa(_ error: NSError) -> Self {
        let path = (error.userInfo[NSFilePathErrorKey] as? String)
            ?? (error.userInfo[NSURLErrorKey] as? URL)?.path
        let subject = path.map { "`\($0)`" } ?? "The file"
        let (pommeCode, message): (PommeErrorCode, String) = switch CocoaError.Code(rawValue: error.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile: (.fileNotFound, "\(subject) doesn't exist.")
        case .fileReadNoPermission, .fileWriteNoPermission: (.permissionDenied, "You don't have permission to access \(path.map { "`\($0)`" } ?? "the file").")
        case .fileWriteOutOfSpace: (.hostDiskFull, "The disk is out of space.")
        case .fileWriteFileExists: (.fileError, "\(subject) already exists.")
        case .fileReadCorruptFile: (.fileError, "\(subject) is damaged or in an unexpected format.")
        case .fileWriteVolumeReadOnly: (.fileError, "The volume is read-only.")
        case .fileReadTooLarge: (.fileError, "\(subject) is too large to read.")
        case .fileLocking: (.fileError, "\(subject) is locked.")
        default: (.fileError, sentence(error.localizedDescription))
        }
        return .init(pommeCode: pommeCode, message: message, domain: NSCocoaErrorDomain, code: String(error.code))
    }

    // MARK: Decoding

    static func decoding(_ error: DecodingError) -> Self {
        let (kind, message): (String, String) = switch error {
        case .keyNotFound(let key, let context):
            ("keyNotFound", "The data is missing the required key '\(ConfigDecodingMessage.dottedPath(context.codingPath + [key]))'.")
        case .typeMismatch(_, let context):
            ("typeMismatch", "The data has the wrong type at '\(ConfigDecodingMessage.dottedPath(context.codingPath))'.")
        case .valueNotFound(_, let context):
            ("valueNotFound", "The data has no value at '\(ConfigDecodingMessage.dottedPath(context.codingPath))'.")
        case .dataCorrupted(let context):
            ("dataCorrupted", context.codingPath.isEmpty
                ? "The data isn't valid JSON."
                : "The data at '\(ConfigDecodingMessage.dottedPath(context.codingPath))' isn't valid.")
        @unknown default:
            ("unknown", "The data couldn't be decoded.")
        }
        return .init(pommeCode: .dataInvalid, message: message, domain: "Swift.DecodingError", code: kind)
    }

    // MARK: Text helpers

    /// Names that keep their capital letter inside a clause.
    static let properNouns: Set<String> = [
        "Pomme", "Virtualization", "Recovery", "Keychain", "Apple", "Setup", "Screen", "Finder", "Terminal"
    ]

    /// Ends framework text with one period.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// Lowercases a leading capitalized word so a sentence reads as a
    /// clause, but leaves acronyms such as `VM` and names such as `macOS`
    /// and `Pomme`.
    static func lowercasingFirstWord(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count > 1, characters[0].isUppercase, characters[1].isLowercase else { return text }
        let firstWord = text.prefix { $0.isLetter }
        guard !properNouns.contains(String(firstWord)) else { return text }
        return characters[0].lowercased() + String(characters.dropFirst())
    }
}

extension PommeErrorDescriber {
    /// The cause of `error` as a clause for a wrapping message, such as
    /// `the disk is out of space (VZErrorDomain 8)`.
    static func clause(for error: any Error) -> String {
        if let system = SystemErrorDescription(error) { return system.clause }
        let message = describe(error).message
        return SystemErrorDescription.lowercasingFirstWord(message.hasSuffix(".") ? String(message.dropLast()) : message)
    }

    static func clause(for report: PommeErrorReport) -> String {
        let message = report.message.hasSuffix(".") ? String(report.message.dropLast()) : report.message
        let lowered = SystemErrorDescription.lowercasingFirstWord(message)
        if let cause = report.causes.first(where: { $0.domain != "pomme" }), report.code != .internalError {
            return lowered.contains("(\(cause.domain) ") ? lowered : "\(lowered) (\(cause.domain) \(cause.code))"
        }
        return lowered
    }
}
