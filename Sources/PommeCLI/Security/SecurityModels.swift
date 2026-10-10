import Foundation

enum SIPAction: String, CaseIterable, Codable, Sendable {
    case status
    case disable
    case enable
}
enum AMFIAction: String, CaseIterable, Codable, Sendable {
    case status
    case disable
    case enable
}

enum PrivateXPCSecurityAction: String, CaseIterable, Codable, Sendable {
    case status
    case prepare
}

struct SIPBootstrapOptions: Sendable {
    var enabled = false
    var user: String?
    var password: String?
    var fullName: String?
    var authorizerUser: String?
    var authorizerPassword: String?
    var keychainPath: String?
}

struct SIPCredentialResolution: @unchecked Sendable {
    let user: String
    let password: String
    let source: String
    let keychainService: String
    let keychainAccount: String
    let bootstrapPayload: [String: Any]?
}

struct StartupDiskCredential: Sendable {
    let user: String
    let password: String
    let source: String
}

struct GuestKCPasswordCredential: @unchecked Sendable {
    let user: String
    let password: String
    let payload: [String: Any]
}

/// The error that a Recovery or SIP and AMFI failure replaced, kept so that a
/// report shows the underlying reason. Two failures of the same kind compare
/// equal whatever their causes, so callers and tests match failures by kind.
struct PommeRetainedCause: Equatable, Sendable {
    let report: PommeErrorReport?

    init() { report = nil }

    /// Keeps the full description of `error`, redacted for secrets. An
    /// operating-system error keeps its domain and number.
    init(_ error: any Error) { report = PommeErrorReport(keepingSystemCause: error) }

    /// Keeps only codes and domains, for an error whose text might contain
    /// credentials or guest command output.
    init(codesOnly error: any Error) { report = PommeErrorReport(keepingSystemCause: error, codesOnly: true) }

    static func == (_: Self, _: Self) -> Bool { true }

    var underlying: (any Error)? { report }

    /// Ends `message` with the cause, such as "Pomme couldn't save the file
    /// because the disk is out of space (NSPOSIXErrorDomain 28)."
    func describing(_ message: String) -> String {
        guard let report else { return message }
        let base = message.hasSuffix(".") ? String(message.dropLast()) : message
        return "\(base) because \(PommeErrorDescriber.clause(for: report))."
    }

    /// Adds the cause to the first sentence of a longer message.
    func describing(_ first: String, then rest: String) -> String {
        "\(describing(first)) \(rest)"
    }
}
