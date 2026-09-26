# Performance evidence

## Preparing the input node without capture, 2026-09-06

An explicit preparation probe constructed the AVAudioEngine input node before
measuring readiness. It did not install a tap or call `start` during preparation.
Preparation took 154.7 ms; `AVAudioEngine.isRunning` was false and
`kAudioOutputUnitProperty_IsRunning` returned zero with status zero.
The three subsequent readiness measurements were 297.9, 207.5, and 195.9 ms;
their main-thread request intervals were 0.016, 0.074, and 0.072 ms.

The 12-second Instruments capture completed successfully at
`build/microphone-startup-20260906-015434.trace`, PID 91206. The probe briefly
started and stopped audio for the readiness measurements, but retained no
dictation and uploaded no audio. The preparation-state measurements precede
those starts. They do not constitute visual verification of Control Center.

Tok now queues input-node construction at engine startup after permission checks,
while on-demand capture remains stopped. Device selection, tap installation,
and actual audio start still happen when capture is requested. The probe keeps
its unprepared baseline path and enables the preparation experiment explicitly:

```sh
TOK_PREPARE_MIC=1 make profile-microphone
```

This moves setup work before the first shortcut. These small sequential samples
do not prove a stable latency improvement, first-word accuracy, or the separate
sub-500 ms key-up-to-paste target.

## Stored dictation timing, 2026-09-06

A read-only aggregate of Tok's history found 19 records, including 16 successful
Live-route paste dispatches with finite total timings. No transcript text was
selected or displayed.

| Measurement | Median | Minimum | Maximum |
| --- | ---: | ---: | ---: |
| Key release to dispatch | 583.7 ms | 521.5 ms | 1100.7 ms |
| Capture finalization | 86.8 ms | 77.8 ms | 209.6 ms |
| API interval | 458.5 ms | 364.9 ms | 989.4 ms |
| Injection | 14.4 ms | 12.7 ms | 31.3 ms |
| Event queue | 0.9 ms | 0.0 ms | 7.6 ms |

The sub-500 ms target is not met in this sample. These are separate marginal
medians and must not be added as a decomposition of the median total. Paste
dispatch does not independently prove that the destination consumed the text.

All 19 records had a NULL build identifier, so this is a mixed-version baseline,
not evidence about the latest implementation alone. Tok now stamps its source
revision into the bundle and assigns that value to new history records, including
a `-dirty` suffix for uncommitted source. Existing rows are not backfilled.
Diagnostics and the development runtime report show the same build identifier.

## Microphone startup baseline, 2026-09-05

Before the hardware-queue change, Tok's on-demand microphone startup blocked
the main thread. This was a measured UI responsiveness problem, separate from
key-up-to-paste latency.

The debug probe starts and suspends the microphone three times with zero
pre-roll. It does not record a dictation or send audio for transcription.
It measures elapsed time until the first healthy audio buffer and elapsed time
inside the synchronous `ensureReady` call on the main thread.

| Attempt | Main-thread setup | Total readiness |
| --- | ---: | ---: |
| 1 | 306.0 ms | 496.2 ms |
| 2 | 85.7 ms | 191.8 ms |
| 3 | 78.0 ms | 184.7 ms |

These measurements were collected under Instruments Time Profiler against
one running Tok process, PID 75553. The recording completed with exit 0 and a
12-second time limit. The app remained running afterward. The local trace is
`build/microphone-startup-20260905-232839.trace`. Traces are generated artifacts
and are not committed. The JSON probe report is `/tmp/tok-microphone-probe.json`.

The measured interval includes synchronous audio-device selection, tap and
converter setup, and `AVAudioEngine.prepare/start`. CPU samples establish
call-stack attribution but do not measure blocked-thread wall time. The trace
export contained 69 main-thread CPU samples, 44 with `rebuildHardware` on the
stack, including input-node and audio-unit construction. The probe's
separate elapsed-time measurement covers that wait. Device and profiler state
affect timings, so these three samples do not establish a stable distribution
or compare performance against earlier unprofiled samples.

