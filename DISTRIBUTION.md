# Local distribution workflow

Nothing here uploads a public release, creates a tag, or pushes Git commits.
Notarization sends the signed archive to Apple's notary service.

## Build

`make distribute` archives and exports a universal Developer ID application,
then creates `build/package/Tok.dmg` and `Tok-distribution.zip`.
It requires a Developer ID Application identity in Keychain. The DMG includes
Tok and an Applications shortcut. `make containers` recreates those containers
from the existing `build/distribution/Tok.app` without rebuilding the app.

Xcode archive and export each have a 120-second deadline. Container creation
has a 60-second deadline per command. Identity lookup and signing are bounded.
Only extend a live command after inspecting progress, using the control path
printed by `Scripts/bounded_run.py`. Extensions are limited to 60 seconds.

## Notarize

Complete the source security review before submission. Configure credentials
directly with Apple's `notarytool store-credentials` interactive flow, outside
logs and source control. Set `NOTARY_PROFILE` to that Keychain profile's name.
The scripts accept no password, private key, or token on their command line.

1. Run `make notarize-app`. This submits the ZIP once. If Apple reports
   `In Progress`, the command stops with exit 75 from the Python helper.
   Run the same target later to check the saved submission. Once accepted,
   it staples and validates the app, then rebuilds the ZIP and signed DMG.
2. Run `make notarize-dmg`. This submits the final DMG, with the same resumable
   behavior, then staples and validates it. It also runs `spctl --assess`
   against the app. Do not rebuild containers after this step.
3. Test a fresh download on another Mac before distributing it to users.

Submission state is saved under `build/notary/`, indexed by archive SHA-256.
Do not run `make clean` while a submission is pending. Uploads have a 120-second
timeout and status queries have a 30-second timeout. There is no polling loop.
An interrupted upload without a captured ID is deliberately not retried.
Inspect `notarytool history` using the same Keychain profile to identify the
submission for that exact archive, then recover it with:

```sh
python3 Scripts/notarize.py build/package/Tok-distribution.zip --submission SUBMISSION_ID
```

Use the DMG path instead when recovering its submission. Rejected submissions
remain recorded. Inspect Apple's submission log before changing the build.

## Updates

Sparkle 2.9.6 is pinned in `project.yml`. Set `TOK_UPDATE_FEED_URL` to the public
HTTPS appcast URL before building. Credentials, query strings, and fragments
are rejected. No host is selected by default, so update checks remain inactive.
Tok requires signed feeds and verifies update archives before extraction.
Release notes use no embedded web view, and system profile submission is off.

The public Ed25519 key in `Config/Info.plist` belongs to the dedicated Keychain
account `com.adhishthite.tok`. Its private key stays in Keychain. Do not generate
a replacement for an existing release without planning key rotation.
Use the bundled `generate_appcast --account com.adhishthite.tok` tool on a
directory containing only final, notarized update archives. Supply the approved
download URL prefix. The tool signs both the archive entries and the feed.
Increment `CURRENT_PROJECT_VERSION` for every update. Verify an actual update
from the previous build before publishing the archive and feed together.

`make check-updates` exercises local signing with the built Debug app. It checks
the embedded public key against the signing key, generates a feed using a reserved
`.invalid` download host, verifies signatures, and rejects modified copies.
Each command has a 30-second limit and the signing phase has a 120-second limit.
Artifacts stay in a marked test-only directory under `build/`; the command does
not publish anything or install an update. A cryptographic failure must be
reported explicitly; authentication failures cannot count as tamper rejection.

On 2026-09-06, the embedded public-key comparison passed, but `generate_appcast`
timed out. A one-second process sample showed it waiting in `SecItemCopyMatching`
and Keychain decryption. A second bounded attempt stopped with exit 124. No
generator process remained. Feed generation, signature verification, and tamper
rejection have not yet run successfully with this Keychain. macOS authorization
may be needed; no signing success is inferred from the mock script tests.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).

## Current limits

The 2026-09-06 refresh packaged source `67ef83eef079` as version 0.1.0, build 1.
`make distribute` exited 0 with `ARCHIVE SUCCEEDED` and `EXPORT SUCCEEDED`.
`codesign --verify --deep --strict --verbose=2` passed for the exported app;
strict signature verification also passed for the DMG. `lipo -archs` returned
`x86_64 arm64`, and the app declares macOS 14.0 and `LSUIElement = true`.

The ZIP's Info.plist matched the source identity and its entries contained no
`.env` files. A read-only DMG mount contained the same signed build and an
Applications shortcut; it was detached after verification. These checks do not
prove a successful fresh-Mac install. Artifacts from this checkpoint:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/package/Tok.dmg` | 2646001 | `bbfc13327ac85c6ed73428810612da45d648db0cd4108eb62ba78a8e9b25c002` |
| `build/package/Tok-distribution.zip` | 2546200 | `772bbdbb66b0d856c6456ac04b9845a0e137796bdfa47f95c2d71ed77d466994` |

The exact app again failed `spctl --assess --type execute --verbose=2` with
`rejected`, `source=Unnotarized Developer ID`. No submission was attempted.
The build log is `/tmp/tok-distribution-67ef83e.log`. Rebuilding or stapling
changes artifact hashes, so these values identify only this checkpoint.

Local archive, export, and signed-container creation have been exercised.
Notarization credentials and a public feed URL are not configured in this
session. Notarization, Gatekeeper acceptance, an installed Sparkle update,
and fresh-Mac installation remain unverified. The current `spctl --assess`
result is `rejected`, `source=Unnotarized Developer ID`.

The source security review at revision `42ed1f0` covered all 185 files in its
source/configuration inventory and reported two low-severity findings: stale
transcript visibility after enabling privacy and cascading replacement expansion.
Both have now been addressed with regression tests. The review was sequential,
without an independent worker, and did not audit macOS or Sparkle internals or
certify runtime release behavior. The generated report remains a record of the
audited revision, not a report rewritten to hide its findings.
