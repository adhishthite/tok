# Deferred acceptance session

Prepared 2026-09-06. This is a test protocol, not a result. No speech, fresh-account,
VoiceOver, frame-presentation, or installed-update gate passes by following this
document on paper. Record actual results in ACCEPTANCE.md and the relevant review.

## Smallest owner action

Provide access to one isolated macOS test account or another Mac, with a valid
Gemini key available privately in a password manager. Do not send the key in chat.
Keep the owner's account, permissions, Keychain, and saved data unchanged. A fresh
account on the same Mac tests onboarding isolation, not another OS or architecture.

Use the exact signed DMG and hash approved in DISTRIBUTION.md for this session.
Build 7's preserved path is `build/package/build-7/Tok.dmg`; do not assume the
mutable `build/package/Tok.dmg` is the same artifact. Recheck the chosen build
before timing. If installing in shared `/Applications` would replace the owner's
app, use a separate Mac or coordinate that installation explicitly.

1. In the isolated account, open the DMG in Finder. Start the total timer at this
   action. Drag Tok to Applications and launch without a Gatekeeper override.
2. Mark when Setup becomes usable. Grant Microphone, Accessibility, and Input
   Monitoring using the presented controls. Each permission row must refresh.
3. Paste the key privately, choose Test and save, and confirm success and an empty
   key field. Select and test a shortcut. For Fn, follow the Globe-key instruction.
4. Open a blank TextEdit document and dictate: “Please send the revised report by
   Friday.” Stop the total timer when the complete sentence appears exactly once.
5. Quit and relaunch Tok. Dictate the same sentence. Confirm the shortcut,
   permissions, saved key, and settings persist and idle capture is released.

Record total installation-to-visible-text time and Setup-to-visible-text time
separately. The current request's under-two-minute gate applies to the total.
The older Setup-only timer in ACCEPTANCE.md must not mask a longer total.
Record interruptions and assistance. An assisted retry does not replace the
first attempt. No terminal may be needed by the test participant.

In a separate untimed pass, deny each permission before granting it, one at a
time, in the isolated account only. Record the denied state, recovery action,
whether the row refreshes, and successful dictation after recovery and relaunch.
Do not use `tccutil reset`, erase Keychain entries, or clear owner data. If a truly
first-run denial cannot be repeated safely, record that case as untested.

## Speech evaluation conditions

The owner must review expected wording before any run. Copy the synthetic prompt
bank below into a private session sheet outside Git, correct it, and freeze that
version. The reviewed sheet is ground truth. Tok's output is not ground truth.
Record deviations in actual speech separately; do not silently blame recognition
for a reading mistake or revise expected text to match an output.

Record exact Tok bundle build/source revision, macOS build, architecture, microphone/model/connection, display
refresh rate, destination app/version, and network condition. Record configuration
by safe names and nonsecret values only: language codes, vocabulary fixture ID,
Live/fallback models, pre/post-roll, silence flush, frame size, VAD, warm capture,
shortcut, replacement rules, and live-model cleanup. Hold these constant across
the session and document any change.

Tok's optional “Polish dictations before pasting” and “Adapt formatting to the
app” must both be off for baseline. This is separate from its existing live-model
cleanup setting, which must be recorded. Quit other dictation apps so Tok alone
owns the microphone and shortcut. Use real speech, consistent speaking distance and
pace, and the same speaker. Do not substitute synthesized audio for this gate.

## Synthetic prompt bank for owner review

Bracketed pauses are instructions, not spoken text. Expected punctuation, number
formatting, spelling variants, and English technical-word script in Marathi must
be agreed before scoring. These invented sentences contain no private transcripts.

| ID | Slice | Prompt |
| --- | --- | --- |
| E1 | English, short | Send it tomorrow. |
| E2 | English, names | Priya and Nikhil will review the Kubernetes deployment. |
| E3 | English, numbers | Set the retry limit to twenty seven and the timeout to twelve seconds. |
| E4 | English, pause | Save the draft [pause two seconds] before closing the window. |
| E5 | English, longer | Please check the staging report, confirm the totals, and send the revised version by Friday afternoon. |
| M1 | Marathi, short | उद्या पुन्हा भेटूया. |
| M2 | Marathi, names | प्रिया आणि निखिल पुण्यातील बैठकीला येणार आहेत. |
| M3 | Marathi, numbers | एकूण सत्तावीस नोंदी आहेत आणि बारा नोंदी तपासायच्या आहेत. |
| M4 | Marathi, pause | आधी मसुदा जतन करा [pause two seconds] आणि मग खिडकी बंद करा. |
| M5 | Marathi, longer | कृपया आजचा अहवाल तपासा, सर्व आकडे बरोबर असल्याची खात्री करा आणि सुधारित प्रत उद्या पाठवा. |
| X1 | Mixed, short | उद्या report पाठव. |
| X2 | Mixed, names | प्रिया, Kubernetes deployment निखिलला दाखव. |
| X3 | Mixed, numbers | Retry limit सत्तावीस ठेवा आणि timeout बारा seconds करा. |
| X4 | Mixed, pause | आधी draft save करा [pause two seconds] मग review सुरू करा. |
| X5 | Mixed, longer | आज staging report तपासा, totals confirm करा आणि updated version शुक्रवारी team ला पाठवा. |

