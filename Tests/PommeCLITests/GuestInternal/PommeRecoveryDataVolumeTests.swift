import Foundation
import Testing

@Suite("Pomme Recovery Data-volume resolver")
struct PommeRecoveryDataVolumeTests {
    @Test("selects only the request-bound System and Data volume group")
    func selectsBoundGroup() throws {
        let group = UUID()
        let record: [String: Any] = ["APFSVolumeGroupUUID": group.uuidString, "Volumes": [
            ["Role": "System", "DeviceIdentifier": "disk9s1"],
            ["Role": "Data", "DeviceIdentifier": "disk9s5"]
        ]]
        let data = try groupsPlist([record])
        #expect(try PommeRecoveryDataVolumeResolver.resolveDataVolume(from: data, expectedVolumeGroupUUID: group) == .init(volumeGroupUUID: group, systemDevice: "disk9s1", dataDevice: "disk9s5"))
    }

    @Test("rejects ambiguous, unsafe, and wrongly bound volume groups")
    func rejectsUnsafeGroups() throws {
        let expected = UUID()
        let other = UUID()
        let wrong = try groupsPlist([[
            "APFSVolumeGroupUUID": other.uuidString,
            "Volumes": [["Role": "System", "DeviceIdentifier": "disk9s1"], ["Role": "Data", "DeviceIdentifier": "disk9s5"]]
        ]])
        #expect(throws: PommeRecoveryDataVolumeResolver.Error.self) {
            try PommeRecoveryDataVolumeResolver.resolveDataVolume(from: wrong, expectedVolumeGroupUUID: expected)
        }
        let unsafe = try groupsPlist([[
            "APFSVolumeGroupUUID": expected.uuidString,
            "Volumes": [["Role": "System", "DeviceIdentifier": "disk9s1"], ["Role": "Data", "DeviceIdentifier": "../disk9s5"]]
        ]])
        #expect(throws: PommeRecoveryDataVolumeResolver.Error.self) {
            try PommeRecoveryDataVolumeResolver.resolveDataVolume(from: unsafe, expectedVolumeGroupUUID: expected)
        }
    }

    @Test("binds mount metadata to the selected APFS Data member")
    func validatesMount() throws {
        let group = UUID()
        let volume = PommeRecoveryDataVolumeResolver.Volume(volumeGroupUUID: group, systemDevice: "disk9s1", dataDevice: "disk9s5")
        let data = try plist([
            "DeviceIdentifier": "disk9s5", "FilesystemType": "apfs",
            "APFSVolumeGroupUUID": group.uuidString, "MountPoint": "/Volumes/Pomme Data"
        ])
        #expect(try PommeRecoveryDataVolumeResolver.dataMountURL(from: data, expected: volume).path == "/Volumes/Pomme Data")
    }

    @Test("accepts Tahoe role encodings and initial uniquely eligible selection")
    func acceptsTahoeRoleVariants() throws {
        let group = UUID()
        for roleKey in ["Roles", "Role", "APFSVolumeRole"] {
            let systemRole: Any = roleKey == "Roles" ? ["System"] : "System"
            let dataRole: Any = roleKey == "Roles" ? ["Data"] : "Data"
            let record: [String: Any] = [
                "APFSVolumeGroupUUID": group.uuidString,
                "Volumes": [[roleKey: systemRole, "DeviceIdentifier": "disk9s1"], [roleKey: dataRole, "DeviceIdentifier": "disk9s5"]]
            ]
            #expect(try PommeRecoveryDataVolumeResolver.resolveDataVolume(from: groupsPlist([record]), expectedVolumeGroupUUID: nil).volumeGroupUUID == group)
        }
    }

    @Test("requires diskNsM APFS identifiers")
    func rejectsWholeDiskIdentifier() throws {
        let group = UUID()
        let record: [String: Any] = [
            "APFSVolumeGroupUUID": group.uuidString,
            "Volumes": [["Role": "System", "DeviceIdentifier": "disk9"], ["Role": "Data", "DeviceIdentifier": "disk9s5"]]
        ]
        #expect(throws: PommeRecoveryDataVolumeResolver.Error.self) {
            try PommeRecoveryDataVolumeResolver.resolveDataVolume(from: groupsPlist([record]), expectedVolumeGroupUUID: group)
        }
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    private func groupsPlist(_ groups: [[String: Any]]) throws -> Data {
        try plist(["Containers": [["VolumeGroups": groups]]])
    }
}
