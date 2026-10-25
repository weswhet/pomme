import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Experimental Recovery image isolation")
struct PommeExperimentalRecoveryImageTests {
    private typealias Image = PommeExperimentalRecoveryImage
    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    @Test("Native executor observes immediate exit and drains output", .timeLimit(.minutes(1)))
    func nativeSuccess() async throws {
        let empty = try await Image.execute(.init(executable: "/usr/bin/true", arguments: [], timeout: 5))
        #expect(empty.status == 0)
        let output = try await Image.execute(.init(executable: "/usr/bin/printf", arguments: ["%s", "executor-proof"], timeout: 5))
        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "executor-proof")
        #expect(output.stderr.isEmpty)
    }
    @Test("Native executor timeout terminates a child without blocking", .timeLimit(.minutes(1)))
    func nativeTimeout() async throws {
        await #expect(throws: Image.Failure.self) {
            try await Image.execute(.init(executable: "/bin/sleep", arguments: ["30"], timeout: 0.1))
        }
    }
    @Test("Native executor cancellation drains and confirms child termination", .timeLimit(.minutes(1)))
    func nativeCancellation() async throws {
        let child = Task { try await Image.execute(.init(executable: "/bin/sleep", arguments: ["30"], timeout: 40)) }
        try await Task.sleep(for: .milliseconds(150))
        child.cancel()
        await #expect(throws: CancellationError.self) { try await child.value }
    }

    @Test("APFS selection follows physical stores and refuses ambiguity")
    func physicalStoreSelection() throws {
        let data = try plist(["Containers": [
            ["PhysicalStores": [["DeviceIdentifier": "disk3s2"]], "Volumes": [["DeviceIdentifier": "disk9s3", "Roles": ["Recovery"]]]],
            ["PhysicalStores": [["DeviceIdentifier": "disk7s2"]], "Volumes": [["DeviceIdentifier": "disk4s3", "Roles": ["Recovery"]]]]
        ]])
        let volumes = try Image.volumes(apfs: data, attachedDevices: ["disk7", "disk7s2"])
        #expect(try Image.select(volumes, role: "Recovery").device == "disk4s3")
        #expect(throws: Error.self) { try Image.select(volumes + volumes, role: "Recovery") }
        #expect(throws: Error.self) { try Image.select(volumes, role: nil) }
        #expect(throws: Error.self) { try Image.volumes(apfs: data, attachedDevices: ["disk99"]) }
        let untrusted = try plist(["Containers": [["PhysicalStores": [["DeviceIdentifier": "../../disk7s2"]], "Volumes": []]]])
        #expect(throws: Error.self) { try Image.volumes(apfs: untrusted, attachedDevices: ["disk7s2"]) }
    }
    @Test("Installed Recovery excludes iSC, fallback, and unrelated disks")
    func installedContainerSelection() throws {
        func container(_ store: String, _ roles: [(String, String)]) -> [String: Any] {
            ["PhysicalStores": [["DeviceIdentifier": store]],
             "Volumes": roles.map { ["DeviceIdentifier": $0.0, "Roles": [$0.1]] }]
        }
        let isc = container("disk16s1", [("disk17s1", "Preboot"), ("disk17s2", "xART"), ("disk17s3", "Hardware"), ("disk17s4", "Recovery")])
        let fallback = container("disk16s3", [("disk18s1", "Recovery")])
        let installed = container("disk16s2", [("disk19s1", "System"), ("disk19s2", "Preboot"), ("disk19s3", "Recovery"), ("disk19s4", "Update"), ("disk19s5", "Data")])
        let foreign = container("disk90s2", [("disk91s1", "System"), ("disk91s2", "Data"), ("disk91s3", "Recovery")])
        let devices: Set<String> = ["disk16", "disk16s1", "disk16s2", "disk16s3"]
        let all = try plist(["Containers": [isc, fallback, installed, foreign]])
        #expect(try Image.installedRecovery(apfs: all, attachedDevices: devices).device == "disk19s3")
        let ambiguous = try plist(["Containers": [installed, installed]])
        #expect(throws: Image.Failure.self) { try Image.installedRecovery(apfs: ambiguous, attachedDevices: devices) }
        let noInstalled = try plist(["Containers": [isc, fallback, foreign]])
        #expect(throws: Image.Failure.self) { try Image.installedRecovery(apfs: noInstalled, attachedDevices: devices) }
    }

    @Test("Detach uses partition metadata, never lexical disk number ordering")
    func partitionIdentity() throws {
        let entries: [[String: Any]] = [
            ["dev-entry": "/dev/disk2", "content-hint": "Apple_APFS"],
            ["dev-entry": "/dev/disk19", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk19s1", "content-hint": "Apple_APFS"]
        ]
        #expect(try Image.partitionDevice(entries) == "disk19")
        #expect(throws: Error.self) { try Image.partitionDevice(entries + [entries[1]]) }
        #expect(throws: Error.self) { try Image.partitionDevice([["dev-entry": "/dev/disk19s1", "content-hint": "GUID_partition_scheme"]]) }
        let attach = try plist(["system-entities": entries])
        #expect(try Image.attachedDevices(attach) == ["disk2", "disk19", "disk19s1"])
    }
    @Test("Role clear requires a unique role-free volume")
    func clearedRole() throws {
        #expect(try Image.select([.init(device: "disk4s1", roles: [])], role: nil).device == "disk4s1")
        #expect(throws: Error.self) { try Image.select([.init(device: "disk4s1", roles: ["System"])], role: nil) }
        #expect(throws: Error.self) { try Image.select([.init(device: "disk4s1", roles: []), .init(device: "disk4s2", roles: [])], role: nil) }
    }

    private struct Fixture {
        let root: URL
        let request: Image.Request
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/pomme-image-unit-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in ["Disk.img", "pomme", "agent.token", "autostart.sh", "launchd.plist"] {
                guard FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(name.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let digest = SHA256.hash(data: Data("pomme".utf8)).map { String(format: "%02x", $0) }.joined()
            let credential = SHA256.hash(data: Data("agent.token".utf8)).map { String(format: "%02x", $0) }.joined()
            request = Image.Request(diskURL: root.appendingPathComponent("Disk.img"), workspaceURL: workspace,
                vmID: UUID(), sessionID: UUID(), artifacts: .init(executableURL: root.appendingPathComponent("pomme"), tokenURL: root.appendingPathComponent("agent.token"), autostartURL: root.appendingPathComponent("autostart.sh"), launchdPlistURL: root.appendingPathComponent("launchd.plist")), executableSHA256: digest, credentialSHA256: credential, manifestSHA256: String(repeating: "a", count: 64))
        }
    }
    private actor InterruptedAttach {
        var attached = false
        var detached = false
        var intentObserved = false
        var commandCount = 0
        let request: Image.Request
        let failDetach: Bool
        let unconfirmed: Bool
        init(_ request: Image.Request, failDetach: Bool, unconfirmed: Bool = false) {
            self.request = request; self.failDetach = failDetach; self.unconfirmed = unconfirmed
        }
        func exposeAttachment() { attached = true }
        func execute(_ command: Image.Command) throws -> Image.CommandResult {
            commandCount += 1
            let operation = command.arguments.first ?? ""
            if operation == "attach" {
                let receipt = try Data(contentsOf: request.workspaceURL.appendingPathComponent("receipt.json"))
                intentObserved = String(decoding: receipt, as: UTF8.self).contains("pendingAttachmentImages")
                attached = true
                if unconfirmed { throw Image.Failure(reason: "mock command still running", processTerminationUnconfirmed: true) }
                throw CancellationError()
            }
            if operation == "detach" {
                if failDetach { return .init(status: 1, stdout: Data(), stderr: Data("bounded failure".utf8)) }
                attached = false; detached = true
                return .init(status: 0, stdout: Data(), stderr: Data())
            }
            guard operation == "info" else { throw CocoaError(.featureUnsupported) }
            let images: [[String: Any]] = attached ? [["image-path": request.diskURL.path,
                "system-entities": [["dev-entry": "/dev/disk88", "content-hint": "GUID_partition_scheme"]]]] : []
            let bytes = try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
            return .init(status: 0, stdout: bytes, stderr: Data())
        }
    }
    @Test("Interrupted attach is detached from durable intent without a VM boot")
    func cancellationCleanup() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = InterruptedAttach(fixture.request, failDetach: false)
        await #expect(throws: CancellationError.self) {
            try await Image.prepare(fixture.request, executor: { try await fake.execute($0) })
        }
        #expect(await fake.intentObserved)
        #expect(await fake.detached)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.request.workspaceURL.appendingPathComponent("receipt.json"))) as? [String: Any]
        let receipt = json?["receipt"] as? [String: Any]
        #expect(receipt?["pendingAttachmentImages"] as? [String] == [])
        #expect(receipt?["completed"] as? Bool == false)
    }
    @Test("Failed detach exposes pending image ownership and prevents success")
    func failedDetach() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = InterruptedAttach(fixture.request, failDetach: true)
        do {
            _ = try await Image.prepare(fixture.request, executor: { try await fake.execute($0) })
            Issue.record("Preparation unexpectedly succeeded")
        } catch let error as Image.Failure {
            #expect(error.pendingAttachmentImages == [fixture.request.diskURL.path])
        }
    }
    @Test("Unconfirmed child termination prevents detach and all retry commands")
    func unconfirmedTermination() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = InterruptedAttach(fixture.request, failDetach: false, unconfirmed: true)
        do {
            _ = try await Image.prepare(fixture.request, executor: { try await fake.execute($0) })
            Issue.record("Expected unresolved process failure")
        } catch let failure as Image.Failure {
            #expect(failure.processTerminationUnconfirmed)
            #expect(failure.pendingAttachmentImages == [fixture.request.diskURL.path])
        }
        #expect(await fake.commandCount == 2) // pre-attach info, then attach; no detach/info afterward
        #expect(await fake.detached == false)
        let retry = InterruptedAttach(fixture.request, failDetach: false)
        await #expect(throws: Image.Failure.self) {
            try await Image.prepare(fixture.request, executor: { try await retry.execute($0) })
        }
        #expect(await retry.commandCount == 0)
    }

    @Test("Untrusted receipt attachment intents execute no host commands")
    func unauthorizedReceipt() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let setup = InterruptedAttach(fixture.request, failDetach: false)
        await #expect(throws: CancellationError.self) {
            try await Image.prepare(fixture.request, executor: { try await setup.execute($0) })
        }
        let path = fixture.request.workspaceURL.appendingPathComponent("receipt.json")
        let original = try Data(contentsOf: path)
        for pending in [["/private/tmp/unrelated.dmg"],
                        [fixture.request.diskURL.path, fixture.request.diskURL.path],
                        [fixture.request.workspaceURL.path + "/../unrelated.dmg"]] {
            var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            var receipt = try #require(json["receipt"] as? [String: Any])
            receipt["pendingAttachmentImages"] = pending
            json["receipt"] = receipt
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            let probe = InterruptedAttach(fixture.request, failDetach: false)
            await #expect(throws: Image.Failure.self) {
                try await Image.prepare(fixture.request, executor: { try await probe.execute($0) })
            }
            #expect(await probe.commandCount == 0)
        }
    }

    @Test("Known interrupted copies rebuild atomically from the preserved source")
    func interruptedCopies() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.request.artifacts.executableURL
        let destination = fixture.request.workspaceURL.appendingPathComponent("original.dmg")
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        try Data("interrupted backup".utf8).write(to: destination)
        try Data("interrupted temporary copy".utf8).write(to: partial)
        let original = try Data(contentsOf: source)
        try Image.copyVerified(source, to: destination, expected: fixture.request.executableSHA256, mode: 0o600)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try Image.copyVerified(source, to: destination, expected: fixture.request.executableSHA256, mode: 0o600)
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("Post-rename retry recognizes prepared bytes before journal completion")
    func atomicReplacementRecovery() throws {
        let original = String(repeating: "a", count: 64), prepared = String(repeating: "b", count: 64)
        #expect(try Image.backingState(current: original, original: original, prepared: "") == .original)
        #expect(try Image.backingState(current: prepared, original: original, prepared: prepared) == .prepared)
        #expect(throws: Error.self) { try Image.backingState(current: String(repeating: "c", count: 64), original: original, prepared: prepared) }
    }

    @Test("Completed admission is read-only and rejects a reattached image")
    func completedAdmission() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = InterruptedAttach(fixture.request, failDetach: false)
        await #expect(throws: CancellationError.self) {
            try await Image.prepare(fixture.request, executor: { try await fake.execute($0) })
        }
        let path = fixture.request.workspaceURL.appendingPathComponent("receipt.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var receipt = try #require(json["receipt"] as? [String: Any])
        receipt["completed"] = true
        receipt["relativeImagePath"] = "11111111-1111-4111-8111-111111111111/usr/standalone/firmware/arm64eBaseSystem.dmg"
        receipt["originalSHA256"] = String(repeating: "b", count: 64)
        receipt["imageSHA256"] = String(repeating: "c", count: 64)
        json["receipt"] = receipt
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let completed = try await Image.validateCompleted(fixture.request, executor: { try await fake.execute($0) })
        #expect(completed.completed)
        let request = fixture.request
        let wrongVM = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: UUID(), sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: request.credentialSHA256, manifestSHA256: request.manifestSHA256)
        let wrongSession = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: request.vmID, sessionID: UUID(),
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: request.credentialSHA256, manifestSHA256: request.manifestSHA256)
        let wrongDigest = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: request.vmID, sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: String(repeating: "f", count: 64), credentialSHA256: request.credentialSHA256, manifestSHA256: request.manifestSHA256)
        let wrongManifest = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: request.vmID, sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: request.credentialSHA256, manifestSHA256: String(repeating: "d", count: 64))
        let wrongWorkspace = Image.Request(diskURL: request.diskURL, workspaceURL: fixture.root, vmID: request.vmID, sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: request.credentialSHA256, manifestSHA256: request.manifestSHA256)
        let wrongCredential = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: request.vmID, sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: String(repeating: "e", count: 64), manifestSHA256: request.manifestSHA256)
        for wrong in [wrongVM, wrongSession, wrongDigest, wrongManifest, wrongWorkspace, wrongCredential] {
            await #expect(throws: Image.Failure.self) {
                try await Image.validateCompleted(wrong, executor: { try await fake.execute($0) })
            }
        }
        #expect(try Data(contentsOf: path) == bytes)
        await fake.exposeAttachment()
        await #expect(throws: Image.Failure.self) {
            try await Image.validateCompleted(fixture.request, executor: { try await fake.execute($0) })
        }
        #expect(try Data(contentsOf: path) == bytes)
    }


    private actor BackingHost {
        let request: Image.Request
        let relative: String
        var backing: Data
        var attached = false
        var interruptDetach = false
        var interruptMount = false
        var seedAdjacent = false
        var adjacentAbsentAtDetach = false
        var companion: Data?
        var imagePresent = true
        var commands = 0
        var mounts: [[String]] = []
        init(_ request: Image.Request, relative: String, backing: Data) {
            self.request = request; self.relative = relative; self.backing = backing
        }
        func interruptNextDetach() { interruptDetach = true }
        func interruptNextMount() { interruptMount = true }
        func replaceBacking(_ data: Data) { backing = data }
        func addCompanion(_ data: Data) { companion = data }
        func removeImage() { imagePresent = false }
        func seedInterruptedAdjacent() { seedAdjacent = true }
        func bytes() -> Data { backing }
        func commandCount() -> Int { commands }
        func mountArguments() -> [[String]] { mounts }
        func execute(_ command: Image.Command) throws -> Image.CommandResult {
            commands += 1
            let mount = request.workspaceURL.appendingPathComponent("recovery")
            let image = mount.appendingPathComponent(relative)
            var response: [String: Any] = [:]
            switch (command.executable, command.arguments.first ?? "") {
            case ("/usr/bin/hdiutil", "info"):
                response = ["images": attached ? [["image-path": request.diskURL.path, "system-entities": [["dev-entry": "/dev/disk80", "content-hint": "GUID_partition_scheme"]]]] : []]
            case ("/usr/bin/hdiutil", "attach"):
                attached = true
                response = ["system-entities": [["dev-entry": "/dev/disk80"], ["dev-entry": "/dev/disk80s2"]]]
            case ("/usr/sbin/diskutil", "apfs"):
                response = ["Containers": [["PhysicalStores": [["DeviceIdentifier": "disk80s2"]], "Volumes": [
                    ["DeviceIdentifier": "disk81s1", "Roles": ["System"]],
                    ["DeviceIdentifier": "disk81s2", "Roles": ["Data"]],
                    ["DeviceIdentifier": "disk81s3", "Roles": ["Recovery"]]
                ]]]]
            case ("/usr/sbin/diskutil", "mount"):
                if interruptMount { interruptMount = false; throw CocoaError(.fileReadUnknown) }
                mounts.append(command.arguments)
                let firmware = image.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: firmware, withIntermediateDirectories: true)
                if imagePresent { try backing.write(to: image) }
                if let companion { try companion.write(to: firmware.appendingPathComponent("iBoot.img4")) }
                if seedAdjacent {
                    seedAdjacent = false
                    let name = ".pomme-experimental-" + request.vmID.uuidString.lowercased() + ".dmg"
                    for suffix in ["", ".partial"] {
                        try Data("interrupted adjacent".utf8).write(to: firmware.appendingPathComponent(name + suffix))
                    }
                }
            case ("/usr/sbin/diskutil", "info"):
                response = ["DeviceIdentifier": "disk81s3", "MountPoint": mount.path]
            case ("/usr/bin/hdiutil", "detach"):
                if interruptDetach {
                    interruptDetach = false
                    throw CocoaError(.fileWriteUnknown)
                }
                if FileManager.default.fileExists(atPath: image.path) {
                    backing = try Data(contentsOf: image)
                    let name = ".pomme-experimental-" + request.vmID.uuidString.lowercased() + ".dmg"
                    adjacentAbsentAtDetach = [name, name + ".partial"].allSatisfy {
                        !FileManager.default.fileExists(atPath: image.deletingLastPathComponent().appendingPathComponent($0).path)
                    }
                }
                if FileManager.default.fileExists(atPath: mount.path) {
                    for entry in try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil) {
                        try FileManager.default.removeItem(at: entry)
                    }
                }
                attached = false
            default: throw CocoaError(.featureUnsupported)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: response, format: .xml, options: 0)
            return .init(status: 0, stdout: data, stderr: Data())
        }
    }

    private let relative = "11111111-1111-4111-8111-111111111111/usr/standalone/firmware/arm64eBaseSystem.dmg"
    private let original = Data("stock recovery".utf8)
    private let prepared = Data("modified recovery".utf8)
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func updateReceipt(_ fixture: Fixture, _ fields: [String: Any]) throws {
        let path = fixture.request.workspaceURL.appendingPathComponent("receipt.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var receipt = try #require(json["receipt"] as? [String: Any])
        for (key, value) in fields { receipt[key] = value }
        json["receipt"] = receipt
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// A completed receipt whose last selection is `active`, with the
    /// retained copies that preparation leaves. A nil selection is a legacy
    /// receipt, which used Recovery.
    private func completedFixture(active: Image.BackingMode?, retain: Set<String> = ["original.dmg", "prepared.dmg"]) async throws -> Fixture {
        let fixture = try Fixture()
        let setup = InterruptedAttach(fixture.request, failDetach: false)
        await #expect(throws: CancellationError.self) {
            try await Image.prepare(fixture.request, executor: { try await setup.execute($0) })
        }
        var fields: [String: Any] = ["completed": true, "relativeImagePath": relative,
                                     "originalSHA256": hash(original), "imageSHA256": hash(prepared)]
        if let active { fields["activeBacking"] = active.rawValue }
        try updateReceipt(fixture, fields)
        for (name, data) in [("original.dmg", original), ("prepared.dmg", prepared)] where retain.contains(name) {
            let url = fixture.request.workspaceURL.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return fixture
    }

    @Test("Backing activation switches both modes, reconciles interrupted switches, and upgrades legacy receipts")
    func backingActivation() async throws {
        // Legacy completed receipts recorded no selection and deleted prepared.dmg.
        let fixture = try await completedFixture(active: nil, retain: ["original.dmg"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.request.workspaceURL
        let preparedPartial = workspace.appendingPathComponent("prepared.dmg.partial")
        try Data("interrupted legacy retention".utf8).write(to: preparedPartial)
        let host = BackingHost(fixture.request, relative: relative, backing: prepared)
        let normal = try await Image.activate(fixture.request, mode: .normal, executor: { try await host.execute($0) })
        #expect(normal.completed && normal.activeBacking == .normal && normal.desiredBacking == nil)
        #expect(await host.bytes() == original)
        #expect(!FileManager.default.fileExists(atPath: preparedPartial.path))
        #expect(try Data(contentsOf: workspace.appendingPathComponent("prepared.dmg")) == prepared)
        let mounts = await host.mountArguments()
        #expect(!mounts.isEmpty && mounts.allSatisfy { $0.contains("nobrowse") })

        // An interrupted switch keeps its intent, so the next activation
        // reconciles it and removes only its own staging names.
        try updateReceipt(fixture, ["desiredBacking": "recovery"])
        try Data("interrupted redundant copy".utf8).write(to: preparedPartial)
        await host.seedInterruptedAdjacent()
        _ = try await Image.activate(fixture.request, mode: .normal, executor: { try await host.execute($0) })
        #expect(await host.bytes() == original)
        #expect(await host.adjacentAbsentAtDetach)
        #expect(!FileManager.default.fileExists(atPath: preparedPartial.path))
        await #expect(throws: Image.Failure.self) {
            try await Image.validateCompleted(fixture.request, expectedMode: .recovery, executor: { try await host.execute($0) })
        }
        await host.interruptNextMount()
        await #expect(throws: Error.self) {
            try await Image.activate(fixture.request, mode: .recovery, executor: { try await host.execute($0) })
        }
        #expect(await host.bytes() == original)
        await #expect(throws: Image.Failure.self) {
            try await Image.validateCompleted(fixture.request, expectedMode: .normal, executor: { try await host.execute($0) })
        }
        await host.interruptNextDetach()
        await #expect(throws: Error.self) {
            try await Image.activate(fixture.request, mode: .recovery, executor: { try await host.execute($0) })
        }
        #expect(await host.bytes() == prepared) // Rename succeeded; receipt still carries intent.
        await #expect(throws: Image.Failure.self) {
            try await Image.validateCompleted(fixture.request, executor: { try await host.execute($0) })
        }
        let recovery = try await Image.prepare(fixture.request, executor: { try await host.execute($0) })
        #expect(recovery.completed && recovery.activeBacking == .recovery && recovery.desiredBacking == nil)
        _ = try await Image.validateCompleted(fixture.request, expectedMode: .recovery, executor: { try await host.execute($0) })
    }

    @Test("A completed selection attaches nothing, and a saved state refuses a switch")
    func completedSelection() async throws {
        let fixture = try await completedFixture(active: .normal)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = BackingHost(fixture.request, relative: relative, backing: original)
        let receipt = try await Image.activate(fixture.request, mode: .normal, executor: { try await host.execute($0) })
        #expect(receipt.activeBacking == .normal && receipt.desiredBacking == nil)
        _ = try await Image.activate(fixture.request, mode: .normal, preservingDisk: true, executor: { try await host.execute($0) })
        await #expect(throws: Image.Failure.self) {
            try await Image.activate(fixture.request, mode: .recovery, preservingDisk: true, executor: { try await host.execute($0) })
        }
        #expect(await host.commandCount() == 0)
        // The refusal leaves boot admission open for the selected mode.
        _ = try await Image.validateCompleted(fixture.request, expectedMode: .normal, executor: { try await host.execute($0) })
        #expect(await host.bytes() == original)
    }

    @Test("A Recovery image that the guest replaced retires both retained copies", arguments: ["bytes", "companions", "missing"])
    func replacedRecovery(change: String) async throws {
        let fixture = try await completedFixture(active: .normal)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let updated = Data("updated recovery".utf8)
        let host = BackingHost(fixture.request, relative: relative, backing: change == "bytes" ? updated : original)
        if change == "companions" { await host.addCompanion(Data("updated firmware".utf8)) }
        if change == "missing" { await host.removeImage() }
        let receipt = try await Image.activate(fixture.request, mode: .recovery, executor: { try await host.execute($0) })
        #expect(receipt.recoveryReplaced == true && receipt.activeBacking == .normal && receipt.desiredBacking == nil)
        #expect(await host.bytes() == (change == "bytes" ? updated : original))
        for name in ["original.dmg", "prepared.dmg"] {
            #expect(!FileManager.default.fileExists(atPath: fixture.request.workspaceURL.appendingPathComponent(name).path))
        }
        let commands = await host.commandCount()
        for mode in [Image.BackingMode.normal, .recovery] {
            _ = try await Image.activate(fixture.request, mode: mode, executor: { try await host.execute($0) })
        }
        #expect(await host.commandCount() == commands)
        let admitted = try await Image.validateCompleted(fixture.request, expectedMode: .recovery, executor: { try await host.execute($0) })
        #expect(admitted.recoveryReplaced == true)
    }

    @Test("Changed companions beside the prepared image fail closed")
    func preparedCompanionChange() async throws {
        let fixture = try await completedFixture(active: .normal)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = BackingHost(fixture.request, relative: relative, backing: prepared)
        await host.addCompanion(Data("unexpected firmware".utf8))
        await #expect(throws: Image.Failure.self) {
            try await Image.activate(fixture.request, mode: .recovery, executor: { try await host.execute($0) })
        }
        #expect(try Image.receipt(fixture.request).recoveryReplaced != true)
        #expect(FileManager.default.fileExists(atPath: fixture.request.workspaceURL.appendingPathComponent("prepared.dmg").path))
        #expect(await host.bytes() == prepared)
    }

    @Test("A missing retained copy blocks only the switch that needs it")
    func missingRetainedCopy() async throws {
        let fixture = try await completedFixture(active: .recovery, retain: ["original.dmg"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = BackingHost(fixture.request, relative: relative, backing: original)
        let normal = try await Image.activate(fixture.request, mode: .normal, executor: { try await host.execute($0) })
        #expect(normal.activeBacking == .normal)
        await #expect(throws: Image.Failure.self) {
            try await Image.activate(fixture.request, mode: .recovery, executor: { try await host.execute($0) })
        }
        #expect(await host.bytes() == original) // Cannot invent a missing prepared image from stock bytes.
    }

    @Test("A completed receipt needs no staged credential, and a staged one must match Keychain")
    func stagedCredentialLifetime() async throws {
        let fixture = try await completedFixture(active: .normal)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let token = fixture.request.artifacts.tokenURL
        try FileManager.default.removeItem(at: token)
        let host = BackingHost(fixture.request, relative: relative, backing: original)
        _ = try await Image.validateCompleted(fixture.request, expectedMode: .normal, executor: { try await host.execute($0) })
        #expect(try Image.receipt(fixture.request).completed)
        // Boot selection omits the credential, so it doesn't read Keychain.
        let request = fixture.request
        let unbound = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: request.vmID, sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: nil, manifestSHA256: request.manifestSHA256)
        _ = try await Image.validateCompleted(unbound, expectedMode: .normal, executor: { try await host.execute($0) })
        _ = try await Image.activate(unbound, mode: .normal, executor: { try await host.execute($0) })
        #expect(FileManager.default.createFile(atPath: token.path, contents: Data("other credential".utf8), attributes: [.posixPermissions: 0o600]))
        #expect(throws: Image.Failure.self) { try Image.receipt(fixture.request) }
        #expect(throws: Image.Failure.self) { try Image.receipt(unbound) }
    }

    @Test("Preparation can't start without the resident credential")
    func preparationRequiresCredential() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = fixture.request
        try FileManager.default.removeItem(at: request.artifacts.tokenURL)
        let unbound = Image.Request(diskURL: request.diskURL, workspaceURL: request.workspaceURL, vmID: request.vmID, sessionID: request.sessionID,
            artifacts: request.artifacts, executableSHA256: request.executableSHA256, credentialSHA256: nil, manifestSHA256: request.manifestSHA256)
        let probe = InterruptedAttach(unbound, failDetach: false)
        await #expect(throws: Image.Failure.self) {
            try await Image.prepare(unbound, executor: { try await probe.execute($0) })
        }
        #expect(await probe.commandCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: request.workspaceURL.path).isEmpty)
    }
}
