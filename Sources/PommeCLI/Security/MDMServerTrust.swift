import Foundation
import Security

/// Endpoints and certificate payloads from an enrollment profile.
///
/// This is parsed from the same bytes as the journaled
/// `MDMEnrollmentProfileIdentity`, whose digest already covers these
/// payloads; the value itself is never journaled or returned in output.
struct MDMProfileTrustMaterial: Equatable, Sendable {
    static let certificatePayloadTypes: Set<String> = [
        "com.apple.security.root", "com.apple.security.pkcs1", "com.apple.security.pem",
    ]
    static let maximumCertificates = 16
    static let maximumCertificateBytes = 64 * 1024

    let serverURL: URL
    let checkInURL: URL?
    /// DER certificates in profile order.
    let certificates: [Data]

    /// Each distinct scheme, host, and port the enrollment contacts.
    var endpoints: [URL] {
        var seen = Set<String>()
        return [serverURL, checkInURL].compactMap { $0 }.filter { url in
            seen.insert(MDMServerEndpoint(url).key).inserted
        }
    }

    /// Decodes DER, or one or more PEM certificate blocks. Returns nil for
    /// anything that is not entirely certificates within the size bounds.
    static func certificates(fromPayloadContent content: Data) -> [Data]? {
        guard !content.isEmpty, content.count <= maximumCertificates * maximumCertificateBytes * 2 else {
            return nil
        }
        let blocks: [Data]
        if let text = String(data: content, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            guard let decoded = pemBlocks(text) else { return nil }
            blocks = decoded
        } else {
            blocks = [content]
        }
        guard !blocks.isEmpty, blocks.count <= maximumCertificates,
              blocks.allSatisfy({ $0.count <= maximumCertificateBytes
                  && SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
            return nil
        }
        return blocks
    }

    private static func pemBlocks(_ text: String) -> [Data]? {
        var blocks: [Data] = []
        var body: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch line {
            case "-----BEGIN CERTIFICATE-----":
                guard body == nil else { return nil }
                body = ""
            case "-----END CERTIFICATE-----":
                guard let encoded = body, let der = Data(base64Encoded: encoded) else { return nil }
                blocks.append(der)
                body = nil
            default:
                if body != nil { body! += line }
            }
        }
        return body == nil ? blocks : nil
    }
}

struct MDMServerEndpoint: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(_ url: URL) {
        scheme = url.scheme?.lowercased() ?? ""
        host = url.host?.lowercased() ?? ""
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    var key: String { "\(scheme)://\(host):\(port)" }
}

/// How the MDM server's TLS identity can be trusted.
enum MDMServerTrustDecision: String, Codable, Sendable {
    /// Default trust validates the server; no profile certificate is needed.
    case publicTrust
    /// Only the profile's own certificates validate the server.
    case profileRootTrust
    /// A handshake completed, but nothing available validates it.
    case untrusted
    /// No TLS handshake completed.
    case unreachable
    /// Plain HTTP carries no server trust decision.
    case notApplicable
}

struct MDMServerTrustEndpointReport: Equatable, Sendable {
    let endpoint: MDMServerEndpoint
    let decision: MDMServerTrustDecision

    var publicValue: [String: Any] {
        ["host": endpoint.host, "port": endpoint.port, "result": decision.rawValue]
    }
}

struct MDMServerTrustReport: Equatable, Sendable {
    let endpoints: [MDMServerTrustEndpointReport]

    /// The most restrictive endpoint decision: any untrusted endpoint blocks,
    /// then any unreachable one, then any that needs profile certificates.
    var decision: MDMServerTrustDecision {
        let decisions = Set(endpoints.map(\.decision))
        for candidate in [MDMServerTrustDecision.untrusted, .unreachable, .profileRootTrust, .publicTrust]
            where decisions.contains(candidate) {
            return candidate
        }
        return .notApplicable
    }

    var publicValue: [String: Any] {
        ["result": decision.rawValue, "endpoints": endpoints.map(\.publicValue)]
    }
}

