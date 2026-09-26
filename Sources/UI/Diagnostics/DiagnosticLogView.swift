// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct DiagnosticLogView: View {
  let entries: [DiagnosticEntry]
  let clear: () -> Void
  var saveReport: () -> Void = {}
  @State private var search = ""
  @State private var issuesOnly = false
  @State private var selection: Set<UUID> = []
  private var filtered: [DiagnosticEntry] {
    entries.reversed().filter { $0.matches(search, issuesOnly: issuesOnly) }
  }
  private var selected: [DiagnosticEntry] { entries.filter { selection.contains($0.id) } }

  var body: some View {
    VStack(spacing: 0) {
      Table(filtered, selection: $selection) {
        TableColumn("Time") { row in
          Text(row.receivedAt, format: .dateTime.hour().minute().second()).monospacedDigit()
        }.width(90)
        TableColumn("Level") { row in
          Label(row.level.rawValue, systemImage: row.level.symbol)
            .labelStyle(.iconOnly)
            .foregroundStyle(
              row.level == .error ? Color.red : row.level == .warning ? .orange : .secondary
            )
            .help(row.level.rawValue)
        }.width(45)
        TableColumn("Category", value: \.category).width(min: 70, ideal: 90, max: 140)
        TableColumn("Message") { row in
          Text(row.message).font(.system(.caption, design: .monospaced)).lineLimit(1)
        }
      }
      .overlay {
        if filtered.isEmpty {
          ContentUnavailableView(
            entries.isEmpty ? "No events yet" : "No matching events",
            systemImage: "list.bullet.rectangle",
            description: Text(
              entries.isEmpty
                ? "Events from this session appear here." : "Try another search or show all events."
            ))
        }
      }
      .onCopyCommand { selected.map { NSItemProvider(object: $0.line as NSString) } }
      if selected.count == 1, let entry = selected.first {
        Divider()
        ScrollView {
          Text(entry.message).font(.system(.callout, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(height: 100)
      }
    }
    .searchable(text: $search, prompt: "Search events")
    .toolbar {
      ToolbarItem {
        Picker("Show", selection: $issuesOnly) {
          Text("All events").tag(false)
          Text("Warnings and errors").tag(true)
        }.pickerStyle(.menu)
      }
      ToolbarItem {
        Button("Save diagnostics report…", systemImage: "square.and.arrow.down") { saveReport() }
          .help("Saves timing, warnings, and non-secret settings to a file. Never your API key.")
      }
      ToolbarItem {
        Button("Clear log", systemImage: "trash") {
          clear()
          selection.removeAll()
        }
        .disabled(entries.isEmpty).help("Clear this session’s log. Saved dictations are kept.")
      }
    }
  }
}
