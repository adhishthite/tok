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
searchable History, a Stats dashboard, Vocabulary editing with suggestions, and
Diagnostics.
Setup guides permissions, API key storage, and shortcut testing. The connection
test shows explicit checking, connected, and failure states. If Tok is missing
from a permission list, setup can reveal the running app in Finder.
Audio settings include a native microphone picker with System Default,
automatic lid-based selection, and connected device names. Explicit device
choices use stable IDs. Disconnected and imported selections are preserved.
The microphone stays closed between dictations by default.
Optional cleanup is in Settings > Transcription: enable “Polish dictations before
pasting” for an extra Gemini 3.5 Flash-Lite pass. It is off by default. The separate
“Adapt formatting to the app” option includes only the destination app name and
identifier captured when dictation started, not window titles or contents.
Cleanup can format numbers and lists while preserving the spoken meaning and
languages. It adds a model round trip. Failed, timed-out, or unusable results fall
back to the original transcript. See [POSTPROCESSING.md](POSTPROCESSING.md).

Stats refreshes when opened, when Tok becomes active, after wake, and when the day changes.
Choose Refresh (Command-R) to reload local stats on demand. Percentage changes compare
the same elapsed duration in the previous period; no comparison is shown when that
period is too short.

Stats shows words dictated, speaking rate, time saved against your typing speed,
streaks, activity by day and hour, words by application, and the most and least
used words for today, this week, this month, this year, or all time. It reads a
separate local database, `stats.db`, that holds per-dictation counts and timing
plus per-day word counts and never transcripts, so totals survive history being
off, pruned, or cleared. Stats tracking and word counting are separate toggles in
Settings > Privacy, and Reset deletes the database contents.
Diagnostics shows the latest timing breakdown and a searchable session log.
Warnings and errors can be filtered, selected entries can be copied, and clearing
the log leaves saved dictations intact. Transcript text is not logged by the
live-stream or completed-turn paths.
REST failures use safe messages that direct you to Tok Settings; raw response
bodies and provider-supplied error text are not copied into error descriptions.
Settings > Privacy states what leaves the Mac and what stays, with a button
beside each statement to check it. Usage metrics are off by default, record
only counts and categories, and this version sends nothing. See
[PRIVACY.md](PRIVACY.md), which also carries the generated event schema.
Builds use an available Apple Development identity, with ad-hoc signing as a
local fallback. Hardened runtime is enabled.
`make package` creates a local ZIP in `build/package/`; it is not a notarized release.
`make distribute` creates a universal Developer ID-signed app, DMG, and ZIP.
See [DISTRIBUTION.md](DISTRIBUTION.md) for notarization and update configuration.
GitHub CI and manual draft-release workflows are described in
[CI_RELEASE.md](CI_RELEASE.md). The source repository is private. CI can run after
the first push; release automation needs a separate update-hosting design and
signing setup before use.

Contributors and coding agents should start with [AGENTS.md](AGENTS.md) and
[CLAUDE.md](CLAUDE.md). The original handoff and kickoff are historical briefs.

`project.yml` owns the generated Xcode project. Build output stays in `build/`.
`make icon` regenerates the committed app-icon sizes from the original vector
drawing in `Scripts/generate_icon.swift`.
Run `make format` before `make check`. Keep credentials in the ignored `.env`.

For development only, `make run` seeds settings from the local `.env` and stores
its API key in Keychain.
Development seeding preserves the current history path and retention choice.
Change retention in History settings, where deleting older records requires
confirmation.

“Add vocabulary from file” accepts UTF-8 text up to 1 MB and merges new lines
without removing existing terms. When the vocabulary is open, additions are
staged in that document without overwriting unsaved edits. Save to apply them.
In Vocabulary, “Analyze history…” reviews up to 500 saved dictations from the
last 30 days, existing vocabulary, and observed corrections through Gemini.
Review the suggestions, choose the terms or replacements to add, then Save.
Analysis is explicitly requested and does not run in the dictation path.
Replacement processing is bounded to 1,000,000 UTF-16 output units, 10,000 matches,
and 16,000,000 scanned UTF-16 units per dictation. If a limit is reached, Tok does
not paste the expanded text and keeps the original in History when history is enabled.
Use Tok's setup window to grant Microphone, Accessibility, and Input Monitoring.
With Fn, set System Settings > Keyboard > Press Globe key to > Do Nothing.

