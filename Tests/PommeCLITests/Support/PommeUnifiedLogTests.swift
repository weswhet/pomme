import Foundation
import Testing

@Suite("Unified log scrubbing")
struct PommeUnifiedLogTests {
    private let digest = "9ed7a91fa8f5bc18e42982628d6e7a041363a437c2fd7e3a48e264186fe14ac7"

    @Test("Diagnostics that only name a secret are kept", arguments: [
        "bootstrap checkpoint stage=agentCredentialAvailable",
        "framework verification checkpoint stage=ownerProof",
        "Owner console proof failed: exact owner and UID did not match before the deadline; VM retained.",
        "template agent adoption skipped: the template's credential is missing",
        "APFS owner evidence: recognized MDM bootstrap-token key; classified as non-account.",
        "security journal credentialRecorded=true attempt=2",
        "xrec-debug cloned pomme-agent-ownerloop-base26-20260922a vm=51f22665-f566-4286-aa74-6ead01a01470",
        "/Users/example/Library/Application Support/pomme/VMs/dev-latest.bundle/Disk.img",
    ])
    func keepsDiagnostics(_ text: String) {
        #expect(PommeUnifiedLog.scrubbed(text) == text)
    }

    @Test("Secret values are redacted and the rest of the message is kept", arguments: [
        ("login failed password=hunter2 for pomme", "login failed password=<redacted> for pomme"),
        ("request {\"agentToken\": \"abc123\"} rejected", "request {\"agentToken\": <redacted>} rejected"),
        ("passphrase: 'open sesame' was wrong", "passphrase: <redacted> was wrong"),
        ("header Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.x sent", "header Authorization: <redacted> <redacted> sent"),
        ("sent Bearer eyJhbGciOiJIUzI1NiJ9.e30.x upstream", "sent Bearer <redacted> upstream"),
        ("key -----BEGIN OPENSSH PRIVATE KEY----- AAAA -----END OPENSSH PRIVATE KEY----- end", "key <redacted key> end"),
    ])
    func redactsValues(_ text: String, _ expected: String) {
        #expect(PommeUnifiedLog.scrubbed(text) == expected)
    }

    @Test("Long letter-and-digit runs keep only a prefix")
    func shortensOpaqueRuns() {
        #expect(PommeUnifiedLog.scrubbed("agent digest \(digest) matched") == "agent digest 9ed7a91f… matched")
        let words = "PommeRecoveryVirtualizationKeyboardPortTests"
        #expect(PommeUnifiedLog.scrubbed(words) == words)
    }

    @Test("Newlines are flattened and long text is capped")
    func flattensAndCaps() {
        #expect(PommeUnifiedLog.scrubbed("one\ntwo\r\nthree") == "one two three")
        #expect(PommeUnifiedLog.scrubbed(String(repeating: "a ", count: 1000)).count == 1024)
    }
}