## Hardware queue result

The same three-attempt probe after moving hardware lifecycle operations to a
serial background queue measured:

| Attempt | Main-thread setup | Total readiness |
| --- | ---: | ---: |
| 1 | 0.132 ms | 462.2 ms |
| 2 | 0.065 ms | 190.7 ms |
| 3 | 0.057 ms | 193.9 ms |

`make profile-microphone` completed with exit 0. The trace is
`build/microphone-startup-20260905-233823.trace`, PID 80691. Exported CPU samples
contain 33 worker-thread samples with `rebuildHardware` on the stack and zero
main-thread samples with that call. There were 25 main-thread samples total.

This removes the measured synchronous startup stall. It does not establish
faster hardware readiness or faster transcription. Hardware readiness remains
hundreds of milliseconds, and first-word capture still needs real dictation
validation. These runs are small samples taken sequentially under Instruments.

The existing recovery state machine now runs with hardware operations on one
serial queue. Locked snapshots let the main thread check readiness and input
metadata. Epoch checks invalidate readiness results immediately on cancellation,
including results already queued for main. The turn arbiter still uses its
original DispatchQueue and NSLock model. No actor replaced it.

The targeted Thread Sanitizer run passed all five selected tests, with no race
reports. Coverage includes the unchanged recovery regression fixtures, startup
while hardware is blocked, cancellation during startup, invalidating a result
already queued for main, and retaining the audio owner until queued shutdown
finishes. This covers the tested paths, not every possible device interaction.

```sh
./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme Tok \
  -configuration Debug -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' -enableThreadSanitizer YES \
  -only-testing:TokEngineTests/MicrophoneLifecycleTests \
  -only-testing:TokEngineTests/MicrophoneRegressionTests test
```

Output: `Executed 5 tests, with 0 failures`, `TEST SUCCEEDED`.

## Reproduce

```sh
make profile-microphone
```

This builds Debug with the existing 120-second build deadline, quits the old
app, launches through Launch Services, and attaches Time Profiler. The probe
waits six seconds to let attachment start. Recording lasts 12 seconds; the
profiler command has a 45-second deadline including trace saving. A successful
build and the profile invocation were exercised separately for this baseline.

Two initial `xctrace --launch` attempts saved samples but returned exit 54 and
left stopped processes at `_dyld_start`. Those processes were terminated after
inspection. The reproducible command uses `--attach` to avoid that launch path.
One quit attempt timed out after ten seconds while addressing a stopped process.
No timed-out command was counted as a successful profile.

## Remaining performance gates

- Real WebSocket-path key-up-to-paste median below 500 ms.
- First-word capture after idle, including device changes and Bluetooth input.
- Windows opening below 100 ms and state presentation within one display frame.
- Refresh-rate scrolling, HUD smoothness, and accessibility interaction.

None of these gates is proven by the startup probe or offline tests.

## Optional cleanup, 2026-09-06

The owner reported that build 3 felt smooth and planned to use Tok exclusively.
That is qualitative feedback, not a frame-time measurement. A metadata-only query
found three successful Live dispatch records attributed to `1d181bd6d8a9`:
median total 596.22 ms, median capture 84.51 ms, median API 497.57 ms, and median
injection 15.05 ms. The maximum total was 781.47 ms. These three observations do
not establish the sub-500 ms target or accuracy parity, and component medians
must not be added together as though they describe one turn.

The optional text cleanup pass defaults to off. Five synthetic text-only checks
against `gemini-3.5-flash-lite` completed in 891–984 ms initially. The final run,
which also asserted three separate numbered-list lines, completed in 815–1,025 ms.
These are cleanup-stage durations alone. They exclude microphone capture, the
original transcription, and paste delivery. The fixtures cover spoken numbers,
numbered items, Marathi, mixed language, and a terminal-context question; they do
not substitute for a real-speech accuracy evaluation.