`make check` runs offline XCTest fixtures and lint. `make test-live` uses the
local key for three synthetic Live turns and one REST transcription, with bounded
waits. Its timing measures audio-end to settlement, not physical key-up to paste.
See [VALIDATION.md](VALIDATION.md) for actual results and the real-dictation gate.
`make profile-microphone` records a bounded Instruments startup profile.
See [PERFORMANCE.md](PERFORMANCE.md) for the measured main-thread setup delay.

Tok is independent software.

Update the reference below with `make settings-reference`. `make check` verifies
it against the compiled catalog without reading user configuration.

<!-- BEGIN GENERATED SETTINGS -->

## Settings reference

Generated from `SettingCatalog`. Defaults below are built-in values, before imports or environment overrides.
The API key is stored separately in Keychain and is never part of this table.

History retention is changed through a confirmation in Settings. An empty vocabulary path uses Tok’s Application Support folder.

### General

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Dictation shortcut | <code>HOTKEY</code> | <code>fn</code> | <code>fn</code>, <code>right_option</code>, <code>left_option</code>, <code>right_control</code>, <code>left_control</code>, <code>right_cmd</code>, <code>left_cmd</code>, <code>f13</code>, <code>f14</code>, <code>f15</code>, <code>f16</code>, <code>f17</code>, <code>f18</code>, <code>f19</code>, <code>f20</code> | Hold this key to dictate. Fn requires “Do Nothing” in Keyboard settings. |
| Shortcut behavior | <code>HOTKEY_MODE</code> | <code>push_to_talk</code> | <code>push_to_talk</code>, <code>toggle</code> | Hold to speak, or press once to start and again to finish. |
| Hold to lock | <code>HOLD_TO_LOCK</code> | <code>15.0</code> | 0.0 to 60.0 | Seconds before a held shortcut locks recording. Zero disables it. |
| Locked recording limit | <code>LOCK_LIMIT</code> | <code>120.0</code> | 0.0 to 600.0 | Maximum seconds for hands-free recording. Zero removes the limit. Every dictation still ends before the 10 minute live session limit. |
| Play dictation sounds | <code>SOUND_FEEDBACK</code> | <code>false</code> | true, false | Quiet cues when recording starts, finishes, locks, or fails. |
| Play a release cue | <code>RELEASE_SOUND</code> | <code>false</code> | true, false | An additional short cue when you release the shortcut. |
| Restore clipboard | <code>RESTORE_CLIPBOARD</code> | <code>true</code> | true, false | Put your previous clipboard back after pasting, unless you copied something new. |
| Add a trailing space | <code>TRAILING_SPACE</code> | <code>true</code> | true, false | Keep consecutive dictations separated. |
| Typing speed | <code>TYPING_WPM</code> | <code>40</code> | 10 to 200 | Your typing speed. Stats uses it to estimate the time dictation saves. |

### Transcription

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Clean up during live transcription | <code>SMART_TRANSCRIPTION</code> | <code>true</code> | true, false | Ask the live model to remove fillers and format numbers and dates, using the existing transcription request. |
| Polish dictations before pasting | <code>POST_PROCESS_ENABLED</code> | <code>false</code> | true, false | Send the transcript through an optional cleanup pass for punctuation, numbers, and lists. Adds response time and API usage. Off by default. |
| Adapt formatting to the app | <code>POST_PROCESS_APP_CONTEXT</code> | <code>false</code> | true, false | When cleanup is enabled, include the destination app name and identifier. Window titles and contents are not sent. |
| Languages | <code>LANGUAGE_CODES</code> | <code>en-IN,hi-IN,mr-IN</code> | Text | Comma-separated language codes, such as en-IN,hi-IN,mr-IN. Use auto for unrestricted recognition. |

