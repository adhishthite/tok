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

## Build 6 prepared on 2026-09-06

Version 0.1.0, build 6, was built from clean isolated commit `2c22537f7932`,
including the History fix and accessibility improvements. Archive and export
passed within the 120-second deadline. The build log is
`/tmp/tok-build6-distribution.log`.

Apple accepted app submission `b6b2757d-2ada-4b55-b1d0-dd298b7c9225` and DMG
submission `63296fd3-1c24-4bb4-9d57-83b5601a84cd`. Each was uploaded once, then
checked using its saved ID. App and DMG stapling passed. The first container
rebuild after app stapling returned `hdiutil: create failed - Resource busy`;
one bounded container-only retry passed. No notarization upload was repeated.

Deep strict app signature, strict DMG signature, app and DMG Gatekeeper,
extracted ZIP app checks, and read-only mounted DMG app checks all passed.
The DMG included the Applications shortcut and the mount was detached.
Metadata confirms macOS 14.0, `x86_64 arm64`, `LSUIElement`, and no hosted feed.
Build 6 was not installed or published during packaging. Builds 4 and 5 remain
preserved.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/package/build-6/Tok.dmg` | 2725167 | `318cc1dfbef89d3fcfa77334ad44ec6a49e28da17b70b12b02e4564345d8b934` |
| `build/package/build-6/Tok-distribution.zip` | 2638613 | `a0c043e88f426c37b9ada5541126b50055e8631c01ad33b94ada4116fe72f9b3` |

`build/package/build-6/` also contains the signed app, saved notarization state,
and `verification.json`. Interactive acceptance and installed updates remain
separate gates.

After packaging, build 6 replaced `/Applications/Tok.app`. The installed bundle
reports source `2c22537f7932`; its executable was verified running. The designated
signing requirement matched the previous build. Build 4 is retained at
`build/installed-backups/build-4/Tok.app`. This was a local installation, not a
Sparkle update or a fresh-account setup test. No release was published.

## Deferred-work verification refresh, 2026-09-06

Installed build 6, source `2c22537f7932`, again passed deep strict codesign,
`stapler validate`, and Gatekeeper execute assessment (`Notarized Developer ID`).
Its process path is `/Applications/Tok.app/Contents/MacOS/Tok`. The preserved
build 6 ZIP and DMG SHA-256 values match the table above. No new notarization
submission or bundle replacement was needed for this refresh.

The bounded local signing check completed with exit 0. The existing Keychain
key matches the test app's embedded public key; generated feed/archive signatures
verify, and modified feed/archive copies fail signature verification. New
test-only artifacts are in `build/sparkle-check-qz8huvx2/`. This uses the local
Sparkle tools and development bundle, not the installed updater.

[UPDATE_HOSTING.md](UPDATE_HOSTING.md) recommends a separate public binary
repository with local Keychain signing and no credential export. It remains a
proposal pending owner approval. The source repo is still private; GitHub reports
no releases. Build 6 still has no hosted feed. Installed update, preservation,
anonymous hosting, runtime tamper rejection, and fresh-account gates remain open.

## Build 7 prepared on 2026-09-06

Version 0.1.0, build 7, was built from clean main commit `0c7cdb76f915`, including
the mid-animation Reduce Motion fix. `make distribute` exited 0 under a
120-second outer deadline. Log: `/tmp/tok-build7-distribution.log`.

Apple accepted app submission `666f37bd-9365-4e31-907b-7881daf17c04` and DMG
submission `2591b6bf-f93f-4b36-9712-c38e79ccd628`. Each was submitted once and then
resumed using its saved ID. Both tickets were stapled and validated. Deep strict
app signing, strict DMG signing, both Gatekeeper assessments, extracted ZIP app
checks, and read-only mounted DMG app checks passed. The mount had the Applications
link and was detached. Artifact verification exited 0 under a 120-second deadline.

| Preserved artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/package/build-7/Tok.dmg` | 2731284 | `0c2d715b84f50509f7ed0a30b08e24aac8c9af0c1c157093418e833cb778fb51` |
| `build/package/build-7/Tok-distribution.zip` | 2641963 | `ed8318694fee6bda1a4ccaad698ef746a41e9e1ec09301493b665d92e0fcec1b` |

