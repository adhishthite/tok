# Accessibility source review

Reviewed on 2026-09-06. This is a source review, not a completed keyboard or
VoiceOver acceptance test. The workstream had a ten-minute maximum and did not
interact with the running app, microphone, or saved dictations.

## Changes

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| Medium | Sources/UI/Vocabulary/VocabularySuggestionsView.swift | Suggestion sheet actions had no explicit cancel/default keyboard equivalents. | Escape cancels; Return adds the selected suggestions. The add action stays disabled when nothing is selected. | Native sheet keyboard actions avoid requiring traversal to the action buttons. |
| Low | Sources/UI/Settings/SettingRow.swift | Setting explanations were separate text below controls. | Each catalog control also exposes its explanation as an accessibility hint. | A screen-reader user can obtain the explanation while focused on the control. |

## Source evidence

- Settings, setup, menu, vocabulary, History, and diagnostics use native buttons,
  toggles, pickers, text inputs, tables, and confirmation dialogs. No custom tap
  gesture substitutes were found in the inspected UI sources.
- The vocabulary text editor has an explicit accessible name. Permission buttons
  include the permission name. Menu navigation decorations are hidden from
  accessibility. Connection status has a text label and symbol as well as color.
- History and diagnostic tables expose native copy commands. History also exposes
  the delete command with confirmation. Vocabulary Save has Command-S.
- HUD entrance and exit have reduced-motion opacity paths. Hold-ring animation,
  text crossfades, and aura pulses have reduced-motion guards. The waveform is
  driven by input level and remains an informational signal display.
- No focus-ring suppression was found in the inspected UI sources.

## Checks run

- `python3 Scripts/bounded_run.py --seconds 30 --label accessibility-format -- xcrun swift format format --in-place Sources/UI/Settings/SettingRow.swift Sources/UI/Vocabulary/VocabularySuggestionsView.swift`
  exited 0, with no formatter diagnostics.
- `python3 Scripts/bounded_run.py --seconds 30 --label accessibility-lint -- xcrun swift format lint --strict Sources/UI/Settings/SettingRow.swift Sources/UI/Vocabulary/VocabularySuggestionsView.swift`
  exited 0, with no lint diagnostics.
- `git diff --check` exited 0, with no output before this report was added.
- No Xcode build or XCTest was run by this workstream. The coordinating agent owns
  the build queue and must validate the combined source changes.

## Not verified

- Actual VoiceOver names, roles, states, reading order, and dynamic status delivery.
- Tab traversal, visible focus, sidebar-to-detail navigation, sheet initial focus,
  and restoration to the initiating control after dismissal.
- Escape and Return behavior in a running suggestion sheet.
- HUD discoverability and status announcements while another app holds focus.
- Reduce Motion changed during an active HUD animation, increased contrast,
  reduced transparency, enlarged text, and rendered color contrast.

The coordinating agent ran `make check` with a 120-second deadline after both
changes. It exited 0: 68 XCTest passes, three explicit live-test skips, 18 Python
regression passes, and a matching 53-setting reference. The log is
`/tmp/tok-accessibility-check.log`. Runtime accessibility acceptance remains open;
this review does not establish full accessibility.
