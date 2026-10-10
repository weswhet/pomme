import Foundation

/// A stable, kebab-case identifier for a kind of failure, such as
/// `vm-not-found`. Codes appear in error text, in JSON output, in bug
/// reports, and as anchors on the Errors reference page, so a published code
/// never changes meaning.
struct PommeErrorCode: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    /// Whether the value has the published shape: lowercase ASCII words
    /// joined by single hyphens.
    var isWellFormed: Bool {
        let words = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        return !words.isEmpty && words.allSatisfy { word in
            !word.isEmpty && word.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }
}

/// An error that names its stable code, says what happened in
/// `errorDescription`, and says what to do next in `recoverySuggestion`.
/// `underlying` keeps the cause that a wrapping error replaced, so reports
/// can show the operating-system or framework reason.
protocol PommeDescribedError: LocalizedError {
    var code: PommeErrorCode { get }
    var underlying: (any Error)? { get }
}

extension PommeDescribedError {
    var underlying: (any Error)? { nil }
}

/// The redacted, serializable form of an error: its code, message, next
/// step, and the chain of causes underneath it. The helper sends it to the
/// CLI, JSON output prints its fields, and `pomme bug-report` includes the
/// last one.
struct PommeErrorReport: Codable, Equatable, Sendable, Error {
    struct Cause: Codable, Equatable, Sendable {
        /// `pomme` for a Pomme error, or the framework's error domain, such
        /// as `VZErrorDomain` or `NSPOSIXErrorDomain`.
        let domain: String
        /// The Pomme error code, or the domain's numeric code as text.
        let code: String
        let description: String
    }

    let code: PommeErrorCode
    let message: String
    let hint: String?
    let causes: [Cause]

    init(code: PommeErrorCode, message: String, hint: String? = nil, causes: [Cause] = []) {
        self.code = code
        self.message = message
        self.hint = hint
        self.causes = causes
    }

    /// Describes `error` and the errors underneath it. With `.secrets`, every
    /// text field passes through `PommeErrorRedaction`, as it must before the
    /// report crosses a process boundary or is written to disk.
    init(_ error: any Error, redaction: PommeErrorRedaction.Mode = .secrets) {
        if let report = error as? PommeErrorReport {
            self = redaction == .none ? report : report.redacted()
            return
        }
        let top = PommeErrorDescriber.describe(error)
        var causes: [Cause] = []
        // A framework error keeps its own domain and number as the first
        // cause, so wrapping messages can still name them.
        if !(error is any PommeDescribedError), top.domain != "pomme", SystemErrorDescription(error) != nil {
            causes.append(.init(domain: top.domain, code: top.domainCode, description: top.message))
        }
        var next = PommeErrorDescriber.underlying(of: error)
        while let current = next, causes.count < 8 {
            if let external = current as? PommeExternalCause {
                causes.append(.init(domain: external.domain, code: external.code, description: external.description))
                break
            }
            if let report = current as? PommeErrorReport {
                causes.append(.init(domain: "pomme", code: report.code.rawValue, description: report.message))
                causes.append(contentsOf: report.causes)
                break
            }
            let described = PommeErrorDescriber.describe(current)
            causes.append(.init(domain: described.domain, code: described.domainCode, description: described.message))
            next = PommeErrorDescriber.underlying(of: current)
        }
        self.init(code: top.code, message: top.message, hint: top.hint, causes: Array(causes.prefix(8)))
        if redaction == .secrets { self = redacted() }
    }

    /// A report that keeps only codes, domains, and numbers, for an error
    /// whose text might contain credentials or command output. Each message
    /// is the catalog's title for its code.
    init(codesOnly error: any Error) {
        let full = PommeErrorReport(error, redaction: .none)
        func title(_ code: String) -> String {
            PommeErrorCatalog.entry(for: PommeErrorCode(code))?.title ?? "An error occurred."
        }
        self.init(
            code: full.code,
            message: title(full.code.rawValue),
            hint: PommeErrorCatalog.entry(for: full.code)?.hint,
            causes: full.causes.map { cause in
                // Only Pomme's own domains and the system domains that the
                // translators know are kept; any other domain is caller
                // supplied text.
                let domain = cause.domain == "pomme" || SystemErrorDescription.knownDomains.contains(cause.domain)
                    || cause.domain.hasPrefix("PommeCLI.") || cause.domain == "PommeAgentProtocol"
                    ? cause.domain : "external"
                return .init(
                    domain: domain,
                    code: domain == "external" ? "unknown" : cause.code,
                    description: cause.domain == "pomme"
                        ? title(cause.code)
                        : (domain == "external" ? "An error from another component." : "\(domain) error \(cause.code).")
                )
            }
        )
        self = redacted()
    }

    func redacted() -> PommeErrorReport {
        .init(
            code: code.isWellFormed ? code : .internalError,
            message: PommeErrorRedaction.redact(message),
            hint: hint.map(PommeErrorRedaction.redact),
            causes: causes.prefix(8).map {
                .init(
                    domain: String($0.domain.prefix(128)),
                    code: String($0.code.prefix(64)),
                    description: PommeErrorRedaction.redact($0.description)
                )
            }
        )
    }

