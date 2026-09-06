# Proposed update hosting

Status: prepared on 2026-09-06 for owner review. No destination is approved by
this document. No public repository, tag, release, or feed was created during
this review. Installed-update and runtime tamper tests remain unperformed.

## Recommendation

Keep `adhishthite/tok` private. Use a separate public repository,
`adhishthite/tok-releases`, containing a short product README, distribution
license notices, release manifests, and binary release assets. Do not copy the
source repository or its Git history. GitHub's automatically offered source
archives will contain only the public repository's manifest content.

Build, sign, and notarize locally using the existing Developer ID identity,
`TokNotary` profile, and Sparkle Keychain account `com.adhishthite.tok`. Upload
only the approved final artifacts using the existing authenticated `gh` session.
This approach needs no certificate, notary key, or Sparkle private-key export.
Do not run the current hosted signing setup as part of this approach.

An independent HTTPS object host is viable, but would add host administration,
credential setup, and feed promotion logic. The binary repository fits the
existing release asset layout with fewer new operational components.

### Proposed URLs

| Purpose | URL |
| --- | --- |
| Production feed embedded in the app | `https://github.com/adhishthite/tok-releases/releases/latest/download/appcast.xml` |
| Stable installer link | `https://github.com/adhishthite/tok-releases/releases/latest/download/Tok.dmg` |
| Versioned update archive, example | `https://github.com/adhishthite/tok-releases/releases/download/v0.1.2/Tok.zip` |
| Versioned installer, example | `https://github.com/adhishthite/tok-releases/releases/download/v0.1.2/Tok.dmg` |
| Isolated validation feed, example | `https://github.com/adhishthite/tok-releases/releases/download/v0.1.2/appcast-validation.xml` |

Version numbers are proposed, not reserved. Refresh the next available versions
and build numbers before building. Use increasing `CURRENT_PROJECT_VERSION`
values and separate marketing versions for the initial pair, for example
0.1.1/build 8 and 0.1.2/build 9 if those numbers remain unused.
Build 7 was subsequently used for the local Reduce Motion fix.

