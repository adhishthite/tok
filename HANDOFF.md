# Tok: Handoff Brief

> Historical brief, retained for design context. Read [CLAUDE.md](CLAUDE.md) for
> current instructions and [README.md](README.md) for implemented behavior.
> Work on main, continue without milestone review stops, and omit the JustSpeak
> configuration-import UI. These decisions supersede the instructions below. Targets here
> are requirements, not measured results; see [ACCEPTANCE.md](ACCEPTANCE.md).

Status: draft for a fresh implementation session. Written 2026-09-05 against
the reference repo `adhishthite/justspeak` at commit `06f1e09`
(branch `feat/astra-changes`).

## 0. What this is

**Tok** is a native macOS push-to-talk dictation app: hold a hotkey, speak,
release, and the transcript is pasted into the frontmost app in under half a
second. It is the productized successor of **JustSpeak**, a working prototype
that today runs as an interpreted Swift script started from a terminal with
`make run`. Tok is a signed, notarized, double-clickable `.app` with a menu-bar
presence, first-run onboarding, a Settings window, a history browser, and a
login item.

Tok is an independent product. It is not a Google app and carries no Google
branding. It uses the Gemini API as its transcription backend.

The dictation engine already exists and works in JustSpeak. Tok is a **port
plus a shell**: the engine moves over with its behavior intact and is
reorganized into a real app structure; the new work is everything around it.

The reference implementation is the spec. Read it before writing code.

| Reference | Location |
|---|---|
| Local clone (treat as read-only from the Tok project) | `/Users/adhish/Projects/AI/justspeak` |
| GitHub | https://github.com/adhishthite/justspeak |
| Engineering rules and hard-won invariants | `CLAUDE.md` in that repo |
| Every user-facing knob with rationale | `.env.example` in that repo |
| Feature list, architecture diagram, permissions guide | `README.md` in that repo |
| Source (30 modules, one type each, numerically prefixed) | `src/*.swift` |
| Executable behavior spec | `tests/*-regressions.swift`, `tests/verify_algorithms.py` |

## 1. Read these facts first

1. **Why JustSpeak is a script, and why Tok is not.** JustSpeak is interpreted
   by `/usr/bin/swift` so it can run on a corporate Mac governed by Santa
   binary authorization, which blocks unsigned binaries. That constraint
   produced the numeric file prefixes, the concatenate-then-interpret runner,
   the ban on third-party dependencies, and the ban on `async/await`. **None
   of those constraints apply to Tok.** Tok is a compiled, signed app for
   personal Macs and public distribution. Whether it runs on a Santa-governed
   Mac depends on that org's policy and is out of scope. JustSpeak stays as
   it is; do not modify that repo from the Tok project.
2. **No App Sandbox, no Mac App Store.** Tok needs a global `CGEventTap`,
   `AXIsProcessTrusted`, synthesized ⌘V, IOKit reads for secure-input
   holders, and CoreAudio device pinning. None of that survives the sandbox.
   Distribution is Developer ID + notarization + direct download.
3. **Toolchain on the owner's Mac (verified 2026-09-05):** Xcode 26.6
   (17F113), Swift 6.3.3, macOS 26.6.2, `xcodegen` installed at
   `/opt/homebrew/bin/xcodegen`, `tuist` not installed.
4. **The owner's `.env` and API key are private.** Tok imports them at
   runtime on the owner's machine. Never copy values into the Tok repo,
   logs, or commit history.
5. **Latency is the product.** Sub-500 ms end-to-end on the WebSocket path,
   measured by the existing `Diagnostics` module. A port that regresses this
   is a failed port. Keep the engine's threading model (section 4.1).

## 2. Product definition

### Users

The owner first, then other Mac users who want push-to-talk dictation with a
Gemini backend. Assume a technical but impatient user: onboarding must take
under two minutes and must never require a terminal.

### The v1 promise

Install Tok, grant three permissions from a guided checklist, paste an API
key, hold the hotkey, speak, release, text appears. Everything JustSpeak does
today, with no terminal.

