import CryptoKit
import Darwin
import Foundation
import Security
@preconcurrency import Virtualization

/// Errors from the terminal bootstrap deliberately contain no paths, request
/// payloads, or credential material. A Recovery session is one-shot, so an
/// uncertain failure is terminal until its caller has completed cleanup.
enum PommeRecoveryVirtioFSBootstrapError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput
    case sourceRejected
    case signatureRejected
    case digestRejected
    case cleanupFailed
    case shareReleaseFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "Recovery VirtioFS bootstrap input was rejected."
        case .sourceRejected:
            "Recovery VirtioFS bootstrap executable was rejected."
        case .signatureRejected:
            "Recovery VirtioFS bootstrap executable signature was rejected."
        case .digestRejected:
            "Recovery VirtioFS bootstrap executable digest was rejected."
        case .cleanupFailed:
            "Recovery VirtioFS bootstrap cleanup could not be proven complete."
        case .shareReleaseFailed:
            "Recovery VirtioFS bootstrap share release could not be verified."
        }
    }
}

/// The binding is kept separate from a display name or bundle path. Both
/// values are required when a bounded Recovery listener authenticates.
struct PommeRecoveryVirtioFSBinding: Equatable, Sendable {
    let vmUUID: UUID
    let requestID: UUID
}

struct PommeRecoveryVirtioFSCapabilityProbe: Equatable, Sendable {
    let command: String
    let marker: String
}

/// All text sent through Recovery Terminal is bounded and checked against the
/// host keyboard map. The long launcher remains on the read-only share;
/// Terminal receives only the short command that mounts the exact tag and
/// copies that launcher into the request workspace.
struct PommeRecoveryVirtioFSTerminalPlan: Equatable, Sendable {
    static let maximumCommandLength = 256
    static let maximumTagLength = 35

    let capabilityProbes: [PommeRecoveryVirtioFSCapabilityProbe]
    let commands: [String]
    let binding: PommeRecoveryVirtioFSBinding
    let tag: String
    let mountWorkspacePath: String
    let guestWorkspacePath: String
    let runScriptPath: String
    let requestSHA256: String
    let completionMarker: String
    let launcherScript: String

    /// Convenience projections for the Recovery composition layer.
    /// These names describe this Pomme plan only; none contains credential
    /// material or a path to the persistent normal-agent installation.
    var command: String { commands[0] }
    var script: String { launcherScript }
    var mountedPath: String { "\(mountWorkspacePath)/m" }
    var privateWorkspacePath: String { guestWorkspacePath }
    var guestStagingPath: String { guestWorkspacePath }
    var guestTokenPath: String { "\(guestWorkspacePath)/\(PommeRecoveryArtifactNames.credential)" }
    var listenerPort: UInt32 { requestListenerPort }
    var expiresAt: Date { requestExpiresAt }
    var vmID: UUID { binding.vmUUID }
    var sessionID: UUID { binding.requestID }

    private let requestListenerPort: UInt32
    private let requestExpiresAt: Date

