public struct VocabularySuggestion: Identifiable, Sendable {
  public let line: String
  public let reason: String
  public var id: String { line.lowercased() }
}
