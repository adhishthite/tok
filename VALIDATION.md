# Validation, 2026-09-05

## Current result

The compiled app launches with a development signature and hardened runtime.
The engine is connected to the observable store, menu-bar state, setup checklist,
Keychain configuration, and Diagnostics window. Real microphone dictation is
awaiting the owner's macOS permission grants. It is not yet proven end to end.

The app's credential-free development report confirmed:

```json
{"hasAPIKey":true,"microphone":false,"accessibility":false,"inputMonitoring":false,"status":"Setup required","latency":"No dictations measured yet."}
```

## Checks actually run

- `make install`: `swift format` 6.3.0; XcodeGen generated Tok.xcodeproj.
- `make format`: exited 0.
- `make check`: strict Swift format lint, XCTest, `git diff --check`, and
  `bash -n` for the build scripts passed. XCTest output:

```text
Executed 4 tests, with 0 failures (0 unexpected)
Executed 14 tests, with 2 tests skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

The two skipped tests require the explicit Live scheme. The offline tests include
the five reference suites, 300 differential correction cases, 10,000 independent
window-search cases, deadline bounds, WAV bytes, REST gating, native store events,
configuration parsing, and cancellation of queued settlement after engine stop.

- `make run`: `BUILD SUCCEEDED`, then `Tok is running.`
- `codesign -dv --verbose=4`: `Identifier=com.adhishthite.tok` and
  `flags=0x10000(runtime)` on the development-signed app.
- `codesign --verify --strict --verbose=2`: `valid on disk` and
  `satisfies its Designated Requirement` with host Keychain access.
- `plutil -lint Config/Info.plist Config/Tok.entitlements`: both `OK`.
- `make package`: `BUILD SUCCEEDED`; created `build/package/Tok.zip`.
- `lipo -archs` on the Release executable: `x86_64 arm64`.
- `git check-ignore .env`: `.env`.

The initial sandboxed XCTest run failed because it could not access testmanagerd.
Host-access runs passed. The initial ad-hoc launch exposed a debug-dylib signing
mismatch. Development identity selection and a direct debug executable corrected
that launch failure. The UI inspection service timed out, so no visual inspection
or VoiceOver validation is claimed.

## Real API checks

Generated one 16 kHz mono synthetic sentence using macOS speech synthesis:
"Please send the revised architecture report by Friday."

Ran:

```sh
./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme TokLiveChecks \
  -configuration Debug -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  -only-testing:TokEngineTests/LiveIntegrationTests test
```

```text
testRESTFallbackTranscribesSpeech passed
testThreeLiveTurns passed
Executed 2 tests, with 0 failures
** TEST SUCCEEDED **
```

The Live tests matched the expected sentence on all three turns. Measured
audio-end-to-settlement times were 617.1, 582.2, and 520.7 ms. The median was
582.2 ms. Each used the server-turn-complete path.

A separate three-turn run of JustSpeak's unchanged Live client, using the same
synthetic audio and configuration, returned 469.9, 651.6, and 736.8 ms. These
small, sequential samples do not establish parity or a sub-500 ms result. They
exclude microphone finalization and paste delivery.

## Owner test at the working-dictation gate

1. In Tok, open Set up Tok and enable all three permissions. Expected: each row
   changes to Allowed, and the menu-bar status becomes Ready. Failure: a row
   remains ungranted or configuration reports an error.
2. Open an empty TextEdit document. Hold the configured hotkey, speak a short
   sentence, and release. Expected: one transcript appears once. Failure: no text,
   duplicate text, clipped words, or a delivery error.
3. Repeat in English, Marathi, and mixed speech. Include a mid-sentence pause,
   quick re-press while processing, and hold-to-lock.
4. Open Tok Diagnostics after each turn. Expected: a LATENCY line with route,
   capture, API, injection, total, and delivery outcome. Paste dispatch alone
   does not prove TextEdit received the text; inspect the document too.

The real-dictation median, accuracy comparison, native UI responsiveness,
notarization, Gatekeeper, and fresh-account onboarding remain unverified.
The overall application goal remains active.

## Bounded execution and microphone readiness

The in-app microphone probe completed three startup attempts with zero pre-roll:
382.6 ms, 180.9 ms, and 163.7 ms. It did not start a recording or send audio to
transcription. These are hardware-readiness delays, not key-up-to-paste latency.
The first-start delay warrants further profiling and first-word capture tests.

Builds and tests now run through `Scripts/bounded_run.py`, with a 120-second
initial deadline. The runner prints its live process ID and control-file path.
After checking actual progress, extend that live deadline by up to 60 seconds:

```sh
python3 Scripts/bounded_run.py --extend CONTROL_FILE --seconds 60
```

The deadline helper passed normal completion, expiry (exit 124), live extension,
rejection of extension after completion, and child cleanup after malformed control
data. Ruff passed. The full XCTest run passed with 20 tests passed and two explicit
live-API tests skipped. Deadline supervision bounds external commands; it cannot
preempt a model or client stall before the next tool call.