### v1 scope (must ship)

- **Menu-bar app** (`LSUIElement = true`, no Dock icon by default). Status
  item shows state: idle, listening, processing, error, mic released,
  offline. Click opens a compact panel: last dictation, today's count and
  cost, quick toggles (privacy mode, sound), Settings, History, Quit.
- **The JustSpeak engine, ported faithfully.** Hotkey (`fn` default,
  push-to-talk and toggle modes, hold-to-lock), always-on audio engine with
  pre-roll ring buffer and adaptive post-roll, Gemini Live WebSocket primary
  path, REST fallback with validation gate, settle-once turn arbiter,
  replacement engine, clipboard injector with restore, secure-input
  detection, network gate, input-device pinning with lid-state auto mode,
  audio ducking, mic idle release, history store, correction watcher.
- **The JustSpeak HUD, ported as AppKit.** Notch-anchored pill, aura, orb,
  waveform, hold-to-lock ring, all reveal styles, particles, privacy mode,
  follow-focus. This is the product's visual signature. Do not rewrite it in
  SwiftUI (section 4.3). Re-skin its palette (section 4.7).
- **First-run onboarding window.** Live permission checklist with deep links
  to the exact System Settings panes: Microphone, Accessibility, Input
  Monitoring. API key entry stored in Keychain, validated with the logic
  behind JustSpeak's `--test-api`. Hotkey picker with the Fn-key caveat
  (System Settings > Keyboard > "Press 🌐 key to" must be "Do Nothing"; read
  `com.apple.HIToolbox AppleFnUsageType` to detect this and show a fix
  button; verify that key against macOS 26 before relying on it). Optional
  import of an existing JustSpeak `.env` and `vocabulary.txt` from a folder
  the user picks.
- **Settings window** (`Settings` scene, ⌘,). Every knob in JustSpeak's
  `.env.example` reachable, grouped (section 5). Backed by `UserDefaults`
  via `@AppStorage` except the API key (Keychain).
- **History window.** Table of turns from the SQLite DB: text, app, route
  (WS or REST), latency, tokens, cost, finish mode, status. Search, date
  filter, copy text, delete row, clear all. Summary strip for today, 7 days,
  30 days: count, words, cost, p50 and p95 latency.
- **Vocabulary editor.** Edit boost terms and `wrong => right` rules in a
  text view with syntax help, saved to the app's support directory, hot
  reloaded. A "Suggest from history" button runs the ported analyzer and
  offers suggestions as checkable rows that append in vocabulary-file syntax.
- **Login item** via `SMAppService.mainApp` with a Settings toggle.
- **Diagnostics.** An in-app log window (bounded, copyable) replacing
  terminal output. Per-turn latency breakdown in the history row detail.
- **Packaging.** Developer ID signing, hardened runtime, notarization,
  stapling, zip and DMG, Sparkle updates, versioned GitHub releases.

### Explicit non-goals for v1

iOS, App Store, cloud sync, accounts, server components, additional
transcription providers, text "polishing" prompts, streaming into the target
field character by character (paste-on-settle stays).

## 3. Build system and repo layout

Recommendation: **XcodeGen `project.yml` as the source of truth**, generated
`.xcodeproj` gitignored, builds via `xcodebuild` from a `Makefile`. Reasons:
the owner asked for an Xcode project, `xcodegen` is already installed, a text
manifest is agent-editable and diff-reviewable, and the owner's other project
(`~/Documents/Blocktris`) already uses this pattern. Tuist is not installed;
do not introduce it.

Alternative if the owner prefers zero Xcode project files: SwiftPM executable
target plus the bundle-assembly and notarization scripts from the
`macos-spm-app-packaging` skill. Only take this route on explicit request.

The numeric prefixes (`01-logging.swift`) and the "everything is one file"
access-control idiom are gone. One type per file, named after the type,
grouped by layer, with normal Swift access control. Top-level `private`
declarations that JustSpeak relied on being visible everywhere (for example
`SQLITE_TRANSIENT`) become `internal` members of the type that owns them.

