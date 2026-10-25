import Foundation

/// `pomme firmware`: detects and repairs the boot firmware that the macOS
/// 26.7 and 15.8 guest updates install. See `VMBootFirmware`.
extension PommeApplication {
    static let bootFirmwareTroubleshootingURL =
        "https://pommevm.dev/resources/troubleshooting/#a-guest-update-hangs-and-the-vm-has-less-memory"

    static func firmwareInspect(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let inspection = try VMBootFirmware.inspect(url: reference.bundle.auxiliaryStorageURL)
        let guest = guestFirmwareReport(reference: reference)
        let diagnosis = VMBootFirmware.diagnosis(inspection, guest: guest.report)
        var payload: [String: Any] = [
            "ok": true,
            "operation": "firmware.inspect",
            "name": name,
            "bootFirmware": inspection.payload,
            "guest": guest.report?.payload ?? ["checked": false, "reason": guest.unavailableReason ?? ""],
            "diagnosis": diagnosis.rawValue,
            "hostExitCode": 0
        ]
        if let advice = firmwareAdvice(diagnosis, name: name) { payload["advice"] = advice }
        return result(title: "Firmware", reference: reference, payload: payload,
                      text: formatFirmwareInspect(inspection, guest: guest, diagnosis: diagnosis, name: name))
    }