    init(request: PommeRecoverySessionRequest) throws {
        guard request.isWellFormed,
              let operation = PommeRecoveryOperation(wireName: request.operation),
              operation.listenerPort.rawValue == request.listenerPort,
              Self.isSHA256(request.executableSHA256)
        else { throw PommeRecoveryVirtioFSBootstrapError.invalidInput }

        let binding = PommeRecoveryVirtioFSBinding(
            vmUUID: request.vmUUID,
            requestID: request.requestID
        )
        let compactRequestID = request.requestID.uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        let shortID = String(compactRequestID.prefix(24))
        let mountWorkspace = "/private/var/run/.pomme-vfs-\(shortID)"
        let guestWorkspace = "/private/var/tmp/pomme-recovery-\(request.requestID.uuidString.lowercased())"
        let runScript = "\(mountWorkspace)/run"
        let tag = PommeRecoveryVirtioFSBootstrapBuilder.tag(for: request.requestID)
        guard Self.validTag(tag), tag.utf8.count <= Self.maximumTagLength else {
            throw PommeRecoveryVirtioFSBootstrapError.invalidInput
        }

        let requestData = try Self.canonicalRequestData(request)
        let requestSHA256 = PommeRecoveryCrypto.sha256(requestData)
        let marker = "POMME \(Self.ocrSafeMarkerSuffix(requestID: request.requestID)) OK"
        let probe = "test -x /sbin/mount_virtiofs&&test -x /sbin/umount&&test -x /usr/bin/codesign&&printf 'POMME %s OK\\n' \(Self.ocrSafeMarkerSuffix(requestID: request.requestID))"
        // The mount point is intentionally nested below a new directory. A
        // pre-existing directory or symlink makes this command fail closed.
        let launch = "d=\(mountWorkspace);umask 077;/bin/mkdir -m 700 \"$d\" \"$d/m\"&&/sbin/mount_virtiofs -r \(tag) \"$d/m\"&&/bin/cp \"$d/m/\(PommeRecoveryArtifactNames.launcher)\" \"$d/run\"&&/bin/sh \"$d/run\""
        guard Self.keyboardSafe(probe),
              Self.keyboardSafe(launch),
              probe.utf8.count <= Self.maximumCommandLength,
              launch.utf8.count <= Self.maximumCommandLength
        else { throw PommeRecoveryVirtioFSBootstrapError.invalidInput }

        capabilityProbes = [.init(command: probe, marker: marker)]
        commands = [launch]
        self.binding = binding
        self.tag = tag
        mountWorkspacePath = mountWorkspace
        guestWorkspacePath = guestWorkspace
        runScriptPath = runScript
        self.requestSHA256 = requestSHA256
        completionMarker = marker
        requestListenerPort = request.listenerPort
        requestExpiresAt = request.expiresAt
        launcherScript = Self.launcherScript(
            request: request,
            binding: binding,
            mountWorkspacePath: mountWorkspace,
            guestWorkspacePath: guestWorkspace,
            requestSHA256: requestSHA256,
            completionMarker: marker
        )
    }

