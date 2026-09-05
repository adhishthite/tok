import Foundation
import SQLite3

extension VocabularyAnalyzer {
  struct ObservedCorrection: Sendable {
    let ts: Double
    let wrong: String
    let right: String
    let app: String
  }
}
