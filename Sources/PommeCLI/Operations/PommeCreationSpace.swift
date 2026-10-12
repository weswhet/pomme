import Foundation

/// The free space that creating a VM or template needs, checked before
/// anything is downloaded or written. A VM's disk image is sparse, so the
/// guest's use can't be known exactly; the estimates below are generous
/// enough that a creation they allow doesn't run out of space partway.
enum PommeCreationSpace {
    /// An installed macOS system, measured at about 23 GB for macOS 26 and
    /// 28 GB for macOS 27, plus room for the first boot and updates. A
    /// smaller disk caps it, because the guest can't use more than its disk.
    static let installedSystemEstimateBytes: UInt64 = 35_000_000_000

    /// What a template clone writes on its own blocks while Pomme installs
    /// and verifies its agent. Cloning shares every other block.
    static let cloneGrowthEstimateBytes: UInt64 = 5_000_000_000

    /// One part of a creation, and the directory its bytes land in.
    struct Need: Equatable, Sendable {
        enum Kind: String, Sendable {
            case restoreImageDownload
            case installedSystem
            case templateCopy
            case cloneGrowth
        }

        let kind: Kind
        let bytes: UInt64
        let directory: URL

        var phrase: String {
            let size = byteCountText(bytes)
            return switch kind {
            case .restoreImageDownload: "\(size) to download the restore image"
            case .installedSystem: "about \(size) for the installed macOS system"
            case .templateCopy: "\(size) to copy the template, because its volume can't clone files"
            case .cloneGrowth: "about \(size) for the clone's own changes"
            }
        }
    }

    /// The needs that land on one volume, and that volume's free space.
    struct VolumeCheck: Equatable, Sendable {
        let directory: URL
        let needs: [Need]
        /// Nil when the volume's free space can't be read; such a volume
        /// never blocks creation.
        let availableBytes: UInt64?

        var requiredBytes: UInt64 { needs.reduce(0) { $0 + $1.bytes } }
        var sufficient: Bool { availableBytes.map { $0 >= requiredBytes } ?? true }

        var payload: [String: Any] {
            [
                "directory": directory.path,
                "requiredBytes": requiredBytes,
                "availableBytes": availableBytes.map { $0 as Any } ?? NSNull(),
                "sufficient": sufficient,
                "needs": needs.map { ["kind": $0.kind.rawValue, "bytes": $0.bytes] }
            ]
        }
    }

    // MARK: Needs

    /// A creation from a restore image: the rest of the download, if any,
    /// and the installed system on the new disk.
    static func restoreNeeds(downloadBytes: UInt64, downloadDirectory: URL, diskSizeBytes: UInt64, destination: URL) -> [Need] {
        var needs: [Need] = []
        if downloadBytes > 0 {
            needs.append(.init(kind: .restoreImageDownload, bytes: downloadBytes, directory: downloadDirectory))
        }
        needs.append(.init(
            kind: .installedSystem,
            bytes: min(installedSystemEstimateBytes, diskSizeBytes),
            directory: destination
        ))
        return needs
    }

    /// A creation from a template: the clone's own changes when the volume
    /// can clone the template's files, and a full copy when it can't.
    static func templateNeeds(template: URL, templateBytes: UInt64, destination: URL) -> [Need] {
        if canClone(from: template, to: destination) {
            return [.init(kind: .cloneGrowth, bytes: cloneGrowthEstimateBytes, directory: destination)]
        }
        return [
            .init(kind: .templateCopy, bytes: templateBytes, directory: destination),
            .init(kind: .cloneGrowth, bytes: cloneGrowthEstimateBytes, directory: destination)
        ]
    }

    // MARK: Checking

