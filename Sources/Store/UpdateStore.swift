import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateStore {
  private(set) var configured = false
  private(set) var canCheck = false
  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var observation: NSKeyValueObservation?
  /// Answered by DictationStore. Sparkle must not check or relaunch during a turn
  /// (audit F35); the delegate hooks consult this before any update UI.
  @ObservationIgnored var isDictationActive: () -> Bool = { false }
  /// Called by DictationStore when a turn ends, so a postponed relaunch can proceed.
  func dictationEnded() {}

  func start() {
    guard controller == nil,
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: feed),
      url.host?.isEmpty == false,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32
    else { return }
    var allowed = url.scheme == "https"
    #if DEBUG
      allowed =
        allowed || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? ""))
    #endif
    guard allowed else { return }
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    self.controller = controller
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] _, change in
      let enabled = change.newValue ?? false
      Task { @MainActor [weak self] in self?.canCheck = enabled }
    }
    configured = true
    controller.startUpdater()
  }

  func check() { controller?.checkForUpdates(nil) }
}
