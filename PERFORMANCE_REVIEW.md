# Performance evidence and comparison plan

Reviewed on 2026-09-06 using source and a read-only query of the configured history
database. The query selected only build, outcome, route, delivery, cleanup status,
and timing columns. It did not select transcripts, app names, corrections, or
credentials. No microphone, preferences, or running app state changed.

## Current observations

Successful Live turns with `delivery_outcome='dispatched'`:

| Source build | Samples | Median total, ms | Maximum, ms | Cleanup |
| --- | ---: | ---: | ---: | --- |
| `1d181bd6d8a9` (build 3) | 6 | 651.85 | 781.47 | Not recorded by this version |
| `061f46c1b42a` (build 4) | 1 | 689.68 | 689.68 | Off |

These are a current snapshot, not a controlled comparison. The six build 3 rows
supersede the earlier three-row snapshot in PERFORMANCE.md for sample count,
without invalidating that historical observation. There are no build 5 samples.
Unversioned records and a single build 2 turn were excluded from this table, not
silently pooled with current releases. Failed and clipboard-only turns were
excluded from latency summaries but remain necessary reliability outcomes.

For the one build 4 turn, capture finalization was 89.41 ms, provider roundtrip
537.06 ms, injection 60.81 ms, and event-queue delay 0.19 ms. This suggests starting
the next investigation at provider settlement, but one observation cannot justify
changing silence, frame size, or fallback settings. Component medians across
multiple turns must not be added as though they describe one turn.

`TextInjector.swift` reports dispatch after posting the paste events. It does not
confirm that the destination application consumed or rendered the text. Therefore
these rows do not prove physical key-up-to-visible-text latency, first-word
retention, duplicate-free delivery, or transcription accuracy. No p95 claim is
useful with one or six samples; nearest-rank p95 is simply their maximum.

## Source review

- History queries and statistics run through HistoryRepository's database queue.
  The initial 180 ms debounce was removed in build 5; only search edits debounce.
  This fixes a loading-state delay, not measured window presentation time.
- History's displayed aggregate includes all successful routes and cleanup states
  within its date range. It must not be used alone for the Live-only, cleanup-off
  acceptance target. Use stratified metadata instead.
- The injector deliberately waits 10 ms between key-down and key-up events. This
  is part of the existing paste behavior; do not remove it without delivery tests.
- Existing microphone profiles in PERFORMANCE.md concern hardware readiness and
  main-thread setup. They do not measure current window frames or speech accuracy.

## Repeatable real-speech comparison

1. Use the same Mac, microphone, destination document, network, language settings,
   vocabulary, and cleanup-off policy for Tok and the read-only JustSpeak build.
   Record exact source builds and relevant configuration before the session.
2. Prepare 15 owner-reviewed prompts outside Git: English, Marathi, and mixed
   language, each covering a short phrase, names/technical terms, numbers and
   punctuation, a mid-sentence pause, and a longer sentence. Define expected words
   before testing; neither app's transcript is the ground truth.
3. Speak each prompt twice per app, alternating which app goes first. This gives
   30 turns per app. Treat this as an initial comparison, not a precise tail study.
   Only one dictation app may hold the shortcut or microphone during a trial.
4. Bound each recording to 20 seconds and each settlement wait to 10 seconds.
   Record timeout/fallback/missing-output trials as failures. Repeat a failed trial
   only as a separately identified retry. Never drop the original result.
5. Inspect the destination after every turn. Record missing first words, incorrect
   words, omissions, additions, punctuation errors, duplicate insertions, and
   clipboard-only results separately. Compute word error rate from the agreed
   tokenization, and also report names/numbers errors and language-specific slices.
6. Report median and nearest-rank p95 dispatch latency for successful Live turns,
   plus sample counts, all failure counts, and REST fallback rate. Report actual
   visible-text timing separately if an instrumented destination is available.
   Do not call dispatch timing visible-text timing.
7. Repeat idle startup and device-switch trials separately, including Bluetooth
   when available. Test optional cleanup in another set so its added roundtrip
   does not contaminate the baseline. Review meaning preservation manually.

Acceptance requires median Live latency below 500 ms and accuracy/latency at least
as good as JustSpeak under comparable conditions. Current evidence establishes
neither. The real-speech session needs owner participation and has not been run.

## UI performance evidence still needed

Use a bounded Instruments capture while opening each window and scrolling a
synthetic History fixture. Measure event-to-presented-frame time, dropped frames
at the display refresh rate, and engine-event-to-menu-state presentation. Capture
the same interaction before and after any proposed change. Source inspection and
the duration of a window-opening method cannot prove the 100 ms presentation or
one-frame update targets. No new Instruments capture was performed in this review.

## Checks performed

- Read-only SQLite metadata queries completed successfully with a two-second busy
  timeout; preference-path lookup used a three-second subprocess timeout.
- Verified cleanup status for the build 4 sample is `off`.
- Inspected timing/injection code and existing performance evidence. No live API
  calls, recording, benchmark settings changes, or transcript analysis were run.