Measurements and API-reported usage are in
`build/post-processing-live-check-initial.json` and
`build/post-processing-live-check.json`. The corresponding test logs are
`/tmp/tok-cleanup-live-checks.log` and `/tmp/tok-cleanup-final-live.log`.
The off-path test verifies no cleanup request and inline continuation. No claim
of zero measured CPU overhead is made. Enabled and disabled dictations must be
kept separate when assessing the latency target.

## Turn latency report

`Scripts/turn_report.py` aggregates the metadata columns in `history.db`
(timings, counters, and enum labels only; it never selects transcript text,
corrections, app identity, or raw error strings) into medians, nearest-rank
p95s, and group-by tables for repeatable latency review. It opens the
database read-only and tolerates older databases that are missing a metric
or grouping column, printing a one-line note instead of failing.

```sh
make report
make report ARGS="--build bb2362f --since 2026-09-01"
make report ARGS="--tag control --json"
```

Default arguments read `~/Library/Application Support/Tok/history.db`;
pass `--db <path>` to point at another file. `--all-outcomes` shows outcome
counts instead of the default success/dispatched/live cohort. Run
`python3 Scripts/turn_report.py --help` for the full filter and column
list, and for the exact median and p95 definitions used.

## Silence flush, 2026-09-26

`SILENCE_FLUSH_MS` was 700 by default. Harness direct mode (Tools/Harness), 294
clips in 13 languages, every clip on every arm twice, paired turn by turn against
350 ms (the owner's setting). Commit-to-result round trip, median of paired
differences, bootstrap 95% CI:

| Flush | Pairs | Round trip vs 350 ms | 95% CI | English WER | Last word missed |
| --- | --- | --- | --- | --- | --- |
| 700 | 588 | +80 ms | +77 to +83 | 2.3% | 3.1% |
| 350 | 588 | reference | | 2.2% | 3.3% |
| 200 | 588 | -35 ms | -38 to -32 | 2.0% | 2.4% |
| 100 | 588 | -58 ms | -63 to -55 | 2.2% | 3.3% |
| 0 | 588 | -82 ms | -86 to -80 | 2.0% | 3.1% |

Each 100 ms of flush costs about 23 ms of round trip and buys no measured accuracy.
The capture tail already ends each turn on at least `POST_ROLL_MS` of real quiet.
At 0 and 100 ms, one short Marathi clip came back romanized in both of its
variants (2 of 48 Marathi turns); at 200 ms and longer, 0 of 48. The default is
now 200 ms: about 115 ms faster than 700 per turn, with no measured cost. The
end-signal A/B in the same runs found no difference: `WS_ENDPOINT_ALIGNED` minus
legacy was -2 ms (95% CI -4 to 0) over 588 pairs.

Not yet confirmed end to end on the acoustic path (key-up to paste through the
real microphone); the flush only changes what is sent after key-up, which direct
mode reproduces.

## Streaming frame size, 2026-09-26

`CHUNK_MS` was 150 by default; the dedicated transcribe docs suggest about 100.
Same direct-mode design as the silence-flush run, 588 pairs per arm:

| Frame | Round trip vs 150 ms | 95% CI | English WER | Hindi / Marathi romanized |
| --- | --- | --- | --- | --- |
| 150 | reference | | 2.1% | 17/46, 0/48 |
| 100 | -8 ms | -10 to -4 | 2.0% | 17/46, 0/48 |
| 50 | -12 ms | -16 to -10 | 2.1% | 17/46, 0/48 |

The default is now 100 ms. 50 ms saves 4 ms more at twice the message rate,
which is not worth it on a lossy network.

## Trailing-capture floor, 2026-09-26

Every turn records at least `POST_ROLL_MIN_MS` after release. On turns where the
speaker was already quiet for `POST_ROLL_MS` (250 ms) before release, the floor is
the whole wait, and that is the usual case: real-use capture finalize has a 78 ms
median. Acoustic harness, 24 turns per arm, finalize time on the turns where the
floor bound (banked quiet of 250 ms or more):

| Floor | Turns | Finalize |
| --- | --- | --- |
| 60 ms | 9 | 61 to 67 ms |
| 30 ms | 6 | 35 to 42 ms |
| 15 ms | 7 | 19 to 21 ms |

Last-word misses did not change (1 of 17 English turns in every arm, the same
clip). On a floor-bound turn all speech ended at least 250 ms before release, so
the only post-release audio that matters is the hardware buffer in flight at
key-up: 1024 frames, about 21 ms at 48 kHz. The default is now 30 ms, which keeps
that buffer with margin and saves about 25 ms on floor-bound turns. 15 ms would
save about 20 ms more but cuts below one buffer.

## Long dictations, 2026-09-26

Forty paragraph clips (16 to 34 s of speech, median 24 s): English prompts,
Hinglish and Marathi-English code-switching, and full Hindi and Marathi
paragraphs. Direct mode, 80 pairs per arm unless noted:

| Comparison | Round trip | 95% CI |
| --- | --- | --- |
| Paragraph vs short-clip baseline | 718 vs 440 ms median | |
| Flush 200 vs 350 ms | -45 ms | -86 to +3 |
| Flush 0 vs 350 ms | -88 ms | -109 to -55 |
| Verbatim vs Smart transcription (40 pairs) | -17 ms | -41 to +10 |

Commit-to-result time grows with the length of the turn, about 280 ms more for a
24 s dictation, and Smart transcription is not the cause. The flush savings hold
on long turns, and accuracy did not change with the flush (English WER 2.5 to
2.7%, the same 4 of 48 last-word misses in every arm). A 12-pair acoustic
paragraph batch ran alongside the 10-session direct run and is too contended to
read.

## Adaptive quiet line, 2026-09-26

The capture tail ends after `POST_ROLL_MS` below `TRAIL_SILENCE_DB` (-40 dBFS). In a
room whose own level reaches that line, room tone reads as speech, and turns wait up
to `POST_ROLL_MAX_MS` (1.5 s). The quiet line now rises to the turn's room floor (10th
percentile of its 20 ms frames) plus `QUIET_MARGIN_DB` (8), never closer than 12 dB to
the turn's speech level (90th percentile), never below the configured threshold.
`quiet_threshold_db` records the line used on every turn.