```
tok/
  project.yml                 # XcodeGen: app target, test targets, entitlements, Info.plist keys
  Makefile                    # install generate build run test lint format check package notarize clean
  CLAUDE.md                   # seeded from Appendix A
  README.md
  .gitignore                  # *.xcodeproj, DerivedData, build/, .env, *.p8, *.dmg, *.zip
  Config/
    Tok.entitlements          # audio-input; sandbox OFF; hardened runtime ON
    version.env               # MARKETING_VERSION, BUILD_NUMBER (Sparkle needs monotonic CFBundleVersion)
  Sources/
    App/                      # @main TokApp, AppDelegate, scenes, dependency wiring only
    Engine/                   # ported JustSpeak modules (Appendix B), no UI imports beyond AppKit event/pasteboard APIs
      Audio/  Transcription/  Turn/  Injection/  Input/  History/  Vocabulary/  System/
    HUD/                      # ported HUD (AppKit + Core Animation on an NSPanel)
    Store/                    # DictationStore (@MainActor @Observable facade), SettingsStore, HistoryQuery
    UI/
      MenuBar/  Onboarding/  Settings/  History/  Vocabulary/  Diagnostics/  Components/
    Support/                  # Keychain, DefaultsKey table, EnvImporter, SystemSettingsLinks, Permissions
  Tests/
    EngineTests/              # XCTest ports of JustSpeak tests/*-regressions.swift
    StoreTests/
    UITests/                  # smoke only
  Scripts/
    build.sh run.sh package_app.sh sign-and-notarize.sh make_appcast.sh
  Resources/
    Assets.xcassets           # AppIcon, menu bar template images, Tok palette colors
```

Makefile targets must include `install clean check format lint` (owner's
global rule) plus `generate build run test package notarize`. `lint` and
`format` use `swift format` from the Apple toolchain; SwiftLint is optional
and must not be required for `make check` to pass.

Deployment target: **macOS 14 (Sonoma)**. Needed: `@Observable` (14),
`SettingsLink` and `openSettings` (14), `NSView.displayLink` (14),
`MenuBarExtra` (13), `SMAppService` (13). Adopt macOS 26 Liquid Glass only
behind `#available` and only where it earns its place (panel chrome,
Settings).

Swift language mode: **Swift 6** for `App/`, `Store/`, `UI/`, `Support/`.
For `Engine/` and `HUD/`, land the port first in Swift 5 mode (per-target
setting) or in Swift 6 with `@unchecked Sendable` on audited types, so the
first milestone is zero behavior change. Tighten afterward with the
`swift-concurrency-expert` skill.

## 4. Architecture decisions (with reasons)

### 4.1 Port the engine's behavior and threading; reorganize its files

JustSpeak's concurrency is NSLock + serial `DispatchQueue` + completion
handlers, and the invariants in its `CLAUDE.md` depend on that shape:

- The **settle-once turn arbiter** (`currentTurnId`, `turnSettled`,
  `pendingFallbackTimer`, mutated only on `sessionQueue`; `settle()` is the
  sole paste-or-error path; WebSocket and REST race and the first result for
  a live turn wins) relies on a serial queue with no suspension points. An
  actor introduces a possible interleaving at every `await`, which is exactly
  the reentrancy the arbiter exists to prevent.
- The audio tap callback runs on a real-time thread; the RMS math and
  ring-buffer writes there must stay allocation-free and lock-light.
- `handleKeyDown` and `handleKeyUp` run on the main thread because the
  `CGEventTap` is installed on the main run loop; `captureActive`,
  `turnLocked`, and the lock work items are main-thread-only.

So: the engine keeps its threading and its algorithms. What changes is
structure: files renamed and grouped (Appendix B), the orchestrator split
into an engine and a store, terminal printing replaced by delegate events and
`os.Logger`, and `Config` replaced by a typed settings table. Use
`async/await` only at the edges where it removes callback nesting without
touching timing: permission requests, `URLSession` in the analyzer and the
API-key test, Keychain, file import.