    /// Groups `needs` by volume and reads each volume's free space.
    static func check(
        _ needs: [Need],
        availableBytes: (URL) -> UInt64? = availableBytes(at:),
        volumeIdentifier: (URL) -> AnyHashable? = volumeIdentifier(of:)
    ) -> [VolumeCheck] {
        var groups: [(key: AnyHashable?, needs: [Need])] = []
        for need in needs {
            let key = volumeIdentifier(need.directory)
            if let index = groups.firstIndex(where: { $0.key != nil && $0.key == key }) {
                groups[index].needs.append(need)
            } else {
                groups.append((key, [need]))
            }
        }
        return groups.map { group in
            let directory = group.needs[0].directory
            return VolumeCheck(directory: directory, needs: group.needs, availableBytes: availableBytes(directory))
        }
    }

    /// Throws when any volume lacks the space that `needs` require.
    @discardableResult
    static func enforce(
        _ needs: [Need],
        subject: String,
        availableBytes: (URL) -> UInt64? = availableBytes(at:),
        volumeIdentifier: (URL) -> AnyHashable? = volumeIdentifier(of:)
    ) throws -> [VolumeCheck] {
        let checks = check(needs, availableBytes: availableBytes, volumeIdentifier: volumeIdentifier)
        if let short = checks.first(where: { !$0.sufficient }), let available = short.availableBytes {
            throw PommeCreationSpaceError(subject: subject, check: short, availableBytes: available)
        }
        return checks
    }

    /// The JSON a dry run prints for its space check.
    static func payload(_ checks: [VolumeCheck]) -> [String: Any] {
        [
            "requiredBytes": checks.reduce(0) { $0 + $1.requiredBytes },
            "sufficient": checks.allSatisfy(\.sufficient),
            "volumes": checks.map(\.payload)
        ]
    }

    // MARK: Volumes

    /// The space that macOS can make available on the volume that holds
    /// `url`, including purgeable space. A path that doesn't exist yet is
    /// measured at its nearest existing parent.
    static func availableBytes(at url: URL) -> UInt64? {
        guard let existing = nearestExisting(url) else { return nil }
        let values = try? existing.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        return values?.volumeAvailableCapacity.flatMap { UInt64(exactly: $0) }
    }

    static func volumeIdentifier(of url: URL) -> AnyHashable? {
        guard let existing = nearestExisting(url),
              let identifier = try? existing.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        else { return nil }
        return AnyHashable(identifier)
    }

    /// Whether `clonefile(2)` can clone `source` into `directory`: both are
    /// on the same volume, and that volume supports cloning.
    static func canClone(from source: URL, to directory: URL) -> Bool {
        guard let sourceVolume = volumeIdentifier(of: source),
              sourceVolume == volumeIdentifier(of: directory),
              let existing = nearestExisting(directory),
              let values = try? existing.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        else { return false }
        return values.volumeSupportsFileCloning == true
    }

    static func nearestExisting(_ url: URL) -> URL? {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
        return current
    }
}

/// Creation stopped before it changed anything, because a volume doesn't
/// have the space that the creation needs.
struct PommeCreationSpaceError: PommeDescribedError, Equatable {
    let subject: String
    let check: PommeCreationSpace.VolumeCheck
    let availableBytes: UInt64

    var code: PommeErrorCode { .hostDiskSpaceInsufficient }

    private var shortfall: UInt64 { check.requiredBytes - min(availableBytes, check.requiredBytes) }
    private var location: String { "`\(PommeErrorRedaction.abbreviatingHome(check.directory.path))`" }

    var errorDescription: String? {
        let parts = check.needs.map(\.phrase)
        let list = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            : parts.joined()
        return "There isn't enough free space to create \(subject). It needs \(byteCountText(check.requiredBytes)) "
            + "on the volume that holds \(location): \(list). Only \(byteCountText(availableBytes)) is available. "
            + "Pomme didn't download or create anything."
    }

    var recoverySuggestion: String? {
        "Free at least \(byteCountText(shortfall)) on that volume, then retry. "
            + "Run `pomme list` to find VMs that you no longer need, and delete them with `pomme delete NAME`."
    }
}
