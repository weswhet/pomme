import Foundation
import Testing

@Suite("Pomme stock account identity")
struct PommeSecurityStockAccountIdentityTests {
  @Test("Known observed stock identities require their exact name, UID, and GeneratedUID")
  func knownStockIdentitiesMatch() {
    let known: [(String, Int64, UUID)] = [
      ("root", 0, deterministicGeneratedUID(0)),
      ("daemon", 1, deterministicGeneratedUID(1)),
      ("nobody", -2, deterministicGeneratedUID(-2)),
      ("_uucp", 4, deterministicGeneratedUID(4)),
    ]

    for (name, uid, generatedUID) in known {
      #expect(PommeSecurityStockAccountIdentity.matches(
        recordName: name, uid: uid, generatedUID: generatedUID
      ))
    }
  }

  @Test("Unknown and mismatched identities fail closed")
  func unknownAndMismatchedIdentitiesFailClosed() {
    let stock499 = deterministicGeneratedUID(499)
    #expect(!PommeSecurityStockAccountIdentity.matches(
      recordName: "alice", uid: 499, generatedUID: stock499
    ))
    #expect(!PommeSecurityStockAccountIdentity.matches(
      recordName: "_custom", uid: 499, generatedUID: stock499
    ))
    #expect(!PommeSecurityStockAccountIdentity.matches(
      recordName: "_uucp", uid: 5, generatedUID: deterministicGeneratedUID(5)
    ))
    #expect(!PommeSecurityStockAccountIdentity.matches(
      recordName: "_uucp", uid: 4,
      generatedUID: UUID(uuidString: "66666666-5555-4444-3333-222222222222")!
    ))
    #expect(!PommeSecurityStockAccountIdentity.matches(
      recordName: "_mbsetupuser", uid: 248, generatedUID: deterministicGeneratedUID(248)
    ))
  }
}

private func deterministicGeneratedUID(_ uid: Int64) -> UUID {
  let suffix = uid == -2 ? UInt32.max - 1 : UInt32(exactly: uid)!
  return UUID(uuidString: String(format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", suffix))!
}
