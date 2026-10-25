import CryptoKit
import Darwin
import Foundation

/// Stages the files that host preparation embeds in the Recovery image: the
/// pinned agent, the resident credential, a launch script, and a replacement
/// for an existing Recovery launchd job. The staged credential exists only
/// until preparation completes.
enum PommeExperimentalRecoveryPayload {
    /// The image-root directory that holds the embedded files.
    static let embeddedDirectoryName = "pomme-recovery-payload"
    /// launchd didn't discover a newly added label in Recovery, so the
    /// prepared image replaces this job, which otherwise saves panic reports.
    static let jobLabel = "com.apple.DumpPanicRecoveryOS"
    /// The root-owned copies that the launch script starts.
    static let runtimeDirectory = "/var/run/pomme-recovery-agent"
    static let runtimeExecutable = runtimeDirectory + "/pomme"
    static let runtimeTokenFile = runtimeDirectory + "/agent.token"
    static let filenames: Set<String> = ["pomme", "agent.token", "manifest.json", "autostart.sh", "launchd.plist"]

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Recovery image preparation: \(reason)" }
    }

    /// Writes every output that's absent and checks that every present one
    /// matches exactly, so an interrupted staging resumes without replacing
    /// anything that another writer committed.
    static func stage(directory: URL, target: String, sessionID: UUID, executable: URL,
                      expectedDigest: String, credential: String, vmID: UUID, diskPath: String) throws {
        let fd = try openDirectory(directory)
        defer { close(fd) }
        try validateEntries(directory)
        let bytes = try Data(contentsOf: executable)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest, expectedDigest.count == 64 else {
            throw Failure(reason: "pinned executable digest mismatch.")
        }
        let manifest: [String: String] = ["target": target, "vmUUID": vmID.uuidString.lowercased(),
            "sessionUUID": sessionID.uuidString.lowercased(), "diskPath": diskPath, "expectedSHA256": digest]
        let outputs: [(String, Data, mode_t)] = [
            ("pomme", bytes, 0o555), ("agent.token", Data(credential.utf8), 0o400),
            ("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]), 0o600),
            ("autostart.sh", Data(wrapper(digest: digest, vmID: vmID, sessionID: sessionID).utf8), 0o500),
            ("launchd.plist", try plist(), 0o600)
        ]
        // Validate all existing outputs before writing any absent output.
        for (name, data, mode) in outputs { try checkExisting(directory: fd, name: name, data: data, mode: mode) }
        for (name, data, mode) in outputs { try writeAtomic(directory: fd, name: name, data: data, mode: mode) }
    }

    /// Removes the staged credential, and an interrupted temporary copy of it,
    /// once the prepared image holds it.
    static func removeCredential(from directory: URL) throws {
        let fd = try openDirectory(directory)
        defer { close(fd) }
        for name in ["agent.token", "agent.token.next"] {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                guard errno == ENOENT else { throw Failure(reason: "staged credential cannot be inspected.") }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                throw Failure(reason: "staged credential must be a user-owned regular file.")
            }
            guard unlinkat(fd, name, 0) == 0 else { throw Failure(reason: "staged credential could not be removed.") }
        }
        guard fsync(fd) == 0 else { throw Failure(reason: "staging directory could not be synced.") }
    }

    static func plist() throws -> Data {
        let fields: [String: Any] = [
            "Label": jobLabel,
            "ProgramArguments": ["/bin/sh", "/\(embeddedDirectoryName)/autostart.sh"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5, "ProcessType": "Interactive",
            "EnablePressuredExit": false, "EnableTransactions": false,
            "_LimitLoadToBootMode": ["recoveryos", "diagnostics"]
        ]
        return try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
    }

    /// Copies the agent and credential into root-owned runtime files, so the
    /// host never needs administrator rights to create root-owned payloads,
    /// and checks the agent's digest before and after the copy.
    static func wrapper(digest: String, vmID: UUID, sessionID: UUID) -> String {
        let session = sessionID.uuidString.lowercased()
        return """
        #!/bin/sh
        set -eu
        umask 077
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        [ "$(/usr/bin/stat -f %u /var/run)" = 0 ] || exit 1
        payload=/\(embeddedDirectoryName)
        stage=\(runtimeDirectory)
        [ -d "$payload" ] && [ ! -L "$payload" ] || exit 1
        for file in pomme agent.token; do
            [ -f "$payload/$file" ] && [ ! -L "$payload/$file" ] || exit 1
        done
        [ "$(/sbin/sha256 -q "$payload/pomme")" = '\(digest)' ] || exit 1
        [ ! -L "$stage" ] || exit 1
        if [ ! -e "$stage" ]; then /bin/mkdir -m 700 "$stage"; fi
        [ -d "$stage" ] && [ "$(/usr/bin/stat -f %u "$stage")" = 0 ] || exit 1
        /bin/chmod 700 "$stage"
        for file in pomme agent.token; do
            [ ! -L "$stage/$file" ] || exit 1
            if [ -e "$stage/$file" ]; then
                [ -f "$stage/$file" ] && [ "$(/usr/bin/stat -f %u "$stage/$file")" = 0 ] || exit 1
            fi
            /bin/cp "$payload/$file" "$stage/$file"
            /usr/sbin/chown 0:0 "$stage/$file"
        done
        /bin/chmod 555 "$stage/pomme"
        /bin/chmod 400 "$stage/agent.token"
        [ "$(/sbin/sha256 -q "$stage/pomme")" = '\(digest)' ] || exit 1
        exec "$stage/pomme" --pomme-agent \(Constants.pommeRecoveryResidentPort) --role recovery --token-file "$stage/agent.token" --expected-sha256 '\(digest)' --vm-id '\(vmID.uuidString.lowercased())' --session-id '\(session)' --resident-recovery '\(session)'
        """ + "\n"
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        // Reject symlink aliases at every component, not only the final leaf.
        let path = url.path
        var current = ""
        for component in path.split(separator: "/") {
            guard component != ".", component != ".." else { throw Failure(reason: "staging path must be canonical.") }
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw Failure(reason: "staging path must contain only existing directories, without symlinks.")
            }
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(reason: "staging directory cannot be opened.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw Failure(reason: "staging directory must be user-owned and private.")
        }
        return fd
    }

    private static func validateEntries(_ directory: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let temporaryNames = Set(filenames.map { $0 + ".next" })
        guard Set(entries).isSubset(of: filenames.union(temporaryNames)) else { throw Failure(reason: "unexpected staging entry.") }
        for entry in entries {
            let executable = entry == "pomme" || entry == "pomme.next"
            var info = stat()
            guard lstat(directory.appendingPathComponent(entry).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o077 == 0 || (executable && info.st_mode & 0o777 == 0o555)) else {
                throw Failure(reason: "staging entries must be private user-owned regular files without symlinks.")
            }
        }
    }

    /// Only known `.next` files belong to the writer. A partial final file is
    /// never overwritten; a private interrupted temporary can be rebuilt.
    private static func writeAtomic(directory: Int32, name: String, data: Data, mode: mode_t) throws {
        let temporary = name + ".next"
        let prior = openat(directory, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if prior >= 0 {
            defer { close(prior) }
            var info = stat()
            guard fstat(prior, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), [mode_t(0o600), mode].contains(info.st_mode & 0o777),
                  info.st_nlink == 1 || info.st_nlink == 2 else {
                throw Failure(reason: "interrupted staging temporary is unsafe.")
            }
            if info.st_nlink == 2 {
                let final = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard final >= 0 else { throw Failure(reason: "staging temporary has an unexpected hard link.") }
                defer { close(final) }
                var committed = stat()
                guard fstat(final, &committed) == 0, info.st_dev == committed.st_dev,
                      info.st_ino == committed.st_ino else { throw Failure(reason: "staging temporary has an unexpected hard link.") }
                try checkExisting(directory: directory, name: name, data: data, mode: mode)
            }
            guard unlinkat(directory, temporary, 0) == 0, fsync(directory) == 0 else {
                throw Failure(reason: "could not remove interrupted staging temporary.")
            }
        } else if errno != ENOENT { throw Failure(reason: "staging temporary cannot be safely opened.") }

        let existing = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 {
            close(existing)
            try checkExisting(directory: directory, name: name, data: data, mode: mode)
            return
        }
        guard errno == ENOENT else { throw Failure(reason: "staging output cannot be safely opened.") }
        let output = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure(reason: "could not create staging temporary.") }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fchmod(output, mode) == 0, fsync(output) == 0 else { throw Failure(reason: "could not finalize staging temporary.") }
        // linkat commits without replacing another inode. A crash between
        // linking and unlinking leaves two known names for the same bytes.
        if linkat(directory, temporary, directory, name, 0) != 0 {
            guard errno == EEXIST else { throw Failure(reason: "could not commit staging output.") }
            try checkExisting(directory: directory, name: name, data: data, mode: mode)
        }
        guard fsync(directory) == 0, unlinkat(directory, temporary, 0) == 0, fsync(directory) == 0 else {
            throw Failure(reason: "could not finalize committed staging output.")
        }
    }

    private static func checkExisting(directory: Int32, name: String, data: Data, mode: mode_t) throws {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw Failure(reason: "staging output cannot be safely reopened.") }
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == mode,
              info.st_size == data.count,
              try handle.read(upToCount: data.count + 1) == data else {
            throw Failure(reason: "existing staging output does not exactly match; refusing replacement.")
        }
    }
}
