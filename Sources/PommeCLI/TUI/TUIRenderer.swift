import Foundation

struct TUIRenderer {
    private let useColor: Bool

    init(useColor: Bool) {
        self.useColor = useColor
    }

    func renderDashboard(
        entries: [TUIVMEntry],
        selectedIndex: Int?,
        statusMessage: String?,
        width: Int
    ) -> String {
        let layout = dashboardLayout(width: width)
        let runningCount = entries.filter(\.running).count
        let pausedCount = entries.filter { $0.state == .paused }.count
        let stoppedCount = entries.filter { $0.state == .stopped }.count
        let unknownCount = entries.filter { $0.state == .unknown }.count
        let connectedAgentCount = entries.filter { $0.guestAgent.connection == .connected }.count
        let disconnectedAgentCount = entries.filter { $0.guestAgent.connection == .disconnected }.count
        let unknownAgentCount = entries.filter { $0.guestAgent.connection == .unknown }.count
        var lines: [String] = []

        lines.append(title("pomme VM dashboard"))
        lines.append(
            muted(
                "VMs: total=\(entries.count) running=\(runningCount) paused=\(pausedCount) stopped=\(stoppedCount) unknown=\(unknownCount) guestAgentConnected=\(connectedAgentCount) guestAgentDisconnected=\(disconnectedAgentCount) guestAgentUnknown=\(unknownAgentCount)"
            )
        )
        lines.append("")

        if let statusMessage, !statusMessage.isEmpty {
            lines.append(warning(statusMessage))
            lines.append("")
        }

        if entries.isEmpty {
            lines.append("No VMs found.")
            lines.append("Press c to create one.")
        } else {
            lines.append(renderDashboardHeader(layout: layout))
            for (index, entry) in entries.enumerated() {
                lines.append(renderDashboardRow(entry: entry, selected: index == selectedIndex, layout: layout))
            }
        }

        lines.append("")
        if let selectedIndex, entries.indices.contains(selectedIndex) {
            let selected = entries[selectedIndex]
            lines.append(contentsOf: wrapText(
                "Selected guestAgent \(selected.guestAgent.summary)",
                width: clampedWidth(width)
            ))
            if selected.name == nil {
                lines.append("Actions: c Create VM | r Refresh | d Delete unavailable for unrecognized entries")
            } else {
                lines.append("Actions: c Create VM | r Refresh | \(danger("[d] Delete"))")
            }
        } else {
            lines.append("Actions: c Create VM | r Refresh")
        }
        lines.append("")
        lines.append(footer("Keys: arrows/j/k move | Return open | r refresh | c create | d delete | q/Esc quit"))
        return lines.joined(separator: "\n")
    }

    func renderMenu(
        title: String,
        subtitle: String?,
        warningMessage: String?,
        items: [TUIMenuItem],
        selectedIndex: Int,
        statusMessage: String?,
        width: Int
    ) -> String {
        let contentWidth = clampedWidth(width)
        let titleWidth = min(28, max(16, contentWidth / 3))
        let detailWidth = max(12, contentWidth - titleWidth - 19)
        var lines: [String] = []

        lines.append(self.title(title))
        if let subtitle, !subtitle.isEmpty {
            lines.append(muted(truncateMiddle(subtitle, width: contentWidth)))
        }
        lines.append("")

        if let statusMessage, !statusMessage.isEmpty {
            lines.append(warning(statusMessage))
            lines.append("")
        }

        if let warningMessage, !warningMessage.isEmpty {
            for line in warningMessage.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(warning(truncateMiddle(String(line), width: contentWidth)))
            }
            lines.append("")
        }

        for (index, item) in items.enumerated() {
            let selected = index == selectedIndex
            let marker = selected ? accent(">") : " "
            let shortcut = item.shortcut.map { "[\($0.lowercased())]" } ?? "   "
            let role = roleLabel(item.role)
            let itemTitle = padRight(truncateEnd(item.title, width: titleWidth), width: titleWidth)
            let detail = truncateMiddle(item.detail, width: detailWidth)
            let line = "\(marker) \(shortcut) \(role) \(itemTitle) \(muted(detail))"
            lines.append(line)
        }

