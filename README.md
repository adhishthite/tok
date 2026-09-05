# Tok

Native macOS push-to-talk dictation with a Gemini backend.

Requires macOS 14 or later. Development requires Xcode 26 and XcodeGen.

```sh
make install
make build
make run
make check
```

The app includes a native menu-bar panel, AppKit dictation overlay, Settings,
searchable History, and Diagnostics. Onboarding and the Vocabulary workflow are
being completed. The microphone stays closed between dictations by default.
Builds use an available Apple Development identity, with ad-hoc signing as a
local fallback. Hardened runtime is enabled.
`make package` creates a local ZIP in `build/package/`; it is not a notarized release.

`project.yml` owns the generated Xcode project. Build output stays in `build/`.
Run `make format` before `make check`. Keep credentials in the ignored `.env`.

For development, `make run` imports the local `.env` at runtime and stores its
API key in Tok's Keychain item. It never imports the old history database path.
Use Tok's setup window to grant Microphone, Accessibility, and Input Monitoring.
With Fn, set System Settings > Keyboard > Press Globe key to > Do Nothing.

`make check` runs offline XCTest fixtures and lint. `make test-live` uses the
local key for three synthetic Live turns and one REST transcription, with bounded
waits. Its timing measures audio-end to settlement, not physical key-up to paste.
See [VALIDATION.md](VALIDATION.md) for actual results and the real-dictation gate.

Tok is independent software. Engine behavior is ported from JustSpeak.
