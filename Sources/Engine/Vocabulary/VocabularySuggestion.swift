public struct VocabularySuggestion: Identifiable, Sendable {
  public let line: String
  public let reason: String
  // Item 2 (optional upgrade; see Engine/Judgment): 0...1, the Jev noul for a vocabulary term
  // or the risk score normalized by its top level for a replacement rule. nil without a
  // TypeSafe key, or when Jev did not judge this particular suggestion.
  public let confidence: Double?
  public var id: String { line.lowercased() }

  public init(line: String, reason: String, confidence: Double? = nil) {
    self.line = line
    self.reason = reason
    self.confidence = confidence
  }
}
