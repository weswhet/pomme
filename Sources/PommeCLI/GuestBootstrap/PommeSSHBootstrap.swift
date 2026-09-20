import CryptoKit
import Darwin
import Foundation

enum PommeSSHBootstrapError: Error, LocalizedError {
    case invalid
    case processLaunchFailed, processTimedOut, processExited(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid: "The guest bootstrap identity or private artifacts could not be verified."
        case .processLaunchFailed: "The guest bootstrap subprocess could not be started."
        case .processTimedOut: "The guest bootstrap subprocess timed out."
        case .processExited(let status): "The guest bootstrap subprocess exited with status \(status)."
        }
    }
}

enum PommeSSHBootstrap {
    /// Framework account provisioning and the first desktop boot can precede SSH readiness.
    static let firstBootReadinessTimeout: TimeInterval = 600

    enum DiscoveryEvent: CaseIterable {
        case candidateSelected, keyscanSucceeded, leaseVerified
    }

    static func mac(_ value: String) throws -> String {
        let parts = value.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy({ $0.isHexDigit && $0.isASCII }) }) else { throw PommeSSHBootstrapError.invalid }
        return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
    }

    static func ipv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let n = UInt8(part), String(n) == part else { return false }; return true
        }
    }

    /// Parse Apple's bootpd lease format. Ambiguity is never resolved by file order.
    static func address(leases: String, stableMAC: String) throws -> String {
        let expected = try mac(stableMAC)
        var entries: [[String: String]] = []; var current: [String: String]?
        for raw in leases.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line == "{" { guard current == nil else { throw PommeSSHBootstrapError.invalid }; current = [:]; continue }
            if line == "}" { guard let record = current else { throw PommeSSHBootstrapError.invalid }; entries.append(record); current = nil; continue }
            guard current != nil, let equal = line.firstIndex(of: "=") else { throw PommeSSHBootstrapError.invalid }
            let key = String(line[..<equal]); let value = String(line[line.index(after: equal)...])
            guard !key.isEmpty, current?[key] == nil else { throw PommeSSHBootstrapError.invalid }
            current?[key] = value
        }
        guard current == nil else { throw PommeSSHBootstrapError.invalid }
        var candidates: [(String, UInt64)] = []
        for entry in entries {
            guard let hardware = entry["hw_address"] else { continue }
            let pieces = hardware.split(separator: ",", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0] == "1" else { continue }
            guard try mac(String(pieces[1])) == expected else { continue }
            guard let ip = entry["ip_address"], ipv4(ip), let expiry = entry["lease"], expiry.hasPrefix("0x"), let time = UInt64(expiry.dropFirst(2), radix: 16) else { throw PommeSSHBootstrapError.invalid }
            candidates.append((ip, time))
        }
        guard let newest = candidates.map(\.1).max() else { throw PommeSSHBootstrapError.invalid }
        let addresses = Set(candidates.filter { $0.1 == newest }.map(\.0))
        guard addresses.count == 1, let address = addresses.first else { throw PommeSSHBootstrapError.invalid }
        return address
    }

    /// Scan the DHCP target and discard the key if its lease changes meanwhile.
    static func discoverHostKey(stableMAC: String, readLeases: () throws -> String,
                                scan: (String) throws -> String,
                                onEvent: (DiscoveryEvent) -> Void = { _ in }) throws -> (address: String, key: Data) {
        let candidate = try address(leases: readLeases(), stableMAC: stableMAC)
        onEvent(.candidateSelected)
        let key = try scannedHostKey(scan(candidate), address: candidate)
        onEvent(.keyscanSucceeded)
        let verified = try address(leases: readLeases(), stableMAC: stableMAC)
        guard verified == candidate else { throw PommeSSHBootstrapError.invalid }
        onEvent(.leaseVerified)
        return (verified, key)
    }

    static func readLeases(at url: URL = URL(fileURLWithPath: "/var/db/dhcpd_leases")) throws -> String {
        let data = try privateRead(url, owner: 0, allowedModes: [0o644, 0o600], maximum: 4 * 1024 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { throw PommeSSHBootstrapError.invalid }; return text
    }

    static func scannedHostKey(_ output: String, address: String) throws -> Data {
        guard ipv4(address) else { throw PommeSSHBootstrapError.invalid }
        var lines = Set<String>()
        for line in output.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[0] == address, fields[1] == "ssh-ed25519", let key = Data(base64Encoded: String(fields[2])), key.count == 51 else { throw PommeSSHBootstrapError.invalid }
            let prefix = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
            guard key.starts(with: prefix) else { throw PommeSSHBootstrapError.invalid }
            lines.insert(fields.map(String.init).joined(separator: " "))
        }
        guard lines.count == 1, let line = lines.first else { throw PommeSSHBootstrapError.invalid }
        return Data((line + "\n").utf8)
    }

    static func pinHostKey(_ key: Data, at url: URL) throws {
        guard let text = String(data: key, encoding: .utf8),
              let host = text.split(whereSeparator: \.isWhitespace).first,
              try scannedHostKey(text, address: String(host)) == key else { throw PommeSSHBootstrapError.invalid }
        let parent = url.deletingLastPathComponent()
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              parent.resolvingSymlinksInPath().path == parent.path else { throw PommeSSHBootstrapError.invalid }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 {
            guard errno == EEXIST else { throw PommeSSHBootstrapError.invalid }
            let old = try privateRead(url, owner: getuid(), allowedModes: [0o600])
            guard let oldText = String(data: old, encoding: .utf8), let oldHost = oldText.split(whereSeparator: \.isWhitespace).first,
                  try scannedHostKey(oldText, address: String(oldHost)) == old,
                  oldText.split(whereSeparator: \.isWhitespace).dropFirst().elementsEqual(text.split(whereSeparator: \.isWhitespace).dropFirst()) else { throw PommeSSHBootstrapError.invalid }
            if old != key {
                // A lease may move while the VM host key stays identical. Only
                // the IP-scoped lookup line changes, via an adjacent atomic file.
                let stage = try PommeAgentFileTransaction.createAdjacentStage(for: url)
                defer { Darwin.close(stage.descriptor); try? PommeAgentFileTransaction.removeAdjacentStage(stage.url, for: url) }
                try PommeAgentFileTransaction.writeAll(stage.descriptor, data: key)
                guard fchmod(stage.descriptor, 0o600) == 0, fsync(stage.descriptor) == 0,
                      try privateRead(url, owner: getuid(), allowedModes: [0o600]) == old,
                      rename(stage.url.path, url.path) == 0 else { throw PommeSSHBootstrapError.invalid }
                try PommeAgentFileTransaction.fsyncParentDirectory(of: url)
            }
            return
        }
        defer { close(fd) }
        try PommeAgentFileTransaction.writeAll(fd, data: key)
        guard fsync(fd) == 0 else { throw PommeSSHBootstrapError.invalid }
    }

    static func privateRead(_ url: URL, owner: uid_t, allowedModes: Set<mode_t>, maximum: Int = 65536) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw PommeSSHBootstrapError.invalid }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_nlink == 1, allowedModes.contains(info.st_mode & 0o7777), info.st_size >= 0, info.st_size <= maximum else { throw PommeSSHBootstrapError.invalid }
        return try readExactly(descriptor: fd, count: Int(info.st_size), maximum: maximum)
    }

    typealias ReadOperation = (Int32, UnsafeMutableRawPointer?, Int) -> Int

    static func readChunk(descriptor: Int32, maximum: Int, read: ReadOperation = Darwin.read) throws -> Data? {
        guard maximum > 0 else { throw PommeSSHBootstrapError.invalid }
        var data = Data(count: maximum)
        while true {
            let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximum else { throw PommeSSHBootstrapError.invalid }
            if count == 0 { return nil }
            data.removeSubrange(count..<data.count)
            return data
        }
    }

    static func readExactly(descriptor: Int32, count: Int, maximum: Int, read: ReadOperation = Darwin.read) throws -> Data {
        guard count >= 0, count <= maximum else { throw PommeSSHBootstrapError.invalid }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try readChunk(descriptor: descriptor, maximum: min(count - result.count, 64 * 1024), read: read) else { throw PommeSSHBootstrapError.invalid }
            result.append(chunk)
        }
        return result
    }

    static func arguments(address: String, knownHosts: URL, command: String? = nil) throws -> [String] {
        guard ipv4(address), knownHosts.path.hasPrefix("/"), !knownHosts.path.contains("\n") else { throw PommeSSHBootstrapError.invalid }
        // OpenSSH parses this option as a list even though it is one argv value.
        let quotedKnownHosts = knownHosts.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var args = ["-F", "/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"\(quotedKnownHosts)\"", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "PasswordAuthentication=yes", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=10", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"]
        if let command { args += ["-T", "pomme@\(address)", command] }
        return args
    }

    static func scpArguments(address: String, knownHosts: URL, source: URL, requestID: UUID) throws -> [String] {
        guard source.path.hasPrefix("/"), !source.path.contains("\n") else { throw PommeSSHBootstrapError.invalid }
        return try arguments(address: address, knownHosts: knownHosts) + ["--", source.path, "pomme@\(address):/private/var/tmp/pomme-bootstrap-\(requestID.uuidString.lowercased())/"]
    }

    static func installerCommand(request: PommeBootstrapRequest, stagedRequestSHA256: String) throws -> String {
        guard [request.planSHA256, request.executableSHA256, stagedRequestSHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) else { throw PommeSSHBootstrapError.invalid }
        let id = request.requestID.uuidString.lowercased()
        let source = "/private/var/tmp/pomme-bootstrap-\(id)"
        // Only fixed system tools run with privilege until the private copy
        // matches the digest of the signed artifact already verified by the host.
        let script = """
        set -eu
        umask 077
        stage=40
        root=''
        trap 'status=$?; set +e; cleanup=0; if [ -n "$root" ]; then /bin/rm -f "$root/pomme" "$root/request.json" "$root/agent.token" || cleanup=49; if [ -e "$root" ]; then /bin/rmdir "$root" || cleanup=49; fi; fi; if [ "$status" -ne 0 ]; then if [ "$stage" -eq 48 ] && [ "$status" -ge 51 ] && [ "$status" -le 54 ]; then exit "$status"; fi; exit "$stage"; fi; exit "$cleanup"' EXIT
        root=$(/usr/bin/mktemp -d /private/var/tmp/pomme-bootstrap-root-\(id).XXXXXXXX)
        stage=41
        /bin/cp -P '\(source)/pomme' "$root/pomme"
        /bin/cp -P '\(source)/request.json' "$root/request.json"
        stage=42
        [ ! -L "$root/pomme" ] && [ -f "$root/pomme" ]
        [ ! -L "$root/request.json" ] && [ -f "$root/request.json" ]
        /bin/chmod 500 "$root/pomme"
        /bin/chmod 600 "$root/request.json"
        stage=43
        [ "$(/usr/bin/shasum -a 256 "$root/request.json" | /usr/bin/cut -d ' ' -f 1)" = '\(stagedRequestSHA256)' ]
        stage=44
        IFS= read -r token
        /usr/bin/printf '%s' "$token" > "$root/agent.token"
        unset token
        stage=45
        IFS= read -r request
        /usr/bin/printf '%s' "$request" | /usr/bin/base64 -D > "$root/request.json"
        unset request
        stage=46
        [ "$(/usr/bin/shasum -a 256 "$root/pomme" | /usr/bin/cut -d ' ' -f 1)" = '\(request.executableSHA256)' ]
        # The host verified this signed artifact; the digest above verifies the exact transferred bytes.
        stage=48
        "$root/pomme" \(PommeNormalBootstrapInstaller.flag) "$root" '\(source)' '\(request.vmUUID.uuidString.lowercased())' '\(request.planSHA256)' '\(request.executableSHA256)' '\(id)'
        """
        return "/usr/bin/sudo -kS -p '' -- /bin/sh -c " + shellQuote(script)
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum PommeBootstrapAskpass {
    static let flag = "--pomme-bootstrap-askpass"
    static func environment(executable: URL, ownerReference: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SSH_ASKPASS": executable.path,
         "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "pomme-bootstrap",
         "POMME_INTERNAL_ASKPASS": "1", "POMME_BOOTSTRAP_OWNER_REFERENCE": ownerReference.path]
    }

    static func response(environment: [String: String],
                         readCredential: (PommeOwnerCredentialReference) throws -> String = {
                             try PommeOwnerCredentialStore().read($0).password
                         }) throws -> Data {
        guard environment["POMME_INTERNAL_ASKPASS"] == "1",
              let path = environment["POMME_BOOTSTRAP_OWNER_REFERENCE"], path.hasPrefix("/"),
              !path.contains("\n") else { throw PommeSSHBootstrapError.invalid }
        let bytes = try PommeSSHBootstrap.privateRead(URL(fileURLWithPath: path), owner: getuid(), allowedModes: [0o600])
        let reference = try JSONDecoder().decode(PommeOwnerCredentialReference.self, from: bytes)
        let password = try readCredential(reference)
        guard !password.isEmpty, !password.contains("\n"), !password.contains("\r") else { throw PommeSSHBootstrapError.invalid }
        return Data((password + "\n").utf8)
    }

    static func run() -> Int32 {
        do { FileHandle.standardOutput.write(try response(environment: ProcessInfo.processInfo.environment)); return 0 } catch { return 1 }
    }
}
