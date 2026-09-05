import Foundation
import SQLite3

extension VocabularyAnalyzer {
  struct Row: Sendable {
    let ts: Double
    let app: String
    let text: String
  }
}