/// What a TLS handshake presented, or that none completed.
enum MDMServerTrustObservation: Equatable, Sendable {
    case presented([Data])
    case unreachable
}

enum MDMServerTrustEvaluator {
    enum DefaultAnchors: Sendable {
        /// Apple's built-in roots only. The host uses this so its own
        /// user or admin trust settings cannot stand in for the guest's.
        case systemRoots
        /// The evaluating system's complete trust, including roots an
        /// administrator or an installed profile already trusts.
        case platformDefault
    }

    static func evaluate(
        _ observation: MDMServerTrustObservation, host: String, profileCertificates: [Data],
        defaultAnchors: DefaultAnchors, verifyDate: Date? = nil
    ) -> MDMServerTrustDecision {
        guard case .presented(let chainData) = observation else { return .unreachable }
        let chain = chainData.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !chain.isEmpty, chain.count == chainData.count else { return .untrusted }
        let anchors: [SecCertificate]?
        switch defaultAnchors {
        case .platformDefault:
            anchors = nil
        case .systemRoots:
            var system: CFArray?
            guard SecTrustCopyAnchorCertificates(&system) == errSecSuccess,
                  let roots = system as? [SecCertificate] else { return .untrusted }
            anchors = roots
        }
        if validates(chain, host: host, anchors: anchors, verifyDate: verifyDate) { return .publicTrust }
        let profile = profileCertificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        let roots = profile.filter(isSelfSigned)
        guard !roots.isEmpty else { return .untrusted }
        let intermediates = profile.filter { !isSelfSigned($0) }
        return validates(chain + intermediates, host: host, anchors: roots, verifyDate: verifyDate)
            ? .profileRootTrust : .untrusted
    }

    static func isSelfSigned(_ certificate: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data? else { return false }
        return subject == issuer
    }

    private static func validates(
        _ certificates: [SecCertificate], host: String, anchors: [SecCertificate]?, verifyDate: Date?
    ) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString),
                                             &trust) == errSecSuccess, let trust else { return false }
        if let anchors {
            guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        }
        if let verifyDate, SecTrustSetVerifyDate(trust, verifyDate as CFDate) != errSecSuccess { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

enum MDMServerTrustProbe {
    static let defaultTimeout: TimeInterval = 15

    /// Completes a TLS handshake and records the presented chain. The
    /// server-trust challenge is cancelled, so no HTTP request is sent.
    static func live(_ url: URL, timeout: TimeInterval) async -> MDMServerTrustObservation {
        guard url.scheme?.lowercased() == "https" else { return .unreachable }
        let delegate = TrustCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        guard let chain = delegate.chain, !chain.isEmpty else { return .unreachable }
        return .presented(chain)
    }

    private final class TrustCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [Data]?

        var chain: [Data]? { lock.withLock { captured } }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                lock.withLock { captured = certificates.map { SecCertificateCopyData($0) as Data } }
            }
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}

enum MDMServerTrustPreflight {
    typealias Probe = @Sendable (URL, TimeInterval) async -> MDMServerTrustObservation

    static func run(
        _ material: MDMProfileTrustMaterial, defaultAnchors: MDMServerTrustEvaluator.DefaultAnchors,
        timeout: TimeInterval = MDMServerTrustProbe.defaultTimeout,
        probe: Probe = { await MDMServerTrustProbe.live($0, timeout: $1) }, verifyDate: Date? = nil
    ) async -> MDMServerTrustReport {
        var reports: [MDMServerTrustEndpointReport] = []
        for url in material.endpoints {
            let endpoint = MDMServerEndpoint(url)
            guard endpoint.scheme == "https" else {
                reports.append(.init(endpoint: endpoint, decision: .notApplicable))
                continue
            }
            let decision = MDMServerTrustEvaluator.evaluate(
                await probe(url, timeout), host: endpoint.host, profileCertificates: material.certificates,
                defaultAnchors: defaultAnchors, verifyDate: verifyDate)
            reports.append(.init(endpoint: endpoint, decision: decision))
        }
        return .init(endpoints: reports)
    }
}
