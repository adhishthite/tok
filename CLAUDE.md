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
- Sparkle is the planned updater. Other dependencies require a concrete engineering benefit.

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

## Current working agreement
- Work directly on main and commit small, verified changes. Tags and releases require the owner's instruction.
- HANDOFF.md is guidance. The reference source wins when the brief disagrees.
- Continue the full goal autonomously. The owner superseded milestone review stops on 2026-09-05.
- Treat native behavior, restrained feedback, responsiveness, and performance as design inputs now, not a final cosmetic phase.
- Keep JustSpeak read-only. Its corporate interpreter restrictions do not apply here.
- Use the relevant skills listed in HANDOFF section 9 before work in each area.
- Before SwiftUI work, read ~/.agents/skills/swiftui-expert-skill/references/latest-apis.md.
- No em dashes in prose, docs, or new user-facing copy.
