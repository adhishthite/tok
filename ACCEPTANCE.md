# Tok acceptance gates

Passing the offline suite does not complete these gates. Record the source build
identifier, macOS version, hardware, input device, date, and outcome for each run.
Keep recordings, transcripts, credentials, and private app content out of Git.

## Fresh-account setup without a terminal

Use a separate test macOS account with no Tok preferences, Keychain entry, or
permission grants. Do not reset permissions or remove data in the owner's account.
Use the preserved notarized DMG at `build/package/build-7/Tok.dmg`. Match its hash to the
verified checkpoint in [DISTRIBUTION.md](DISTRIBUTION.md).

1. Open the DMG, drag Tok into Applications, and launch it from Finder. Confirm
   the normal macOS first-open flow accepts the app without an override.
2. Start the total timer when opening the DMG and mark when the Tok setup
   window becomes usable. Keep a valid
   Gemini key available in a password manager before starting. Report both total installation-to-visible-text and
   Setup-to-visible-text time. The under-two-minute target applies to the total.
3. Follow Tok's Microphone, Accessibility, and Input Monitoring steps. Return to
   Tok after each System Settings action. Each granted row must update without
   restarting the app or using a terminal.
4. Paste the key into the secure field and choose Test and save. Confirm the
   connection succeeds and the field clears. Never include the key in evidence.
5. Choose a shortcut and use Test shortcut. For Fn, follow the Keyboard settings
   instruction and verify the selected keyboard actually sends the event.
6. Choose Done, open an empty TextEdit document, and dictate a known sentence.
   Stop the timer after exactly one complete transcript appears. Pass: under
   two minutes, no terminal, no missing first word, and no duplicate insertion.
7. Quit and relaunch Tok. Confirm setup persists and another dictation works.
   Check that the microphone is released between dictations with the default
   setting. This test does not require hiding the macOS microphone indicator
   while recording.

Repeat permission denial and recovery separately. A denied permission must leave
an actionable setup state. The test must not silently change other user settings.
Exercise vocabulary imports separately, including an open
unsaved vocabulary document. Imports must preserve existing text and undo history.

## Native interaction and accessibility

Exercise Setup, Settings, History, Vocabulary, Diagnostics, and the menu-bar
panel. Verify keyboard navigation and VoiceOver on the actual running app, not
only view source or test fixtures. Record any controls that cannot be reached,
named, operated, or dismissed.

- History: select one and several rows, copy with Command-C, and compare the full
  text and order with context-menu Copy. Delete must request confirmation; cancel
  must preserve data. An empty selection must not delete anything. Search-field
  editing and copying a selection in the detail pane must retain normal behavior.
- Vocabulary: edit, undo, redo, save, close with unsaved changes, and cancel quit.
- Settings: operate every setting without a mouse. Verify validation, unavailable
  microphones, secure key entry, and permission or network error recovery.
- HUD: verify listening, processing, locked recording, cancellation, and failure;
  repeat with Reduce Motion. Verify privacy changes hide displayed text at once.
- Measure window opening, list scrolling, and menu-state delivery with Instruments
  and reproducible input. Required: windows under 100 ms, lists at display refresh
  rate, and state changes visible within one frame. A synchronous method duration
  alone is not proof that the frame was presented.

## Real dictation performance and accuracy

Use versioned Diagnostics records from real speech and inspect the destination
document after each turn. Synthetic speech and paste dispatch alone do not prove
this gate. Keep a separate ground-truth transcript for evaluation outside Git.

Run a fixed, repeatable set of English, Marathi, and mixed-language utterances,
including names, punctuation, pauses, short phrases, idle startup, and sustained
use. Compare Tok and the read-only JustSpeak build under comparable device and
network conditions. Alternate run order and report sample counts and failures.

Report median and tail key-up-to-paste latency for successful WebSocket turns,
alongside failure, fallback, duplicate, and first-word-loss counts. Do not discard
slow turns without recording the exclusion and reason. Required: median below
500 ms and latency and accuracy at least as good as JustSpeak. Evaluate accuracy
against the ground truth rather than treating either app's output as correct.

## Distribution and updates

Follow [DISTRIBUTION.md](DISTRIBUTION.md). Record signatures and architecture,
accepted Apple submissions, stapling validation, and `spctl --assess` passing on
the exact final app. Verify installation and launch on a fresh Mac, including the
minimum supported macOS version and both supported architectures where available.