### 4.2 One facade between engine and UI

`DictationStore`, a `@MainActor @Observable` class, is the only thing
SwiftUI sees. The engine reports through a small delegate protocol
(`stateChanged`, `liveText`, `turnSettled(record)`, `micReleased`,
`permissionsChanged`, `diagnostic(line)`); the store hops to main and
publishes. Views never touch the engine, the WebSocket, or SQLite. This is
the model-client-store-view rule from the `macos-menubar-tuist-app` skill and
keeps the engine testable without a UI.

### 4.3 HUD stays AppKit

The HUD is an `NSPanel` with CALayer-backed views driven by a display-link
tick and a semi-implicit-Euler spring system, on a static max-footprint panel
(never animate the panel frame; window-server frame animation was the old
smoothness ceiling). `HoldRingView`'s backing layer must be the
`CAShapeLayer` itself via `makeBackingLayer`. These are AppKit and Core
Animation facts, and the current implementation is tuned. SwiftUI in a
non-activating overlay panel adds a layout and invalidation layer with no
benefit here. Port the HUD modules with their logic intact; expose the demo
mode behind a hidden Debug menu and a `--hud-demo` launch argument.

### 4.4 Configuration

`.env` becomes `UserDefaults` through one `SettingsStore` with typed keys and
the same defaults, clamps, and normalization JustSpeak's `Config` applies
(for example `normalizeLanguageCode`, the 0-1000 pre-roll clamp). The API key
goes to Keychain (`kSecClassGenericPassword`, service `com.adhishthite.tok`).
Keep process-environment overrides for every key. JustSpeak has two parse
sites per knob; Tok has **one table entry per knob** that drives the
`UserDefaults` key, the env override, the Settings control, and the README
row. An `EnvImporter` reads a user-chosen JustSpeak `.env` and
`vocabulary.txt` once during onboarding.

Files: `~/Library/Application Support/Tok/vocabulary.txt`,
`~/Library/Application Support/Tok/history.db`. On first launch, if
`~/.justspeak/history.db` exists, offer to copy it (same schema).

### 4.5 Permissions and TCC

A native bundle gets its own TCC identity, which is the main UX win: prompts
say "Tok" instead of "Terminal". Required: Microphone
(`NSMicrophoneUsageDescription`), Accessibility (for `CGEvent` posting and
AX reads), Input Monitoring (for the listen-only event tap on modifier
keys). Onboarding polls status every second while visible and flips rows
green without a relaunch. Deep links:

```
x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone
x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent
```

Verify these anchors on macOS 26 before shipping; they have drifted between
releases. Preserve JustSpeak's degradation behavior: a revoked permission
mid-session downgrades to copy-only with a pointer to the right pane; secure
input refuses at key-down and downgrades to copy-only at paste time.

### 4.6 Logging

Replace `print` with `os.Logger` (subsystem `com.adhishthite.tok`,
categories per module) plus the ported bounded log buffer feeding the in-app
Diagnostics window. Privacy mode continues to log character counts, never
text. Never log the API key or Keychain material. The ANSI color helpers are
deleted.

### 4.7 Brand and palette

JustSpeak's HUD cycles "one Google color at a time" (blue, red, yellow,
green, white) and its README carries a Google disclaimer. Tok drops both.
Define a Tok palette in `Assets.xcassets` (Display P3, light and dark) and
route every HUD color through it: the listening cycle, success, error, and
the orb gradient. The HUD's geometry, springs, and glow construction do not
change; only the color inputs do. The About window credits the Gemini API as
the backend and nothing else.

## 5. Settings information architecture

Group JustSpeak's `.env.example` knobs like this. Keep the old key names as
the `UserDefaults` keys so the importer is a straight map.

