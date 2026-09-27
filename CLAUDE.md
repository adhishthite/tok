# CLAUDE.md

Tok: native macOS push-to-talk dictation with a Gemini Live backend, shipped
as a signed menu-bar app. Tok is not a Google product and carries no Google branding.

## Build
- XcodeGen `project.yml` is the source of truth; `*.xcodeproj` is generated
  and gitignored. `make generate build run test lint format check package`.
- Deployment target macOS 14. Swift 6 language mode in App/Store/UI/Support;
  Engine and HUD may stay in Swift 5 mode until audited.
- App Sandbox is OFF by design (global event tap, AX, synthesized paste,
  IOKit). Hardened runtime ON. Distribution is Developer ID + notarization.
- Sparkle is integrated. Hosted updates and an actual installed update remain unverified.
  Other dependencies require a concrete engineering benefit.

## Layering
- `Engine/` has no SwiftUI and no window code. It reports through a delegate.
- `Store/DictationStore` (`@MainActor @Observable`) is the only engine
  surface SwiftUI sees. Views never touch the engine, sockets, or SQLite.
- `HUD/` is AppKit + Core Animation on an NSPanel. Do not rewrite in SwiftUI.
  Never animate the panel frame. `HoldRingView`'s backing layer is the
  CAShapeLayer via `makeBackingLayer`. All colors come from the Tok palette.
- Generative AI calls go to the Gemini API only. Do not add a third-party AI service:
  the owner's approval for Google corporate use depends on it.
- One type per file, named after the type. Normal access control.

## Engine invariants (do not relearn these)
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
- `make check` runs XCTest, Swift format lint, the compiled settings-reference
  check, shell syntax checks, Python regression tests, and `git diff --check`.
  `make check-ci` validates workflows and signing helpers. Report what ran.
- Latency claims require a measured Diagnostics line.
- Never log or commit secrets. Inspect config by key name only.

## Current working agreement
- Work directly on main and commit small, verified changes. Tags and releases require the owner's instruction.
- The source repository is public: `adhishthite/tok`, licensed Apache-2.0. The root
  `LICENSE` and `Resources/Tok-LICENSE.txt` must stay identical; `make check` enforces it.
  Pushes require the owner's authorization. Read [CI_RELEASE.md](CI_RELEASE.md) before
  release work. Binaries and update feeds are published from `adhishthite/tok-releases`.
- Continue the full goal autonomously. The owner superseded milestone review stops on 2026-09-05.
- Treat native behavior, restrained feedback, responsiveness, and performance as design inputs now, not a final cosmetic phase.
- Load the relevant skill before work in its area: `macos-menubar-tuist-app` (layering only),
  `macos-spm-app-packaging` (signing, notarization, Sparkle), `swiftui-expert-skill`,
  `swiftui-ui-patterns`, `swiftui-view-refactor`, `swift-concurrency-expert`,
  `swiftui-performance-audit`, `app-store-changelog` (release notes), `security-review`
  before a release, and `gemini-live-api`/`gemini-api` only for protocol changes.
- Before SwiftUI work, read ~/.agents/skills/swiftui-expert-skill/references/latest-apis.md.
- No em dashes in prose, docs, or new user-facing copy.

## Operation deadlines
- Long foreground commands use Scripts/bounded_run.py with an explicit deadline.
- Builds and tests default to 120 seconds. Inspect a live process and concrete progress before extending its control file, by at most 60 seconds each time.
- A started command has a process handle. A plan or Working indicator does not establish execution.
- Report results or blockers promptly; avoid unbounded waits and repeated UI inventory attempts.
