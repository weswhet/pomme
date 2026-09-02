import Darwin
import Foundation

enum PommeAPFSAttachmentError: Error, LocalizedError, Equatable, Sendable {
    case malformed
    case ambiguous
    case imageMismatch
    case missingVolume

    var errorDescription: String? {
        switch self {
        case .malformed:
            "Recovery attachment evidence was malformed."
        case .ambiguous:
            "Recovery attachment evidence was ambiguous."
        case .imageMismatch:
            "Recovery attachment did not identify the requested image."
        case .missingVolume:
            "Recovery attachment did not identify one APFS volume."
        }
    }
}

struct PommeAPFSAttachment: Equatable, Sendable {
    let imagePath: String
    let wholeDisk: String
    let mountPoint: String
    let volumeUUID: UUID
}

enum PommeAPFSAttachmentParser {
    static func parse(
        _ plist: String,
        imageURL: URL,
        volumeName: String
    ) throws -> PommeAPFSAttachment {
        guard let data = plist.data(using: .utf8) else { throw PommeAPFSAttachmentError.malformed }
        return try parse(data, imageURL: imageURL, volumeName: volumeName)
    }

    static func parse(
        _ data: Data,
        imageURL: URL,
        volumeName: String
    ) throws -> PommeAPFSAttachment {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = object as? [String: Any]
        else { throw PommeAPFSAttachmentError.malformed }

        // `diskutil` has emitted both an `images` wrapper and a direct
        // `system-entities` record across supported macOS releases. Normalize
        // those shapes before applying the same uniqueness checks.
        let images: [[String: Any]]
        if let records = root["images"] as? [[String: Any]] {
            images = records
        } else if let entities = root["system-entities"] as? [[String: Any]] {
            images = [["image-path": imageURL.path, "system-entities": entities]]
        } else {
            throw PommeAPFSAttachmentError.malformed
        }

        let expectedPath = imageURL.standardizedFileURL.path
        let matching = images.filter { image in
            guard let path = image["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == expectedPath
        }
        guard matching.count == 1, let image = matching.first else {
            throw matching.isEmpty ? PommeAPFSAttachmentError.imageMismatch : PommeAPFSAttachmentError.ambiguous
        }
        guard let entities = image["system-entities"] as? [[String: Any]], !entities.isEmpty else {
            throw PommeAPFSAttachmentError.malformed
        }

        let mounts = entities.compactMap { entity -> (path: String, entity: [String: Any])? in
            guard let path = entity["mount-point"] as? String else { return nil }
            let mount = URL(fileURLWithPath: path).standardizedFileURL
            guard mount.path.hasPrefix("/Volumes/"),
                  mount.lastPathComponent == volumeName
            else { return nil }
            return (mount.path, entity)
        }
        guard mounts.count == 1, let mount = mounts.first else {
            throw mounts.isEmpty ? PommeAPFSAttachmentError.missingVolume : PommeAPFSAttachmentError.ambiguous
        }
        let mountPoint = mount.path

        let wholeDisks = Set(entities.compactMap { entity -> String? in
            guard let raw = entity["dev-entry"] as? String else { return nil }
            return wholeDiskName(raw)
        })
        guard wholeDisks.count == 1, let wholeDisk = wholeDisks.first else {
            throw PommeAPFSAttachmentError.ambiguous
        }

        var uuids = Set<UUID>()
        for key in ["VolumeUUID", "volume-uuid", "volume-UUID", "uuid"] {
            if let raw = mount.entity[key] as? String, let uuid = UUID(uuidString: raw) {
                uuids.insert(uuid)
            }
        }
        // Some disk utility versions attach the volume UUID to the image
        // record rather than its mounted entity. Use that value only when the
        // selected entity has no UUID, so unrelated container identifiers do
        // not manufacture a false ambiguity.
        if uuids.isEmpty {
            for key in ["VolumeUUID", "volume-uuid", "volume-UUID", "uuid"] {
                if let raw = image[key] as? String, let uuid = UUID(uuidString: raw) {
                    uuids.insert(uuid)
                }
            }
        }
        guard uuids.count == 1, let volumeUUID = uuids.first else {
            throw uuids.isEmpty ? PommeAPFSAttachmentError.missingVolume : PommeAPFSAttachmentError.ambiguous
        }
        return .init(
            imagePath: expectedPath,
            wholeDisk: wholeDisk,
            mountPoint: mountPoint,
            volumeUUID: volumeUUID
        )
    }

    private static func wholeDiskName(_ raw: String) -> String? {
        let value = raw.hasPrefix("/dev/") ? String(raw.dropFirst(5)) : raw
        guard value.hasPrefix("disk") else { return nil }
        let numeric = value.dropFirst(4).prefix(while: { $0.isNumber })
        guard !numeric.isEmpty else { return nil }
        let remainder = value.dropFirst(4 + numeric.count)
        guard remainder.isEmpty
                || (remainder.count > 1
                    && remainder.first == "s"
                    && remainder.dropFirst().allSatisfy({ $0.isNumber }))
        else { return nil }
        return "disk\(numeric)"
    }
}

protocol PommeRecoveryRescueAttachmentPort: Sendable {
    func detach(_ attachment: PommeAPFSAttachment) throws
}

enum PommeRecoveryRescueCleanupError: Error, LocalizedError, Equatable, Sendable {
    case unsafePath
    case unknownState
    case detachFailed
    case removeFailed

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            "Recovery containment path was rejected."
        case .unknownState:
            "Recovery containment cleanup state was unknown."
        case .detachFailed:
            "Recovery containment attachment could not be detached."
        case .removeFailed:
            "Recovery containment artifact could not be removed."
        }
    }
}

