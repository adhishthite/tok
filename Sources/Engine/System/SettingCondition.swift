/// A dependency on another setting's effective value. A row whose condition
/// does not hold is shown disabled, with its master setting listed first.
public struct SettingCondition: Sendable {
  public let key: String
  public let holds: @Sendable (String) -> Bool

  public static func isOn(_ key: String) -> SettingCondition {
    SettingCondition(key: key) { ["true", "1"].contains($0.lowercased()) }
  }

  public static func isPositive(_ key: String) -> SettingCondition {
    SettingCondition(key: key) { (Double($0) ?? 0) > 0 }
  }

  public static func equals(_ key: String, _ value: String) -> SettingCondition {
    SettingCondition(key: key) { $0.lowercased() == value.lowercased() }
  }
}
