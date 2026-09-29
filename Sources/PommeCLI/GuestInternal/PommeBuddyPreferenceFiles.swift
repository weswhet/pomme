import Darwin
import Foundation

/// Direct, root-side access to one user's preference files for the fixed
/// Buddy domains. Every path component below the home directory is opened
/// relative to its parent with `O_NOFOLLOW` and must be owned by the user,
/// so a user-controlled symlink cannot redirect a root write. Files are
/// replaced atomically and handed to the user before they become visible.
enum PommeBuddyPreferenceFiles {
    static let domains: Set<String> = ["com.apple.SetupAssistant", "com.apple.loginwindow"]
    static let maximumFileBytes = 1024 * 1024
    /// `staff`, the primary group of local users.
    static let staffGroup: gid_t = 20

    /// Whether the user's preferences daemon is running. While it is, it
    /// may hold these domains in memory and overwrite a direct file change,
    /// so direct writes are only safe before the user's first session.
    static func userPreferencesDaemonRunning(uid: uid_t) -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return false }
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            if String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "cfprefsd" {
                return true
            }
        }
        return false
    }

    static func read(home: String, uid: uid_t, domain: String, key: String) throws -> PommeBuddyPreferenceValue? {
        guard let preferences = try preferencesDirectory(home: home, uid: uid, domain: domain, create: false) else {
            return nil
        }
        defer { Darwin.close(preferences) }
        return PommeBuddyPreferenceValue(propertyListValue: try dictionary(in: preferences, domain: domain, uid: uid)?[key])
    }

    static func write(home: String, uid: uid_t, domain: String, key: String, value: PommeBuddyPreferenceValue,
                      daemonRunning: (uid_t) -> Bool = userPreferencesDaemonRunning) throws {
        guard !daemonRunning(uid) else { throw issue("preferences-session-online") }
        guard let preferences = try preferencesDirectory(home: home, uid: uid, domain: domain, create: true) else {
            throw issue("preferences-directory")
        }
        defer { Darwin.close(preferences) }
        var values = try dictionary(in: preferences, domain: domain, uid: uid) ?? [:]
        values[key] = value.propertyListValue
        let data: Data
        do { data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) }
        catch { throw issue("preference-file-invalid") }
        try publish(data, in: preferences, name: "\(domain).plist", uid: uid)
    }

    private static func preferencesDirectory(home: String, uid: uid_t, domain: String, create: Bool) throws -> Int32? {
        guard domains.contains(domain), home.hasPrefix("/"), !home.split(separator: "/").contains("..") else {
            throw issue("unsafe-preferences-directory")
        }
        let homeDescriptor = Darwin.open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeDescriptor >= 0 else { throw issue("unsafe-preferences-directory", errno) }
        defer { Darwin.close(homeDescriptor) }
        try requireOwnedDirectory(homeDescriptor, uid: uid)
        guard let library = try ownedDirectory(in: homeDescriptor, name: "Library", uid: uid, create: create) else {
            return nil
        }
        defer { Darwin.close(library) }
        return try ownedDirectory(in: library, name: "Preferences", uid: uid, create: create)
    }

    private static func ownedDirectory(in parent: Int32, name: String, uid: uid_t, create: Bool) throws -> Int32? {
        var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT {
            guard create else { return nil }
            guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw issue("preferences-directory", errno) }
            descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                var info = stat()
                // Only a directory this call created (still owned by the
                // writer, not the user) is handed to the user.
                if fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_uid != uid {
                    guard fchown(descriptor, uid, staffGroup) == 0 else {
                        Darwin.close(descriptor)
                        throw issue("preferences-directory", errno)
                    }
                }
            }
        }
        guard descriptor >= 0 else { throw issue("unsafe-preferences-directory", errno) }
        do { try requireOwnedDirectory(descriptor, uid: uid) }
        catch { Darwin.close(descriptor); throw error }
        return descriptor
    }

    private static func requireOwnedDirectory(_ descriptor: Int32, uid: uid_t) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == uid, info.st_mode & 0o022 == 0 else {
            throw issue("unsafe-preferences-directory")
        }
    }

    /// The existing preference dictionary, or nil when the file is absent.
    private static func dictionary(in preferences: Int32, domain: String, uid: uid_t) throws -> [String: Any]? {
        let descriptor = openat(preferences, "\(domain).plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw issue(errno == ELOOP ? "unsafe-preference-file" : "preference-file-open", errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= off_t(maximumFileBytes) else {
            throw issue("unsafe-preference-file")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw issue("preference-file-read", errno)
            }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maximumFileBytes else { throw issue("unsafe-preference-file") }
        }
        if data.isEmpty { return [:] }
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw issue("preference-file-invalid")
        }
        return values
    }

    private static func publish(_ data: Data, in directory: Int32, name: String, uid: uid_t) throws {
        let temporary = ".\(name).pomme-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw issue("preference-file-write", errno) }
        var published = false
        defer {
            if !published { _ = unlinkat(directory, temporary, 0) }
        }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw issue("preference-file-write", errno) }
                    offset += count
                }
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw issue("preference-file-write", errno) }
            if info.st_uid != uid || info.st_gid != staffGroup {
                guard fchown(descriptor, uid, staffGroup) == 0 else { throw issue("preference-file-write", errno) }
            }
            guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
                throw issue("preference-file-write", errno)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw issue("preference-file-write", errno) }
        guard renameat(directory, temporary, directory, name) == 0 else { throw issue("preference-file-publish", errno) }
        published = true
        guard fsync(directory) == 0 else { throw issue("preference-file-publish", errno) }
    }

    private static func issue(_ code: String, _ numeric: Int32? = nil) -> PommeBuddyPreferencesFailure {
        .init(code: code, numericCode: numeric.map(Int.init))
    }
}

