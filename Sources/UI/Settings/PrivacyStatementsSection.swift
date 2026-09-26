// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Plain statements about where data goes, each with a way to check the claim.
struct PrivacyStatementsSection: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Section {
      PrivacyStatementRow(
        emoji: "🎙️", title: "Audio, only while you dictate",
        detail: "Sent to the Gemini API only to transcribe it. Tok keeps no audio.")
      PrivacyStatementRow(
        emoji: "📖", title: "Vocabulary for recognition",
        detail: "Vocabulary terms are sent to Gemini to help recognize them.")
      PrivacyStatementRow(
        emoji: "💡", title: "Vocabulary suggestions, when requested",
        detail:
          "Sends recent history, vocabulary, corrections, and any context you provide to Gemini.")
      PrivacyStatementRow(
        emoji: "✨", title: "Optional dictation cleanup",
        detail:
          "When enabled, sends the transcript to Gemini. App-aware formatting also sends the app name and identifier."
      )
      PrivacyStatementRow(
        emoji: "🔑", title: "Your API key, in the request header",
        detail: "Stored in the macOS Keychain. Sent only to Google.",
        action: "Open Keychain Access", perform: openKeychainAccess)
      PrivacyStatementRow(
        emoji: "📊", title: "Usage metrics, only if you turn them on",
        detail: "Off by default. Never transcripts, audio, vocabulary, or your key.",
        action: "View queued events", perform: { openWindow(id: "diagnostics") })
      PrivacyStatementRow(
        emoji: "🔄", title: "Update checks",
        detail: "Fetch a signed appcast. No profile information is sent.",
        action: "Open appcast", perform: openAppcast)
    } header: {
      Text("Leaves this Mac")
    }
    Section {
      PrivacyStatementRow(
        emoji: "🗂️", title: "Dictation history",
        detail: "A local database on this Mac. Retention is set below.",
        action: "Show history file", perform: { reveal(historyURL) })
      PrivacyStatementRow(
        emoji: "📈", title: "Dictation stats",
        detail:
          "Counts, timing, app names, and per-day word usage in a local database. Never full transcripts.",
        action: "Show stats file",
        perform: { reveal(store.stats.fileURL ?? store.settings.supportDirectory) })
      PrivacyStatementRow(
        emoji: "📖", title: "Vocabulary and learned corrections",
        detail:
          "Stored as local files. Vocabulary is sent for recognition; corrections are also sent when you request suggestions.",
        action: "Show vocabulary file",
        perform: { reveal(store.settings.resolvedVocabularyURL) })
      PrivacyStatementRow(
        emoji: "🙈", title: "Dictated words during screen sharing",
        detail: "The overlay and menu can hide them while you share your screen.")
    } header: {
      Text("Stays on this Mac")
    } footer: {
      Button("Read the full privacy document") { PrivacyDocument.open() }
        .controlSize(.small).padding(.top, 4)
    }
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
