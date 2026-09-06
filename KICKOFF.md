# Kickoff prompt for the Tok session

> Historical kickoff prompt. The project is implemented; do not restart bootstrap.
> [CLAUDE.md](CLAUDE.md) contains the current working agreement. Its main-branch
> workflow and continued execution supersede the feature-branch and milestone-stop
> instructions below. The JustSpeak configuration-import UI was also removed.

Paste this as the first message in a fresh session opened in the empty `tok/`
directory that contains `HANDOFF.md`.

---

You are starting **Tok**, a native macOS push-to-talk dictation app. This
directory is empty except for `HANDOFF.md`. Read it in full first; it is the
brief and it names every decision already made.

Then read the reference implementation, which is the behavioral spec:

- Local clone (read-only): `/Users/adhish/Projects/AI/justspeak`
- GitHub: https://github.com/adhishthite/justspeak
- Start with its `CLAUDE.md`, then `README.md`, then `.env.example`, then
  `src/22-app.swift`, `src/08-audio-engine.swift`, `src/09-live-client.swift`,
  `src/21-hud.swift`. Skim the rest of `src/` and `tests/`.

Do not modify anything in that repo.

Then do the following, in order, stopping for my review after each numbered
item:

1. **Confirm the open decisions** in HANDOFF section 8 with a one-line
   recommendation each. Ask only where you would build differently depending
   on the answer. Assume `com.adhishthite.tok`, macOS 14 minimum, XcodeGen,
   Sparkle as the only dependency, unless I say otherwise.
2. **Phase 0 (Bootstrap):** `project.yml`, `Makefile` with
   `install clean check format lint generate build run test package`,
   entitlements (sandbox off, hardened runtime on, audio input), Info.plist
   keys (`LSUIElement`, `NSMicrophoneUsageDescription`), `.gitignore`,
   `CLAUDE.md` from HANDOFF Appendix A, and an empty `MenuBarExtra` app that
   builds with `make build` and launches with `make run`. Commit on
   `feat/phase-0-bootstrap`.
3. **Phase 1 (Engine port):** port the modules per HANDOFF Appendix B with
   zero behavior change, one type per file, delegate instead of `print`.
   Port the regression fixtures from JustSpeak's `tests/` into XCTest. Show
   me `xcodebuild test` output. Commit on `feat/phase-1-engine`.

Rules for the whole project:

- Load the relevant skill before working in its area (HANDOFF section 9).
  For SwiftUI, read `~/.agents/skills/swiftui-expert-skill/references/latest-apis.md`
  first. For packaging, `~/.agents/skills/macos-spm-app-packaging/SKILL.md`.
- Keep the engine's NSLock + serial DispatchQueue threading. No actors in the
  turn arbiter. Reasons are in HANDOFF section 4.1.
- The HUD is AppKit + Core Animation. Do not rewrite it in SwiftUI.
- Never log, print, or commit my API key or `.env` contents.
- Report exactly which checks you ran and their output. Do not claim
  latency numbers you did not measure.
- Feature branch per phase. No merges to `main`, no releases, without my say.
- No em dashes in any prose or docs.

Start with step 1.