GitHub documents the stable latest-release asset URL form. Versioned archive
URLs prevent a feed from silently referring to a different archive when latest
changes. [GitHub release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

## Existing implementation and required changes

The current `Scripts/ci/release.py` uses one `repository` for source provenance,
release tag checks, draft targets, asset upload, feed URLs, and recovery. Its
public-host preflight correctly rejects the private source repository. Changing
only `GITHUB_REPOSITORY` to the binary repository would break provenance and
recovery validation.

After destination approval, separate these fields explicitly:

- `source_repository` and `source_commit`: private checkout and exact tested
  source revision. Recovery must require this checkout and commit.
- `hosting_repository` and `hosting_commit`: approved public repository and
  the exact public manifest commit targeted by its release tag. Validate the
  public tag against this commit, never against a private source commit.
- `feed_url`, release ID, tag, version, build, asset hashes, and saved notary
  state: persist these before upload and check them again during resume.

Preserve clean-main and exact-source checks, unpublished-draft recovery guards,
notary submission reuse, immutable versioned archive naming, and explicit
publication. An allowlisted upload manifest must exclude application data,
logs, recovery tarballs, signing inputs, and source archives. Public manifests
may include source revision identifiers and artifact hashes, but no private
source contents. Public notes must distinguish binary architecture support
from OS and architecture combinations actually tested.

`Sources/Store/UpdateStore.swift` accepts a credential-free HTTPS bundle feed
in release builds. `Config/Info.plist` enables `SURequireSignedFeed` and
`SUVerifyUpdateBeforeExtraction`. Keep these checks. Do not add runtime tokens
or weaken HTTPS for acceptance. Generate final feeds with the existing
`generate_appcast --account com.adhishthite.tok` path and verify both the feed
and archive against the embedded key. Do not edit signed feeds afterward.
Sparkle supports signed feeds and separate archive verification.
[Sparkle settings](https://sparkle-project.org/documentation/customization/)

Ordinary private-source CI remains unchanged. If hosted publication is later
desired, its workflow token cannot publish to a different repository. That
requires a separately approved GitHub App installation token or suitably scoped
token for the binary repository. Local authenticated publication avoids that
new secret-upload requirement. [GitHub token scope](https://docs.github.com/en/actions/concepts/security/github_token),
[release permissions](https://docs.github.com/en/rest/releases/releases#create-a-release)

## Installed update acceptance sequence

Draft assets are not anonymously available. A real hosted test therefore needs
explicit approval to publish test assets before production promotion. Calling
a release a prerelease does not make its contents private.

1. Reserve two distinct versions/builds after approval. Build A embeds the
   isolated validation-feed URL above. Build B embeds the production feed URL.
   Preserve the same bundle identifier, Developer ID identity, designated
   requirement, and Sparkle key. Build A requires a one-time manual install
   because installed build 6 has no feed. No Info.plist patching after signing.
2. Produce and verify both notarized builds locally. Save each build's final
   app, ZIP, DMG, source revision, hashes, signature checks, and submission IDs.
   Keep builds and notarization operations serialized with enforced deadlines.
3. Prepare a public prerelease for B with its final ZIP, DMG, production feed,
   and separately signed `appcast-validation.xml`. The validation feed points
   to B's exact versioned ZIP. Review the concrete asset list, hashes, and notes
   before the authorized publication action. Verify anonymous HTTPS downloads
   of the published validation feed and archive, including redirects and hashes.
4. In an isolated account or Mac, install A. Create synthetic history and
   vocabulary fixtures, a nondefault shortcut, and nondefault harmless settings.
   Grant required permissions and perform a successful dictation. Record only
   counts, stable fixture IDs, boolean comparisons, and permission states.
   Do not collect private transcript contents or Keychain values.
5. Use Tok's Check for Updates action. Record offered version, download,
   installation, quit, and relaunch. Verify the running process path and B's
   version, build, source revision, signature, and configured production feed.
   Confirm exact synthetic fixture preservation, settings and shortcut
   preservation, permission persistence, and successful destination insertion.
   Distinguish manual update checking from automatic background discovery.
6. Exercise automatic checking separately after enabling its user preference.
   Record the actual discovery trigger and timing. A manual check alone does
   not verify scheduled discovery. Avoid editing the owner's Sparkle defaults.
7. Once update and tamper evidence passes, promote the unchanged B assets to
   the approved production release. Verify the production latest-feed URL and
   its exact archive anonymously. Check from installed B that production feed
   retrieval works and reports the expected up-to-date state. Record that A to
   B used the validation URL; do not describe it as a production-feed update.
   A later B to C update is needed to verify production-feed installation.

Build A and B must be installed in the same isolated user context for the
preservation test. A bundle replacement performed by a shell or Finder does
not satisfy Sparkle update acceptance. If no isolated context is available,
prepare artifacts and leave runtime verification blocked instead of changing
the owner's permissions or data.

## Runtime tamper rejection

Use an isolated test installation and a distinct approved HTTPS validation
feed. Never replace a production asset with a corrupt test file. Prefer a
short-lived local HTTPS fixture server trusted only in the isolated account;
if that is unavailable, public tamper fixtures need separate publication
approval. Build the fixture feed URL into a separately signed test baseline.

- Feed test: serve a modified copy of a valid signed feed without resigning
  it. Confirm HTTPS transport succeeded and Sparkle reports a signature failure.
  Confirm no candidate was installed and the baseline still launches.
- Archive test: generate a correctly signed feed that references a deliberately
  modified archive while retaining the original archive signature. Sign only
  the feed after this change. Keep the reported length correct, so rejection
  is attributable to archive signature validation rather than truncation.
  Confirm the archive was downloaded and rejected before installation.
- Control: serve the intact signed feed and archive through the same path.
  Confirm a successful installed update. Without the successful control,
  authentication, TLS, connectivity, or feed parsing failures cannot count as
  cryptographic rejection.

Record test build identifiers, hashes, sanitized error domain/code, unchanged
installed version after rejection, and successful control outcome. The existing
`make check-updates` tests local cryptographic tools; it cannot replace these
running-updater tests. Sparkle's publication guidance requires signed archives
and explains feed signing. [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)

## Approval and blockers

Owner approval must cover the exact public destination, creation of its minimal
repository contents, release tags, publication of the named validation assets,
and subsequent production publication. Approval for one destination or test
release must not be interpreted as approval for unrelated public resources.

Until that approval arrives, implementation of this hosting approach, public
resource creation, and hosted verification are blocked. Isolation availability
and interactive permission/dictation access are separate runtime blockers.
The current release scripts need the repository/provenance separation described
above before use. No hosted or installed-update result is claimed here.