    private static func canonicalRequestData(_ request: PommeRecoverySessionRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    private static func launcherScript(
        request: PommeRecoverySessionRequest,
        binding: PommeRecoveryVirtioFSBinding,
        mountWorkspacePath: String,
        guestWorkspacePath: String,
        requestSHA256: String,
        completionMarker: String
    ) -> String {
        let expiry = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            request.expiresAt.timeIntervalSince1970
        )
        let digest = request.executableSHA256
        let vmID = binding.vmUUID.uuidString.lowercased()
        let sessionID = binding.requestID.uuidString.lowercased()
        // Values interpolated here come only from the validated request or
        // fixed paths. No credential or operation payload is included.
        return #"""
#!/bin/sh
set -eu
umask 077
d='\#(mountWorkspacePath)'
m="$d/m"
g='\#(guestWorkspacePath)'

# Cleanup is deliberately limited to the exact request-bound paths and the
# three files the launcher is allowed to stage. The daemon is run in the
# foreground below, so this trap never removes a workspace while its process
# can still be using it.
cleanup_known_guest_workspace() {
  if test -e "$g" || test -L "$g"; then
    test -d "$g" && test ! -L "$g" || return 64
    test "$(/usr/bin/stat -f '%u:%Lp' "$g")" = 0:700 || return 64
    for n in "$g"/* "$g"/.[!.]* "$g"/..?*; do
      if test -e "$n" || test -L "$n"; then
        case "$n" in
          "$g/pomme-agent"|"$g/request.json"|"$g/session.credential") : ;;
          *) return 64 ;;
        esac
      fi
    done
    for n in pomme-agent request.json session.credential; do
      f="$g/$n"
      if test -e "$f" || test -L "$f"; then
        test -f "$f" && test ! -L "$f" || return 64
        case "$n" in
          pomme-agent) mode='0:555' ;;
          *) mode='0:400' ;;
        esac
        test "$(/usr/bin/stat -f '%u:%Lp' "$f")" = "$mode" || return 64
        /bin/rm -f -- "$f" || return 64
      fi
    done
    /bin/rmdir "$g" || return 64
  fi
  test ! -e "$g" && test ! -L "$g"
}

cleanup_known_mount_workspace() {
  if test -e "$d" || test -L "$d"; then
    test -d "$d" && test ! -L "$d" || return 64
    test "$(/usr/bin/stat -f '%u:%Lp' "$d")" = 0:700 || return 64
    for n in "$d"/* "$d"/.[!.]* "$d"/..?*; do
      if test -e "$n" || test -L "$n"; then
        case "$n" in
          "$d/m"|"$d/run") : ;;
          *) return 64 ;;
        esac
      fi
    done
    if test -e "$m" || test -L "$m"; then
      test -d "$m" && test ! -L "$m" || return 64
      /sbin/umount "$m" >/dev/null 2>&1
      /bin/rmdir "$m" || return 64
      test ! -e "$m" && test ! -L "$m" || return 64
    fi
    if test -e "$d/run" || test -L "$d/run"; then
      test -f "$d/run" && test ! -L "$d/run" || return 64
      /bin/rm -f -- "$d/run" || return 64
    fi
    /bin/rmdir "$d" || return 64
  fi
  test ! -e "$d" && test ! -L "$d"
}

cleanup_on_exit() {
  status=$?
  trap - EXIT
  set +e
  cleanup_known_mount_workspace
  mount_status=$?
  cleanup_known_guest_workspace
  guest_status=$?
  if test "$mount_status" -ne 0 || test "$guest_status" -ne 0; then
    exit 64
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT

test "$(/usr/bin/id -u)" = 0
test -d "$d" && test ! -L "$d"
test "$(/usr/bin/stat -f '%u:%Lp' "$d")" = 0:700
test -d "$m" && test ! -L "$m"
for n in pomme-agent pomme-recovery-launcher request.json session.credential; do
  test -f "$m/$n" && test ! -L "$m/$n"
done
for n in "$m"/* "$m"/.[!.]* "$m"/..?*; do
  if test -e "$n" || test -L "$n"; then
    case "$n" in
      "$m/pomme-agent"|"$m/pomme-recovery-launcher"|"$m/request.json"|"$m/session.credential") : ;;
      *) exit 64 ;;
    esac
  fi
done
test ! -e "$g" && test ! -L "$g"
/bin/mkdir -m 700 "$g"
for n in pomme-agent request.json session.credential; do
  /bin/cp "$m/$n" "$g/$n"
done
/usr/sbin/chown 0:0 "$g" "$g/pomme-agent" "$g/request.json" "$g/session.credential"
/bin/chmod 700 "$g"
/bin/chmod 555 "$g/pomme-agent"
/bin/chmod 400 "$g/request.json" "$g/session.credential"
for n in pomme-agent request.json session.credential; do
  test ! -L "$g/$n"
done
test "$( /usr/bin/stat -f '%u:%Lp' "$g" )" = 0:700
test "$( /usr/bin/stat -f '%u:%Lp' "$g/pomme-agent" )" = 0:555
test "$( /usr/bin/stat -f '%u:%Lp' "$g/request.json" )" = 0:400
test "$( /usr/bin/stat -f '%u:%Lp' "$g/session.credential" )" = 0:400
/usr/bin/codesign --verify --strict --all-architectures "$g/pomme-agent"
test "$(/usr/bin/shasum -a 256 "$g/pomme-agent" | /usr/bin/awk '{print $1}')" = \#(digest)
test "$(/usr/bin/shasum -a 256 "$g/request.json" | /usr/bin/awk '{print $1}')" = \#(requestSHA256)
/sbin/umount "$m"
/bin/rmdir "$m"
test ! -e "$m" && test ! -L "$m"
/bin/rm -f "$d/run"
/bin/rmdir "$d"
test ! -e "$d" && test ! -L "$d"
"$g/pomme-agent" --pomme-agent \#(request.listenerPort) --token-file "$g/session.credential" --expected-sha256 \#(digest) --role recovery --one-shot-expiry \#(expiry) --vm-id \#(vmID) --session-id \#(sessionID) --operation \#(request.operation) --request-file "$g/request.json" </dev/null >/dev/null 2>&1
/usr/bin/printf '%s\n' '\#(completionMarker)'
"""#
    }

    private static func validTag(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
                || (0x61...0x7a).contains(scalar.value)
                || scalar.value == 0x2d
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func ocrSafeMarkerSuffix(requestID: UUID) -> String {
        let alphabet = Array("ACDEHJKMNPQRTUXY")
        return String(requestID.uuidString
            .filter { $0 != "-" }
            .prefix(10)
            .compactMap { nibble in
                Int(String(nibble), radix: 16).map { alphabet[$0] }
            })
    }

    private static func keyboardSafe(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e }
            && value.allSatisfy { HostDisplayKey.lookup(character: $0) != nil }
    }
}

struct PommeRecoveryVirtioFSBootstrapProof: Equatable, Sendable {
    let requestID: UUID
    let vmUUID: UUID
    let requestBound: Bool
    let readOnlyConfiguration: Bool
    let executableSignatureVerified: Bool
    let executableDigestVerified: Bool
    let requestDigestVerified: Bool
    let guestLauncherPrepared: Bool
    let shareRemoved: Bool
    let hostArtifactsRemoved: Bool

    var isComplete: Bool {
        requestBound
            && readOnlyConfiguration
            && executableSignatureVerified
            && executableDigestVerified
            && requestDigestVerified
            && guestLauncherPrepared
            && shareRemoved
            && hostArtifactsRemoved
    }
}

/// A request-bound read-only share plus the exact Terminal bootstrap plan.
/// The underlying staging builder performs descriptor-based source checks,
/// strict/all-architecture signature verification, fixed-name writes, and
/// symlink-resistant cleanup.
final class PommeRecoveryVirtioFSBootstrap: @unchecked Sendable {
    let request: PommeRecoverySessionRequest
    let terminalPlan: PommeRecoveryVirtioFSTerminalPlan
    let staging: PommeRecoveryStaging

    private let lock = NSLock()
    private var shareAndArtifactsRemoved = false

    init(
        request: PommeRecoverySessionRequest,
        terminalPlan: PommeRecoveryVirtioFSTerminalPlan,
        staging: PommeRecoveryStaging
    ) throws {
        guard request == staging.request,
              terminalPlan.binding.vmUUID == request.vmUUID,
              terminalPlan.binding.requestID == request.requestID,
              staging.proof.isComplete
        else { throw PommeRecoveryVirtioFSBootstrapError.invalidInput }
        self.request = request
        self.terminalPlan = terminalPlan
        self.staging = staging
    }

    var rootURL: URL { staging.rootURL }
    var deviceConfiguration: VZVirtioFileSystemDeviceConfiguration { staging.deviceConfiguration }
    var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] {
        staging.directorySharingDevices
    }

    func releaseShareAndRemoveHostArtifacts(
        from vm: VZVirtualMachine,
        on queue: DispatchQueue,
        authenticatedAgentConnected: Bool
    ) throws -> PommeRecoveryVirtioFSBootstrapProof {
        guard authenticatedAgentConnected else {
            throw PommeRecoveryVirtioFSBootstrapError.shareReleaseFailed
        }
        try staging.clearShare(from: vm, on: queue)
        try staging.removeHostArtifacts()
        guard !FileManager.default.fileExists(atPath: rootURL.path) else {
            throw PommeRecoveryVirtioFSBootstrapError.cleanupFailed
        }
        lock.withLock { shareAndArtifactsRemoved = true }
        return .init(
            requestID: request.requestID,
            vmUUID: request.vmUUID,
            requestBound: terminalPlan.binding.requestID == request.requestID
                && terminalPlan.binding.vmUUID == request.vmUUID,
            readOnlyConfiguration: staging.proof.readOnly,
            executableSignatureVerified: staging.proof.signatureVerified,
            executableDigestVerified: staging.proof.digestVerified,
            requestDigestVerified: terminalPlan.requestSHA256 == Self.requestSHA256(request),
            guestLauncherPrepared: !terminalPlan.launcherScript.isEmpty,
            shareRemoved: true,
            hostArtifactsRemoved: true
        )
    }

    func contain(from vm: VZVirtualMachine, on queue: DispatchQueue) throws {
        try staging.clearShare(from: vm, on: queue)
        try staging.removeHostArtifacts()
        guard !FileManager.default.fileExists(atPath: rootURL.path) else {
            throw PommeRecoveryVirtioFSBootstrapError.cleanupFailed
        }
        lock.withLock { shareAndArtifactsRemoved = true }
    }

    var hasBeenRemoved: Bool { lock.withLock { shareAndArtifactsRemoved } }

    private static func requestSHA256(_ request: PommeRecoverySessionRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(request) else { return "" }
        return PommeRecoveryCrypto.sha256(data)
    }
}

enum PommeRecoveryVirtioFSBootstrapConfiguration {
    static func directorySharingDevices(
        bootMode: BootMode,
        recoveryAgentEnabled: Bool,
        preparedBootstrap: PommeRecoveryVirtioFSBootstrap?
    ) throws -> [VZDirectorySharingDeviceConfiguration] {
        guard bootMode == .recovery, recoveryAgentEnabled else { return [] }
        guard let preparedBootstrap else {
            throw PommeRecoveryVirtioFSBootstrapError.invalidInput
        }
        guard preparedBootstrap.directorySharingDevices.count == 1 else {
            throw PommeRecoveryVirtioFSBootstrapError.invalidInput
        }
        return preparedBootstrap.directorySharingDevices
    }
}

struct PommeRecoveryVirtioFSBootstrapBuilder: Sendable {
    struct Input: Sendable {
        let request: PommeRecoverySessionRequest
        let signedExecutableURL: URL
        let credential: PommeRecoveryCredential
        let temporaryParentURL: URL
    }

    struct Dependencies: Sendable {
        var verifyCodeSignature: @Sendable (URL) throws -> Void
        var rootName: @Sendable () -> String

        init(
            verifyCodeSignature: @escaping @Sendable (URL) throws -> Void = Self.verifyCodeSignature,
            rootName: @escaping @Sendable () -> String = {
                "\(PommeRecoveryStagingBuilder.rootPrefix)\(UUID().uuidString.lowercased())"
            }
        ) {
            self.verifyCodeSignature = verifyCodeSignature
            self.rootName = rootName
        }

        private static func verifyCodeSignature(_ url: URL) throws {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecStaticCodeCheckValidity(
                      code,
                      SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                      nil
                  ) == errSecSuccess
            else { throw PommeRecoveryVirtioFSBootstrapError.signatureRejected }
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .init()) {
        self.dependencies = dependencies
    }

    func build(_ input: Input) throws -> PommeRecoveryVirtioFSBootstrap {
        guard input.request.isWellFormed,
              input.credential.matches(request: input.request),
              PommeRecoveryOperation(wireName: input.request.operation) != nil
        else { throw PommeRecoveryVirtioFSBootstrapError.invalidInput }

        let terminalPlan: PommeRecoveryVirtioFSTerminalPlan
        do { terminalPlan = try .init(request: input.request) }
        catch { throw PommeRecoveryVirtioFSBootstrapError.invalidInput }

        let staging: PommeRecoveryStaging
        do {
            staging = try PommeRecoveryStagingBuilder(dependencies: .init(
                verifyCodeSignature: dependencies.verifyCodeSignature,
                rootName: dependencies.rootName
            )).build(.init(
                request: input.request,
                signedExecutableURL: input.signedExecutableURL,
                launcherScript: terminalPlan.launcherScript,
                credential: input.credential,
                temporaryParentURL: input.temporaryParentURL
            ))
        } catch let error as PommeRecoveryStagingError {
            switch error {
            case .signatureRejected:
                throw PommeRecoveryVirtioFSBootstrapError.signatureRejected
            case .identityChanged:
                throw PommeRecoveryVirtioFSBootstrapError.digestRejected
            case .sourceRejected:
                throw PommeRecoveryVirtioFSBootstrapError.sourceRejected
            default:
                throw PommeRecoveryVirtioFSBootstrapError.invalidInput
            }
        } catch {
            throw PommeRecoveryVirtioFSBootstrapError.sourceRejected
        }

        do {
            return try PommeRecoveryVirtioFSBootstrap(
                request: input.request,
                terminalPlan: terminalPlan,
                staging: staging
            )
        } catch {
            try? staging.removeHostArtifacts()
            throw PommeRecoveryVirtioFSBootstrapError.invalidInput
        }
    }

    static func tag(for requestID: UUID) -> String {
        let compact = requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "pomme-\(compact.prefix(24))"
    }
}

/// Cleanup is a closed guest command. It accepts only the two request-bound
/// workspace paths and removes only the known artifact names, refusing
/// symlinks or unexpected entries. The caller executes this after the
/// Recovery daemon has been reaped.
enum PommeRecoveryVirtioFSBootstrapGuestCleanup {
    static func request(
        terminalPlan: PommeRecoveryVirtioFSTerminalPlan,
        timeout: TimeInterval
    ) -> GuestCommandRequest {
        let script = #"""
set -eu
remove_known() {
  d="$1"
  if test -e "$d" || test -L "$d"; then
    test -d "$d" && test ! -L "$d"
    for n in pomme-agent pomme-recovery-launcher request.json session.credential; do
      f="$d/$n"
      if test -e "$f" || test -L "$f"; then test -f "$f" && test ! -L "$f" && /bin/rm -f -- "$f"; fi
    done
    /bin/rmdir "$d"
  fi
}
remove_known "$1"
remove_known "$2"
test ! -e "$1" && test ! -L "$1"
test ! -e "$2" && test ! -L "$2"
"""#
        return GuestCommandRequest(
            path: "/bin/sh",
            arguments: [
                "-c", script, "pomme-recovery-vfs-cleanup",
                terminalPlan.guestWorkspacePath,
                terminalPlan.mountWorkspacePath
            ],
            timeout: timeout
        )
    }

    static func verifyRequest(
        terminalPlan: PommeRecoveryVirtioFSTerminalPlan,
        timeout: TimeInterval
    ) -> GuestCommandRequest {
        GuestCommandRequest(
            path: "/bin/sh",
            arguments: [
                "-c",
                "test ! -e \"$1\" && test ! -L \"$1\" && test ! -e \"$2\" && test ! -L \"$2\"",
                "pomme-recovery-vfs-cleanup-verify",
                terminalPlan.guestWorkspacePath,
                terminalPlan.mountWorkspacePath
            ],
            timeout: timeout
        )
    }

    static func run(
        terminalPlan: PommeRecoveryVirtioFSTerminalPlan,
        timeout: TimeInterval,
        execute: @escaping @Sendable (GuestCommandRequest) async throws -> GuestCommandResult
    ) async throws {
        guard timeout.isFinite, timeout > 0 else {
            throw PommeRecoveryVirtioFSBootstrapError.cleanupFailed
        }
        let removal = try await execute(request(terminalPlan: terminalPlan, timeout: timeout))
        guard closedSuccess(removal) else {
            throw PommeRecoveryVirtioFSBootstrapError.cleanupFailed
        }
        let absence = try await execute(verifyRequest(terminalPlan: terminalPlan, timeout: timeout))
        guard closedSuccess(absence) else {
            throw PommeRecoveryVirtioFSBootstrapError.cleanupFailed
        }
    }

    private static func closedSuccess(_ result: GuestCommandResult) -> Bool {
        result.exitCode == 0
            && result.signal == nil
            && result.stdout.isEmpty
            && result.stderr.isEmpty
            && !result.stdoutTruncated
            && !result.stderrTruncated
    }
}
