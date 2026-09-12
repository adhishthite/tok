/// Prompts that name the dictation shortcut. Toggle mode has no release, so the
/// push-to-talk wording was wrong there, and the raw key id leaked into two of the
/// messages (audit F05).
enum ShortcutPrompt {
  static func ready(shortcut: String, toggleMode: Bool) -> String {
    toggleMode ? "Press \(shortcut) to dictate." : "Hold \(shortcut) to dictate."
  }

  static func listening(shortcut: String, toggleMode: Bool) -> String {
    toggleMode ? "Speak, then press \(shortcut) to paste." : "Speak, then release to paste."
  }

  static func wake(shortcut: String, toggleMode: Bool) -> String {
    toggleMode
      ? "Press \(shortcut) to wake the microphone." : "Hold \(shortcut) to wake the microphone."
  }

  /// The menu line, which invites a first dictation rather than describing one in progress.
  static func menu(shortcut: String, toggleMode: Bool) -> String {
    toggleMode ? "Press \(shortcut) and speak." : "Hold \(shortcut) and speak."
  }
}
