import Darwin
import Foundation
import Security

/// A current, normally signed CLI performs staging for older pinned agents.
/// Guest paths stay lexical: Foundation on macOS 15 aliases /private/var.
enum PommeMDMStagingHelper {
    static let flag = "--pomme-mdm-staging-helper"
    private static let parent = "/private/var/db"
    private static let prefix = "pomme-mdm-bootstrap-"

    static func isCanonicalPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("/") && !path.contains("\0")
            && !parts.dropFirst().contains("")
            && !parts.contains(".") && !parts.contains("..")
    }

    static func isBootstrapPath(_ path: String) -> Bool {
        guard isCanonicalPath(path), path.hasPrefix(parent + "/"),
              URL(fileURLWithPath: path).deletingLastPathComponent().path == parent else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(".bin") else { return false }
        let id = String(name.dropFirst(prefix.count).dropLast(4))
        return UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            guard arguments.count >= 3, arguments[0] == flag,
                  let id = UUID(uuidString: arguments[1]),
                  id.uuidString.lowercased() == arguments[1], geteuid() == 0 else {
                throw GuestMDMStagingError.invalidRoot
            }
            let path = parent + "/" + prefix + arguments[1] + ".bin"
            guard try executablePath() == path else { throw GuestMDMStagingError.invalidRoot }
            let parentFD = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parentFD >= 0 else { throw GuestMDMStagingError.unsafeRoot }
            defer { _ = Darwin.close(parentFD) }
            var directory = stat()
            guard fstat(parentFD, &directory) == 0,
                  directory.st_mode & S_IFMT == S_IFDIR,
                  directory.st_uid == 0, directory.st_gid == 0,
                  directory.st_mode & 0o022 == 0 else { throw GuestMDMStagingError.unsafeRoot }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let fd = Darwin.openat(parentFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw GuestMDMStagingError.unsafeProfile }
            defer { _ = Darwin.close(fd) }
            var file = stat()
            guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
                  file.st_uid == 0, file.st_gid == 0, file.st_nlink == 1,
                  file.st_mode & 0o7777 == 0o700 else { throw GuestMDMStagingError.unsafeProfile }
            var code: SecCode?
            var requirement: SecRequirement?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(PommeAgentArtifactStore.signingRequirement as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
                throw GuestMDMStagingError.unsafeProfile
            }
            let result: JSONValue
            switch arguments[2] {
            case "prepare" where arguments.count == 3:
                result = try GuestMDMStaging.prepare()
            case "cleanup" where arguments.count == 4:
                result = try GuestMDMStaging.cleanup(profilePath: arguments[3])
            case "remove" where arguments.count == 3:
                var linked = stat()
                guard fstatat(parentFD, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                      linked.st_dev == file.st_dev, linked.st_ino == file.st_ino,
                      linked.st_mode == file.st_mode, linked.st_nlink == 1,
                      unlinkat(parentFD, name, 0) == 0, fsync(parentFD) == 0,
                      fstatat(parentFD, name, &linked, AT_SYMLINK_NOFOLLOW) != 0,
                      errno == ENOENT else { throw GuestMDMStagingError.cleanupFailed }
                result = .object(["removed": .bool(true)])
            default: throw GuestMDMStagingError.invalidProfile
            }
            var output = try JSONEncoder().encode(result)
            output.append(0x0a)
            FileHandle.standardOutput.write(output)
            return 0
        } catch {
            FileHandle.standardOutput.write(Data("{\"errorCode\":\"staging-failed\"}\n".utf8))
            return 1
        }
    }

    private static func executablePath() throws -> String {
        var size: UInt32 = 0
        guard _NSGetExecutablePath(nil, &size) == -1, size > 0, size < 16_384 else {
            throw GuestMDMStagingError.invalidRoot
        }
        var bytes = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&bytes, &size) == 0 else { throw GuestMDMStagingError.invalidRoot }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