Acoustic harness, adaptive (default) vs the fixed line (`QUIET_MARGIN_DB=0`), paired:

| Room | Pairs | Arm | Median total | p95 total | Finalize | Tail caps | WER |
| --- | --- | --- | --- | --- | --- | --- | --- |
| About -47 dBFS (natural) | 24 | adaptive | 659 ms | 911 ms | 78 ms | 0% | 2.9% |
| | | fixed | 738 ms | 1,151 ms | 105 ms | 0% | 3.2% |
| About -40 dBFS (steady fan-like noise) | 12 | adaptive | 670 ms | 765 ms | 41 ms | 0% | 0.8% |
| | | fixed | 984 ms | 2,142 ms | 305 ms | 25% | 5.6% |

In the -40 dBFS room the fixed line was 341 ms slower per turn (median paired
difference, 95% CI +97 to +1,001) and less accurate: waiting on room tone adds noise to
the clip. In the quieter room the line barely moved (median -38.7 dBFS) and nothing
regressed.

Review follow-up: in that first version the raised line also decided how much quiet was
banked before release, so a soft final syllable under the raised line could count as
quiet and a release during it could end capture at the 30 ms floor. Banked quiet is now
judged against the configured threshold, and the adaptive line applies only to the wait
after release, so a noisy-room turn always waits out the full 250 ms quiet window. Re-run
in the fan-noise room (it ran louder, -34 to -38 dBFS), 12 pairs:

| Arm | Median total | p95 total | Finalize | Tail caps | WER |
| --- | --- | --- | --- | --- | --- |
| adaptive | 748 ms | 1,132 ms | 258 ms | 0% | 5.6% |
| fixed | 1,982 ms | 2,146 ms | 1,502 ms | 83% | 5.6% |