        lines.append("")
        lines.append(footer("Keys: arrows/j/k move | Return choose | shortcut key choose | q/Esc back"))
        return lines.joined(separator: "\n")
    }

    func renderDetail(
        title: String,
        vmName: String?,
        phase: String,
        elapsed: TimeInterval,
        statusLines: [String],
        progress: TUIProgressState?,
        result: PommeOperationResult?,
        errorMessage: String?,
        width: Int
    ) -> String {
        let contentWidth = clampedWidth(width)
        var lines: [String] = []
        lines.append(self.title(title))
        var header = "phase=\(phase) elapsed=\(formatElapsed(elapsed))"
        if let vmName, !vmName.isEmpty {
            header = "vm=\(vmName) " + header
        }
        if let result {
            header += " exit=\(result.hostExitCode)"
        }
        lines.append(muted(truncateMiddle(header, width: contentWidth)))
        lines.append("")

        if let progress {
            lines.append(renderProgressBar(progress, width: contentWidth))
            lines.append("")
        }

        if !statusLines.isEmpty {
            lines.append(muted("Progress"))
            for line in statusLines.suffix(8) {
                lines.append(truncateMiddle(line, width: contentWidth))
            }
            lines.append("")
        }

        if let errorMessage, !errorMessage.isEmpty {
            lines.append(contentsOf: errorLines(errorMessage, width: contentWidth))
        } else if let result {
            if result.ok {
                let body = result.text.isEmpty ? "OK" : result.text
                for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append(truncateMiddle(String(line), width: contentWidth))
                }
            } else {
                // Result text no longer carries its own ERROR marker; the
                // renderer supplies it, the same as for a thrown error.
                let message = result.text.isEmpty ? "The operation failed." : result.text
                lines.append(contentsOf: errorLines(message, width: contentWidth))
            }
            let detailLines = renderPayloadDetails(result.payload, width: contentWidth)
            if !detailLines.isEmpty {
                lines.append("")
                lines.append(muted("Details"))
                lines.append(contentsOf: detailLines)
            }
        } else {
            lines.append("Running...")
        }

        lines.append("")
        if phase == "running" {
            lines.append(footer("Operation is running; cancellation is unavailable."))
        } else {
            lines.append(footer("Keys: Return/q/Esc Back | r return and refresh"))
        }
        return lines.joined(separator: "\n")
    }

    func renderPrompt(
        title: String,
        message: String?,
        errorMessage: String?,
        width: Int
    ) -> String {
        let contentWidth = clampedWidth(width)
        var lines: [String] = []
        lines.append(self.title(title))
        if let message, !message.isEmpty {
            lines.append("")
            for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(truncateMiddle(String(line), width: contentWidth))
            }
        }
        if let errorMessage, !errorMessage.isEmpty {
            lines.append("")
            lines.append(warning(errorMessage))
        }
        lines.append("")
        lines.append(muted("Press Ctrl-D to cancel."))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    func vmSummary(_ entry: TUIVMEntry) -> String {
        let run = entry.state.badge
        return "\(run) vmState=\(entry.vmState) boot=\(entry.bootModeLabel) guestAgent \(entry.guestAgent.summary) bundle=\(entry.bundlePath)"
    }

    private func renderDashboardHeader(layout: DashboardLayout) -> String {
        [
            "  ",
            padRight("STATE", width: layout.badgeWidth),
            padRight("NAME", width: layout.nameWidth),
            padRight("VM STATE", width: layout.stateWidth),
            padRight("BOOT", width: layout.bootWidth),
            padRight("GUEST AGENT", width: layout.agentWidth),
            "BUNDLE"
        ].joined(separator: " ")
    }

    private func renderDashboardRow(entry: TUIVMEntry, selected: Bool, layout: DashboardLayout) -> String {
        let marker = selected ? accent(">") : " "
        let badge = statusBadge(entry.state, width: layout.badgeWidth)
        let name = padRight(truncateEnd(entry.displayName, width: layout.nameWidth), width: layout.nameWidth)
        let state = padRight(truncateEnd(entry.vmState, width: layout.stateWidth), width: layout.stateWidth)
        let boot = padRight(truncateEnd(entry.bootModeLabel, width: layout.bootWidth), width: layout.bootWidth)
        let agent = truncateEnd(entry.guestAgent.summary, width: layout.agentWidth)
        let bundle = truncatePath(entry.bundlePath, width: layout.bundleWidth)
        return "\(marker) \(badge) \(name) \(state) \(boot) \(agent) \(muted(bundle))"
    }

    private func dashboardLayout(width: Int) -> DashboardLayout {
        let contentWidth = clampedWidth(width)
        var nameWidth = min(24, max(12, contentWidth / 4))
        let badgeWidth = 7
        let stateWidth = 12
        let bootWidth = 8
        let agentWidth = min(62, max(24, contentWidth / 3))
        let fixedWidth = 2 + badgeWidth + 1 + stateWidth + 1 + bootWidth + 1 + agentWidth + 1
        var bundleWidth = contentWidth - fixedWidth - nameWidth
        if bundleWidth < 12 {
            let deficit = 12 - bundleWidth
            nameWidth = max(10, nameWidth - deficit)
            bundleWidth = max(8, contentWidth - fixedWidth - nameWidth)
        }
        return DashboardLayout(
            badgeWidth: badgeWidth,
            nameWidth: nameWidth,
            stateWidth: stateWidth,
            bootWidth: bootWidth,
            agentWidth: agentWidth,
            bundleWidth: bundleWidth
        )
    }

    private func clampedWidth(_ width: Int) -> Int {
        min(max(width, 60), 180)
    }

    private func statusBadge(_ state: TUIVMState, width: Int) -> String {
        let text = padRight(state.badge, width: width)
        switch state {
        case .running: return success(text)
        case .paused: return warning(text)
        case .stopped, .unknown: return muted(text)
        }
    }

    private func renderProgressBar(_ progress: TUIProgressState, width: Int) -> String {
        let percent = min(100, max(0, progress.percent))
        let suffix = " \(percent)%"
        let prefix = "\(progress.label) "
        let barWidth = max(10, min(40, width - prefix.count - suffix.count - 2))
        let filled = Int((Double(barWidth) * Double(percent) / 100.0).rounded(.down))
        let empty = max(0, barWidth - filled)
        let bar = "[\(String(repeating: "#", count: filled))\(String(repeating: "-", count: empty))]"
        return "\(truncateEnd(prefix, width: max(0, width - bar.count - suffix.count)))\(bar)\(suffix)"
    }

    private func roleLabel(_ role: TUIMenuRole) -> String {
        switch role {
        case .normal:
            return "        "
        case .warning:
            return "\(warning("[WARN]"))  "
        case .destructive:
            return danger("[DANGER]")
        }
    }

    private func title(_ text: String) -> String {
        colored(text, code: "1;36")
    }

    private func footer(_ text: String) -> String {
        muted(text)
    }

    private func accent(_ text: String) -> String {
        colored(text, code: "1;36")
    }

    private func success(_ text: String) -> String {
        colored(text, code: "32")
    }

    private func warning(_ text: String) -> String {
        colored(text, code: "33")
    }

    private func danger(_ text: String) -> String {
        colored(text, code: "31")
    }

    private func muted(_ text: String) -> String {
        colored(text, code: "2")
    }

    private func colored(_ text: String, code: String) -> String {
        guard useColor else {
            return text
        }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    private func padRight(_ value: String, width: Int) -> String {
        guard value.count < width else {
            return value
        }
        return value + String(repeating: " ", count: width - value.count)
    }

    private func truncateEnd(_ value: String, width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        guard value.count > width else {
            return value
        }
        guard width > 3 else {
            return String(value.prefix(width))
        }
        return String(value.prefix(width - 3)) + "..."
    }

    private func truncateMiddle(_ value: String, width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        guard value.count > width else {
            return value
        }
        guard width > 6 else {
            return String(value.prefix(width))
        }
        let leftCount = (width - 3) / 2
        let rightCount = width - 3 - leftCount
        return String(value.prefix(leftCount)) + "..." + String(value.suffix(rightCount))
    }

    private func errorLines(_ message: String, width: Int) -> [String] {
        let prefix = "ERROR: "
        let wrapped = wrapText(message, width: max(8, width - prefix.count))
        return wrapped.enumerated().map { index, line in
            let linePrefix = index == 0 ? prefix : String(repeating: " ", count: prefix.count)
            return warning(linePrefix + line)
        }
    }

    private func wrapText(_ value: String, width: Int) -> [String] {
        let width = max(1, width)
        var lines: [String] = []
        for rawLine in value.split(separator: "\n", omittingEmptySubsequences: false) {
            var remaining = String(rawLine).trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty {
                lines.append("")
                continue
            }
            while remaining.count > width {
                let end = remaining.index(remaining.startIndex, offsetBy: width)
                let candidate = remaining[..<end]
                if let breakIndex = candidate.lastIndex(where: { $0 == " " || $0 == "\t" }),
                   breakIndex > remaining.startIndex {
                    lines.append(String(remaining[..<breakIndex]))
                    let nextIndex = remaining.index(after: breakIndex)
                    remaining = String(remaining[nextIndex...]).trimmingCharacters(in: .whitespaces)
                } else {
                    lines.append(String(candidate))
                    remaining = String(remaining[end...]).trimmingCharacters(in: .whitespaces)
                }
            }
            lines.append(remaining)
        }
        return lines
    }

    private func truncatePath(_ value: String, width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        guard value.count > width else {
            return value
        }
        guard width > 3 else {
            return String(value.suffix(width))
        }
        return "..." + String(value.suffix(width - 3))
    }

    private func renderPayloadDetails(_ payload: [String: Any], width: Int) -> [String] {
        var lines: [String] = []
        let simpleKeys = [
            "operation", "action", "name", "bundlePath", "bootMode", "hostExitCode",
            "healthy", "sipDisabled", "amfiBootArgActive",
            "durationSeconds", "error"
        ]
        for key in simpleKeys where payload[key] != nil {
            lines.append(truncateMiddle("\(key): \(redactedString(payload[key], key: key))", width: width))
        }

        if let steps = payload["steps"] as? [[String: Any]], !steps.isEmpty {
            for step in steps {
                let name = redactedString(step["name"], key: "name")
                let ok = step["ok"] as? Bool == true ? "ok" : "fail"
                let detail = redactedString(step["error"] ?? step["detail"] ?? step["response"], key: "detail")
                let suffix = detail.isEmpty ? "" : " \(detail)"
                lines.append(truncateMiddle("step.\(name): \(ok)\(suffix)", width: width))
            }
        }
        return lines
    }

    private func redactedString(_ value: Any?, key: String) -> String {
        let lowerKey = key.lowercased()
        if lowerKey.contains("password") || lowerKey.contains("secret") || lowerKey.contains("token") {
            return "[redacted]"
        }
        if let value = value as? Bool {
            return value ? "true" : "false"
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return value.stringValue
        }
        if let value {
            return String(describing: value)
        }
        return ""
    }

    private func formatElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct DashboardLayout {
    let badgeWidth: Int
    let nameWidth: Int
    let stateWidth: Int
    let bootWidth: Int
    let agentWidth: Int
    let bundleWidth: Int
}
