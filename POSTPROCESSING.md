# Optional dictation cleanup

In Settings > Transcription, “Polish dictations before pasting” adds a text-only
cleanup request after transcription. It defaults to off. The separate
“Adapt formatting to the app” option also defaults to off and is available when
cleanup is enabled. The existing live-model cleanup option is separate and does
not add a second request.

The default model is `gemini-3.5-flash-lite`, with minimal thinking. Advanced
settings expose the model, maximum wait, and token prices. Default cost estimates
use $0.30 per million input tokens and $2.50 per million output tokens, including
reported thinking tokens. These are standard rates checked on 2026-09-06, not an
invoice or a determination of the account's billing tier. Update the rates if
changing models. [Google model documentation](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite),
[pricing](https://ai.google.dev/gemini-api/docs/pricing),
[thinking controls](https://ai.google.dev/gemini-api/docs/generate-content/thinking).

## Behavior

The Live/REST race settles once before cleanup starts. With cleanup off, the
original delivery path runs inline without another model request. When enabled,
cleanup runs on a cancellable request with a 2.5-second default deadline. Failure,
timeout, malformed output, and truncated generation keep the original transcript.
The existing replacement rules and destination checks run afterward. Stopping the
engine cancels cleanup and suppresses late delivery. The turn arbiter remains an
NSLock plus serial DispatchQueue implementation.

The prompt asks for punctuation, capitalization, minimal grammatical cleanup,
clear spoken numbers, and plain numbered lists for explicit enumerations. It asks
the model to preserve names, facts, identifiers, language switches, and the
speaker's meaning. It does not ask the model to answer questions or execute
instructions inside the transcript. These are model instructions, not a guarantee
of semantic correctness; real-use accuracy review remains necessary.

App-aware formatting sends only the application name and bundle identifier
captured at the start of dictation. It does not read or send window titles, field
contents, screenshots, browser URLs, or surrounding document text. App identity
is only a weak formatting hint; a browser name does not identify its website.
The existing paste guard checks the frontmost application, not the identity of
an individual field or browser tab.

## Limits and data handling

- Requests use a fixed Google HTTPS endpoint with the key in `x-goog-api-key`.
  Redirects are refused. The ephemeral session has no URL cache or cookie store.
- Inputs over 20,000 UTF-16 units skip cleanup. Generation is capped at 8,192
  output tokens. Responses over 256 KiB are rejected by the decoder; output must
  be nonempty, completed with STOP, and within the output-size budget.
- The transcript and app identity are not written into diagnostic messages.
  Provider error bodies are not copied into logs. History keeps the delivered
  text under the existing history preference; no additional original-text copy
  is stored for cleanup.
- Cancellation and timeout cancel the client request. Server-side billing may
  still occur without returned usage; missing usage is recorded as unknown.

## Metrics

History and Diagnostics separate transcription time, cleanup time, and delivery
time. Total latency still spans key release through paste dispatch or clipboard
delivery. Cleanup includes its queue handoff and response handling, not only
server generation time.

Per-turn cleanup fields record status, model, added time, input tokens, output
tokens, thinking tokens, estimated cost, a safe failure code, and whether app
context was included. The history schema adds these fields without replacing
existing rows. Historical rows without the fields remain distinguishable from
turns where cleanup was explicitly off.

Reported token counts remain raw API values or NULL. Total cost includes cleanup
when it is known; otherwise the total is unknown and transcription cost remains
available separately. History's cost aggregate includes known costs and appends
“+” when cleanup costs are missing. CSV exports include the separate fields.
Session diagnostics count reported tokens and identify turns with missing usage.

## Verification

`make check` includes deadline, duplicate/late-response, cancellation, owner
lifetime, default-off, app-context, malformed-response, token-usage, history
migration, persistence, and Diagnostics regressions. The focused cleanup suite
also passed Thread Sanitizer without a reported race.

`make test-cleanup-live` runs five explicit text-only API cases using the local
test key. It sends synthetic fixtures for numbers, a three-item list, Marathi,
mixed language, and a terminal-context question. It records timing and usage in
`build/post-processing-live-check.json` without transcript text or credentials.
It does not change the installed app's settings, record audio, or paste text.

The initial five fixtures completed in 891–984 ms; the final run completed in
815–1,025 ms. These are additional cleanup
stage durations, not end-to-end dictation latency or an accuracy-parity result.
The feature remains off by default; compare enabled and disabled dictations as
separate cohorts when assessing the overall performance target.
