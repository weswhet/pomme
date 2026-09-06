import Foundation
import Darwin

/// Shared by the main-actor TUI renderer and its child operation task. Every mutable
/// field is protected by `lock`; the unchecked conformance documents that boundary.
private final class TUIActionProgress: @unchecked Sendable {
    struct Snapshot {
        let lines: [String]
        let progress: TUIProgressState?
        let result: PommeOperationResult?
        let errorMessage: String?
        let isFinished: Bool
    }

    private let lock = NSLock()
    private var lines: [String] = []
    private var progress: TUIProgressState?
    private var completion: Result<PommeOperationResult, Error>?
    init() {}

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if let parsedProgress = Self.parseProgress(from: line) {
            progress = parsedProgress
        }
        lock.unlock()
    }

    func finish(_ result: Result<PommeOperationResult, Error>) {
        lock.lock()
        completion = result
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let lines = self.lines
        let progress = self.progress
        let completion = self.completion
        lock.unlock()

        switch completion {
        case .success(let result):
            return Snapshot(lines: lines, progress: progress, result: result, errorMessage: nil, isFinished: true)
        case .failure(let error):
            return Snapshot(lines: lines, progress: progress, result: nil, errorMessage: error.localizedDescription, isFinished: true)
        case nil:
            return Snapshot(lines: lines, progress: progress, result: nil, errorMessage: nil, isFinished: false)
        }
    }

    private static func parseProgress(from line: String) -> TUIProgressState? {
        if let percent = parsePercent(from: line, prefix: "Install progress:") {
            return TUIProgressState(label: "Installing macOS", percent: percent)
        }
        if let percent = parsePercent(from: line, prefix: "Download progress:") {
            return TUIProgressState(label: "Downloading restore image", percent: percent)
        }
        return nil
    }

    private static func parsePercent(from line: String, prefix: String) -> Int? {
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let remainder = line.dropFirst(prefix.count)
        guard let percentIndex = remainder.firstIndex(of: "%") else {
            return nil
        }
        let numberText = remainder[..<percentIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(numberText) else {
            return nil
        }
        return min(100, max(0, value))
    }
}

@MainActor
struct PommeTUI {
    typealias CreateAction = @MainActor @Sendable (
        _ name: String,
        _ restoreArgs: [String],
        _ diskSize: String,
        _ memory: String,
        _ startMode: StartMode
    ) async throws -> PommeOperationResult
    typealias VMListAction = @MainActor @Sendable () throws -> [TUIVMEntry]
    typealias SnapshotListAction = @MainActor @Sendable (_ name: String) throws -> [VMSnapshotRecord]
    typealias SnapshotMutationAction = @MainActor @Sendable (_ name: String, _ snapshot: String) throws -> PommeOperationResult
    typealias SnapshotRestoreAction = @MainActor @Sendable (
        _ name: String,
        _ snapshot: String,
        _ allowDrift: Bool
    ) throws -> PommeOperationResult

    static var isInteractiveTerminal: Bool {
        TUITerminal.isInteractiveTerminal
    }

    private let initialVMName: String?
    private let terminal: TUITerminal
    private let renderer: TUIRenderer
    private let createAction: CreateAction
    private let vmListAction: VMListAction
    private let snapshotListAction: SnapshotListAction
    private let snapshotCreateAction: SnapshotMutationAction
    private let snapshotRestoreAction: SnapshotRestoreAction
    private let snapshotDeleteAction: SnapshotMutationAction
    private var statusMessage: String?

    init(initialVMName: String?) {
        self.init(
            initialVMName: initialVMName,
            terminal: TUITerminal(),
            createAction: { name, restoreArgs, diskSize, memory, startMode in
                try await PommeApplication.create(
                    name: name,
                    restoreArgs: restoreArgs,
                    diskSize: diskSize,
                    memory: memory,
                    startMode: startMode
                )
            },
            vmListAction: {
                let object = try PommeApplication.listVMsPayload()
                guard let vms = object["vms"] as? [[String: Any]] else {
                    throw RunnerError.hostCommandFailed("Could not parse VM list output.")
                }
                return vms.compactMap(TUIVMEntry.init(payload:))
            },
            snapshotListAction: { try PommeApplication.snapshotsList(name: $0) },
            snapshotCreateAction: { name, snapshot in
                try PommeApplication.snapshotCreate(name: name, snapshot: snapshot)
            },
            snapshotRestoreAction: { name, snapshot, allowDrift in
                try PommeApplication.snapshotRestore(name: name, snapshot: snapshot, allowDrift: allowDrift)
            },
            snapshotDeleteAction: { name, snapshot in
                try PommeApplication.snapshotDelete(name: name, snapshot: snapshot)
            }
        )
    }

