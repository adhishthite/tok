# HUD Reduce Motion review

Date: 2026-09-06

## Confirmed source defect

`FloatingHUD` sampled Reduce Motion while starting transitions but did not observe
changes. An already running display link continued spring travel, width motion,
lock pulse, and ambient phases. A stopped display link also did not cancel an
independent Core Animation success ripple or already emitted particles.

## Change

Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on the
workspace notification center, with a weak callback and explicit observer removal.
On enabling Reduce Motion, stop the display link, settle spring geometry, stop
particle and ripple motion, release queued lock-hint text, and preserve privacy
and visibility. On disabling it, resume an active HUD or unfinished exit. Keep
hold timing so a resumed ring uses the existing deadline.

The HUD remains AppKit and Core Animation. No engine synchronization changed.

Apple documents that this notification must use the workspace notification
center: [API reference](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification).

## Verification status

Added synthetic tests for active entrance and width settling, motion resumption,
locked text release, privacy preservation, exit interruption, and active ripple
removal. Tests use a private notification center and injected preference closure.
They do not change the owner's global accessibility preferences.

Subagent did not run builds, tests, GUI interactions, or microphone tests. Parent
must record actual check results. Source and regression coverage do not establish
visual behavior or VoiceOver acceptance. A running-app check must still toggle
Reduce Motion during entrance, listening, hold lock, success ripple, and exit,
then toggle it off and check resumption without a stuck HUD.

The coordinator ran `make check` under a 120-second supervisor. The first attempt
stopped on test formatting before compilation. After scoped formatting, the
second attempt exited 0: XCTest succeeded, including all four new HUD tests;
three explicit live tests remained skipped, the 53-setting reference matched,
and all 18 Python regression tests passed. Log:
`/tmp/tok-deferred-acceptance-check-2.log`. No runtime visual claim follows.
