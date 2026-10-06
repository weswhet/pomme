# macOS 26 native UI enrollment comparison — September 26, 2026 (PDT)

Status: native UI enrollment is resolved by the PKCS12 packaging fix described
in the [diagnostic follow-up](#pkcs12-diagnostic-follow-up). Enrollment was
confirmed by the guest and server and persisted across a normal restart. The VM
is retained stopped. Pomme's private enrollment helper remains unqualified.

Initial attempt status: the original profile failed twice with the same
certificate authentication error, including after explicit server CA trust. The
following initial observations are preserved as evidence preceding the fix.

## Purpose and environment

This attempt tests enrollment through the normal macOS UI using the complete
profile. It compares that path with the failed Pomme enrollment helper attempts
on [macOS 26](2026-09-26-mdm-macos26-comparison.md) and
[macOS 27](2026-09-25-mdm-macos27.md). It does not invoke `pomme mdm` or the private
enrollment helper.

- Fresh clone: `pomme-agent-mdmui26-20260926a`.
- Protected source template: `pomme-agent-ownerloop-base26-20260922a`.
- Guest: macOS 26.6.2 / build `25G83`.
- Resources: 4 GB memory and 40 GB disk, on the internal drive.

The fresh signed build gate passed with installed runner
`/Users/wes/.local/bin/pomme`, version `pomme 0.1.0 (b1cdcc4-dirty)`, and SHA256
`84ae79b2c18c4b4fbe86225b632c68d292e2b4a220a5d22aeda1332e715a7370`.
This is the same binary used in the prior enrollment attempts. The protected
source template remains a template, not a live target.

## Profile and server

The existing NanoHUB server is healthy. A fresh per-device profile was generated
with the existing script in `/Users/wes/dev/nanohub-acme-docker`:

`/Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmui26-20260926a.mobileconfig`.

The profile has mode `0600` and contains the complete root CA, PKCS12 identity,
and MDM payloads. Its CA pin and MDM server, access, signing, topic, and capability
settings match the prior macOS 26 attempt. The device identity is fresh. Profile
contents, credentials, device identifiers, and raw screenshots are excluded from
this record.

## Preparation deviation

The primary agent unnecessarily chose the SIP disable/enable owner-setup route.
Normal UI enrollment requires a usable desktop and does not require this
security change. The first attempt hit the known console transport timeout; an
exact resume created and verified the owner, then disabled SIP at
`2026-09-26T16:22:28Z`.

The user corrected the approach, and the primary agent acknowledged the error.
SIP enable restoration completed at `2026-09-26T16:26:13Z`, before native UI
enrollment. No further SIP or AMFI workflows were used for enrollment or the
controlled retry.

## Native UI results

At `2026-09-26T16:30:04Z`, the first native installation attempt displayed:

> Profile installation failed. The certificate could not be verified (authentication error).

Pomme's MDM command and private enrollment helper were not invoked. The clone
was stopped after the initial attempt.

For one controlled retry, the root CA was imported through Keychain Access into
the System keychain. The certificate matched the expected source pin and was
shown trusted for all users. Guest HTTPS access to the server's version endpoint
succeeded without `-k`.

The unchanged profile was retried once through System Settings administrator
Enrollment at approximately `2026-09-26T16:46:45Z`. It displayed the same exact
alert. No further installation attempts are planned.

Read-only guest checks reported DEP: No, MDM enrollment: No, SIP enabled, and
empty configured NVRAM boot arguments. Final status confirmed the clone stopped
with no running helper. A bounded guest unified-log window from 16:46:15 to
16:48:30 provided no allowlisted error domain with a numeric code.

Server baseline, post-first-attempt, and post-retry queries each found zero
device and enrollment records. Sanitized Caddy and NanoHUB log windows contained
zero lines. That absence is inconclusive and does not establish whether an
attempt reached the server.

## Profile checks and interpretation

Basic OpenSSL checks accepted the PKCS12 password and MAC, matched its key and
certificate, verified the issuer link, and found current certificate validity.
The inspected encryption parameters were PBES2, PBKDF2, AES-256-CBC,
HMAC-SHA256, SHA256 MAC, and 2,048 iterations.

A separate native probe on the macOS 27 host called `SecPKCS12Import` with
`kSecImportToMemoryOnly` true. It returned status 0 and one item. This documented
option avoids Keychain persistence; no host Keychain writes were performed.
Only fixed status and count output was recorded, and the exact probe source,
binary, and temporary directory were removed. This result does not qualify
macOS 26 native UI processing or a file-Keychain import.

The native path also fails, so missing server CA trust is not the sole cause.
The checks do not prove that the profile is valid in every respect or rule out
the server. Profile identity handling, native processing, and server client
authentication remain unresolved possibilities. The original Pomme helper's
generic failure cannot be assigned to PKCS12 import from this evidence alone.

## Cleanup and final state

The first attempt's cleanup removed 19 exact private screenshots and debug files
and three directories. Retry cleanup removed 23 screenshots and their exact
temporary directory. The guest CA staging file
`/Users/pomme/Downloads/openmac26-ui-root-ca.crt` was removed and its absence
verified.

The stopped VM is retained with its journals, required Pomme credential, trusted
System CA, original guest profile at
`/Users/pomme/Downloads/openmac26-ui.mobileconfig`, and the host private profile.
No further installation tests were performed.

No enrollment success or production repair is claimed. No production source
changes were made for this attempt.

## PKCS12 diagnostic follow-up

The following work extends the observations above. The corrected profile succeeded in the native UI. Database evidence and
restart verification confirmed the enrollment.

On host macOS 27, the original identity imported successfully through
`SecPKCS12Import` both in memory and into an explicit isolated file Keychain
(status 0, one item). A comparison with `SecItemImport` and
`SecKeychainItemImport` produced a different result:

| PKCS12 protection / MAC | Both legacy import APIs |
| --- | --- |
| AES / SHA256 (original) | `-25264` |
| AES / SHA1 | `-25257` |
| 3DES / SHA256 | `-25264` |
| 3DES / SHA1 | Status 0; isolated file import returned three items |

Each result was reproduced with no-Keychain inspection and an explicit isolated
file Keychain. All variants preserved the identity, password, and certificate
chain. Temporary Keychains were deleted through the native API; exact helper
sources, binaries, and temporary directories were removed. No real host Keychain
or search-list changes were made.

OpenSSL documents AES/PBKDF2, SHA256 MAC, and 2,048 iterations as its defaults.
See the [OpenSSL PKCS12 documentation](https://docs.openssl.org/3.5/man1/openssl-pkcs12/).
The actual comparisons above demonstrate an import API compatibility difference;
they do not establish which private API the native UI calls. The native alert
text maps to the `CertificatePasswordError` resource key, but that mapping alone
does not identify the failing API.

A private candidate profile was created at
`/Users/wes/dev/nanohub-acme-docker/local/profiles/pomme-agent-mdmui26-20260926a-importfix.mobileconfig`.
Only the PKCS12 `PayloadContent` differs semantically from the original profile.
Its key, certificates, password, identifiers, MDM settings, and root payload are
unchanged. Native UI installation began at `2026-09-26T17:17:12Z` and succeeded
at approximately `17:18Z`. Device Management showed the VM supervised and managed
by the lab MDM server's organization, with three installed settings and an Unenroll control. This
controlled change confirms PKCS12 packaging compatibility as the cause of the
observed native UI failure. No new SIP, AMFI, or private-helper workflow was used.
Both protected templates remain unchanged.

Independent server TLS checks found the leaf and intermediate chain, the exact
IP subject alternative name, successful root verification (status 0), and host
HTTPS status 200. After the earlier failed retry and reboot, the expected guest
System root was absent, explaining that guest's curl status 60. The reason for
the root's disappearance remains unproven. The initial access-log sanitizer missed JSON embedded in Caddy console lines,
including a known GET. Those initial empty results were therefore inconclusive.
The corrected parser confirms three `PUT /mdm` requests returning HTTP 200 at
`17:18:05Z`, another at `17:19:52Z`, and later successful `GET /version` requests.
NanoHUB logs contain six entries matching this clone from `17:18:05.470` through
`17:19:52.114`. No raw private log content is included here. Rechecking with the corrected
parser found zero HTTP events, including zero MDM requests, in both failed
windows: `16:28:30–16:31:00Z` and `16:46:15–16:49:00Z`. The control window
`16:42–16:43Z` contained one `GET /version` HTTP 200 event. The successful window
`17:17–17:21Z` contained six events: four `PUT /mdm` HTTP 200 responses and two
`GET /version` HTTP 200 responses. This confirms logging worked and recorded no
MDM HTTP request during either failed window, consistent with the controlled
import comparison and successful UI retry.

### Generator fix and preflight

In `/Users/wes/dev/nanohub-acme-docker`, the profile generator now explicitly
selects `PBE-SHA1-3DES` for key and certificate protection, SHA1 MAC, and 2,048
iterations. This changes container encoding while preserving identity generation
and TLS settings; it does not use broad `-legacy` defaults or RC2.

The new `scripts/check-profile-pkcs12.sh` checks embedded identities through
`SecItemImport` with no destination Keychain or returned items. Profile passwords
remain in process memory, and output contains only fixed stages and numeric
statuses. The actual script rejected the original profile with `-25264` and
accepted the candidate with status 0. Shell syntax and explicit whitespace checks
passed. The lab MDM server's setup notes document the compatibility scope and preflight.

The generator and setup guide were already locally excluded from Git; the new
checker is untracked. No exclusions were changed, commits created, or server
services restarted. Server database confirmation and persistence across a normal
restart both passed. The Pomme private enrollment helper was not retested
under the user's instruction to avoid further SIP changes; this result does not
qualify that helper or establish that its generic failure is fixed.

### Final enrollment and cleanup verification

The exact server query found one device and one enabled Device enrollment, with
`token_update_tally` 1 and creation/update time `2026-09-26 17:18:05 UTC`.
Guest read-only checks confirmed enrollment, the expected System root CA pin,
and HTTPS status 200 with standard certificate verification.

After one normal restart, independent guest checks still reported MDM enrollment
and user approval. The System root pin still matched, and the server version
endpoint returned HTTP 200 without bypassing certificate verification.

The candidate guest staging file
`/Users/pomme/Downloads/openmac26-ui-importfix.mobileconfig` was removed. The
original guest profile remains for inspection. Seven known screenshots and the
exact `/private/tmp/pomme-agent-mdmui26-20260926a.importfix` directory were removed,
and their absence was verified. Final state is stopped with no running helper.
The VM, enrollment, trusted CA, required credentials, journals, and private host
profiles are retained.

No SIP, AMFI, `pomme mdm`, or private enrollment helper operation occurred during
this follow-up. Both protected templates remain unchanged.