/// Cleans one explicitly owned rescue image. This type has no guest command
/// surface; display and attachment containment can never become an alternate
/// guest execution path.
struct PommeRecoveryRescueContainment: Sendable {
    let imageURL: URL
    let directoryURL: URL
    let attachment: PommeAPFSAttachment
    let attachmentPort: any PommeRecoveryRescueAttachmentPort

    init(
        imageURL: URL,
        directoryURL: URL,
        attachment: PommeAPFSAttachment,
        attachmentPort: any PommeRecoveryRescueAttachmentPort
    ) throws {
        let image = imageURL.standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        let mount = URL(fileURLWithPath: attachment.mountPoint).standardizedFileURL
        guard image.deletingLastPathComponent() == directory,
              attachment.imagePath == image.path,
              attachment.wholeDisk.hasPrefix("disk"),
              !attachment.wholeDisk.dropFirst(4).isEmpty,
              attachment.wholeDisk.dropFirst(4).allSatisfy({ $0.isNumber }),
              mount.path == attachment.mountPoint,
              mount.path.hasPrefix("/Volumes/"),
              mount.path == mount.resolvingSymlinksInPath().standardizedFileURL.path,
              image.path == image.resolvingSymlinksInPath().standardizedFileURL.path,
              directory.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              image.lastPathComponent.count > 0,
              !image.lastPathComponent.contains("/"),
              !directory.path.isEmpty
        else { throw PommeRecoveryRescueCleanupError.unsafePath }
        self.imageURL = image
        self.directoryURL = directory
        self.attachment = attachment
        self.attachmentPort = attachmentPort
    }

    func cleanup() throws {
        var directoryInfo = stat()
        guard lstat(directoryURL.path, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o777 == 0o700
        else { throw PommeRecoveryRescueCleanupError.unsafePath }
        var imageInfo = stat()
        guard lstat(imageURL.path, &imageInfo) == 0,
              imageInfo.st_uid == geteuid(),
              imageInfo.st_mode & S_IFMT == S_IFREG,
              imageInfo.st_mode & 0o077 == 0,
              imageInfo.st_nlink == 1
        else { throw PommeRecoveryRescueCleanupError.unknownState }
        do { try attachmentPort.detach(attachment) }
        catch { throw PommeRecoveryRescueCleanupError.detachFailed }

        let parentFD = open(directoryURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw PommeRecoveryRescueCleanupError.removeFailed }
        defer { close(parentFD) }
        let directoryName = directoryURL.lastPathComponent
        guard !directoryName.isEmpty, directoryName != ".", directoryName != ".." else {
            throw PommeRecoveryRescueCleanupError.unsafePath
        }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_mode & 0o022 == 0
        else { throw PommeRecoveryRescueCleanupError.unsafePath }
        let directoryFD = openat(parentFD, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw PommeRecoveryRescueCleanupError.unknownState }
        defer { close(directoryFD) }

        var openedDirectoryInfo = stat()
        guard fstat(directoryFD, &openedDirectoryInfo) == 0,
              openedDirectoryInfo.st_dev == directoryInfo.st_dev,
              openedDirectoryInfo.st_ino == directoryInfo.st_ino,
              openedDirectoryInfo.st_uid == geteuid(),
              openedDirectoryInfo.st_mode & S_IFMT == S_IFDIR,
              openedDirectoryInfo.st_mode & 0o777 == 0o700
        else { throw PommeRecoveryRescueCleanupError.unknownState }

        var current = stat()
        guard fstatat(directoryFD, imageURL.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == imageInfo.st_dev,
              current.st_ino == imageInfo.st_ino,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_mode & 0o077 == 0,
              current.st_nlink == 1,
              unlinkat(directoryFD, imageURL.lastPathComponent, 0) == 0,
              fsync(directoryFD) == 0
        else { throw PommeRecoveryRescueCleanupError.unknownState }

        guard isEmpty(directoryFD),
              unlinkat(parentFD, directoryName, AT_REMOVEDIR) == 0,
              fsync(parentFD) == 0
        else {
            throw PommeRecoveryRescueCleanupError.removeFailed
        }
    }

    private func isEmpty(_ descriptor: Int32) -> Bool {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return false
        }
        var count = 0
        while readdir(stream) != nil { count += 1 }
        closedir(stream)
        return count == 2
    }
}
