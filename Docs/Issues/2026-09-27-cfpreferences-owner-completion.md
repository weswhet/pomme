# CFPreferences owner-completion experiment

## Request and scope

The user requested trying CFPreferences instead of `defaults` for the two
per-user completion preferences and asked whether performing the work directly
when the guest agent starts under launchd would help. This authorized a new
bounded attempt on the retained native arm,
`pomme-agent-autologin-native26-20260927a`. The legacy arm and protected templates
were not operated.

Apple documentation was read through Sosumi:

- [CFPreferencesSetValue](https://developer.apple.com/documentation/corefoundation/cfpreferencessetvalue(_:_:_:_:_:))
- [CFPreferencesSynchronize](https://developer.apple.com/documentation/corefoundation/cfpreferencessynchronize(_:_:_:))
- [CFPreferencesCopyValue](https://developer.apple.com/documentation/corefoundation/cfpreferencescopyvalue(_:_:_:_:))
- [kCFPreferencesCurrentUser](https://developer.apple.com/documentation/corefoundation/kcfpreferencescurrentuser)

The API accepts predefined user/host qualifiers; Apple explicitly advises
against arbitrary user/host names. SetValue has no success return. The same
domain must be synchronized, and synchronization returns false on error.

## Implementation and verification

Added a standalone, nonproduction C probe at
`Scripts/Labs/CFPreferencesProbe.c`. It uses exact-domain current-user/any-host
CFPreferences calls, with explicit string/boolean types and synchronization
before readback. It accepts only write or verify mode, the `pomme` UID/EUID,
`/Users/pomme` home, and guest build `25G83`. The first failure exits before the
second preference. It never accepts credentials or arbitrary preference names.

The canonical Pomme signed build/install passed again; fresh-login resolution
was `/Users/wes/.local/bin/pomme`, version `0.1.0 (b1cdcc4-dirty)`. Signed runner
digest remained `bb7768a2680d10cd6c93f1460d93a4729fa1afbd1fab6931aa6a0dfc5f35cdfd`.

Native `xcrun clang` compiled the probe for arm64/macOS 26 with
`-Wall -Wextra -Werror -framework CoreFoundation`. Developer ID signing,
Hardened Runtime, secure timestamp, and explicit identifier/team verification
passed. Probe SHA-256:
`e3a094f8fa5d0e6a996ca529d1960056419d04238db0cb2b6b6f7fe18b6a36dd`.

Before the attempt, the exact clone was running normally with a connected
creation-pinned agent. The signed runner transferred the probe with matching
SHA-256 to `/private/tmp/pomme-cfprefs-20260927-KTIB0I`, then made it executable.
The guest agent launched:

```sh
/usr/bin/sudo -n -H -u pomme /private/tmp/pomme-cfprefs-20260927-KTIB0I write
```

## Result

The command exited 1. Its complete application diagnostics were:

```text
stage=context uid=501 euid=501 ownerUID=501 homeMatches=true accountHomeMatches=true
stage=context mode=write home=/Users/pomme guestBuild=25G83
stage=com.apple.SetupAssistant/LastSeenBuddyBuildVersion action=set expectedType=CFString
stage=com.apple.SetupAssistant/LastSeenBuddyBuildVersion action=synchronize success=false scope=currentUser/anyHost
error stage=com.apple.SetupAssistant/LastSeenBuddyBuildVersion reason=CFPreferencesSynchronize-returned-false
```

The probe did not attempt `MiniBuddyLaunch`, and the independent verify process
was not launched because synchronization failed. No further guest commands,
restart, automatic cleanup, marker write, or security change followed the
failure. The probe and VM state were retained for inspection.

Using CFPreferences directly in the same owner execution context did not resolve
the first write failure. The API's boolean result does not establish whether the
cause is session context, preferences-service state, or filesystem policy. This
was a later attempt on the retained failed clone, not a fresh first-boot timing
comparison. It did not test writing from inside the persistent daemon itself.

## Agent startup evaluation

The existing call chain is host orchestration, authenticated guest agent, then
`sudo -n -H -u pomme defaults`. The writes already execute inside the guest.
`PommeAgentInstall.swift` installs a system LaunchDaemon with RunAtLoad and
KeepAlive, without a UserName override. `PommeAgentDaemon.run` starts the service
and host connection loop; it does not prepare the owner or mutate preferences.
The fresh owner is created later by the host-driven owner workflow.

Moving the calls into the daemon's startup would initially run them as root and
potentially before the owner exists. CurrentUser would then select root's
preferences; AnyUser would select a different system-wide scope. A dedicated
owner-context helper or user LaunchAgent could provide a different execution
context, but merely moving the existing calls into daemon startup does not prove
that the failing owner preference domain becomes writable. Session/bootstrap
context remains a hypothesis, not an established cause. Production startup and
preference behavior were not changed by this experiment.
