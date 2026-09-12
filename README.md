# Tok

**Hold a key. Speak. Release to paste.**

Tok is a native macOS menu-bar app that turns speech into text with Gemini.
It supports English, Hindi, Marathi, and other languages, with a configurable
shortcut and vocabulary for names and technical terms.

**macOS 14 or later · Apple silicon and Intel · Your own Gemini API key**

[Download Tok](https://github.com/adhishthite/tok-releases/releases/latest/download/Tok.dmg)
· [Release notes](https://github.com/adhishthite/tok-releases/releases/latest)
· [Privacy](PRIVACY.md)

## Get started

1. Open the DMG and drag Tok into Applications.
2. Launch Tok and follow setup to grant Microphone, Accessibility, and Input Monitoring.
3. Add your Gemini API key. Tok stores it in macOS Keychain.
4. Choose and test a dictation shortcut.
5. Place the cursor in a text field, hold the shortcut, speak, and release to paste.

If you use **Fn**, set **System Settings → Keyboard → Press Globe key to → Do Nothing**.
Choose your microphone in **Settings → Audio**. By default, Tok releases the
microphone between dictations.

## What you can do

- **Dictate where you write.** Use push-to-talk, toggle recording, or hold-to-lock
  for longer dictations. A small overlay shows recording and processing state.
- **Find past dictations.** Search, copy, and manage transcripts in History.
- **Add your vocabulary.** Save names, technical terms, and text replacements.
  Import a UTF-8 text file, or request suggestions from saved dictations.
- **Track your usage.** See word counts, speaking rate, estimated time saved,
  streaks, activity by app and time of day, and frequently used words in Stats.
- **Polish the result.** Enable **Settings → Transcription → Polish dictations
  before pasting** for an optional extra cleanup pass. It is off by default and
  adds processing time. If cleanup fails, Tok uses the original transcript.
- **Inspect problems.** Diagnostics shows timing, warnings, and errors without
  logging transcript text.

### Stats

Choose today, this week, this month, this year, or all time. Set your typing speed
for the time-saved estimate. Percentage changes compare equal elapsed durations
in the previous period; the comparison is omitted when that period is too short.

Stats refreshes when opened, when Tok becomes active, after wake, and at a day
change. Use **Refresh** or **Command-R** to reload local stats on demand.

Stats and word-usage tracking are on by default. They use a separate local
database, so clearing or disabling History does not clear Stats. Manage the two
tracking switches or reset Stats in **Settings → Privacy**.

## Privacy

Audio is sent to Gemini for transcription. Tok keeps no audio recordings.
Vocabulary terms are also sent to help recognition. Optional cleanup sends the
transcript again; app-aware formatting adds the destination app name and identifier.
Requested vocabulary suggestions send recent history, vocabulary, and corrections.

History and Stats are stored locally. Stats retains counts, timing, app names,
and optional per-day word frequencies, not full transcripts or word order.
Usage metrics are off by default. You can hide dictated words in the overlay
and menu for screen sharing.

See [the privacy document](PRIVACY.md) for data flows, retention, and controls.
Tok is independent software.

## Development

Requires **Xcode 26** and **XcodeGen**. Contributors and coding agents should read
[AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md) first.

```sh
make install  # Check tools and generate the Xcode project
make build    # Build the app
make run      # Launch the development build
make check    # Run tests, lint, and reference checks
```

`project.yml` is the source of truth for the generated Xcode project. Build output
stays in `build/`. Run `make format` before `make check`.

For local development, `make run` can seed settings from an ignored `.env` and
store its API key in Keychain. It preserves the current history path and retention
choice. Never commit credentials.

| Task | Guide |
| --- | --- |
| Engine architecture and invariants | [CLAUDE.md](CLAUDE.md) |
| Optional transcript cleanup | [POSTPROCESSING.md](POSTPROCESSING.md) |
| Validation results and live checks | [VALIDATION.md](VALIDATION.md) |
| Performance measurements | [PERFORMANCE.md](PERFORMANCE.md) |
| Packaging, signing, and notarization | [DISTRIBUTION.md](DISTRIBUTION.md) |
| CI and release workflows | [CI_RELEASE.md](CI_RELEASE.md) |
| Update hosting | [UPDATE_HOSTING.md](UPDATE_HOSTING.md) |
| Product acceptance and remaining checks | [ACCEPTANCE.md](ACCEPTANCE.md) |

`make package` produces a local ZIP, not a notarized release. See the distribution
guide before preparing release artifacts. Passing offline tests does not establish
real-dictation accuracy, latency, or accessibility acceptance.

## Configuration

Most options are available in Settings. Expand the complete reference for defaults,
allowed values, and environment keys. Regenerate it with `make settings-reference`;
`make check` verifies it against the compiled catalog.

<details>
<summary>All settings and defaults</summary>

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
| REST input price | <code>REST_INPUT_PRICE_PER_1M</code> | <code>0.30</code> | 0.0 to 1000.0 | US dollars per million tokens, used for cost estimates. |
| REST output price | <code>REST_OUTPUT_PRICE_PER_1M</code> | <code>2.50</code> | 0.0 to 1000.0 | US dollars per million tokens, used for cost estimates. |
| Cleanup input price | <code>POST_PROCESS_INPUT_PRICE_PER_1M</code> | <code>0.30</code> | 0.0 to 1000.0 | USD per million input tokens, for cost estimates. Default matches Gemini 3.5 Flash-Lite standard pricing. |
| Cleanup output price | <code>POST_PROCESS_OUTPUT_PRICE_PER_1M</code> | <code>2.50</code> | 0.0 to 1000.0 | USD per million output tokens, including reported thinking tokens. Costs remain unknown when usage is not reported. |
| History database path | <code>HISTORY_DB</code> | (empty) | Text | Empty uses Tok’s Application Support folder. |
| Diagnostic detail | <code>LOG_LEVEL</code> | <code>normal</code> | <code>normal</code>, <code>verbose</code> | Normal records essential events. Verbose includes additional engineering detail. |

<!-- END GENERATED SETTINGS -->

</details>