Verify an actual Sparkle update between two separately versioned signed builds.
The signed feed and archive must validate; modified feed/archive copies must be
rejected for signature failure. Confirm successful relaunch and preserved settings,
history, vocabulary, and permissions. Publishing needs separate owner approval.

## Open gates on 2026-09-06

Fresh-account timing, interactive keyboard and VoiceOver coverage, visual QA,
window/frame timing, versioned real-dictation latency and accuracy comparison,
and installed Sparkle updates remain open. Notarization, stapling, local
Gatekeeper assessment, and real Sparkle signature/tamper checks have passed;
see [DISTRIBUTION.md](DISTRIBUTION.md) for the exact artifacts and evidence.
The notary profile is `TokNotary`. The update hosting destination is not configured.
No test result above should be inferred from the existence of this procedure.

The bounded parallel review results are in
[ACCESSIBILITY_REVIEW.md](ACCESSIBILITY_REVIEW.md) and
[PERFORMANCE_REVIEW.md](PERFORMANCE_REVIEW.md). Source fixes and offline checks
do not close the interactive gates above.

Build 6 is now installed locally, including the History and accessibility fixes.
Its signed app and DMG passed notarization, stapling, and Gatekeeper checks.
See [DISTRIBUTION.md](DISTRIBUTION.md) for provenance and installation evidence.
The application-source CI run for `2c22537` passed tests and artifact packaging.
The remaining gates are still fresh-account setup, interactive accessibility,
measured frame timing, real-speech comparison, and an installed Sparkle update.

## Deferred-work live audit, 2026-09-06

The checkout was clean on main at `f151dacd04f5b0af26117845e99067e3274f1237`.
GitHub confirmed the source repository remains private and no releases exist.
[Exact-commit CI](https://github.com/adhishthite/tok/actions/runs/34048477536)
completed successfully. Installed build 6 reports source `2c22537f7932` and runs
from `/Applications/Tok.app` (observed PID 29963). Deep strict code-signature,
stapled-ticket, and Gatekeeper checks passed again on this installed bundle.
The observed host is macOS 26.6.2 (25G83), arm64. No Intel or macOS 14 runtime
coverage was added.

Computer Use attachment to Tok by name and exact installed path returned
`timeoutReached`; bundle-ID lookup was ambiguous because preserved builds share
its identifier. Native app inventory was available. No keyboard, VoiceOver,
window presentation, scrolling, or HUD visual result is inferred from this.
Interactive checks require working app control or an owner-driven session.
Instruments lists the host and SwiftUI/Animation Hitches templates, but discovery
alone is not a profile or presented-frame measurement.

[ACCEPTANCE_SESSION.md](ACCEPTANCE_SESSION.md) contains the smallest isolated
onboarding test and owner-reviewable synthetic speech protocol. No isolated
account, reviewed ground truth, or real-speech session has been supplied for this
run. Those requirements remain untested. The metadata-only history refresh
contains no build 6 records and does not establish destination output or parity.

[UPDATE_HOSTING.md](UPDATE_HOSTING.md) is the concrete hosting proposal awaiting
owner approval. Public destination approval and publication remain distinct
from local preparation. No hosted update or runtime tamper test has run.

Build 7 (`0c7cdb76f915`) is now signed, notarized, stapled, and preserved, with
container verification passing as recorded in DISTRIBUTION.md. It is not installed
because normal app control remains unavailable; installed build 6 is unchanged.
The Reduce Motion regression fix passed `make check`, including four new synthetic
HUD tests. Real keyboard/VoiceOver and mid-animation visual verification remain
untested. Final installation, hosting approval/publication, isolated onboarding,
owner speech review, hardware coverage, and presented-frame measurements are still
required. The deferred task is incomplete.

## Approved-host preparation, 2026-09-07

The owner approved the public binary destination. Its current tree contains only
Tok-branded README and license notices. Source remains private. Builds 8 (0.1.1,
validation feed) and 9 (0.1.2, production feed) are notarized and locally verified.
PUBLICATION_REVIEW.md contains the concrete test-prerelease approval request.
No binaries or tags have been published, neither build is installed, and no
installed Sparkle update or preservation test has occurred. All previously open
human, hardware, VoiceOver, real-speech, and presented-frame gates remain open.

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
