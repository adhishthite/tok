public struct SettingDefinition: Identifiable, Sendable {
  public let key: String
  public let title: String
  public let help: String
  public let group: SettingGroup
  public let kind: SettingKind
  public let defaultValue: String
  let apply: @Sendable (inout EngineConfiguration, String) -> Void
  public var id: String { key }
}
