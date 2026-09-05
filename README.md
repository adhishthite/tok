# Tok

Native macOS push-to-talk dictation with a Gemini backend.

Requires macOS 14 or later. Development requires Xcode 26 and XcodeGen.

```sh
make install
make build
make run
make check
```

The current bootstrap displays a menu-bar panel. The dictation engine is next.
Builds use an available Apple Development identity, with ad-hoc signing as a
local fallback. Hardened runtime is enabled.
`make package` creates a local ZIP in `build/package/`; it is not a notarized release.

`project.yml` owns the generated Xcode project. Build output stays in `build/`.
Run `make format` before `make check`. Keep credentials in the ignored `.env`.

Tok is independent software. Engine behavior is ported from JustSpeak.
