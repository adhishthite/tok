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

Source `061f46c1b42a` is packaged as version 0.1.0, build 4, for `x86_64 arm64`.
The app declares macOS 14.0 and `LSUIElement = true`. The validated Keychain
profile is `TokNotary`; use `NOTARY_PROFILE=TokNotary` with the notarization
commands. No credential values belong in source or logs.

Both Apple submissions returned `Accepted`:

- App ZIP: `c4ccbbf3-6d56-4ca7-969c-08b2abb381e4`.
- Final DMG: `7ed95d29-ef39-41b1-b91a-f8154cfba493`.

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
| `build/package/Tok.dmg` | 2718337 | `a5a2913c516eb1c8ed44a3646d8c55ff418d36ff25212e00d762f43d4bbb6bb3` |
| `build/package/Tok-distribution.zip` | 2636078 | `ccfd2e270f659f3f262ad348b33cd33c2b07d4db669a31e4d827837bb8039f01` |

`build/package/verification.json` records the checks, identities, and hashes.
Rebuilding the containers changes these artifacts and removes the final DMG's
stapled ticket, so do not rebuild them to repeat verification. The original
archive/export build log is `/tmp/tok-cleanup-distribution.log`.

Builds 1, 2, and 3 and their verification records are preserved under
`build/package/build-1/`, `build/package/build-2/`, and `build/package/build-3/`.

## Remaining distribution gates

The verified release was installed at `/Applications/Tok.app` after confirming
that no app existed at that path. Its ticket, signature, and Gatekeeper checks
passed before installation. The development copy quit normally, and process
inspection confirmed the release running from Applications at source
`67ef83eef079`, version 0.1.0, without development launch arguments. This used
the owner's existing macOS account and does not satisfy the fresh-account gate.

Build 3 (`1d181bd6d8a9`) subsequently replaced build 2 in Applications. Their
designated signing requirements matched, and the candidate passed ticket,
signature, and Gatekeeper checks before replacement. The app quit normally and
was relaunched from the same installation path. Process inspection confirmed
that path; Info.plist confirmed build 3. Previous installed bundles remain in
`build/installed-backups/`. This was a local replacement, not a Sparkle update.

Build 4 (`061f46c1b42a`) replaced build 3 after the same signature and ticket
checks. The installed process was verified at `/Applications/Tok.app`, and its
Gatekeeper assessment passed. Cleanup and app-aware formatting remain off.
The build 3 application remains in `build/installed-backups/build-3/`.

Build 4 initially encountered an unavailable `TokNotary` profile. Once the profile
was accessible, Apple history confirmed no submission from that attempt. The
failed-attempt state was preserved as a `.credential-failure.json` backup before
submitting the unchanged archive. Both resulting submissions were accepted.

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

## Build 5 prepared on 2026-09-06

Version 0.1.0, build 5, was built from the clean isolated commit `138a64fe65fe`.
It includes the committed History loading fix. Concurrent accessibility changes
were excluded. The archive and export passed within the 120-second deadline.
The complete build log is `/tmp/tok-build5-distribution.log`.

Apple accepted the app submission `4844c9b5-9427-4543-b6ce-d89f799eb68b` and DMG
submission `a39fc72a-2bd8-4643-aadd-e8cd38c1e0b5`. Each artifact was submitted
once, then its saved submission was checked. App and DMG stapling passed.
Deep strict app signatures, strict DMG signature, and Gatekeeper assessments
passed. The app extracted from the ZIP and the app on a read-only DMG mount
also passed signature, ticket, and Gatekeeper checks. The DMG included the
Applications shortcut; its verification mount was detached.

The app declares macOS 14.0, both `x86_64 arm64` architectures, and `LSUIElement`.
It has no hosted update feed. Build 5 is prepared, not installed or published.
The installed build 4 and its artifacts were not changed.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/package/build-5/Tok.dmg` | 2719587 | `7a830c97b88db2ac7a85311c16e6dc52d78deba13f4dccd7d66740c9ef9444b7` |
| `build/package/build-5/Tok-distribution.zip` | 2637204 | `f3794a59940fdc78c410ee9a4d8fb85e3ec3f0a0997571a6f754edddb13c7834` |

The signed app, saved notarization state, and `verification.json` are preserved
in `build/package/build-5/`. No fresh-Mac or installed-update claim follows from
these local artifact checks.
