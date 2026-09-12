import AppKit

// The HUD is a borderless, non-activating panel that never takes focus, so VoiceOver
// reads nothing from it. State changes are posted as announcements instead. They do not
// depend on the panel being on screen, which is what makes privacy mode usable.
enum HUDAnnouncer {
  static func announce(_ message: String) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
    // High priority: these are short, rare, and describe an action the user just took,
    // so they are worth interrupting the current utterance.
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: trimmed,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
}
