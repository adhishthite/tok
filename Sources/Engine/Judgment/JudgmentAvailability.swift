import Foundation

/// Store-facing snapshot of the TypeSafe judgments gate (`JudgmentService`). Distinct from
/// `JudgmentService.isAvailable` (a plain Bool for engine-internal gating): this carries enough
/// state for the Experimental settings pane to show why judgments are off, not just whether.
public enum JudgmentAvailability: Equatable, Sendable {
  /// No key configured; nothing is probed.
  case off
  /// A probe is in flight for the current key.
  case checking
  /// The probe succeeded; judgments run.
  case available
  /// The probe failed. `reason` is the short, safe diagnostic text already used for the log
  /// line (an HTTP status or transport error class) - never the key or response body.
  case unavailable(reason: String)
}
