import Foundation
import Testing

@Suite("Pomme live Recovery composition")
struct PommeLiveRecoveryIntegrationTests {
    @Test("Launcher mounts before invoking the staged script and carries only the bounded binding")
    func launcherCommandAndScript() throws {
        let issuedAt = Date(timeIntervalSince1970: 10_000)
        let credential = try PommeRecoveryCredential(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            secret: Data(repeating: 0x42, count: 32),
            expiresAt: issuedAt.addingTimeInterval(60)
        )
        let request = try PommeRecoverySessionRequest(
            requestID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            vmUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            operation: .sip(.disable),
            issuedAt: issuedAt,
            expiresAt: credential.expiresAt,
            executableSHA256: String(repeating: "a", count: 64),
            payloadSHA256: PommeRecoveryCrypto.sha256(Data("security".utf8)),
            requestedFinalState: .previous,
            credential: credential
        )

        let launcher = try PommeLiveRecoveryIntegration.Launcher(request: request)
        #expect(!launcher.command.contains("(tag)"))
        #expect(!launcher.command.contains("(workspace)"))
        for placeholder in ["(agent)", "(requestFile)", "(credential)", "(expiry)", "(vm)", "(session)", "(operation)"] {
            #expect(!launcher.script.contains(placeholder))
        }
        #expect(launcher.command.contains("/sbin/mount_virtiofs -r \(launcher.tag)"))
        #expect(launcher.command.contains("/bin/cp \"$d/m/\(PommeRecoveryArtifactNames.launcher)\" \"$d/run\""))
        #expect(launcher.command.contains("/bin/sh \"$d/run\""))
        #expect(launcher.script.contains("codesign --verify --strict --all-architectures"))
        #expect(launcher.script.contains("shasum -a 256"))
        #expect(launcher.script.contains("--pomme-agent 505053"))
        #expect(launcher.script.contains("--one-shot-expiry 10060"))
        #expect(launcher.script.contains("--vm-id 99999999-8888-7777-6666-555555555555"))
        #expect(launcher.script.contains("--session-id aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        #expect(launcher.script.contains("--operation sip.disable"))
        #expect(launcher.script.contains("--request-file \"$g/request.json\""))
        #expect(launcher.script.contains("printf '%s\\n' '\(launcher.completionMarker)'"))
        #expect(!launcher.command.contains(credential.sha256))
        #expect(!launcher.script.contains(credential.sha256))
        #expect(PommeRecoveryTerminalCommand.isKeyboardSafe(launcher.command))
    }

    @Test("Install launcher uses the bootstrap port and private workspace contract")
    func installLauncherContract() throws {
        let issuedAt = Date(timeIntervalSince1970: 20_000)
        let credential = try PommeRecoveryCredential(
            secret: Data(repeating: 0x33, count: 32),
            expiresAt: issuedAt.addingTimeInterval(30)
        )
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!,
            operation: .installAgent,
            issuedAt: issuedAt,
            expiresAt: credential.expiresAt,
            executableSHA256: String(repeating: "b", count: 64),
            payloadSHA256: PommeRecoveryCrypto.sha256(Data("plan".utf8)),
            requestedFinalState: .stopped,
            credential: credential
        )

        let launcher = try PommeLiveRecoveryIntegration.Launcher(request: request)
        #expect(launcher.listenerPort == 505052)
        #expect(launcher.script.contains("--pomme-agent 505052"))
        #expect(launcher.script.contains("--operation agent.install"))
        #expect(launcher.privateWorkspacePath == "/private/var/tmp/pomme-recovery-\(request.requestID.uuidString.lowercased())")
        #expect(launcher.guestStagingPath == launcher.privateWorkspacePath)
    }

    @Test("Factory creates a fresh request binding from each payload and final state")
    func requestBindingIsLazyAndExact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-live-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let executableURL = root.appendingPathComponent("pomme")
        let executableData = Data("signed-pomme-agent-test".utf8)
        #expect(FileManager.default.createFile(atPath: executableURL.path, contents: executableData, attributes: [.posixPermissions: 0o555]))
        let digest = PommeProvisioningDigest.sha256(executableData)
        let ownership = try PommeVMOwnership(
            name: "demo",
            uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            bundlePath: root.path
        )
        let identity = try PommeLiveRecoveryIntegration.VMIdentity(ownership: ownership)
        let executable = try PommeLiveRecoveryIntegration.ExecutableIdentity(url: executableURL, sha256: digest)
        let reference = VMReference(name: "demo", bundle: BundleLayout(rootURL: root))
        let recorder = RequestRecorder()
        let now = Date(timeIntervalSince1970: 30_000)
        let credentialID = UUID(uuidString: "11111111-aaaa-bbbb-cccc-222222222222")!
        let factory = PommeLiveRecoveryIntegration.factory(
            dependencies: .init(
                resolveVM: { _ in identity },
                resolveExecutable: { _ in executable },
                makeRuntime: { _, request, _, _ in
                    await recorder.append(request)
                    throw IntegrationProbe.stopBeforeRuntime
                },
                stagingParent: { _ in root },
                recoveryProfileEvidence: { _ in
                    .init(build: .tahoe2660Build25G72, locale: .english, geometry: .pixels1280x800, privateHostABI: .qualifiedRecoveryInputV1, manifestHash: .tahoe2660Build25G72, ownership: .verified)
                },
                persistentAgentSecret: { _ in String(repeating: "a", count: 64) },
                issueCredential: { input in
                    try PommeRecoveryCredential(
                        id: credentialID,
                        secret: Data(repeating: 0x61, count: 32),
                        expiresAt: input.context.issuedAt.addingTimeInterval(60)
                    )
                },
                stagingBuilder: .init(dependencies: .init(verifyCodeSignature: { _ in })),
                now: { now },
                credentialLifetime: 60,
                authenticationTimeout: 1
            )
        )
        let integration = try await factory.make(reference: reference, operation: .sip(.disable))
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)

        await #expect(throws: IntegrationProbe.stopBeforeRuntime) {
            try await integration.sip(action: .disable, payload: firstPayload, finalState: .stopped)
        }
        await #expect(throws: IntegrationProbe.stopBeforeRuntime) {
            try await integration.sip(action: .disable, payload: secondPayload, finalState: .normal)
        }

        let requests = await recorder.values
        #expect(requests.count == 2)
        #expect(requests[0].payloadSHA256 == PommeRecoveryCrypto.sha256(firstPayload))
        #expect(requests[1].payloadSHA256 == PommeRecoveryCrypto.sha256(secondPayload))
        #expect(requests[0].requestedFinalState == VMFinalState.stopped.rawValue)
        #expect(requests[1].requestedFinalState == VMFinalState.normal.rawValue)
        #expect(requests[0].requestID != requests[1].requestID)
    }
}

private enum IntegrationProbe: Error, Equatable, Sendable {
    case stopBeforeRuntime
}

private actor RequestRecorder {
    private(set) var values: [PommeRecoverySessionRequest] = []

    func append(_ request: PommeRecoverySessionRequest) {
        values.append(request)
    }
}