The fixed line was 1,246 ms slower per turn (95% CI +893 to +1,346). The safer version
gives up the 41 ms finalize of the first version for the full quiet window, and still
removes the cap. Loud transient sounds at speech level (a notification, a voice) still hold
the tail; no level-based rule can separate those from words.

## Latency harness

The harness runs real engine turns without a person. `TokHarness` builds a
`DictationEngine` with a `.sink` delivery: real capture on the built-in mic, real
Live and REST routes, real history rows. It presses and releases the shortcut in
code, and it never touches the clipboard, pastes, or needs Accessibility. Clips
play through the built-in speakers, so capture start, warm and cold microphone
state, and the capture tail are measured on hardware.

```sh
make harness-clips   # once: 60 phrases x 2 variants from Gemini 3.8 Flash and Flash-Lite TTS
make harness-smoke   # 2 turns per arm, about 2 minutes, to check the setup
make harness         # default: baseline, warm90, aligned; 60 turns each, about 4 hours
make harness ARGS="--arms baseline,flush700 --turns-per-arm 80"
make harness-direct ARGS="--arms baseline,aligned,flush700 --repeats 2"
make harness-report  # add ARGS="--min-turns 20" to drop smoke runs
```

- **Direct mode.** `--direct` streams each clip straight into `GeminiLiveClient`
  at real-time pace, over -60 dBFS room tone at a -20 dBFS speech peak, with the
  engine's pre-roll and digital-zero silence flush. Several workers run at once,
  each holding one persistent socket per arm and running every clip on every arm
  back to back, so contention falls on all arms alike. It measures the end signal,
  the commit-to-result round trip, and accuracy by accent and language. It cannot
  measure capture start, warm or cold state, or the capture tail; those need the
  acoustic run. It reaches the internal client through `@testable import`, as
  `LiveIntegrationTests` does. Each `make harness*` run executes a copy of the
  binary under `build/harness/bin`, so a rebuild never replaces a running one.

- **Clips.** `Scripts/harness_clips.py` renders `Tools/Harness/phrases.json` with
  weighted accents (mostly Indian English), voices, and pacing styles, alternating
  the two TTS models. Each clip is transcribed once over REST and regenerated when
  the check misses more than 20% of words, so a TTS mistake is not scored as an
  engine mistake. The 3.8 TTS models speak plain-text instructions aloud and
  reject `systemInstruction`; direction goes in a leading bracketed tag.
- **Design.** Each round draws a block of clips with idle gaps drawn from the
  owner's measured gap mix (40% under 30 s, 17% 30 to 90 s, 43% 95 to 110 s; past the 90 s release
  window a longer gap leaves the microphone in the same cold state),
  a 150 to 450 ms lead from press to speech, and a 100 to 500 ms tail from
  last word to release. Every arm runs the same block, in an order that rotates
  each round. The report pairs turns on round and position.
- **Settings.** Arms start from the installed app's own preferences
  (`com.adhishthite.tok`), then force sounds, ducking, clipboard restore,
  correction learning, hold-to-lock, and usage metrics off. Each arm changes one
  factor. Rows go to `build/harness/history.db`, tagged `harness-<arm>`, and to
  `build/harness/runs/<run>.jsonl`.
- **Conditions.** Keep the lid open, the built-in speakers on at a fixed volume,
  and the room quiet. Before each arm block the harness measures the room with
  nothing playing. It pauses while the median is above `TRAIL_SILENCE_DB` minus
  5 dB, because room tone near the threshold keeps resetting the quiet window
  and runs the tail to `POST_ROLL_MAX_MS`. It also pauses when the output is not
  the built-in speakers, and it stops after 4 turns in a row without a transcript.
- **Limits.** Speakers into the laptop mic are not a person at dictation
  distance, so absolute tail and accuracy numbers are approximate. Paired arm
  differences are the result. Smart transcription removes fillers, so a phrase
  that opens with "Okay" can count as a first-word miss in every arm alike.