/// The owner's preferences through cfprefsd, as root, naming the user
/// explicitly. This is correct whether or not the user is logged in. The
/// direct file writer is used only when cfprefsd rejects the change and no
/// session for the user is running.
enum PommeBuddyCFPreferences {
    static func read(owner: PommeBuddyPreferencesOwner, domain: String, key: String) throws -> PommeBuddyPreferenceValue? {
        guard PommeBuddyPreferenceFiles.domains.contains(domain) else { throw issue("unsafe-preferences-directory") }
        let user = owner.account as CFString
        // Drop this process's cached copy so the read reflects cfprefsd.
        _ = CFPreferencesSynchronize(domain as CFString, user, kCFPreferencesAnyHost)
        return PommeBuddyPreferenceValue(propertyListValue: CFPreferencesCopyValue(
            key as CFString, domain as CFString, user, kCFPreferencesAnyHost))
    }

    static func write(owner: PommeBuddyPreferencesOwner, domain: String, key: String,
                      value: PommeBuddyPreferenceValue) throws {
        guard PommeBuddyPreferenceFiles.domains.contains(domain) else { throw issue("unsafe-preferences-directory") }
        let user = owner.account as CFString
        CFPreferencesSetValue(key as CFString, value.propertyListValue as CFPropertyList, domain as CFString,
                              user, kCFPreferencesAnyHost)
        if CFPreferencesSynchronize(domain as CFString, user, kCFPreferencesAnyHost) { return }
        guard !PommeBuddyPreferenceFiles.userPreferencesDaemonRunning(uid: owner.uid) else {
            throw issue("preference-write-failed")
        }
        try PommeBuddyPreferenceFiles.write(home: owner.homeDirectory, uid: owner.uid, domain: domain,
                                            key: key, value: value)
        _ = CFPreferencesSynchronize(domain as CFString, user, kCFPreferencesAnyHost)
    }

    private static func issue(_ code: String) -> PommeBuddyPreferencesFailure {
        .init(code: code, numericCode: nil)
    }
}
