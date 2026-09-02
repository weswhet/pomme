import Foundation
import Testing

@Suite("Stable VM network identity")
struct StableVMMACAddressTests {
    @Test("Machine identifier derives a stable locally administered unicast MAC")
    func stableLocallyAdministeredUnicastAddress() throws {
        let identifier = Data(0...31)

        let first = PommeCore.stableVMMACAddress(machineIdentifierData: identifier)
        let second = PommeCore.stableVMMACAddress(machineIdentifierData: identifier)
        let octets = try octets(in: first)

        #expect(first == second)
        #expect(octets.count == 6)
        #expect(octets[0] & 0b0000_0001 == 0)
        #expect(octets[0] & 0b0000_0010 == 0b0000_0010)
    }

    @Test("Different machine identifiers have distinct configuration compatibility evidence")
    func distinctIdentifiersChangeMACAndConfigurationDigest() throws {
        let firstIdentifier = Data(repeating: 0x11, count: 32)
        let secondIdentifier = Data(repeating: 0x22, count: 32)

        let firstMAC = PommeCore.stableVMMACAddress(machineIdentifierData: firstIdentifier)
        let secondMAC = PommeCore.stableVMMACAddress(machineIdentifierData: secondIdentifier)
        let firstDigest = try VMSnapshotStore.configurationCompatibilityDigest(
            machineIdentifierData: firstIdentifier,
            memorySize: Constants.defaultMemorySizeBytes
        )
        let repeatedDigest = try VMSnapshotStore.configurationCompatibilityDigest(
            machineIdentifierData: firstIdentifier,
            memorySize: Constants.defaultMemorySizeBytes
        )
        let secondDigest = try VMSnapshotStore.configurationCompatibilityDigest(
            machineIdentifierData: secondIdentifier,
            memorySize: Constants.defaultMemorySizeBytes
        )

        #expect(firstMAC != secondMAC)
        #expect(firstDigest == repeatedDigest)
        #expect(firstDigest != secondDigest)
    }

    private func octets(in address: String) throws -> [UInt8] {
        let values = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard values.count == 6 else {
            throw RunnerError.hostCommandFailed("Invalid generated MAC address.")
        }
        return values
    }
}
