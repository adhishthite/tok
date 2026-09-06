# GitHub automation

The source repository is [adhishthite/tok](https://github.com/adhishthite/tok),
created as private and connected as `origin`. As of 2026-09-06, the workflow files
are committed locally but have not been pushed or run on GitHub. No signing
credentials have been exported or uploaded.
Hosted signing remains unverified until the first configured run succeeds.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to main, pull requests, and manual
requests. It uses GitHub's macOS 26 runner and Xcode 26.6, validates the workflow
tooling, runs `make check`, and creates a development ZIP with `make package`.
Test results and the ZIP are retained as workflow artifacts for 14 days.
Repository checks and development packaging each have a 120-second process
deadline and a three-minute workflow-step limit.
This job has read-only repository permissions and no signing secrets. Its ZIP is
a development artifact, not a notarized release.

## Release preparation

`.github/workflows/release.yml` is manual and runs only from main. Supply a tag
such as `v0.1.0` matching `MARKETING_VERSION`. Increment `CURRENT_PROJECT_VERSION`
for each new update before starting a release. It does not release on every push.

The workflow reserves a GitHub draft, then builds the universal Developer ID app,
submits and staples the app, recreates the containers, submits and staples the
DMG, and verifies signatures, metadata, architecture, and Gatekeeper acceptance.
It generates and verifies a signed Sparkle appcast and checks the signing key
against the public key embedded in the actual app.

The draft receives `Tok.dmg`, `Tok.zip`, `appcast.xml`, and `checksums.txt`.
An existing tag must resolve to the recorded source commit. This is checked
before preparation and again before uploading assets.
The workflow updates its notes when preparation completes. Review the successful
run and assets before publishing the draft in GitHub. Do not publish a draft
while its workflow is still running. The scripts never publish it themselves.

The default feed is
`https://github.com/OWNER/REPO/releases/latest/download/appcast.xml`.
Anonymous update downloads require this release repository to be public; the
release preflight rejects a private repository. Therefore, the current release
workflow cannot prepare releases in `adhishthite/tok`. Ordinary CI can run there
after the first push; it does not use this release preflight.

Keep the source private. Update hosting is still undecided and requires owner
approval before implementation. Options include a separate public binary
repository or an HTTPS download host. Either requires adapting the release
workflow and feed URL; a separate binary repository also needs an appropriately
scoped publishing token. Never embed a GitHub access token in the app.

The currently installed build 4 has no hosted feed configured. The first
GitHub-enabled release needs a one-time manual installation before later
Sparkle updates can be exercised. A real installed update remains an acceptance
gate even after signature checks pass.

## One-time signing setup

Create a GitHub environment named `release`, restrict it to main, and configure
an owner approval rule where supported by the repository's plan. Add these
environment secrets through GitHub's secure settings UI, never through chat:

| Name | Required value |
| --- | --- |
| `TOK_CERTIFICATE_P12_BASE64` | Base64 of the Developer ID Application certificate and its private key exported as an encrypted P12 |
| `TOK_CERTIFICATE_PASSWORD` | That P12's export password |
| `TOK_NOTARY_KEY_BASE64` | Base64 of a Team App Store Connect API private key authorized for notarization |
| `TOK_NOTARY_KEY_ID` | The API key's identifier |
| `TOK_NOTARY_ISSUER_ID` | The Team API issuer identifier |
| `TOK_SPARKLE_PRIVATE_KEY` | The existing Sparkle private-key export, preserving its base64 text |

Add the non-secret environment variable `TOK_EXPECTED_TEAM_ID` with the signing
team identifier. Use the existing Tok Sparkle key; generating a different key
would break the embedded-key check and existing clients' update trust.

Signing setup is restricted in code to disposable GitHub-hosted runners. It
creates a temporary keychain under RUNNER_TEMP with an empty temporary password;
the encrypted P12 password is supplied directly to Security through a Swift
helper, never a process argument. The file-based keychain API emits a known SDK
deprecation warning; it is used only by this CI helper for native codesign access.
The private API and Sparkle key files have mode 0600 inside a private temporary
directory. Signing-tool output is captured, and failures report safe statuses.

The cleanup step restores the runner's prior keychain selection and removes the
temporary keychain and files. This setup is not run on the owner's Mac. Nothing
here exports existing local credentials automatically.

## Bounded waits and recovery

Build and export subprocesses retain their existing 120-second deadlines. The
release helper checks the same notarization submission at 20-second intervals
within a five-minute polling budget; individual commands also have deadlines.
An unfinished Apple review stops preparation and leaves the draft unpublished.
Each poll is limited to the remaining polling budget. Command timeout cleanup
interrupts the process group and terminates surviving group members after the
grace period.

The always-run recovery step saves `release-recovery.tar`, containing the signed
app, containers, notarization state, and `release-state.json`. Signing credentials
are outside these directories and are not included. Starting a fresh workflow
for an existing draft is rejected to prevent an accidental second attempt.

For a stopped attempt:

1. Download the recovery artifact from that trusted release workflow run.
2. Use a fresh checkout of the recorded source commit, with the correct GitHub
   origin and no existing release output. Install the normal build tools.
3. Run `python3 Scripts/ci/release.py restore /path/to/release-recovery.tar`.
   The restore checks allowed paths and link targets and refuses existing output.
4. Verify the repository, version, commit, and stage in `build/release-state.json`.
   Make the same Developer ID identity and notary profile available locally,
   set `NOTARY_PROFILE` and `TOK_EXPECTED_TEAM_ID`, and authenticate `gh`.
5. Ensure Sparkle tools are available at the normal DerivedData artifact path.
   Set `TOK_SPARKLE_KEY_FILE` to a protected export, or use the existing local
   Keychain account `com.adhishthite.tok`.
6. Run `python3 Scripts/ci/release.py resume`. A DMG-stage resume skips rebuilding
   the app and containers and checks the saved submission. It only updates the
   matching draft, never a published release.

If an upload failed without a returned submission ID, inspect Apple history and
recover the matching ID using the existing `Scripts/notarize.py --submission`
procedure before resuming. Do not delete the state and blindly upload again.

## Local validation

`make check-ci` runs actionlint, type-checks both Swift signing helpers, and checks
the Python CI scripts with Ruff. Install actionlint and uv first, or pass
`ACTIONLINT=build/tools/actionlint` when using the locally staged checker.
`make check` includes the CI guard and recovery regression tests.

Sources: [GitHub macOS runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md),
[workflow triggers](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
[Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
