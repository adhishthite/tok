/// Words dictated into one application.
public struct StatsAppShare: Sendable, Equatable, Identifiable {
  public var name: String
  public var words: Int
  public var dictations: Int
  public var id: String { name }
  public init(name: String, words: Int, dictations: Int) {
    self.name = name
    self.words = words
    self.dictations = dictations
  }
}
