import Foundation

enum MainAction {
    case vm(TUIVMEntry)
    case delete(TUIVMEntry)
    case create
    case refresh
    case quit
}

enum StartMode: Equatable {
    case none
    case normal
    case recovery
}

enum TUIMenuRole: Equatable {
    case normal
    case warning
    case destructive
}

enum TUIVMAction: CaseIterable {
    case startNormal
    case bootRecovery
    case stop
    case pause
    case resume
    case status
    case inspect
    case health
    case security
    case snapshots
    case destroy
    case back

    var menuItem: TUIMenuItem {
        switch self {
        case .startNormal:
            return TUIMenuItem(title: "Start Normal", detail: "Start or resume normal macOS.", shortcut: "n")
        case .bootRecovery:
            return TUIMenuItem(title: "Boot Recovery", detail: "Start macOS Recovery.", shortcut: "b")
        case .stop:
            return TUIMenuItem(title: "Stop", detail: "Stop the VM helper/guest.", shortcut: "x")
        case .pause:
            return TUIMenuItem(title: "Pause", detail: "Pause the running VM in place.", shortcut: "p")
        case .resume:
            return TUIMenuItem(title: "Resume", detail: "Resume the paused VM in place.", shortcut: "r")
        case .status:
            return TUIMenuItem(title: "Status", detail: "Show VM status.", shortcut: "s")
        case .inspect:
            return TUIMenuItem(title: "Inspect", detail: "Show detailed VM inspection output.", shortcut: "i")
        case .health:
            return TUIMenuItem(title: "Health", detail: "Show VM health payload.", shortcut: "h")
        case .security:
            return TUIMenuItem(title: "Security", detail: "SIP and AMFI security controls.", shortcut: "g")
        case .snapshots:
            return TUIMenuItem(title: "Snapshots", detail: "Create, restore, or delete named VM snapshots.", shortcut: "v")
        case .destroy:
            return TUIMenuItem(title: "Destroy", detail: "Delete this named VM bundle after typed confirmation.", shortcut: "d", role: .destructive)
        case .back:
            return TUIMenuItem(title: "Back", detail: "Return to VM dashboard.")
        }
    }
}

struct TUIProgressState {
    let label: String
    let percent: Int
}

struct TUIMenuItem {
    let title: String
    let detail: String
    let shortcut: String?
    let role: TUIMenuRole

    init(title: String, detail: String = "", shortcut: String? = nil, role: TUIMenuRole = .normal) {
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.role = role
    }
}

enum TUIVMState: String, Sendable {
    case running, paused, stopped, unknown

    var badge: String {
        switch self {
        case .running: "[RUN]"
        case .paused: "[PAUSE]"
        case .stopped: "[STOP]"
        case .unknown: "[?]"
        }
    }
}

struct TUIVMEntry: Sendable {
    let name: String?
    let bundlePath: String
    let vmState: String
    let bootMode: String?
    let guestAgent: TUIGuestAgent

    var state: TUIVMState { TUIVMState(rawValue: vmState) ?? .unknown }
    var running: Bool { state == .running }
    var hasActiveSession: Bool { state == .running || state == .paused }

    var displayName: String {
        name ?? bundlePath
    }

    var bootModeLabel: String {
        guard let bootMode, !bootMode.isEmpty else {
            return "-"
        }
        return bootMode
    }

    init?(payload: [String: Any]) {
        guard let bundlePath = payload["bundlePath"] as? String else {
            return nil
        }
        self.name = payload["name"] as? String
        self.bundlePath = bundlePath
        self.vmState = payload["vmState"] as? String ?? "unknown"
        self.bootMode = payload["bootMode"] as? String
        self.guestAgent = TUIGuestAgent(payload: payload["guestAgent"] as? [String: Any] ?? [:])
    }
}

enum TUIGuestAgentConnection: String, Equatable, Sendable {
    case connected
    case disconnected
    case unknown
}

enum TUIGuestAgentRole: String, Equatable, Sendable {
    case normal
    case recovery
    case unknown
}

struct TUIGuestAgent: Equatable, Sendable {
    let connection: TUIGuestAgentConnection
    let role: TUIGuestAgentRole
    let protocolVersion: String
    let digest: String
    let capabilities: [String]
    let updateState: String

    init(payload: [String: Any]) {
        self.connection = Self.connection(payload["connection"])
        self.role = Self.role(payload["role"])
        self.protocolVersion = Self.version(payload["protocolVersion"])
        self.digest = Self.text(payload["executableDigest"])
        self.capabilities = (payload["capabilities"] as? [String] ?? []).sorted()
        self.updateState = Self.text(payload["updateState"])
    }

    var summary: String {
        let capabilityText = capabilities.isEmpty ? "-" : capabilities.joined(separator: ",")
        return "connection=\(connection.rawValue) role=\(role.rawValue) protocol=\(display(protocolVersion)) digest=\(display(digest)) capabilities=\(capabilityText) update=\(display(updateState))"
    }

    private static func connection(_ value: Any?) -> TUIGuestAgentConnection {
        if let text = value as? String, let connection = TUIGuestAgentConnection(rawValue: text) {
            return connection
        }
        if let connected = value as? Bool { return connected ? .connected : .disconnected }
        return .unknown
    }

    private static func role(_ value: Any?) -> TUIGuestAgentRole {
        guard let text = value as? String else { return .unknown }
        return TUIGuestAgentRole(rawValue: text) ?? .unknown
    }

    private static func text(_ value: Any?) -> String {
        guard let text = value as? String, !text.isEmpty else { return "-" }
        return text
    }

    private static func version(_ value: Any?) -> String {
        guard let value, case .integer(let version) = try? JSONValue(any: value), version > 0 else { return "-" }
        return String(version)
    }

    private func display(_ value: String) -> String {
        value.isEmpty ? "-" : value
    }
}

enum TUIKey {
    case up
    case down
    case enter
    case escape
    case backspace
    case character(Character)
}
