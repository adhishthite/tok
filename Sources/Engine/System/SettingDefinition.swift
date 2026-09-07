public struct SettingDefinition: Identifiable, Sendable {
  public let key: String
  public let title: String
  public let help: String
  public let group: SettingGroup
  /// Header of the Settings section this row belongs to, within its group.
  public let section: String
  public let kind: SettingKind
  /// Placeholder for text kinds while the value is empty.
  public let prompt: String?
  public let unit: SettingUnit?
  public let enabledWhen: SettingCondition?
  public let defaultValue: String
  let apply: @Sendable (inout EngineConfiguration, String) -> Void
  public var id: String { key }

  init(
    key: String, title: String, help: String, group: SettingGroup, section: String,
    kind: SettingKind, prompt: String? = nil, unit: SettingUnit? = nil,
    enabledWhen: SettingCondition? = nil, defaultValue: String,
    apply: @escaping @Sendable (inout EngineConfiguration, String) -> Void
  ) {
    self.key = key
    self.title = title
    self.help = help
    self.group = group
    self.section = section
    self.kind = kind
    self.prompt = prompt
    self.unit = unit
    self.enabledWhen = enabledWhen
    self.defaultValue = defaultValue
    self.apply = apply
  }
}