Speak each prompt twice: 30 baseline turns. Bound speech to
20 seconds and wait at most 10 seconds after release. A late delivery after that
cutoff remains a timeout with a separately recorded late-delivery event.
Retries get new IDs; never discard their original failures.

Inspect the destination after every turn, including failures. Record complete,
partial, absent, clipboard-only, late, or duplicated delivery, and first-word
retention. Only synthetic destination content may enter automated fixtures or
screenshots. Private speech and actual output stay outside Git and tool output.

## Additional cohorts

Keep these separate from the 30-turn steady-condition baseline:

| Cohort | Minimum | Procedure |
| --- | ---: | --- |
| Idle startup | 6 | E1, M1, X1 twice, each after at least 60 seconds idle with on-demand capture off between turns; record actual idle duration. |
| Device change | 6 per transition | E1, M1, X1 twice immediately after a documented device switch; include Bluetooth connect/disconnect when hardware is available. |
| Cleanup enabled | 30 | Repeat the 15-prompt bank twice; report added time, meaning changes, names/numbers errors, and cleanup fallback separately. |
| App-aware cleanup | 6 per destination | Use three agreed prompts twice in each selected destination, record context enabled and review formatting/meaning separately. |

If only one device is available,
device-change and Bluetooth coverage remain blocked. A successful fallback is
successful delivery via REST, but not a successful Live-path latency sample.

## Privacy-safe result sheet

Keep raw speech, truth text, and destination output in an owner-controlled local
sheet. Commit only aggregate counts, timings, fixture IDs, and safe failure codes.
Never export complete History CSV or run `SELECT *` against the owner's database.

Per-turn metadata fields:

```text
session_id, trial_id, prompt_id, repetition, source_build, cohort,
device_fixture_id, cleanup_status, route, outcome,
delivery_outcome, dispatch_ms, visible_ms, visible_method, timing_uncertainty_ms,
reference_word_count, substitutions, deletions, insertions,
names_error_count, numbers_error_count, punctuation_error_count,
first_word_lost, duplicate_insertions, timeout, late_delivery,
speech_deviation, retry_of, exclusion_reason
```

Report enrolled, attempted, failed, timed-out, clipboard-only, and successful
counts. For successful Live dispatches with cleanup explicitly off, report median,
nearest-rank p95 (`ceil(0.95 * n)` in sorted values), minimum, and maximum. At
30 turns p95 is descriptive and unstable; it is not a precise tail estimate.
Report REST fallback count/all attempted turns and cleanup fallback separately.
Report pooled WER as `(substitutions + deletions + insertions) / reference words`,
using NFC normalization and an owner-agreed tokenization/number policy. Score
punctuation, names, and numbers separately. Give English/Marathi/mixed slices.

Report latency only for turns meeting the same success/path criteria, and report
how many failed turns were excluded. Those exclusions must remain in reliability
totals. Acceptance needs median Live latency below 500 ms and per-slice accuracy
against the ground truth, with uncertainty stated. A favorable median alone does
not establish tail behavior.

History total timing ends at paste-event dispatch. A destination change observer
can confirm insertion but still does not prove a displayed frame. For visible
timing, use synchronized capture of key release and first complete rendered text,
record capture frame rate and uncertainty, and inspect the actual destination.
If there is no suitable capture, leave visible latency unknown. Preserve both
metrics and do not rename dispatch latency as visible-text latency.

## Existing helpers and limits

- `Scripts/live_check.sh` / `make test-live` synthesize one English fixture and
  exercise API integration. They do not measure real speech or the installed UI.
- `make test-cleanup-live` uses five synthetic text fixtures. It measures the
  extra cleanup request, not speech accuracy or end-to-end visible delivery.
- `make profile-microphone` builds and uses `Scripts/run.sh` to launch a microphone
  readiness probe under a bounded Instruments attach. It changes the running app
  and briefly captures audio. It is not a window/frame benchmark or a fresh setup.
- `Sources/Support/RuntimeReport.swift` and History timing can identify build and
  engine state; use only explicit metadata fields. No existing reviewed helper
  establishes destination-frame presentation.

For UI profiling, the coordinator must capture actual presentation events and
refresh-rate evidence with reproducible synthetic interactions. CPU profiles or
method intervals alone cannot establish the under-100 ms or one-frame targets.
All builds/tests use an initial 120-second supervisor; hosted CI checks may use
180 seconds. Extend a live handle only after progress, by at most 60 seconds.

## Blockers to record, not waive

- Isolated-account/Mac access and owner-controlled key entry for onboarding.
- Owner-reviewed ground truth and real speaker participation for the evaluation.
- Actual hardware access for each claimed OS, architecture, and device condition.
- A capture method tying release/state input to a presented destination/UI frame.
- Approved public destination and publication for the installed hosted update.

Preparation does not resolve these dependencies. Mark each unperformed case
untested with its precise reason and retain all existing acceptance gates.
