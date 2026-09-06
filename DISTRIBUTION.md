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

The earlier Keychain signing timeout is resolved. Running
`python3 Scripts/check_updates.py` under a 120-second supervisor completed with:

```text
PASS: embedded public key matches the signing key.
PASS: generated feed and archive signatures verify.
PASS: modified feed and archive are rejected.
```

The real signing tools used the existing Keychain key. Test-only artifacts are
in `build/sparkle-check-bwxct1gq/`. This verifies local cryptographic behavior;
it does not verify a hosted feed or an installed update.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).

## Verified notarized distribution

Source `67ef83eef079` is packaged as version 0.1.0, build 1, for `x86_64 arm64`.
The app declares macOS 14.0 and `LSUIElement = true`. The validated Keychain
profile is `TokNotary`; use `NOTARY_PROFILE=TokNotary` with the notarization
commands. No credential values belong in source or logs.

Both Apple submissions returned `Accepted`:

- App ZIP: `31d9978c-fe18-4a21-bf46-6aaa296bd7c5`.
- Final DMG: `2a261a52-6a48-456f-a806-2ae742b5419d`.

`make notarize-app` attached and validated the app ticket, then rebuilt the
containers. `make notarize-dmg` attached and validated the DMG ticket. Both were
run with `NOTARY_PROFILE=TokNotary` and 120-second outer deadlines. No upload
was repeated while awaiting a verdict.

`spctl --assess --type execute --verbose=2 build/distribution/Tok.app` returned:

```text
build/distribution/Tok.app: accepted
source=Notarized Developer ID
```

The DMG also passed `spctl --assess --type open --context
context:primary-signature --verbose=2`. Strict code-signature checks passed for
the app and DMG. Separately, the app extracted from the final ZIP and the app on
a read-only DMG mount each passed `stapler validate`, deep strict signature
verification, and `spctl --assess --type execute`. The mounted app matched the
source revision and the DMG contained the Applications shortcut. The temporary
ZIP extraction was removed and the verification volume was detached.

Final artifacts after stapling:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/package/Tok.dmg` | 2650452 | `e4901abff6c2757d7a61cc0fdc48d42d7bed91923278fd24ff9d8d6ecba08755` |
| `build/package/Tok-distribution.zip` | 2548052 | `daf4bffee9effa125124fc43211826467f06aa708a18dc073a99f19374235fa5` |

`build/package/verification.json` records the checks, identities, and hashes.
Rebuilding the containers changes these artifacts and removes the final DMG's
stapled ticket, so do not rebuild them to repeat verification. The original
archive/export build log is `/tmp/tok-distribution-67ef83e.log`.

## Remaining distribution gates

No artifacts, tags, releases, or update feeds have been published. A hosted
update feed, an installed Sparkle update, and installation on a fresh Mac remain
unverified. Local Gatekeeper acceptance is not a fresh-Mac installation test.

The source security review at revision `42ed1f0` covered all 185 files in its
source/configuration inventory and reported two low-severity findings: stale
transcript visibility after enabling privacy and cascading replacement expansion.
Both have now been addressed with regression tests. The review was sequential,
without an independent worker, and did not audit macOS or Sparkle internals or
certify runtime release behavior. The generated report remains a record of the
audited revision, not a report rewritten to hide its findings.