| Tab | Knobs |
|---|---|
| General | HOTKEY, HOTKEY_MODE, HOLD_TO_LOCK, LOCK_LIMIT, launch at login, SOUND_FEEDBACK, RELEASE_SOUND, TRAILING_SPACE, RESTORE_CLIPBOARD |
| Transcription | API key (Keychain, test button), GEMINI_LIVE_MODEL, GEMINI_MODEL, SMART_TRANSCRIPTION, LANGUAGE_CODES (chips from the docs table), ENABLE_LIVE_WEBSOCKET, REST_FALLBACK_TIMEOUT, VAD_MODE, VAD_SILENCE_MS |
| Audio | INPUT_DEVICE (picker fed by the device catalog, with "auto" and the lid-state explanation), MIC_IDLE_TIMEOUT, DUCK_AUDIO, DUCK_FRACTION, PRE_ROLL_MS, POST_ROLL_MS, POST_ROLL_MAX_MS, TRAIL_SILENCE_DB (with a live meter) |
| Appearance | SHOW_HUD, HUD_REVEAL (with a preview button that runs the demo), HUD_FOLLOW_FOCUS, HUD_PARTICLES, PRIVACY_MODE, menu bar icon style |
| Vocabulary | editor, file location, "Suggest from history" (ANALYZE_MODEL, ANALYZE_CONTEXT), LEARN_CORRECTIONS, LEARN_DELAY_MS |
| History | HISTORY on/off, DB path, retention, export CSV, clear |
| Advanced | WS_ENDPOINT_ALIGNED, CHUNK_MS, SILENCE_FLUSH_MS, pricing knobs, LOG_LEVEL, open logs folder, reset to defaults |

Copy rules: one term per concept ("dictation", "turn", "hotkey", "HUD"),
sentence-case labels, help text under each control taken from the
`.env.example` comments and shortened.

## 6. Phased plan

Each phase ends with `make check` green and a short user test script. Commit
per phase on a feature branch.

| Phase | Deliverable | Done when |
|---|---|---|
| 0 Bootstrap | `project.yml`, Makefile, entitlements, Info.plist keys, `.gitignore`, empty menu-bar app named Tok that launches | `make run` shows a status item; `codesign -dv` shows hardened runtime with a dev identity |
| 1 Engine port | `Sources/Engine/` per Appendix B, compiling with zero behavior change; XCTest ports of JustSpeak's regression fixtures | all ported regression checks pass under `xcodebuild test` |
| 2 Orchestrator + store | JustSpeak's `JustSpeakApp` becomes `DictationEngine` reporting to `DictationStore`; status item reflects state; dictation works end to end with a Keychain key | hold, speak, release pastes text; Diagnostics latency line matches JustSpeak within noise on the same network |
| 3 HUD port | `Sources/HUD/` with the Tok palette; Debug menu runs the demo | all reveal styles, lock ring, particles, privacy mode behave as in JustSpeak |
| 4 Onboarding | permissions checklist, API key entry and test, hotkey picker with Fn check, `.env` import | a fresh macOS user account reaches a working dictation without a terminal |
| 5 Settings | every knob in section 5, live-applied where the engine supports it, restart-required badge where it does not | each knob changes behavior; env override still wins |
| 6 History + Vocabulary | history window, stats strip, vocabulary editor, analyzer suggestions | analyzer output appends valid vocabulary-file syntax the parser reads back |
| 7 Packaging | Developer ID signing, notarization, stapling, Sparkle appcast, DMG, GitHub release, login item | `spctl --assess --type execute` passes on a clean Mac; Sparkle updates from a test appcast |
| 8 Polish | Liquid Glass where warranted, accessibility pass, copy pass, app icon | `better-interface` review has no open high-severity items |

## 7. Acceptance criteria

- Latency: median WebSocket-path end-to-end under 500 ms on the owner's Mac,
  measured with the ported `Diagnostics`, no worse than JustSpeak on the same
  network.
- Zero regressions in the ported regression checks. JustSpeak's
  `tests/verify_algorithms.py` remains the reference for DSP, regex, and
  SQL-bind alignment questions.
- Every `.env.example` knob is reachable in Settings and documented in the
  README table.
- Onboarding completes on a fresh macOS user account with no terminal use.
- The history DB schema is compatible with JustSpeak's (currently 38 INSERT
  columns; migrations stay best-effort `ALTER TABLE`).
