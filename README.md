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
searchable History, Vocabulary editing with suggestions, and Diagnostics.
Setup guides permissions, API key storage, and shortcut testing.
Audio settings include a native microphone picker with System Default,
automatic lid-based selection, and connected device names. Explicit device
choices use stable IDs. Disconnected and imported selections are preserved.
The microphone stays closed between dictations by default.
Diagnostics shows the latest timing breakdown and a searchable session log.
Warnings and errors can be filtered, selected entries can be copied, and clearing
the log leaves saved dictations intact. Transcript text is not logged by the
live-stream or completed-turn paths.
Builds use an available Apple Development identity, with ad-hoc signing as a
local fallback. Hardened runtime is enabled.
`make package` creates a local ZIP in `build/package/`; it is not a notarized release.
`make distribute` creates a universal Developer ID-signed app, DMG, and ZIP.
See [DISTRIBUTION.md](DISTRIBUTION.md) for notarization and update configuration.

`project.yml` owns the generated Xcode project. Build output stays in `build/`.
Run `make format` before `make check`. Keep credentials in the ignored `.env`.

For development, `make run` imports the local `.env` at runtime and stores its
API key in Tok's Keychain item. It never imports the old history database path.
Imports preserve your existing history retention choice. Change retention in
History settings, where deleting older records requires confirmation.
Use Tok's setup window to grant Microphone, Accessibility, and Input Monitoring.
With Fn, set System Settings > Keyboard > Press Globe key to > Do Nothing.

`make check` runs offline XCTest fixtures and lint. `make test-live` uses the
local key for three synthetic Live turns and one REST transcription, with bounded
waits. Its timing measures audio-end to settlement, not physical key-up to paste.
See [VALIDATION.md](VALIDATION.md) for actual results and the real-dictation gate.
`make profile-microphone` records a bounded Instruments startup profile.
See [PERFORMANCE.md](PERFORMANCE.md) for the measured main-thread setup delay.

Tok is independent software. Engine behavior is ported from JustSpeak.