    static func firmwareRepair(name: String) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name) { _ in
            let reference = try namedReference(name)
            PommeProgressContext.sink?.step(vm: name, "Repairing boot firmware")
            guard !PommeCore.hasRuntimeRecord(bundle: reference.bundle) else {
                throw VMBootFirmwareError.running(name: name)
            }
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: reference.bundle.saveStateURL.path),
                  !fileManager.fileExists(atPath: reference.bundle.requiredSnapshotRestoreURL.path)
            else { throw VMBootFirmwareError.savedState(name: name) }

            let outcome = try VMBootFirmware.repair(
                auxiliaryStorageURL: reference.bundle.auxiliaryStorageURL,
                backupDirectory: reference.bundle.firmwareBackupsURL
            )
            let changed = outcome.backupURL != nil
            let text: String
            if let backup = outcome.backupURL {
                text = """
                Restored boot firmware \(outcome.after.active?.version ?? "") in place of \(outcome.before.active?.version ?? "").
                backup: \(backup.path)
                Start the VM with `pomme start \(name)`. You can then install the macOS update again.
                """
            } else {
                text = "No repair needed: the VM's boot firmware is \(outcome.before.active?.version ?? "unknown") (\(outcome.before.status.rawValue))."
            }
            return result(title: "Firmware Repair", reference: reference, payload: [
                "ok": true,
                "operation": "firmware.repair",
                "name": name,
                "changed": changed,
                "backupPath": outcome.backupURL?.path as Any? ?? NSNull(),
                "before": outcome.before.payload,
                "after": outcome.after.payload,
                "hostExitCode": 0
            ], text: text)
        }
    }

    /// The firmware as `firmware repair` will find it, read without the VM's
    /// lock, so that the command asks for confirmation only when it will
    /// change something. The repair inspects the file again under its lock.
    static func firmwareInspection(name: String) throws -> VMBootFirmware.Inspection {
        let reference = try namedReference(name)
        return try VMBootFirmware.inspect(url: reference.bundle.auxiliaryStorageURL)
    }

    /// The `pomme inspect` view: the file only, so it never runs anything in
    /// the guest.
    static func bootFirmwareInspectPayload(reference: VMReference) -> [String: Any] {
        guard let inspection = try? VMBootFirmware.inspect(url: reference.bundle.auxiliaryStorageURL) else {
            return ["status": VMBootFirmware.Status.unrecognized.rawValue, "repairable": false]
        }
        var payload = inspection.payload
        if inspection.status == .incompatibleUpdate, let name = reference.name {
            payload["advice"] = firmwareAdvice(.likelyAffected, name: name)
        }
        return payload
    }

    static func formatBootFirmwareInspect(_ payload: [String: Any]) -> String {
        var lines = ["bootFirmware: \(PommeCore.stringValue(payload["activeVersion"]).isEmpty ? "unknown" : PommeCore.stringValue(payload["activeVersion"])) status=\(PommeCore.stringValue(payload["status"]))"]
        if let advice = payload["advice"] as? String { lines.append("bootFirmware.advice: \(advice)") }
        return lines.joined(separator: "\n")
    }

    struct GuestFirmwareCheck {
        let report: VMBootFirmware.GuestReport?
        let unavailableReason: String?
    }

    /// Asks a running guest for its memory and macOS version. Anything that
    /// prevents the check is reported, not thrown: the file is still useful.
    private static func guestFirmwareReport(reference: VMReference) -> GuestFirmwareCheck {
        guard let name = reference.name else { return .init(report: nil, unavailableReason: "The VM has no name.") }
        let status: [String: Any]
        do { status = try PommeCore.vmStatusPayload(reference: reference) } catch {
            return .init(report: nil, unavailableReason: error.localizedDescription)
        }
        let agent = status["guestAgent"] as? [String: Any]
        guard status["helperRunning"] as? Bool == true, PommeCore.stringValue(status["vmState"]) == "running",
              PommeCore.stringValue(status["bootMode"]) == BootMode.normal.rawValue,
              PommeCore.stringValue(agent?["connection"]) == GuestAgentStatusV1.ConnectionState.connected.rawValue
        else {
            return .init(report: nil, unavailableReason: "The guest is checked only while the VM runs normal macOS with a connected Pomme agent.")
        }
        let command = VMBootFirmware.GuestReport.command
        let request = GuestCommandRequest(path: command.path, arguments: command.arguments, timeout: 30)
        do {
            let response = try VMBundleMutationLease.withLease(name: name) { _ in
                try PommeCore.sendForegroundControlObject(request.controlPayload, bundle: reference.bundle, timeout: 45)
            }
            let completed = try PommeSecurityNormalAgent.decodeCompletedCommand(response)
            guard completed.exitCode == 0,
                  let report = VMBootFirmware.GuestReport(sysctlOutput: String(decoding: completed.stdout, as: UTF8.self))
            else {
                return .init(report: nil, unavailableReason: "The guest didn't report its memory and macOS version.")
            }
            return .init(report: report, unavailableReason: nil)
        } catch {
            return .init(report: nil, unavailableReason: error.localizedDescription)
        }
    }

    private static func firmwareAdvice(_ diagnosis: VMBootFirmware.Diagnosis, name: String) -> String? {
        switch diagnosis {
        case .affected:
            return "This firmware leaves the guest about 1.75 GB of memory, so a macOS update can't finish and Recovery can't start. Stop the VM with `pomme stop \(name)`, then run `pomme firmware repair \(name)`. See \(bootFirmwareTroubleshootingURL)"
        case .likelyAffected:
            return "A guest update installed macOS 27 boot firmware, which leaves macOS 26 and earlier about 1.75 GB of memory, so a macOS update can't finish and Recovery can't start. Run `pomme firmware inspect \(name)` while the VM runs to confirm. If the VM runs macOS 26 or earlier, stop it and run `pomme firmware repair \(name)`. See \(bootFirmwareTroubleshootingURL)"
        case .notAffected, .unknown:
            return nil
        }
    }

    private static func formatFirmwareInspect(
        _ inspection: VMBootFirmware.Inspection,
        guest: GuestFirmwareCheck,
        diagnosis: VMBootFirmware.Diagnosis,
        name: String
    ) -> String {
        var lines = ["status: \(inspection.status.rawValue)"]
        if let active = inspection.active {
            lines.append("active: \(active.version ?? "unknown") (slot \(active.name))")
        }
        if let fallback = inspection.fallback {
            lines.append("previous: \(fallback.version ?? "unknown") (slot \(fallback.name))")
        }
        if let report = guest.report {
            let usable = ByteCountFormatter.string(fromByteCount: Int64(report.usableMemoryBytes), countStyle: .memory)
            let total = ByteCountFormatter.string(fromByteCount: Int64(report.memoryBytes), countStyle: .memory)
            lines.append("guest: macOS \(report.macOSVersion), \(usable) of \(total) memory usable")
        } else {
            lines.append("guest: not checked. \(guest.unavailableReason ?? "")")
        }
        lines.append("diagnosis: \(diagnosis.rawValue)")
        if let advice = firmwareAdvice(diagnosis, name: name) { lines.append(advice) }
        return lines.joined(separator: "\n")
    }
}

extension PommeCore {
    /// A Recovery boot of a VM with the incompatible firmware hangs without
    /// any frames, which looks like a Pomme failure. Say why first.
    static func warnIfBootFirmwareBlocksRecovery(reference: VMReference) {
        guard let inspection = try? VMBootFirmware.inspect(url: reference.bundle.auxiliaryStorageURL),
              inspection.status == .incompatibleUpdate
        else { return }
        let name = reference.name ?? "NAME"
        warning(
            "\(reference.displayName) has boot firmware \(inspection.active?.version ?? "") from a guest update. If the VM runs macOS 26 or earlier, Recovery can't start with it. Stop the VM and run `pomme firmware repair \(name)`. See \(PommeApplication.bootFirmwareTroubleshootingURL)"
        )
    }
}

extension BundleLayout {
    var firmwareBackupsURL: URL { rootURL.appendingPathComponent("FirmwareBackups", isDirectory: true) }
}