- HUD parity: side by side with JustSpeak, identical geometry and motion;
  only colors differ, and those match the Tok palette.
- A notarized build passes Gatekeeper on a Mac that has never seen the app.
- No Google branding, palette, or disclaimer anywhere in the bundle.

## 8. Risks and open decisions for the owner

1. **Third-party dependencies.** JustSpeak forbids them because of Santa. Tok
   has no such constraint. Recommendation: allow exactly one, Sparkle for
   updates. Everything else stays first-party (SQLite3, AppKit, AVFoundation,
   CoreAudio, IOKit, Network, Security, ServiceManagement, Observation).
2. **Sharing engine source with JustSpeak.** Tempting, but it pins the engine
   to the interpreter's constraints forever. Recommendation: fork cleanly;
   backport fixes by hand when they matter.
3. **Fn key detection.** `AppleFnUsageType` in `com.apple.HIToolbox` is the
   likely signal; confirm it on macOS 26 before building UI on it.
4. **Minimum macOS.** 14 is recommended; 13 would cost `@Observable` and
   `SettingsLink`. The owner runs 26.
5. **Bundle ID.** Suggested `com.adhishthite.tok`. Confirm before the first
   notarization, since TCC grants are keyed by bundle ID.
6. **Tok palette.** Needs a decision before Phase 3. Recommendation: one
   accent hue with a listening cycle built from its analogous neighbors,
   plus system green and red for success and error.
7. **Sounds.** JustSpeak uses macOS system sounds by path. They may move
   between macOS releases. Recommendation: bundle a small set of Tok earcons
   in Phase 8; keep system sounds until then.

## 9. Skills available to the implementing model

All under `~/.agents/skills/<name>/SKILL.md` unless noted. Load the skill
before working in its area.

| Skill | Use it for |
|---|---|
| `macos-menubar-tuist-app` | Architecture rules for `LSUIElement` menu-bar apps: model-client-store-view, no networking in views, script-based launch. Ignore its Tuist specifics (not installed); keep the layering. |
| `macos-spm-app-packaging` | Signing, hardened runtime, notarization, stapling, Sparkle appcast, validation checkpoints, common notarization failures. Its scripts in `assets/templates/` adapt to `xcodebuild` output with small edits. |
| `swiftui-expert-skill` | `references/latest-apis.md` before any SwiftUI work; `macos-scenes.md` for `MenuBarExtra`, `Settings`, `Window`; `macos-views.md`; Instruments trace analysis. |
| `swiftui-ui-patterns` | `references/menu-bar.md`, `macos-settings.md`, `app-wiring.md`, `form.md`, `list.md`, `overlay.md`, `lightweight-clients.md`. |
| `swiftui-view-refactor` | Small view bodies, MV over MVVM, dedicated subview types, stable view trees. |
| `swift-concurrency-expert` | After Phase 1: Sendable audits, `@MainActor` placement, fixing Swift 6 diagnostics without changing engine timing. |
| `swiftui-performance-audit` | If the History table or Settings feel slow; code-first, then Instruments. |
| `swiftui-liquid-glass` | Phase 8 only, behind `#available(macOS 26, *)`. |
| `app-store-changelog` | Release notes for GitHub releases and the Sparkle appcast, even though Tok is not an App Store app. |
| `~/Documents/Blocktris/.agents/skills/swift-ios-project-tooling` | The XcodeGen + Makefile + `swift format` pattern; iOS-flavored, drop the simulator bits. |
| `frontend-design`, `make-interfaces-feel-better`, `better-interface`, `better-colors`, `better-writing` | Palette, visual, and copy passes on onboarding, Settings, History, menu-bar panel. |
| `tdd`, `code-review`, `security-review`, `review-swarm` | Per-phase verification. `security-review` before the first notarized release (Keychain, TCC, clipboard handling). |
| `gemini-live-api`, `gemini-api` | Only if the Gemini protocol needs a change. The ported live client already encodes the working recipe: `setup.inputAudioTranscription` at top level, manual VAD via `realtimeInputConfig.automaticActivityDetection.disabled: true`, `x-goog-api-key` header. Verify against the live-transcribe docs page, not generic Live API docs. |