### Audio

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Microphone | <code>INPUT_DEVICE</code> | (empty) | System Default, Automatic, or a connected microphone | System Default follows your Mac’s sound settings. Automatic uses the built-in microphone with the lid open and an external microphone with it closed. |
| Keep microphone ready | <code>KEEP_MICROPHONE_WARM</code> | <code>false</code> | true, false | Keep capturing between dictations for pre-roll. macOS will show microphone use while idle. |
| Release an idle microphone | <code>MIC_IDLE_TIMEOUT</code> | <code>300</code> | 0 to 7200 | Seconds before releasing warm capture. Zero keeps it open. Applies only when “Keep microphone ready” is on. |
| Lower other audio while dictating | <code>DUCK_AUDIO</code> | <code>false</code> | true, false | Restore the volume after capture. Your manual volume changes take priority. |
| Background volume fraction | <code>DUCK_FRACTION</code> | <code>0.2</code> | 0.0 to 1.0 | How much output volume to keep while dictating, from zero to one. |

### Appearance

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Show dictation overlay | <code>SHOW_HUD</code> | <code>true</code> | true, false | A small overlay follows your dictation without taking keyboard focus. |
| Follow the focused display | <code>HUD_FOLLOW_FOCUS</code> | <code>true</code> | true, false | Show the overlay on the display where you are writing. |
| Overlay motion | <code>HUD_REVEAL</code> | <code>drift</code> | <code>drift</code>, <code>slide</code>, <code>bloom</code>, <code>unfurl</code>, <code>morph</code> | Preview the entrance and exit before choosing. |
| Ambient particles | <code>HUD_PARTICLES</code> | <code>false</code> | true, false | Optional particles while listening. Disabled with Reduce Motion. |

### Vocabulary

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Additional terms | <code>CUSTOM_VOCABULARY</code> | (empty) | Text | Comma-separated words or wrong => right replacements. |
| Vocabulary file | <code>CUSTOM_VOCABULARY_FILE</code> | <code>vocabulary.txt</code> | Text | Edit terms and replacements in the Vocabulary window. |
| Your work and terminology | <code>ANALYZE_CONTEXT</code> | (empty) | Text | Optional context to help vocabulary suggestions understand your domain. |
| Learn from typed corrections | <code>LEARN_CORRECTIONS</code> | <code>false</code> | true, false | Observe word corrections after a paste. Only word pairs are stored, never the surrounding field. |
| Correction observation delay | <code>LEARN_DELAY_MS</code> | <code>8000</code> | 2000 to 60000 | Milliseconds after a paste before checking for a correction. |

### Privacy

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Hide dictated words on screen | <code>PRIVACY_MODE</code> | <code>false</code> | true, false | Hide live words in the overlay and menu. Local history is controlled separately. |
| Save dictation history | <code>HISTORY</code> | <code>true</code> | true, false | Store dictations locally on this Mac. |
| History retention | <code>HISTORY_RETENTION_DAYS</code> | <code>0</code> | 0 to 3650 | Days to retain history. Zero keeps it indefinitely. |
| Track dictation stats | <code>STATS</code> | <code>true</code> | true, false | Count words, dictations, speaking time, and time saved in a local stats database. No transcripts are stored there. |
| Track word usage | <code>STATS_WORDS</code> | <code>true</code> | true, false | Count how often each word is dictated for the most and least used lists. Stored as per-day counts, never as sentences. |
| Share anonymous usage metrics | <code>SHARE_USAGE_METRICS</code> | <code>false</code> | true, false | Off by default. Records counts, categories, and timing buckets only. Never transcripts, audio, vocabulary, or your API key. See PRIVACY.md. |

### Advanced

