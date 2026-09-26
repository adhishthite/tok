# GitHub automation and local releases

The application source remains private in `adhishthite/tok`. The owner approved
`adhishthite/tok-releases` as the public binary destination on 2026-09-07. Its
current main tree contains only a README and Tok/Sparkle license notices. No
release tags or assets are published. Publication needs approval of exact assets.

## Continuous integration

`.github/workflows/lint.yml` is the pull-request check. It runs on Linux (1x
minutes) on every pull-request push and every push to main: swift-format lint
with the Swift 6.4 image, the license file and header checks, shell syntax, Ruff,
the Python regression tests, and actionlint. It needs no Xcode and takes a few
minutes.

`.github/workflows/ci.yml` is the full build and XCTest run, using macOS 26 and
Xcode 26.6. It runs on pushes to main that change a build input (`Sources`,
`Tests`, `Resources`, `Scripts`, `Tools`, `Config`, `project.yml`, `Makefile`, or
the workflows) and on manual requests. Pull requests do not trigger it; run it
once before a merge with `gh workflow run CI --ref <branch>`. Every run validates
tooling and runs `make check` under the documented 300-second hosted deadline.
The Sparkle package checkout is cached between runs, keyed on `project.yml`. Only
manual runs also package a development ZIP, bounded at 240 seconds and retained
for 14 days. These are development artifacts, not signed public releases. Test
results are uploaded only when a run fails, and kept for three days. macOS
minutes count 10x against the plan's included minutes, which is why pull
requests, the package step, and Markdown-only pushes are off the automatic path.

## Approved release route

Build, sign, and notarize locally with the existing Developer ID identity,
`TokNotary` profile, and Sparkle Keychain account `com.adhishthite.tok`. No signing
credential export or upload is authorized or needed. The manual release workflow
now performs readiness checks only. It has no signing secrets or publication step.

The helper separates `source_repository`/`source_commit` from
`hosting_repository`/`hosting_commit`. Source must be a clean main checkout at
fetched origin/main. Public tags must resolve to the public hosting commit,
never to a private source commit. The source repo must stay private and the
binary host must be public. Feed URLs use credential-free HTTPS on that host.

Before local staging, set these nonsecret inputs:

```sh
export GITHUB_REPOSITORY=adhishthite/tok
export TOK_RELEASE_REPOSITORY=adhishthite/tok-releases
export TOK_RELEASE_HOSTING_COMMIT=EXACT_PUBLIC_MAIN_COMMIT
export TOK_RELEASE_TAG=v0.1.2
export NOTARY_PROFILE=TokNotary
```

Set `TOK_EXPECTED_TEAM_ID` to the signing team identifier. The release tag must
match `MARKETING_VERSION`; every build requires a new `CURRENT_PROJECT_VERSION`.
Refresh origin/main before the read-only preflight. The public hosting commit
must be an exact 40-character commit ID. This configuration does not authorize
creating a tag or publishing a release.

1. Run the repository checks and commit/push the exact source. Wait for its CI.
2. Use `make distribute`, `make notarize-app`, and `make notarize-dmg` with the
   bounded, resumable procedure in DISTRIBUTION.md. Preserve each tested build.
   `TOK_UPDATE_FEED_URL` may override the production feed for a validation build.
3. Run `python3 Scripts/ci/release.py stage-assets` under a 120-second supervisor.
   It verifies the prebuilt artifacts and writes `build/release-assets/` with
   Tok.dmg, Tok.zip, appcast.xml, checksums.txt, and a local release manifest.
   It creates no draft or tag and uploads nothing. Existing nonempty stage
   directories are refused; preserve them before staging another build.
4. Review exact filenames, hashes, version, feed, and release notes with the owner.
   Only after approval may the named assets be uploaded and published. Never
   publish a recovery bundle, private source archive, logs, or application data.
5. Verify anonymous downloads and the real installed Sparkle update separately.
   See UPDATE_HOSTING.md for validation-feed and tamper-test requirements.

The production feed is
`https://github.com/adhishthite/tok-releases/releases/latest/download/appcast.xml`.
Archive URLs use the exact release tag. The app never includes a GitHub token.

## Optional authorized draft preparation

`prepare` and `resume` require the explicit nonsecret
`TOK_RELEASE_DRAFT_AUTHORIZATION` value
`HOSTING_REPOSITORY:TAG:HOSTING_COMMIT`, matching the request exactly. Set it only
after owner authorization for that specific draft/tag. The helper never publishes.
`prepare` builds and notarizes; do not use it to upload already reviewed staged
assets because it would prepare another build. Local `stage-assets` is the normal
path for the current acceptance work.

Saved notarization IDs remain under `build/notary/`; an unfinished Apple review
must reuse its submission. Recover an ambiguous upload with the documented
`Scripts/notarize.py --submission` procedure, never by retrying an upload blindly.
Recovery checks all recorded source, hosting, tag, build, and feed identities.
Old single-repository release-state files cannot be resumed by this interface.
Preserve old records; do not reinterpret them as a new request.

## Validation

`make check` includes release regression tests. `make check-ci` validates workflow
syntax, signing helper types, and Python lint. The legacy signing helper remains
unused by the approved local route; it must not be invoked to export credentials.