## 10. Working rules for the implementing model

- Read JustSpeak's `CLAUDE.md` in full before touching `Engine/`. Its
  "Invariants that past bugs were made of" section is a list of regressions
  that already happened once.
- When porting a module, diff the ported logic against the original before
  committing. Structural changes (file split, rename, access control,
  delegate instead of print) and behavior changes are separate commits.
- Never print, log, or commit the API key or the contents of the owner's
  `.env`. Inspect config by key name only.
- You can compile and run on this Mac. Report exactly which checks ran and
  their output. Do not claim latency numbers you did not measure.
- Commit to a feature branch per phase. Do not merge to `main` without the
  owner's instruction. Do not publish releases without instruction.
- Every phase ends with a user test script: steps, expected behavior, and
  the failure signature if it is still broken.

---

## Appendix A: seed for Tok's `CLAUDE.md`

```markdown
# CLAUDE.md

Tok: native macOS push-to-talk dictation with a Gemini Live backend, shipped
as a signed menu-bar app. Ported from https://github.com/adhishthite/justspeak
(an interpreted-script prototype; local clone at
/Users/adhish/Projects/AI/justspeak, read-only from here). When engine
behavior is in question, that repo's `src/` and `CLAUDE.md` are the spec.
Tok is not a Google product and carries no Google branding.

## Build
- XcodeGen `project.yml` is the source of truth; `*.xcodeproj` is generated
  and gitignored. `make generate build run test lint format check package`.
- Deployment target macOS 14. Swift 6 language mode in App/Store/UI/Support;
  Engine and HUD may stay in Swift 5 mode until audited.
- App Sandbox is OFF by design (global event tap, AX, synthesized paste,
  IOKit). Hardened runtime ON. Distribution is Developer ID + notarization.
- One third-party dependency is allowed: Sparkle. Nothing else.

## Layering
- `Engine/` has no SwiftUI and no window code. It reports through a delegate.
- `Store/DictationStore` (`@MainActor @Observable`) is the only engine
  surface SwiftUI sees. Views never touch the engine, sockets, or SQLite.
- `HUD/` is AppKit + Core Animation on an NSPanel. Do not rewrite in SwiftUI.
  Never animate the panel frame. `HoldRingView`'s backing layer is the
  CAShapeLayer via `makeBackingLayer`. All colors come from the Tok palette.
- One type per file, named after the type. Normal access control.

## Engine invariants (inherited; do not relearn these)
- Settle-once arbiter: `currentTurnId`/`turnSettled`/`pendingFallbackTimer`
  mutate only on `sessionQueue`; `settle()` is the sole paste-or-error path;
  WS and REST race, first result for a live turn wins. No second path to
  `handleTranscribedText`. No actors here.
- `isProcessing` is set in `handleKeyUp` before the post-roll drain; every
  pipeline exit clears it.
- `captureActive`, `turnLocked`, lock work items: main-thread-only.
  `handleKeyDown` checks `turnLocked` before `isProcessing`.
- Micro-click guard and silent-clip gate abandon the WS turn without
  committing; `startNewTurn` resets state.
- Nothing calls `sessionQueue.sync` from main.
- Never hold an NSLock while logging or calling out. Snapshot, release, act.
- History shows the clean transcript; only the pasted payload gets the
  trailing space. Token counts are raw API values or NULL, never estimates.
- Every config knob: one table entry drives UserDefaults key, env override,
  Settings UI, and README row. API key lives in Keychain only.

## Verification
- `make check` = `xcodebuild test` + `swift format lint`. Report what ran.
- Latency claims require a measured Diagnostics line.
- Never log or commit secrets. Inspect config by key name only.
```

## Appendix B: engine module map (JustSpeak file → Tok home)