    /// The public JSON fields that every failed result carries.
    var publicFields: [String: Any] {
        let causeObjects: [[String: Any]] = causes.map { cause in
            ["domain": cause.domain, "code": cause.code, "description": cause.description]
        }
        var fields: [String: Any] = ["errorCode": code.rawValue, "causes": causeObjects]
        fields["hint"] = hint.map { $0 as Any } ?? NSNull()
        return fields
    }

    /// The private payload key a helper uses to carry the report next to
    /// the human-readable `error` string.
    static let payloadKey = "errorReport"

    var jsonValue: JSONValue {
        let causeValues: [JSONValue] = causes.map { cause in
            JSONValue.object([
                "domain": .string(cause.domain),
                "code": .string(cause.code),
                "description": .string(cause.description)
            ])
        }
        var object: [String: JSONValue] = [:]
        object["code"] = .string(code.rawValue)
        object["message"] = .string(message)
        object["hint"] = hint.map { JSONValue.string($0) } ?? JSONValue.null
        object["causes"] = .array(causeValues)
        return .object(object)
    }

    var payloadObject: [String: Any] { jsonValue.publicValue as? [String: Any] ?? [:] }

    /// Reads a report from a helper payload, accepting only well-formed
    /// fields. A payload from an older helper has none.
    init?(payload value: Any?) {
        guard let object = value as? [String: Any],
              let rawCode = object["code"] as? String,
              let message = object["message"] as? String
        else { return nil }
        let code = PommeErrorCode(rawCode)
        guard code.isWellFormed else { return nil }
        let causes = (object["causes"] as? [[String: Any]] ?? []).compactMap { cause -> Cause? in
            guard let domain = cause["domain"] as? String,
                  let code = cause["code"] as? String,
                  let description = cause["description"] as? String
            else { return nil }
            return Cause(domain: domain, code: code, description: description)
        }
        self = PommeErrorReport(code: code, message: message, hint: object["hint"] as? String, causes: causes).redacted()
    }
}

extension PommeErrorReport: PommeDescribedError {
    var errorDescription: String? { message }
    var recoverySuggestion: String? { hint }
}

/// A cause expressed in another component's vocabulary, such as a guest
/// agent's wire code, kept so a report shows the original code.
struct PommeExternalCause: LocalizedError, Equatable, Sendable {
    let domain: String
    let code: String
    let description: String

    var errorDescription: String? { description }
}

/// An error that the VM helper reported over the control socket. It keeps the
/// helper's code and causes so the CLI prints the same text and JSON it would
/// for a local error.
struct RemotePommeError: PommeDescribedError, Equatable, Sendable {
    let report: PommeErrorReport

    init(_ report: PommeErrorReport) { self.report = report }

    var code: PommeErrorCode { report.code }
    var errorDescription: String? { report.message }
    var recoverySuggestion: String? { report.hint }
    var underlying: (any Error)? { nil }
}

/// The one redaction rule for error text that leaves the process that
/// produced it: text that mentions a token, password, or secret is withheld,
/// and the rest is capped at 512 characters.
enum PommeErrorRedaction {
    enum Mode: Sendable { case none, secrets }

    static let maximumCharacters = 512
    static let withheldMessage = "Pomme withheld this message because it might contain a secret."

    static func redact(_ text: String) -> String {
        if mentionsSecret(text) { return withheldMessage }
        return String(text.prefix(maximumCharacters))
    }

    static func mentionsSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("token") || lowered.contains("password") || lowered.contains("secret")
    }

    /// Replaces the user's home directory with `~`, for files a person may
    /// share, such as a bug report.
    static func abbreviatingHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

/// Turns any error into a code, message, and hint, and finds the error
/// underneath it.
enum PommeErrorDescriber {
    struct Description {
        let code: PommeErrorCode
        let message: String
        let hint: String?
        let domain: String
        let domainCode: String
    }

    static func describe(_ error: any Error) -> Description {
        if let described = error as? any PommeDescribedError {
            let code = described.code
            return .init(
                code: code,
                message: described.errorDescription ?? PommeErrorCatalog.entry(for: code)?.title ?? code.rawValue,
                hint: described.recoverySuggestion ?? PommeErrorCatalog.entry(for: code)?.hint,
                domain: "pomme",
                domainCode: code.rawValue
            )
        }
        if let system = SystemErrorDescription(error) {
            return .init(
                code: system.pommeCode,
                message: system.message,
                hint: system.hint ?? PommeErrorCatalog.entry(for: system.pommeCode)?.hint,
                domain: system.domain,
                domainCode: system.code
            )
        }
        let typeName = String(reflecting: type(of: error))
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return .init(
                code: .internalError,
                message: message,
                hint: localized.recoverySuggestion,
                domain: typeName,
                domainCode: PommeErrorCode.internalError.rawValue
            )
        }
        return .init(
            code: .internalError,
            message: "An unexpected \(typeName) error occurred.",
            hint: PommeErrorCatalog.entry(for: .internalError)?.hint,
            domain: typeName,
            domainCode: PommeErrorCode.internalError.rawValue
        )
    }

    static func underlying(of error: any Error) -> (any Error)? {
        if let described = error as? any PommeDescribedError {
            return described.underlying
        }
        guard type(of: error) is NSError.Type || SystemErrorDescription.isBridgedSystemError(error) else { return nil }
        return (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }
}
