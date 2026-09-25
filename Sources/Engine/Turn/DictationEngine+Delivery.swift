import Foundation

extension DictationEngine {
  /// Where a settled transcript goes. The app always uses `paste`. `sink` exists for the
  /// latency harness (Tools/Harness): it runs the real capture and transcription path, but
  /// the text goes to a closure instead of the clipboard and a synthesized Cmd-V, and
  /// frontmost-app checks are skipped, because no destination window is involved.
  public enum Delivery {
    case paste
    /// Called on sessionQueue with the final text (after post-processing and replacements).
    case sink((String) -> Void)
  }
}
