# Publication review: Tok 0.1.2, build 9

Approved and published on 2026-09-07 at 05:42:55 UTC as a validation prerelease in
`adhishthite/tok-releases`, tag `v0.1.2`, targeting public commit
`bc63f4f69a41ee6189e68e2da629999294bc8771`. Do not mark it latest.
Private app source: `577d9e92f636900506efbbc63b49efde2f1115b8`.
Production promotion requires separate approval.

| Upload asset | Bytes | SHA-256 |
| --- | ---: | --- |
| Tok.dmg | 2730790 | d134bf3021072c6bc5b16075cf7d4c87fbe0f6852ee18e68a9664d848f6b278b |
| Tok.zip | 2641810 | 69ac9039e09d5b245a1cb5b0279dc466103a17b3c89d7c6e85542845a01bf59f |
| appcast.xml | 1176 | a32ac79f91c6e14c288362187f3f41426f825efb9dae602a3c11016561baec84 |
| appcast-validation.xml | 1176 | a32ac79f91c6e14c288362187f3f41426f825efb9dae602a3c11016561baec84 |
| checksums.txt | 315 | 5df1b40c20f921d1abbfaa5fa69624466d1cef7ea9b4d365da2f202f6bf83123 |

Exact files: `build/package/build-9/release-assets/`. Upload only the five files
above. The local manifest, source, logs, recovery files, keys, and application data
are excluded.

The validation feed has identical signed bytes to the production feed. Both
point to the exact versioned ZIP. Baseline 0.1.1/build 8 uses the pinned validation
URL; target 0.1.2/build 9 uses the production latest URL. A prerelease exposes the
validation path without promoting the production feed.

## Proposed public release notes

Tok 0.1.2 (build 9), an update-validation prerelease.

Signed, notarized, and stapled binaries declaring macOS 14 or later, with Apple
silicon and Intel code. Artifact checks ran on macOS 26.6.2 arm64. Other OS and
architecture combinations have not been runtime-tested in this release work.

Installed updates, fresh-account setup, keyboard and VoiceOver, real-speech
performance, and frame timing remain under verification. This prerelease does
not establish that those acceptance checks have passed.

## Local verification and limits

App and DMG signatures, tickets, Gatekeeper, extracted ZIP, and read-only mounted
DMG checks passed. The staging helper compared the complete ZIP app against the
verified bundle before signing the feed. Intact feed/archive signatures passed.
Changing the signed feed URL and appending bytes to the ZIP caused signature
rejection. Appending bytes outside the signed XML payload did not fail the feed
tool check; that case is not counted as tamper rejection.

No runtime updater tamper test has run. Native Tok control timed out, and an
isolated test account/Mac remains unavailable for installed-update preservation.
Neither build 8 nor build 9 is installed. The owner app is unchanged. No automatic
discovery, installed update, relaunch, or data-preservation result is claimed.

## Publication result

[Public validation release](https://github.com/adhishthite/tok-releases/releases/tag/v0.1.2)
is published, not draft, and marked prerelease. It was explicitly published with
`latest=false`. The public tag resolves to the reviewed public commit above.
All five server-reported asset digests matched the reviewed hashes before
publication. Anonymous HTTPS downloads of all five published assets then matched
again. The downloaded validation feed and ZIP passed Sparkle signature checks.
Anonymous verification files remain in `build/anonymous-release-verification/`.
No installed update or production promotion was performed.
