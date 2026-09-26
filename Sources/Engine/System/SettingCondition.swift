// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

/// A dependency on another setting's effective value. A row whose condition
/// does not hold is shown disabled, with its master setting listed first.
public struct SettingCondition: Sendable {
  public let key: String
  public let holds: @Sendable (String) -> Bool
  /// Conditions on further settings that must hold as well. The lock rows need both a
  /// positive hold-to-lock value and push-to-talk mode (audit F33). An array keeps the
  /// struct non-recursive.
  public let others: [SettingCondition]

  init(
    key: String, others: [SettingCondition] = [],
    holds: @escaping @Sendable (String) -> Bool
  ) {
    self.key = key
    self.others = others
    self.holds = holds
  }

  /// Evaluates this condition and every chained condition. The caller supplies the
  /// effective value for a key, because only it knows about overrides and defaults.
  public func isSatisfied(_ value: (String) -> String) -> Bool {
    holds(value(key)) && others.allSatisfy { $0.isSatisfied(value) }
  }

  /// Returns a condition that holds only when this one and `other` both hold.
  public func and(_ other: SettingCondition) -> SettingCondition {
    SettingCondition(key: key, others: others + [other], holds: holds)
  }

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
