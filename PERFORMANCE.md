# Performance evidence

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