| Setting | Key | Default | Values | Description |
| --- | --- | --- | --- | --- |
| Live model | <code>GEMINI_LIVE_MODEL</code> | <code>gemini-3.5-transcribe-live</code> | Text | Used for streaming transcription. |
| Fallback model | <code>GEMINI_MODEL</code> | <code>gemini-3.5-flash-lite</code> | Text | Used when the live connection cannot finish a dictation. |
| Vocabulary analysis model | <code>ANALYZE_MODEL</code> | <code>gemini-3.7-flash</code> | Text | Used only when you request suggestions from history. |
| Cleanup model | <code>POST_PROCESS_MODEL</code> | <code>gemini-3.5-flash-lite</code> | Text | Default: Gemini 3.5 Flash-Lite. Update cleanup token prices if you choose another model. |
| Maximum cleanup wait | <code>POST_PROCESS_TIMEOUT_MS</code> | <code>2500</code> | 500 to 10000 | Milliseconds before using the original transcript. Failed cleanup never blocks delivery indefinitely. |
| Stream while speaking | <code>ENABLE_LIVE_WEBSOCKET</code> | <code>true</code> | true, false | Use the live connection for lower settlement latency. |
| Fallback delay | <code>REST_FALLBACK_TIMEOUT</code> | <code>4.0</code> | 0.1 to 30.0 | Seconds to wait before also trying the fallback route. |
| Streaming frame size | <code>CHUNK_MS</code> | <code>150</code> | 20 to 500 | Milliseconds of audio sent in each streaming frame. |
| Trailing silence | <code>SILENCE_FLUSH_MS</code> | <code>700</code> | 0 to 2000 | Milliseconds of synthetic silence sent to help finalize the final word. |
| Use aligned end signals | <code>WS_ENDPOINT_ALIGNED</code> | <code>true</code> | true, false | Send only the documented end-of-turn signal. Turn off to compare latency and last-word accuracy with the earlier triple signal. |
| Pre-roll | <code>PRE_ROLL_MS</code> | <code>400</code> | 0 to 1000 | Milliseconds retained before pressing the shortcut when warm capture is enabled. |
| Trailing quiet window | <code>POST_ROLL_MS</code> | <code>250</code> | 0 to 500 | Milliseconds of quiet needed before finishing capture. |
| Maximum trailing capture | <code>POST_ROLL_MAX_MS</code> | <code>1500</code> | 0 to 5000 | Milliseconds to wait for speech after release, at most. |
| Quiet threshold | <code>TRAIL_SILENCE_DB</code> | <code>-40.0</code> | -80.0 to -10.0 | Audio below this level in dBFS counts as quiet. |
| Speech boundary detection | <code>VAD_MODE</code> | <code>manual</code> | <code>manual</code>, <code>tuned</code>, <code>auto</code> | Manual uses the shortcut. Tuned and automatic use server speech detection. |
| Server quiet window | <code>VAD_SILENCE_MS</code> | <code>1500</code> | 200 to 5000 | Milliseconds of silence before the tuned server mode finishes speech. |
| Live input price | <code>LIVE_INPUT_PRICE_PER_1M</code> | <code>3.50</code> | 0.0 to 1000.0 | US dollars per million tokens, used for cost estimates. |
| Live output price | <code>LIVE_OUTPUT_PRICE_PER_1M</code> | <code>21.00</code> | 0.0 to 1000.0 | US dollars per million tokens, used for cost estimates. |
| Rest input price | <code>REST_INPUT_PRICE_PER_1M</code> | <code>0.30</code> | 0.0 to 1000.0 | US dollars per million tokens, used for cost estimates. |
| Rest output price | <code>REST_OUTPUT_PRICE_PER_1M</code> | <code>2.50</code> | 0.0 to 1000.0 | US dollars per million tokens, used for cost estimates. |
| Cleanup input price | <code>POST_PROCESS_INPUT_PRICE_PER_1M</code> | <code>0.30</code> | 0.0 to 1000.0 | USD per million input tokens, for cost estimates. Default matches Gemini 3.5 Flash-Lite standard pricing. |
| Cleanup output price | <code>POST_PROCESS_OUTPUT_PRICE_PER_1M</code> | <code>2.50</code> | 0.0 to 1000.0 | USD per million output tokens, including reported thinking tokens. Costs remain unknown when usage is not reported. |
| History database path | <code>HISTORY_DB</code> | (empty) | Text | Empty uses Tok’s Application Support folder. |
| Diagnostic detail | <code>LOG_LEVEL</code> | <code>normal</code> | <code>normal</code>, <code>verbose</code> | Normal records essential events. Verbose includes additional engineering detail. |

<!-- END GENERATED SETTINGS -->