| JustSpeak | Type(s) | Tok location | Notes |
|---|---|---|---|
| 00-header, 99-main | (top-level) | App/TokApp.swift, App/AppDelegate.swift | `@main`, scenes, DI; `setbuf` and the CLI arg parsing go away except `--hud-demo` |
| 01-logging | ANSI, BoundedLogWriter, Logger | Engine/System/Log.swift, Engine/System/BoundedLogBuffer.swift | ANSI deleted; Log wraps os.Logger + buffer |
| 02-config | Config, ReplacementRule | Store/SettingsStore.swift, Support/DefaultsKey.swift, Engine/Vocabulary/ReplacementRule.swift | one knob table |
| 03-wav | (free functions) | Engine/Audio/WAVEncoder.swift | verbatim |
| 04-sound | SoundManager | Engine/System/SoundManager.swift | system sounds until Phase 8 |
| 05-injector | ClipboardPreparation, TextInjector | Engine/Injection/ | verbatim |
| 06-replacement-engine | ReplacementEngine | Engine/Vocabulary/ReplacementEngine.swift | verbatim, port tests |
| 07-history-store | TranscriptionHistoryStore | Engine/History/HistoryStore.swift | same schema; add read queries for the UI |
| 08-audio-engine | AudioCaptureEngine, MicRecoveryController | Engine/Audio/ | verbatim |
| 09-live-client | GeminiLiveClient | Engine/Transcription/GeminiLiveClient.swift | verbatim |
| 10-validation-gate | RestValidationGate | Engine/Transcription/RestValidationGate.swift | verbatim, port tests |
| 11-rest-client | CancellableRequest, GeminiRestClient | Engine/Transcription/ | verbatim |
| 12-hotkey | HotkeyManager | Engine/Input/HotkeyManager.swift | verbatim |
| 13-permissions | PermissionChecker | Support/Permissions.swift | becomes observable status for onboarding |
| 14-secure-input | SecureInputMonitor | Engine/Input/SecureInputMonitor.swift | verbatim |
| 15-design-palette | AppleDesign | HUD/Palette.swift | rewritten against the Tok palette assets |
| 16-notch | NotchGeometry | HUD/NotchGeometry.swift | verbatim |
| 17-hud-aura | AppleNotchAuraView | HUD/AuraView.swift | logic verbatim, colors from palette |
| 18-hud-orb | AppleIntelligenceOrbView | HUD/OrbView.swift | logic verbatim, gradient from palette |
| 19-hud-waveform | AppleSiriWaveformView | HUD/WaveformView.swift | verbatim |
| 20-hud-backplate | AppleIslandBackplateView | HUD/BackplateView.swift | verbatim |
| 21-hud | FloatingHUD, HoldRingView, MainQueueDelivery, SpringChannel | HUD/FloatingHUD.swift, HUD/HoldRingView.swift, HUD/SpringChannel.swift, HUD/MainQueueDelivery.swift | split by type, logic verbatim |
| 22-app | JustSpeakApp | Engine/Turn/DictationEngine.swift, Store/DictationStore.swift | split: orchestration stays in the engine, printing becomes delegate events |
| 23-diagnostics | Diagnostics | Engine/Turn/Diagnostics.swift | feeds history detail + log window |
| 24-network-monitor | NetworkMonitor | Engine/System/NetworkMonitor.swift | verbatim |
| 25-analyzer | VocabularyAnalyzer | Engine/Vocabulary/VocabularyAnalyzer.swift | UI wraps it; never in the dictation path |
| 26-audio-ducker | AudioDucker | Engine/Audio/AudioDucker.swift | verbatim |
| 27-hud-demo | HudDemo | HUD/HUDDemo.swift | Debug menu + launch argument |
| 28-correction-watcher | CorrectionWatcher | Engine/Vocabulary/CorrectionWatcher.swift | verbatim |
| 29-input-devices | InputDeviceCatalog | Engine/Audio/InputDeviceCatalog.swift | also feeds the Settings picker |
| 30-focus-screen | FocusScreenResolver | HUD/FocusScreenResolver.swift | verbatim |
