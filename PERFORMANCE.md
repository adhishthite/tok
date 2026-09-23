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
