import Foundation

/// The host's reading of the guest agent's `keystore.init.status` receipt.
///
/// `state` is one of `prepared`, `failed`, `skipped`, `pending`,
/// `agentUpdateRequired`, or `unavailable`.
struct PommeKeystoreInitReport: Equatable, Sendable {
    let state: String
    let reason: String?

    init(state: String, reason: String?) {
        self.state = state
        self.reason = reason
    }

    init(_ value: JSONValue) {
        guard let object = value.objectValue else { self.init(state: "unavailable", reason: nil); return }
        if object == ["initializing": .bool(true)] { self.init(state: "pending", reason: nil); return }
        guard let data = try? JSONEncoder().encode(value),
              let status = try? JSONDecoder().decode(PommeKeystoreInitStatus.self, from: data),
              PommeKeystoreInitStatus.outcomes.contains(status.outcome) else {
            self.init(state: "unavailable", reason: nil)
            return
        }
        let reason = status.reason.flatMap { Self.isSafeReason($0) ? $0 : nil }
        switch status.outcome {
        case "succeeded": self.init(state: "prepared", reason: nil)
        case "running": self.init(state: "pending", reason: nil)
        default: self.init(state: status.outcome, reason: reason)
        }
    }

    /// A phrase that completes "the keystore initializer …".
    var summary: String {
        switch state {
        case "prepared": return "ran in this boot"
        case "pending": return "hasn't finished in this boot"
        case "agentUpdateRequired": return "needs a newer Pomme agent; run `pomme agent update NAME`"
        case "skipped" where reason == "launch-constraints-enforced":
            return "was skipped because SIP is enabled"
        case "skipped": return "was skipped (\(reason ?? "unknown reason"))"
        case "failed": return "failed (\(reason ?? "unknown reason"))"
        default: return "status couldn't be read"
        }
    }

    private static func isSafeReason(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}

/// Holds the report read while the guest is still running normal macOS,
/// before `pomme mdm` returns the VM to its original run state.
actor PommeKeystoreInitReportBox {
    private(set) var report: PommeKeystoreInitReport?
    func record(_ report: PommeKeystoreInitReport) { self.report = report }
}
