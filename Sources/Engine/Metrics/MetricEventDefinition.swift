/// One documented usage metric event and the fields it may carry.
public struct MetricEventDefinition: Sendable {
  public let name: String
  public let description: String
  public let fields: [MetricFieldDefinition]
  public init(_ name: String, _ description: String, fields: [MetricFieldDefinition]) {
    self.name = name
    self.description = description
    self.fields = fields
  }
  public var fieldNames: Set<String> { Set(fields.map(\.name)) }
}
