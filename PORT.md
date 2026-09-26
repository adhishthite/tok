# Engine port

Reference: JustSpeak commit `06f1e09137be9569f877322257b05b88c7f6da6a`.
The reference source is the spec. JustSpeak remains read-only.

The engine is a static Swift module, compiled in Swift 5 language mode during
the port. The app and store use Swift 6. The serial turn arbiter, audio queue,
lock boundaries, silence gates, WebSocket send budgets and settlement rules,
REST retry rules, clipboard snapshot behavior, and SQLite schema are retained.

Structural adaptations:

- One type per file, including nested helper types in extensions.
- `EngineConfiguration` accepts explicit values and vocabulary text. Runtime
  configuration discovery belongs to the native app, not the engine.
- `DictationEngine` replaces script startup and process exit with start/stop
  lifecycle and delegate events. UI feedback no longer owns windows.
- `MainQueueDelivery` belongs to engine support because audio recovery uses it.
- `Log` writes through the ported bounded producer queue to unified logging and
  a delegate. ANSI output is removed. Unified log message bodies are private.
- The default database path is Application Support/Tok. All 41 insert fields
  remain aligned, including delivery outcome and next-turn readiness.
- Fixture-accessed state is internal to the module for `@testable` access.
  The original tests relied on a concatenated file's private access.

The five reference regression files run as XCTest suites. The correction
comparison retains the original fixture's earlier algorithm from `c82d3a1`,
alongside concrete expected-output checks. Native algorithm tests also cover
configuration bounds, canonical vocabulary casing, WAV bytes, and REST gating.

The HUD, standalone diagnostic UI, and analyzer UI are delivered separately.
Passing offline fixtures does not establish real-world accuracy or latency.

The native lifecycle now rejects settlement after stop is requested, before its
queued cleanup executes. A controlled queue test covers that ordering. Shutdown
also invalidates the client's URLSession. These are native lifecycle adaptations
to the script's process-exit behavior. API error text redacts the key before it
can reach history or diagnostics.

The algorithm mirror and deadline fixtures from `verify_algorithms.py` now run
against the Swift code in XCTest. Analyzer porting remains grouped with its
history/vocabulary UI milestone; the HUD retains its separate milestone.