The preserved directory also contains Tok.app, verification.json, and the two
saved notary records. It declares macOS 14.0 and contains x86_64 and arm64 code.
Runtime coverage in this session is only macOS 26.6.2 arm64. There is no hosted
feed. No tag, public resource, or release was created.

Build 7 is prepared, not installed. Build 6 remains running in Applications.
Native Computer Use could not attach to Tok and returned a blank desktop capture.
The normal quit/unsaved-document flow and post-install UI relaunch could not be
verified, so the owner bundle was not forcibly terminated or replaced. Open Tok's
Settings or quit Tok normally to permit the next serialized installation attempt.
This installation blocker is separate from public-host approval and fresh-account
acceptance. Build 4 rollback remains intact.

## Update-test baseline prepared, 2026-09-07

The approved public binary destination is `adhishthite/tok-releases`; application
source remains private. No release or tag is published. Public product text and
bundled notices now use Tok branding. Signing credentials remain in Keychain.

Version 0.1.1/build 8, source `f085cae621b7`, embeds the isolated HTTPS validation
feed at `/releases/download/v0.1.2/appcast-validation.xml` on the binary host.
It is preserved under `build/package/build-8/`, with verification.json and saved
notary records. Both Apple submissions were accepted:
`f179aa30-0cb3-4898-a2c4-ffa248b25c85` (app),
`c50030df-0526-4395-8e07-0039bfa30080` (DMG).
App/DMG signatures, tickets, Gatekeeper, extracted ZIP app, and read-only mounted
DMG app verification passed. The verification mount was detached. Build, notary,
and artifact-verification commands each used 120-second outer deadlines.

| Artifact | SHA-256 |
| --- | --- |
| build-8/Tok.dmg | dc84f4e35539d906a0e28462dcb31aac548563a76ec506d37baecccf264051d4 |
| build-8/Tok-distribution.zip | d277561f6343d0d8fa3775b307ab5186fa17d8a6c76fcd8b263a8cb051bdab53 |

This baseline is not installed or publicly available. It does not demonstrate an
installed update. Build 9 is reserved as version 0.1.2 with the production feed.
The source checks passed, including 25 Python tests; `make check-ci` passed after
import/formatting corrections. The live private/public release preflight passed
without creating a tag or draft.

## Signed update target prepared, 2026-09-07

Version 0.1.2/build 9, source `577d9e92f636`, embeds the production HTTPS feed.
Artifacts, verification.json, notary records, and signed release assets are
preserved under `build/package/build-9/`. App and DMG submissions were accepted:
`220c6443-22a6-4a81-ae41-3b3c6d3f129a` and
`2f9a5e06-54fb-4f5a-89fe-e776b2ef445c`.

The first app upload returned notarytool exit 69 without an ID. Apple history
confirmed no new submission; the failed-upload marker was preserved before one
retry. The resulting saved ID was then resumed. No successful upload was repeated.
App/DMG signatures, stapling, Gatekeeper, ZIP app, and mounted DMG app checks
passed. All long local operations used 120-second supervisors.

The local-only release helper successfully verified and staged the exact build,
compared the full ZIP app against the signed bundle, and generated a signed feed.
Modified signed feed content and a changed archive failed signature verification.
This is local cryptographic testing, not running-updater rejection.

[PUBLICATION_REVIEW.md](PUBLICATION_REVIEW.md) lists the five exact upload assets,
hashes, public tag target, proposed prerelease notes, and limits. No tag, draft,
asset upload, or release publication occurred. Builds 8 and 9 are not installed;
build 6 remains in Applications because native app control is unavailable.
The source commit passed GitHub CI run 34085789871.

## Validation prerelease published, 2026-09-07

The owner approved the exact five assets in PUBLICATION_REVIEW.md. Release
[v0.1.2](https://github.com/adhishthite/tok-releases/releases/tag/v0.1.2) was
published at 05:42:55 UTC as a prerelease with `latest=false`. Its public tag
resolves to `bc63f4f69a41ee6189e68e2da629999294bc8771`. The source repo remains private.

All five uploaded asset digests matched the approved SHA-256 values. Anonymous
HTTPS downloads of each published asset matched those hashes, and the downloaded
validation feed and ZIP signatures verified. This establishes anonymous hosting
and signed downloads, not an installed Sparkle update. Build 8 remains the local
validation baseline; neither it nor build 9 has been installed in this work.
Native app control and isolated-account access still block update/relaunch/data
preservation and runtime tamper tests. Production promotion is not approved.
