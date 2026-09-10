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

# Publication review: Tok 0.1.3, build 10

Approved by the owner and published on 2026-09-07 at 16:14:51 UTC as the latest
release in `adhishthite/tok-releases`, tag `v0.1.3`, targeting public commit
`bc63f4f69a41ee6189e68e2da629999294bc8771`. Private app source:
`1312f18bc0f8888895f3a6ec094d7b3763136d53`. This is the first production-feed
release; it carries the Settings audit fixes merged in pull request 1.

| Upload asset | Bytes | SHA-256 |
| --- | ---: | --- |
| Tok.dmg | 2764670 | ddeb73ed01a838021935de424dbe08d9771d64ac558ff57a8f4098e0d51bf27b |
| Tok.zip | 2676207 | a23b3f6807583b386006786ce5ac5638405a319566022c66183b64b3fe1effe3 |
| appcast.xml | 1177 | 6eddd894e3058ec997ba1fb35c69f386b3f0a81a16f49d55dc165dd17697a8fc |
| checksums.txt | 226 | 70efeeed2e3dc2d03aa30927424c8da17b7841705f0805826c7a8160b8e8e64d |

Exact files: `build/package/build-10/release-assets/`. The local manifest was not
uploaded. No validation feed was published; the production latest URL serves
this appcast directly.

## Verification

Apple accepted the app ZIP (`b8a3e20e-b719-4315-8cec-688fc9ef8475`) and the
final DMG (`93e9bb6c-143e-4e79-baea-66c74ca4f1f3`). Both were stapled and
validated, and `spctl` reported `Notarized Developer ID`. `stage-assets`
verified the universal binary, macOS 14.0 minimum, team identifier, and ZIP
contents before signing the feed with the Keychain Sparkle key.

Anonymous HTTPS downloads of all four assets through both the versioned and the
latest URLs matched the staged hashes. The downloaded feed and archive passed
`sign_update --verify`. The tag resolves to the reviewed public commit and the
repository's latest release is `v0.1.3`.

The owner installed the update on the primary Mac from installed build 9. The
installed application afterwards reports 0.1.3 (10), source `1312f18bc0f8`, a
valid signature, a stapled ticket, and `Notarized Developer ID`. The Sparkle
last-check time is 16:16:56 UTC, two minutes after publication. Whether the
install went through the in-app Check for Updates button or a scheduled check
was not recorded; the earlier limits on scheduled-discovery evidence still apply.
Build 9 is preserved in `build/installed-backups/build-9-before-sparkle/`.

# Publication review: Tok 0.1.4, build 11

Approved by the owner and published on 2026-09-10 at 16:50:10 UTC as the latest
release in `adhishthite/tok-releases`, tag `v0.1.4`, targeting public commit
`bc63f4f69a41ee6189e68e2da629999294bc8771`. Private app source:
`2b9463235f70710319260c8a2c4317a48a275b04`, which passed CI run 34479534400.
It carries the Hindi default language, the About pane, the Privacy pane and
setup step, and opt-in local usage metrics from pull requests 2 and 3.

| Upload asset | Bytes | SHA-256 |
| --- | ---: | --- |
| Tok.dmg | 2862324 | ec45a3ed6fa2e75cc6b43974862e1766eff791f86d10f30a88c9536e877ae5b1 |
| Tok.zip | 2786275 | 26d52ef8f34e27a25f66a028f025c3df50e328352c85691ca6e5fe40522d39d3 |
| appcast.xml | 1177 | 7e415c6206ab65fba2b53414398a087ff6a434ea87bdaf18a025dfca3c31e290 |
| checksums.txt | 226 | 5752cf2bc5fffca63dd8b20ecb130775d2925fe79292e94dbfa8160187412611 |

Exact files: `build/package/build-11/release-assets/`. The local manifest was not
uploaded. The production latest URL serves this appcast directly.

## Verification

Apple accepted the app ZIP (`1689fd7b-a8ca-44ff-a1a4-ffcc1b1df14c`) and the
final DMG (`492a467d-6fb9-4413-aa6f-f14dfac22bd3`). Each was uploaded once and
resumed from its saved ID. Both were stapled and validated, and `spctl` reported
`Notarized Developer ID`. `stage-assets` verified the universal binary, macOS
14.0 minimum, team identifier, and ZIP contents before signing the feed with the
Keychain Sparkle key. All long steps ran under bounded supervisors.

The release is not a draft and not a prerelease. All four server-reported asset
digests matched the staged hashes. The tag resolves to the reviewed public
commit and the repository's latest release is `v0.1.4`. Anonymous HTTPS
downloads of all four assets through both the versioned and the latest URLs
matched the staged hashes. The downloaded feed and both downloaded archives
passed `sign_update --verify` with the Keychain account, and an archive with one
appended byte was rejected. Verification files are in
`build/anonymous-release-verification/v0.1.4/`.

The public release notes omit the menu-panel focus change because it was not
verified by hand. No installed Sparkle update from build 10 has been recorded
yet.

# Publication review: Tok 0.1.5, build 12

Approved by the owner and published on 2026-09-10 at 17:18:12 UTC as the latest
release in `adhishthite/tok-releases`, tag `v0.1.5`, targeting public commit
`bc63f4f69a41ee6189e68e2da629999294bc8771`. Private app source:
`0296b9baccdeb51c2b594ae4c2c1d6414e6aff20`, which passed CI run 34506648469.
It carries the live session cap, the vocabulary limit, and the aligned
end-of-turn signal default from pull request 4.

| Upload asset | Bytes | SHA-256 |
| --- | ---: | --- |
| Tok.dmg | 2871084 | c28293b59ce6580448273b156db29b3ca6dc71c3ca77a48e0eeacefe29adfe14 |
| Tok.zip | 2792291 | 6adffdae6615209c70bd073e64b662905e72faccd7025e86f91e2c6d098b3d68 |
| appcast.xml | 1177 | 5b68c76259f869bca8bdbc8c88b0717bd0ebbe994bf3e199a78d0cc03673f071 |
| checksums.txt | 226 | 2205e6e5c505b2d77e0b27efbf93b1a47b25b47a131ea6b8457d3f7b8505203a |

Exact files: `build/package/build-12/release-assets/`. The local manifest was not
uploaded. The production latest URL serves this appcast directly.

## Verification

Apple accepted the app ZIP (`6fb0f4bf-7242-4c7b-86ce-d91cc080ccf9`) and the
final DMG (`7f63861d-bd39-4bcd-9cdd-949f9cd3047a`). Each was uploaded once and
resumed from its saved ID. Both were stapled and validated, and `spctl` reported
`Notarized Developer ID`. `stage-assets` verified the universal binary, macOS
14.0 minimum, team identifier, and ZIP contents before signing the feed with the
Keychain Sparkle key. All long steps ran under bounded supervisors.

The release is not a draft and not a prerelease. All four server-reported asset
digests matched the staged hashes. The tag resolves to the reviewed public
commit and the repository's latest release is `v0.1.5`. Anonymous HTTPS
downloads of all four assets through both the versioned and the latest URLs
matched the staged hashes. The downloaded feed and both downloaded archives
passed `sign_update --verify` with the Keychain account, and an archive with one
appended byte was rejected. Verification files are in
`build/anonymous-release-verification/v0.1.5/`.

The aligned end-signal default shipped before a latency comparison against the
legacy signal was measured. The legacy signal remains available through
`WS_ENDPOINT_ALIGNED=false` for that comparison.
