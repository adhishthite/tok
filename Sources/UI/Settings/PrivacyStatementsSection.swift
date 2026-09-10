import AppKit
import SwiftUI

/// Plain statements about where data goes, each with a way to check the claim.
struct PrivacyStatementsSection: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Section {
      statement(
        "Audio goes to the Gemini API only while you dictate, and only to transcribe it. Tok keeps no audio."
      )
      statement(
        "Your API key stays in the macOS Keychain and travels only in the request header to Google.",
        action: "Open Keychain Access", openKeychainAccess)
      statement(
        "Usage metrics are off unless you turn them on below. They never include transcripts, audio, vocabulary, or your key.",
        action: "View queued events", { openWindow(id: "diagnostics") })
      statement(
        "Update checks fetch a signed appcast and send no profile information.",
        action: "Open appcast", openAppcast)
    } header: {
      Text("Leaves this Mac")
    }
    Section {
      statement(
        "Dictations are stored in a local database on this Mac. Retention is set below.",
        action: "Show history file", { reveal(historyURL) })
      statement(
        "Vocabulary and learned corrections stay in local files.",
        action: "Show vocabulary file", { reveal(store.settings.resolvedVocabularyURL) })
      statement(
        "The overlay and menu can hide dictated words during screen sharing.")
    } header: {
      Text("Stays on this Mac")
    } footer: {
      Button("Read the full privacy document") { PrivacyDocument.open() }
        .controlSize(.small).padding(.top, 4)
    }
  }
  private func statement(
    _ text: String, action: String? = nil, _ perform: @escaping () -> Void = {}
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(text).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if let action {
        Button(action, action: perform).controlSize(.small).fixedSize()
      }
    }.padding(.vertical, 2)
  }
  private var historyURL: URL {
    let raw = store.settings.configuration.historyDbPath
    let path = raw.isEmpty ? "~/Library/Application Support/Tok/history.db" : raw
    return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
  }
  private func reveal(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
    }
  }
  private func openKeychainAccess() {
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.keychainaccess")
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: .init())
  }
  private func openAppcast() {
    guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: feed)
    else { return }
    NSWorkspace.shared.open(url)
  }
}
