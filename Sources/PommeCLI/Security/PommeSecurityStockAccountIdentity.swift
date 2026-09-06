import Foundation

/// Exact stock local-account identities captured from the untouched Tahoe
/// 26.6.2 (25G83) pre-owner VM on 2026-09-05. This is experimental evidence,
/// not a universal macOS inventory. Records outside this observed baseline
/// return false so a new OS/account fails closed until independently verified.
/// `_mbsetupuser` is intentionally omitted; Setup Assistant has a separate
/// evidence path for that account.
enum PommeSecurityStockAccountIdentity: Sendable {
  /// Returns true only for an observed account name and UID whose GeneratedUID
  /// matches the exact stock deterministic identity for that UID. The caller
  /// must keep all unknown accounts in the normal-user set.
  static func matches(recordName: String, uid: Int64, generatedUID: UUID) -> Bool {
    guard let expectedUID = stockUIDs[recordName], expectedUID == uid,
      let expectedGeneratedUID = deterministicGeneratedUID(for: uid)
    else { return false }
    return generatedUID == expectedGeneratedUID
  }

  private static let stockUIDs: [String: Int64] = [
    "_accessoryupdater": 278,
    "_amavisd": 83,
    "_analyticsd": 263,
    "_aonsensed": 300,
    "_appinstalld": 273,
    "_appleevents": 55,
    "_applepay": 260,
    "_appowner": 87,
    "_appserver": 79,
    "_appstore": 33,
    "_ard": 67,
    "_assetcache": 235,
    "_astris": 245,
    "_atsserver": 97,
    "_audiomxd": 294,
    "_avbdeviced": 229,
    "_avphidbridge": 288,
    "_backgroundassets": 291,
    "_biome": 289,
    "_calendar": 93,
    "_captiveagent": 258,
    "_ces": 32,
    "_clamav": 82,
    "_cmiodalassistants": 262,
    "_coreaudiod": 202,
    "_coremediaiod": 236,
    "_coreml": 280,
    "_corespeechd": 306,
    "_ctkd": 259,
    "_cvmsroot": 212,
    "_cvs": 72,
    "_cyrus": 77,
    "_darwindaemon": 284,
    "_datadetectors": 257,
    "_demod": 275,
    "_devdocs": 59,
    "_devicemgr": 220,
    "_diagnosticservicesd": 307,
    "_diskimagesiod": 271,
    "_displaypolicyd": 244,
    "_distnote": 241,
    "_dovecot": 214,
    "_dovenull": 227,
    "_dpaudio": 215,
    "_driverkit": 270,
    "_eligibilityd": 297,
    "_eppc": 71,
    "_findmydevice": 254,
    "_fpsd": 265,
    "_ftp": 98,
    "_gamecontrollerd": 247,
    "_geod": 56,
    "_hidd": 261,
    "_iconservices": 240,
    "_installassistant": 25,
    "_installcoordinationd": 274,
    "_installer": 96,
    "_jabber": 84,
    "_kadmin_admin": 218,
    "_kadmin_changepw": 219,
    "_knowledgegraphd": 279,
    "_krb_anonymous": 234,
    "_krb_changepw": 232,
    "_krb_kadmin": 231,
    "_krb_kerberos": 233,
    "_krb_krbtgt": 230,
    "_krbfast": 246,
    "_krbtgt": 217,
    "_launchservicesd": 239,
    "_lda": 211,
    "_locationd": 205,
    "_logd": 272,
    "_lp": 26,
    "_mailman": 78,
    "_mcxalr": 54,
    "_mdnsresponder": 65,
    "_mds_stores": 308,
    "_mmaintenanced": 283,
    "_mobileasset": 253,
    "_mobilegestalthelper": 293,
    "_modelmanagerd": 301,
    "_mysql": 74,
    "_naturallanguaged": 304,
    "_nearbyd": 268,
    "_netbios": 222,
    "_netstatistics": 228,
    "_networkd": 24,
    "_neuralengine": 296,
    "_notification_proxy": 285,
    "_nsurlsessiond": 242,
    "_oahd": 441,
    "_ondemand": 249,
    "_postfix": 27,
    "_postgres": 216,
    "_qtss": 76,
    "_reportmemoryexception": 269,
    "_reportsystemmemory": 302,
    "_rmd": 277,
    "_sandbox": 60,
    "_screensaver": 203,
    "_scsd": 31,
    "_securityagent": 92,
    "_sntpd": 281,
    "_softwareupdate": 200,
    "_spinandd": 305,
    "_spotlight": 89,
    "_sshd": 75,
    "_svn": 73,
    "_swtransparencyd": 303,
    "_systemstatusd": 298,
    "_taskgated": 13,
    "_teamsserver": 94,
    "_terminusd": 295,
    "_timed": 266,
    "_timezone": 210,
    "_tokend": 91,
    "_trustd": 282,
    "_trustevaluationagent": 208,
    "_unknown": 99,
    "_update_sharing": 95,
    "_usbmuxd": 213,
    "_uucp": 4,
    "_warmd": 224,
    "_webauthserver": 221,
    "_windowserver": 88,
    "_www": 70,
    "_wwwproxy": 252,
    "_xserverdocs": 251,
    "daemon": 1,
    "nobody": -2,
    "root": 0,
  ]

  private static func deterministicGeneratedUID(for uid: Int64) -> UUID? {
    let suffix: UInt32
    if uid == -2 {
      suffix = UInt32.max - 1
    } else {
      guard (0..<500).contains(uid), let value = UInt32(exactly: uid) else {
        return nil
      }
      suffix = value
    }
    return UUID(uuidString: String(format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", suffix))
  }
}
