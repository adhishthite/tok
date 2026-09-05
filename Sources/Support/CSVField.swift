import Foundation

enum CSVField {
  static func encode(_ text: String) -> String {
    let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
