import Foundation

struct DiagnosticEntry: Identifiable {
  let id = UUID()
  let receivedAt: Date
  let level: DiagnosticLevel
  let category: String
  let message: String
  let line: String

  init(line: String, receivedAt: Date = Date()) {
    self.line = line
    self.receivedAt = receivedAt
    var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes: [(String, DiagnosticLevel)] = [
      ("[WARNING] ", .warning), ("[ERROR] ", .error), ("[DEBUG] ", .debug),
    ]
    if let (prefix, level) = prefixes.first(where: { text.hasPrefix($0.0) }) {
      self.level = level
      text.removeFirst(prefix.count)
    } else {
      level = .info
    }
    if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
      category = String(text[text.index(after: text.startIndex)..<end])
      message = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
    } else if text.hasPrefix("LATENCY ") {
      category = "LATENCY"
      message = String(text.dropFirst(8))
    } else {
      category = "APP"
      message = text
    }
  }

  func matches(_ query: String, issuesOnly: Bool) -> Bool {
    (!issuesOnly || level.isIssue) && (query.isEmpty || line.localizedStandardContains(query))
  }
}
