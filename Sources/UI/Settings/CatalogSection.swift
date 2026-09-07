import TokEngine

/// One headed group of catalog rows within a Settings pane, in catalog order.
struct CatalogSection: Identifiable {
  let title: String
  let settings: [SettingDefinition]
  var id: String { title }

  static func sections(for group: SettingGroup, excluding: Set<String> = []) -> [CatalogSection] {
    var order: [String] = []
    var members: [String: [SettingDefinition]] = [:]
    for setting in SettingCatalog.all where setting.group == group {
      guard !excluding.contains(setting.key) else { continue }
      if members[setting.section] == nil { order.append(setting.section) }
      members[setting.section, default: []].append(setting)
    }
    return order.map { CatalogSection(title: $0, settings: members[$0] ?? []) }
  }
}
