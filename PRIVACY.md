# Privacy

Tok is a dictation app. This document says what leaves your Mac, what stays,
and what you control. The same statements appear in Settings > Privacy, and
each one there has a button to check the claim.

## What leaves your Mac

- **Audio** goes to the Gemini API only while you hold the dictation shortcut,
  and only to be transcribed. Tok keeps no audio. Google's handling of API
  traffic is governed by the Gemini API terms for your key.
- **Your API key** is stored in the macOS Keychain and travels only in the
  request header to Google. Tok never logs it, copies it into diagnostics, or
  sends it anywhere else.
- **Optional cleanup** (Settings > Transcription > Polish dictations before
  pasting) sends the transcript text to the Gemini API once more. It is off by
  default. The separate "Adapt formatting to the app" option adds the
  destination app name and bundle identifier, never window titles or contents.
- **Vocabulary suggestions** ("Analyze history" in Vocabulary) send up to 500
  saved dictations to the Gemini API only when you ask for suggestions.
- **Update checks** fetch a signed appcast from GitHub and send no profile
  information. Sparkle's profile reporting is disabled in the build.
- **Usage metrics** are off by default. See below.

## What stays on your Mac

- **Dictation history** is a SQLite database in Tok's Application Support
  folder, or the path you set. Retention is controlled in Settings > Privacy.
  Turning history off stops new rows. Deleting the file deletes the history.
- **Vocabulary and learned corrections** are local text and database files.
  Correction learning is off by default and stores only word pairs.
- **The overlay and menu** can hide dictated words during screen sharing with
  "Hide dictated words on screen".
- **Diagnostics** keep a session log in memory. Transcript text is not logged.

## Usage metrics

Metrics are **off by default**. Tok asks once during setup and never again.
The toggle lives in Settings > Privacy > Usage metrics.

When metrics are on, Tok records counts, categories, and timing buckets. It
never records transcripts, audio, vocabulary, your API key, the app you were
dictating into, your name, or your network address.

Identity is a random install ID created on this Mac. It rotates every 90 days
and you can reset it at any time. No hardware identifiers are used.

**This version sends nothing.** Events are kept in a local file capped at 500
entries so you can inspect the exact payload in Diagnostics before any sender
exists. Turning metrics off deletes the file. A version that sends events will
say so in its release notes and in Settings > Privacy.

### Events

The tables below are generated from the schema in the source code. A test
fails if an event carries a field that is not listed here.

<!-- BEGIN GENERATED METRICS SCHEMA -->

### Fields on every event

| Field | Kind | Meaning |
| --- | --- | --- |
| `event` | name | Which event this is. |
| `schema` | integer | Schema version, currently 1. |
| `install_id` | random id | Random identifier created on this Mac, rotated every 90 days, resettable in Settings. |
| `hour` | timestamp | UTC hour the event happened, no minutes. |
| `app_version` | text | Tok version, such as 0.1.3. |
| `build` | text | Tok build number. |
| `os_version` | text | macOS version, such as 15.6. |
| `arch` | category | arm64 or x86_64. |

### app_launched

Tok started.

| Field | Kind | Meaning |
| --- | --- | --- |
| `days_since_install` | bucket | 0, 1-7, 8-30, 31-90, or 90+. |
| `language_count` | integer | Number of configured languages. |
| `non_english` | boolean | Whether any configured language is not English. |
| `smart_transcription` | boolean | Live cleanup setting. |
| `post_process` | boolean | Polish before pasting setting. |
| `hotkey_mode` | category | push_to_talk or toggle. |
| `overlay` | boolean | Dictation overlay setting. |
| `sounds` | boolean | Dictation sounds setting. |
| `privacy_mode` | boolean | Hide dictated words setting. |
| `history` | boolean | Local history setting. |
| `warm_microphone` | boolean | Keep microphone ready setting. |

### setup_state

Permissions and key state at launch and when setup completes.

| Field | Kind | Meaning |
| --- | --- | --- |
| `microphone` | boolean | Microphone permission granted. |
| `accessibility` | boolean | Accessibility permission granted. |
| `input_monitoring` | boolean | Input Monitoring permission granted. |
| `api_key` | boolean | Whether a key is stored. Never the key. |
| `complete` | boolean | Whether setup is finished. |

### dictation

One dictation finished, with or without text.

| Field | Kind | Meaning |
| --- | --- | --- |
| `outcome` | category | success, empty, error, delivery_failed, or other. |
| `route` | category | live, fallback, or none. |
| `delivery` | category | dispatched, copied, failed, or none. |
| `finish` | category | release, lock_press, lock_limit, or other. |
| `latency` | bucket | Release to delivery in milliseconds: <500, 500-1000, 1000-2000, 2000-4000, or 4000+. |
| `audio` | bucket | Audio seconds: <2, 2-5, 5-15, 15-60, or 60+. |
| `smart` | boolean | Live cleanup was on. |
| `cleanup` | category | off, completed, skipped, timed_out, failed, or other. |
| `had_error` | boolean | Whether an error was recorded. |
| `input_tokens` | integer | Raw input token count from the API, or null. |
| `output_tokens` | integer | Raw output token count from the API, or null. |
<!-- END GENERATED METRICS SCHEMA -->