    init(
        initialVMName: String?,
        terminal: TUITerminal,
        createAction: @escaping CreateAction,
        vmListAction: @escaping VMListAction = {
            let object = try PommeApplication.listVMsPayload()
            guard let vms = object["vms"] as? [[String: Any]] else {
                throw RunnerError.hostCommandFailed("Could not parse VM list output.")
            }
            return vms.compactMap(TUIVMEntry.init(payload:))
        },
        snapshotListAction: @escaping SnapshotListAction = { try PommeApplication.snapshotsList(name: $0) },
        snapshotCreateAction: @escaping SnapshotMutationAction = { name, snapshot in
            try PommeApplication.snapshotCreate(name: name, snapshot: snapshot)
        },
        snapshotRestoreAction: @escaping SnapshotRestoreAction = { name, snapshot, allowDrift in
            try PommeApplication.snapshotRestore(name: name, snapshot: snapshot, allowDrift: allowDrift)
        },
        snapshotDeleteAction: @escaping SnapshotMutationAction = { name, snapshot in
            try PommeApplication.snapshotDelete(name: name, snapshot: snapshot)
        }
    ) {
        self.initialVMName = initialVMName
        self.terminal = terminal
        self.renderer = TUIRenderer(useColor: terminal.useColor)
        self.createAction = createAction
        self.vmListAction = vmListAction
        self.snapshotListAction = snapshotListAction
        self.snapshotCreateAction = snapshotCreateAction
        self.snapshotRestoreAction = snapshotRestoreAction
        self.snapshotDeleteAction = snapshotDeleteAction
    }

    mutating func run() async throws {
        try terminal.enableRawMode()
        terminal.enterAlternateScreen()
        terminal.hideCursor()
        defer {
            terminal.showCursor()
            terminal.leaveAlternateScreen()
            terminal.restore()
        }

        var preferredName = initialVMName
        while true {
            let entries = loadVMs()
            let action = try chooseMainAction(entries: entries, preferredName: preferredName)
            switch action {
            case .vm(let entry):
                preferredName = entry.name
                try await showVMMenu(entry)
            case .delete(let entry):
                if let name = entry.name {
                    preferredName = nil
                    try await confirmAndDestroy(name: name, bundlePath: entry.bundlePath)
                } else {
                    statusMessage = "Only managed VMs can be deleted."
                }
            case .create:
                try await showCreateForm()
            case .refresh:
                statusMessage = "Refreshed VM list."
            case .quit:
                return
            }
        }
    }

    private mutating func chooseMainAction(entries: [TUIVMEntry], preferredName: String?) throws -> MainAction {
        var selected = preferredName.flatMap { name in
            entries.firstIndex { $0.name == name }
        } ?? 0
        if entries.isEmpty {
            selected = 0
        } else {
            selected = min(max(selected, 0), entries.count - 1)
        }

        while true {
            renderDashboard(entries: entries, selectedIndex: entries.isEmpty ? nil : selected)
            switch try terminal.readKey() {
            case .up:
                guard !entries.isEmpty else {
                    continue
                }
                selected = selected == 0 ? entries.count - 1 : selected - 1
            case .down:
                guard !entries.isEmpty else {
                    continue
                }
                selected = selected == entries.count - 1 ? 0 : selected + 1
            case .enter:
                guard !entries.isEmpty else {
                    statusMessage = "No VM selected. Press c to create one."
                    continue
                }
                return .vm(entries[selected])
            case .escape:
                return .quit
            case .character(let character):
                switch String(character).lowercased() {
                case "q":
                    return .quit
                case "j":
                    guard !entries.isEmpty else {
                        continue
                    }
                    selected = selected == entries.count - 1 ? 0 : selected + 1
                case "k":
                    guard !entries.isEmpty else {
                        continue
                    }
                    selected = selected == 0 ? entries.count - 1 : selected - 1
                case "r":
                    return .refresh
                case "c":
                    return .create
                case "d":
                    guard !entries.isEmpty else {
                        statusMessage = "No VM selected."
                        continue
                    }
                    return .delete(entries[selected])
                default:
                    continue
                }
            case .backspace:
                continue
            }
        }
    }

