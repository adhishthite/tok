import Foundation
import Sparkle

/// Bridges Sparkle's updater callbacks to dictation activity (audit F35). Sparkle
/// declares SPUUpdaterDelegate with NS_SWIFT_UI_ACTOR, so Swift imports it as a
/// @MainActor protocol; these methods are already main-actor isolated and can call
/// the main-actor closures below directly with no extra hop.
@MainActor
final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
  /// Set by UpdateStore; true while a dictation turn is in flight.
  var isDictationActive: () -> Bool = { false }
  /// The relaunch block Sparkle handed us in shouldPostponeRelaunchForUpdate,
  /// invoked and cleared once the active turn ends.
  private var postponedRelaunch: (() -> Void)?

  /// Refuses a scheduled or user-initiated check while a turn is active, so Sparkle
  /// cannot show update UI over it. Sparkle silently retries on its own schedule.
  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard isDictationActive() else { return }
    throw NSError(
      domain: "com.adhishthite.tok.update", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Deferred: a dictation is in progress."])
  }

  /// Holds a relaunch-for-install until the active turn settles. Relaunching
  /// mid-dictation would downgrade the turn to "Focus changed".
  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvoking installHandler: @escaping () -> Void
  ) -> Bool {
    guard isDictationActive() else { return false }
    postponedRelaunch = installHandler
    return true
  }

  /// Called by UpdateStore when DictationStore reports a turn ended. Runs any
  /// relaunch Sparkle postponed for the duration of that turn.
  func dictationEnded() {
    guard let handler = postponedRelaunch else { return }
    postponedRelaunch = nil
    handler()
  }
}