    private mutating func showVMMenu(_ entry: TUIVMEntry) async throws {
        guard let name = entry.name else {
            statusMessage = "Only managed VMs appear in the TUI."
            return
        }

        var currentEntry = entry
        while true {
            let actions = TUIVMAction.allCases
            let choice = try choose(
                title: name,
                subtitle: renderer.vmSummary(currentEntry),
                items: actions.map(\.menuItem),
                initialIndex: 0,
                emptyMessage: nil
            )
            guard let choice, actions.indices.contains(choice) else {
                return
            }

            switch actions[choice] {
            case .startNormal:
                guard try confirmBootTransitionIfNeeded(entry: currentEntry, targetMode: .normal) else {
                    continue
                }
                try await runTUIAction(title: "Start Normal", vmName: name) {
                    try PommeApplication.boot(name: name, mode: .normal)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .bootRecovery:
                guard try confirmBootTransitionIfNeeded(entry: currentEntry, targetMode: .recovery) else {
                    continue
                }
                try await runTUIAction(title: "Boot Recovery", vmName: name) {
                    try PommeApplication.boot(name: name, mode: .recovery)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .stop:
                try await runTUIAction(title: "Stop", vmName: name) {
                    try PommeApplication.stop(name: name)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .pause:
                try await runTUIAction(title: "Pause", vmName: name) {
                    try PommeApplication.pause(name: name)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .resume:
                try await runTUIAction(title: "Resume", vmName: name) {
                    try PommeApplication.resume(name: name)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .status:
                try await runTUIAction(title: "Status", vmName: name) {
                    try PommeApplication.status(name: name)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .inspect:
                try await runTUIAction(title: "Inspect", vmName: name) {
                    try PommeApplication.inspect(name: name)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .health:
                try await runTUIAction(title: "Health", vmName: name) {
                    try PommeApplication.health(name: name)
                }
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .security:
                try await showSecurityMenu(name: name)
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .snapshots:
                try await showSnapshotsMenu(name: name)
                currentEntry = refreshVMEntry(named: name) ?? currentEntry
            case .destroy:
                try await confirmAndDestroy(name: name, bundlePath: currentEntry.bundlePath)
                return
            case .back:
                return
            }
        }
    }

    private mutating func showSecurityMenu(name: String) async throws {
        while true {
            let items = [
                TUIMenuItem(title: "SIP Status", detail: "Boot Recovery and print csrutil status.", shortcut: "s"),
                TUIMenuItem(title: "Disable SIP", detail: "Use keychain-backed SIP bootstrap credentials.", shortcut: "d", role: .destructive),
                TUIMenuItem(title: "Enable SIP", detail: "Use keychain-backed SIP bootstrap credentials.", shortcut: "e"),
                TUIMenuItem(title: "AMFI Status", detail: "Check AMFI boot-arg policy state.", shortcut: "a"),
                TUIMenuItem(title: "Disable AMFI", detail: "Relax boot-arg policy and set amfi_get_out_of_my_way=0x1.", shortcut: "x", role: .destructive),
                TUIMenuItem(title: "Enable AMFI", detail: "Restore the saved AMFI policy and boot arguments.", shortcut: "m"),
                TUIMenuItem(title: "Back", detail: "Return to VM actions.")
            ]
            let choice = try choose(
                title: "\(name) security",
                subtitle: "Recovery and lab options",
                items: items,
                initialIndex: 0,
                emptyMessage: nil
            )
            guard let choice else {
                return
            }

            switch choice {
            case 0:
                try await runTUIAction(title: "SIP Status", vmName: name) {
                    try await PommeApplication.sip(name: name, action: .status, bootstrap: false)
                }
            case 1:
                try await runTUIAction(title: "Disable SIP", vmName: name) {
                    try await PommeApplication.sip(name: name, action: .disable, bootstrap: true)
                }
            case 2:
                try await runTUIAction(title: "Enable SIP", vmName: name) {
                    try await PommeApplication.sip(name: name, action: .enable, bootstrap: true)
                }
            case 3:
                try await runTUIAction(title: "AMFI Status", vmName: name) {
                    try await PommeApplication.amfi(name: name, action: .status, bootstrap: false)
                }
            case 4:
                try await runTUIAction(title: "Disable AMFI", vmName: name) {
                    try await PommeApplication.amfi(name: name, action: .disable, bootstrap: true)
                }
            case 5:
                try await runTUIAction(title: "Enable AMFI", vmName: name) {
                    try await PommeApplication.amfi(name: name, action: .enable, bootstrap: true)
                }
            default:
                return
            }
        }
    }

    private mutating func showSnapshotsMenu(name: String) async throws {
        while true {
            let snapshots = loadSnapshots(name: name)
            let snapshotItems = snapshots.map { snapshot in
                TUIMenuItem(
                    title: snapshot.name,
                    detail: snapshotSummary(snapshot),
                    role: snapshot.drift.isEmpty ? .normal : .warning
                )
            }
            let items = snapshotItems + [
                TUIMenuItem(title: "Create Snapshot", detail: "Capture VZ machine state only; Disk.img and AuxiliaryStorage are not copied or replaced.", shortcut: "c"),
                TUIMenuItem(title: "Refresh", detail: "Reload the named snapshot list.", shortcut: "r"),
                TUIMenuItem(title: "Back", detail: "Return to VM actions.")
            ]
            let warningMessage = snapshots.contains(where: { !$0.drift.isEmpty })
                ? "One or more snapshots report VM identity or backing-file drift. Review before restoring."
                : nil
            guard let choice = try choose(
                title: "\(name) snapshots",
                subtitle: snapshots.isEmpty ? "No named snapshots." : "\(snapshots.count) named snapshot(s), newest first.",
                warningMessage: warningMessage,
                items: items,
                initialIndex: 0,
                emptyMessage: nil
            ) else {
                return
            }

            if snapshots.indices.contains(choice) {
                try await showSnapshotDetail(name: name, snapshot: snapshots[choice])
                continue
            }
            switch choice - snapshots.count {
            case 0:
                try await showCreateSnapshotForm(name: name)
            case 1:
                statusMessage = "Refreshed snapshot list."
            default:
                return
            }
        }
    }

    private mutating func showSnapshotDetail(name: String, snapshot: VMSnapshotRecord) async throws {
        let warningMessage = snapshotWarning(snapshot)
        let items = [
            TUIMenuItem(
                title: "Restore Snapshot",
                detail: "Restore VZ machine state only; Disk.img and AuxiliaryStorage are not copied or replaced; VM ends paused.",
                shortcut: "r",
                role: .destructive
            ),
            TUIMenuItem(
                title: "Delete Snapshot",
                detail: "Permanently delete this named snapshot.",
                shortcut: "d",
                role: .destructive
            ),
            TUIMenuItem(title: "Back", detail: "Return to the snapshot list.")
        ]
        while true {
            guard let choice = try choose(
                title: "\(name) / \(snapshot.name)",
                subtitle: snapshotSummary(snapshot),
                warningMessage: warningMessage,
                items: items,
                initialIndex: 0,
                emptyMessage: nil
            ) else {
                return
            }

            switch choice {
            case 0:
                let restored = try await confirmAndRestoreSnapshot(name: name, snapshot: snapshot)
                if restored {
                    _ = loadSnapshots(name: name)
                    _ = refreshVMEntry(named: name)
                    statusMessage = "Snapshot \(snapshot.name) restored. VM is paused."
                    return
                }
            case 1:
                let deleted = try await confirmAndDeleteSnapshot(name: name, snapshot: snapshot)
                if deleted {
                    statusMessage = "Snapshot \(snapshot.name) deleted."
                    return
                }
            default:
                return
            }
        }
    }

    private mutating func showCreateSnapshotForm(name: String) async throws {
        guard let snapshot = try promptRequiredLine(
            title: "Create Snapshot",
            message: "Enter a named snapshot. The snapshot service validates its name and VM state.",
            prompt: "Snapshot name",
            defaultValue: ""
        ) else {
            return
        }
        let action = snapshotCreateAction
        let completed = try await runTUIAction(title: "Create Snapshot", vmName: name) {
            try action(name, snapshot)
        }
        if completed {
            statusMessage = "Snapshot \(snapshot) created."
        }
    }

    private mutating func confirmAndRestoreSnapshot(name: String, snapshot: VMSnapshotRecord) async throws -> Bool {
        var allowDrift = false
        if !snapshot.drift.isEmpty {
            let choice = try choose(
                title: "Snapshot drift",
                subtitle: "\(name) / \(snapshot.name)",
                warningMessage: snapshotWarning(snapshot),
                items: [
                    TUIMenuItem(
                        title: "Restore Despite Drift",
                        detail: "Restore despite recorded drift; backing-file changes may affect guest-visible files.",
                        shortcut: "y",
                        role: .destructive
                    ),
                    TUIMenuItem(title: "Cancel", detail: "Leave the VM and snapshot unchanged.", shortcut: "n")
                ],
                initialIndex: 1,
                emptyMessage: nil
            )
            guard choice == 0 else {
                statusMessage = "Snapshot restore cancelled."
                return false
            }
            allowDrift = true
        }
        let expected = "\(name)/\(snapshot.name)"
        guard try promptTypedConfirmation(
            title: "Restore \(snapshot.name)",
            message: "This restores VZ machine state only. Disk.img and AuxiliaryStorage are not copied or replaced. The restored VM will remain paused.\nType \(expected) to continue.",
            expected: expected
        ) else {
            return false
        }
        let action = snapshotRestoreAction
        let completed = try await runTUIAction(title: "Restore Snapshot", vmName: name) {
            try action(name, snapshot.name, allowDrift)
        }
        return completed
    }

    private mutating func confirmAndDeleteSnapshot(name: String, snapshot: VMSnapshotRecord) async throws -> Bool {
        let expected = "\(name)/\(snapshot.name)"
        guard try promptTypedConfirmation(
            title: "Delete \(snapshot.name)",
            message: "This permanently deletes the named snapshot.\nType \(expected) to continue.",
            expected: expected
        ) else {
            return false
        }
        let action = snapshotDeleteAction
        let completed = try await runTUIAction(title: "Delete Snapshot", vmName: name) {
            try action(name, snapshot.name)
        }
        return completed
    }

    private mutating func showCreateForm() async throws {
        guard let name = try promptVMName(title: "Create VM", defaultValue: initialVMName) else {
            return
        }
        guard let restoreArgs = try promptRestoreArgs(title: "Create VM") else {
            return
        }
        guard let diskSize = try promptSize(title: "Create VM", label: "Disk size", defaultValue: "60GB", flag: "--disk-size") else {
            return
        }
        guard let memory = try promptSize(title: "Create VM", label: "RAM", defaultValue: "8GB", flag: "--ram") else {
            return
        }
        let startMode = try chooseStartMode(title: "Create VM")

        let action = createAction
        try await runTUIAction(title: "Create VM", vmName: name) {
            try await action(name, restoreArgs, diskSize, memory, startMode)
        }
    }

    private mutating func confirmAndDestroy(name: String, bundlePath: String) async throws {
        guard try promptTypedConfirmation(
            title: "Destroy \(name)",
            message: "This permanently deletes the named VM bundle.\nBundle: \(bundlePath)\nType \(name) to continue.",
            expected: name
        ) else {
            statusMessage = "Destroy cancelled."
            return
        }
        try await runTUIAction(title: "Destroy \(name)", vmName: name) {
            try PommeApplication.destroy(name: name)
        }
    }

    private mutating func promptVMName(title: String, defaultValue: String?) throws -> String? {
        var errorMessage: String?
        while true {
            guard let name = try promptLine(
                title: title,
                message: "Use 1-64 ASCII letters, numbers, dots, underscores, or hyphens.",
                prompt: "VM name",
                defaultValue: defaultValue,
                errorMessage: errorMessage
            ) else {
                statusMessage = "\(title) cancelled."
                return nil
            }
            guard !name.isEmpty else {
                errorMessage = "VM name is required."
                continue
            }
            do {
                return try validateVMName(name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private mutating func promptRestoreArgs(title: String) throws -> [String]? {
        let items = [
            TUIMenuItem(title: "Latest IPSW", detail: "Use --version latest.", shortcut: "l"),
            TUIMenuItem(title: "Version or Build", detail: "Enter a macOS version, build, or latest.", shortcut: "v"),
            TUIMenuItem(title: "Local Restore Image", detail: "Enter a local Restore.ipsw path.", shortcut: "p"),
            TUIMenuItem(title: "Cancel", detail: "Return without running.")
        ]
        let choice = try choose(title: title, subtitle: "Restore source", items: items, initialIndex: 0, emptyMessage: nil)
        switch choice {
        case 0:
            return ["--version", "latest"]
        case 1:
            guard let version = try promptRequiredLine(
                title: title,
                message: "Enter a macOS version, build, or latest.",
                prompt: "Version/build/latest",
                defaultValue: "latest"
            ) else {
                return nil
            }
            let device = try promptLine(
                title: title,
                message: "Optional ipsw.me Mac model override. Leave blank for the default.",
                prompt: "IPSW device override",
                defaultValue: "",
                errorMessage: nil
            )
            var args = ["--version", version]
            if let device, !device.isEmpty {
                args.append(contentsOf: ["--ipsw-device", device])
            }
            return args
        case 2:
            guard let path = try promptRequiredLine(
                title: title,
                message: "Enter the absolute or relative path to a local Restore.ipsw.",
                prompt: "Restore image path",
                defaultValue: ""
            ) else {
                return nil
            }
            return ["--restore-image", path]
        default:
            return nil
        }
    }

    private mutating func promptSize(title: String, label: String, defaultValue: String, flag: String) throws -> String? {
        var errorMessage: String?
        while true {
            guard let value = try promptLine(
                title: title,
                message: "\(label) accepts raw bytes or K, M, G, T suffixes.",
                prompt: label,
                defaultValue: defaultValue,
                errorMessage: errorMessage
            ) else {
                statusMessage = "\(title) cancelled."
                return nil
            }
            guard !value.isEmpty else {
                errorMessage = "\(label) is required."
                continue
            }
            guard ByteSizeParser.parse(value) != nil else {
                errorMessage = "\(flag) requires a size like 60GB, 8192MB, or raw bytes."
                continue
            }
            return value
        }
    }

    private mutating func chooseBool(title: String, prompt: String, defaultValue: Bool) throws -> Bool? {
        let items = [
            TUIMenuItem(title: "Yes", detail: prompt, shortcut: "y"),
            TUIMenuItem(title: "No", detail: prompt, shortcut: "n")
        ]
        guard let choice = try choose(title: title, subtitle: prompt, items: items, initialIndex: defaultValue ? 0 : 1, emptyMessage: nil) else {
            return nil
        }
        return choice != 1
    }

    private mutating func chooseStartMode(title: String) throws -> StartMode {
        let items = [
            TUIMenuItem(title: "Do Not Boot", detail: "Install macOS and leave the VM stopped.", shortcut: "d"),
            TUIMenuItem(title: "Boot Normal", detail: "Boot normal macOS after install.", shortcut: "n"),
            TUIMenuItem(title: "Boot Recovery", detail: "Boot macOS Recovery after install.", shortcut: "r")
        ]
        switch try choose(title: title, subtitle: "Boot after install", items: items, initialIndex: 0, emptyMessage: nil) {
        case 1:
            return .normal
        case 2:
            return .recovery
        default:
            return .none
        }
    }

    private mutating func promptTypedConfirmation(title: String, message: String, expected: String) throws -> Bool {
        let value = try promptLine(
            title: title,
            message: message,
            prompt: "Confirmation",
            defaultValue: "",
            errorMessage: nil
        )
        let confirmed = value == expected
        if !confirmed {
            statusMessage = "Confirmation did not match \(expected)."
        }
        return confirmed
    }

    private mutating func promptRequiredLine(
        title: String,
        message: String,
        prompt: String,
        defaultValue: String
    ) throws -> String? {
        var errorMessage: String?
        while true {
            guard let value = try promptLine(
                title: title,
                message: message,
                prompt: prompt,
                defaultValue: defaultValue,
                errorMessage: errorMessage
            ) else {
                statusMessage = "\(title) cancelled."
                return nil
            }
            guard !value.isEmpty else {
                errorMessage = "\(prompt) is required."
                continue
            }
            return value
        }
    }

    private mutating func promptLine(
        title: String,
        message: String?,
        prompt: String,
        defaultValue: String?,
        errorMessage: String?
    ) throws -> String? {
        terminal.restore()
        terminal.showCursor()
        terminal.clear()
        defer {
            try? terminal.enableRawMode()
            terminal.hideCursor()
        }

        terminal.write(renderer.renderPrompt(title: title, message: message, errorMessage: errorMessage, width: terminal.width))
        terminal.write("\n")
        let suffix = defaultValue.map { $0.isEmpty ? "" : " [\($0)]" } ?? ""
        terminal.write("\(prompt)\(suffix): ")

        guard let line = terminal.readLine() else {
            return nil
        }
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, let defaultValue, !defaultValue.isEmpty {
            return defaultValue
        }
        return value
    }

    private mutating func choose(
        title: String,
        subtitle: String?,
        warningMessage: String? = nil,
        items: [TUIMenuItem],
        initialIndex: Int,
        emptyMessage: String?
    ) throws -> Int? {
        guard !items.isEmpty else {
            statusMessage = emptyMessage
            return nil
        }
        var selected = min(max(initialIndex, 0), items.count - 1)
        while true {
            renderMenu(title: title, subtitle: subtitle, warningMessage: warningMessage, items: items, selected: selected)
            switch try terminal.readKey() {
            case .up:
                selected = selected == 0 ? items.count - 1 : selected - 1
            case .down:
                selected = selected == items.count - 1 ? 0 : selected + 1
            case .enter:
                return selected
            case .escape:
                return nil
            case .character(let character):
                let key = String(character).lowercased()
                switch key {
                case "q":
                    return nil
                case "j":
                    selected = selected == items.count - 1 ? 0 : selected + 1
                case "k":
                    selected = selected == 0 ? items.count - 1 : selected - 1
                default:
                    if let index = items.firstIndex(where: { $0.shortcut?.lowercased() == key }) {
                        return index
                    }
                }
            case .backspace:
                continue
            }
        }
    }

    private mutating func renderDashboard(entries: [TUIVMEntry], selectedIndex: Int?) {
        terminal.clear()
        let message = statusMessage
        statusMessage = nil
        terminal.write(
            renderer.renderDashboard(
                entries: entries,
                selectedIndex: selectedIndex,
                statusMessage: message,
                width: terminal.width
            ) + "\n"
        )
    }

    private mutating func renderMenu(
        title: String,
        subtitle: String?,
        warningMessage: String? = nil,
        items: [TUIMenuItem],
        selected: Int
    ) {
        terminal.clear()
        let message = statusMessage
        statusMessage = nil
        terminal.write(
            renderer.renderMenu(
                title: title,
                subtitle: subtitle,
                warningMessage: warningMessage,
                items: items,
                selectedIndex: selected,
                statusMessage: message,
                width: terminal.width
            ) + "\n"
        )
    }

    private mutating func confirmBootTransitionIfNeeded(entry: TUIVMEntry, targetMode: BootMode) throws -> Bool {
        guard entry.running else {
            return true
        }
        let currentMode = entry.bootMode ?? BootMode.normal.rawValue
        guard currentMode != targetMode.rawValue else {
            return true
        }

        let items = [
            TUIMenuItem(
                title: "Stop and Restart",
                detail: "Stop the VM and restart it in \(targetMode.rawValue) boot mode.",
                shortcut: "y",
                role: .warning
            ),
            TUIMenuItem(title: "Cancel", detail: "Leave the running VM untouched.", shortcut: "n")
        ]
        let warningMessage = [
            "Switching boot modes requires stopping the current VM session.",
            "This can interrupt running guest processes or unsaved guest work.",
            "Confirming will stop the VM and restart it in \(targetMode.rawValue) boot mode."
        ].joined(separator: "\n")
        let choice = try choose(
            title: "Change boot mode",
            subtitle: "\(entry.displayName) is running in \(currentMode).",
            warningMessage: warningMessage,
            items: items,
            initialIndex: 1,
            emptyMessage: nil
        )
        let confirmed = choice == 0
        if !confirmed {
            statusMessage = "Boot mode change cancelled."
        }
        return confirmed
    }

    @discardableResult
    private mutating func runTUIAction(
        title: String,
        vmName: String?,
        operation: @MainActor @Sendable @escaping () async throws -> PommeOperationResult
    ) async throws -> Bool {
        let progress = TUIActionProgress()
        let startedAt = Date()
        let task = Task {
            do {
                let result = try await PommeCore.withLogSink({ message in
                    progress.append(message)
                }) {
                    try await operation()
                }
                progress.finish(.success(result))
            } catch {
                progress.finish(.failure(error))
            }
        }

        while true {
            let snapshot = progress.snapshot()
            let phase: String
            if snapshot.isFinished {
                phase = snapshot.errorMessage == nil ? "complete" : "failed"
            } else {
                phase = "running"
            }
            renderDetail(
                title: title,
                vmName: vmName,
                phase: phase,
                elapsed: Date().timeIntervalSince(startedAt),
                statusLines: snapshot.lines,
                progress: snapshot.progress,
                result: snapshot.result,
                errorMessage: snapshot.errorMessage
            )
            if snapshot.isFinished {
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        _ = await task.result
        let completed = progress.snapshot().result?.ok == true && progress.snapshot().errorMessage == nil

        while true {
            switch try terminal.readKey() {
            case .enter, .escape:
                return completed
            case .character(let character):
                switch String(character).lowercased() {
                case "q", "r":
                    return completed
                default:
                    continue
                }
            default:
                continue
            }
        }
    }

    private mutating func renderDetail(
        title: String,
        vmName: String?,
        phase: String,
        elapsed: TimeInterval,
        statusLines: [String],
        progress: TUIProgressState?,
        result: PommeOperationResult?,
        errorMessage: String?
    ) {
        terminal.clear()
        terminal.write(
            renderer.renderDetail(
                title: title,
                vmName: vmName,
                phase: phase,
                elapsed: elapsed,
                statusLines: statusLines,
                progress: progress,
                result: result,
                errorMessage: errorMessage,
                width: terminal.width
            ) + "\n"
        )
    }

    private mutating func loadVMs() -> [TUIVMEntry] {
        do {
            return try vmListAction()
        } catch {
            statusMessage = error.localizedDescription
            return []
        }
    }

    private mutating func loadSnapshots(name: String) -> [VMSnapshotRecord] {
        do {
            return try snapshotListAction(name).sorted { lhs, rhs in
                lhs.createdAt > rhs.createdAt
            }
        } catch {
            statusMessage = error.localizedDescription
            return []
        }
    }

    private func snapshotSummary(_ snapshot: VMSnapshotRecord) -> String {
        let status = snapshot.drift.isEmpty ? "ready" : "drift"
        return "created=\(snapshotTimestamp(snapshot.createdAt)) state=\(snapshot.sourceState) size=\(snapshotSize(snapshot)) status=\(status)"
    }

    private func snapshotWarning(_ snapshot: VMSnapshotRecord) -> String? {
        guard !snapshot.drift.isEmpty else {
            return nil
        }
        return ([
            "Snapshot drift detected:",
            "Disk.img and AuxiliaryStorage are not copied or replaced.",
            "Restoring older machine state may expose stale or inconsistent guest-visible filesystem state.",
            "Restore Despite Drift accepts this risk; VM identity/configuration drift is still rejected."
        ] + snapshot.drift.map { "- \($0)" }).joined(separator: "\n")
    }

    private func snapshotTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func snapshotSize(_ snapshot: VMSnapshotRecord) -> String {
        ByteCountFormatter.string(fromByteCount: snapshot.machineStateBytes, countStyle: .file)
    }

    private mutating func refreshVMEntry(named name: String) -> TUIVMEntry? {
        let entry = loadVMs().first { $0.name == name }
        if entry == nil {
            statusMessage = "VM \(name) is no longer in the VM list."
        }
        return entry
    }
}
