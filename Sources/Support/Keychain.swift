// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

enum Keychain {
  private static let service = "com.adhishthite.tok"
  private static let account = "gemini-api-key"
  static func readAPIKey() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainError(status: status)
    }
    return String(data: data, encoding: .utf8)
  }
  static func saveAPIKey(_ value: String) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }
  /// Deletes the key that builds 15 and earlier stored for the removed TypeSafe integration,
  /// so no third-party credential outlives the feature. Best effort: a missing item or a
  /// locked keychain is left for the next launch.
  static func deleteRetiredTypeSafeKey() {
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: "typesafe-api-key",
      ] as CFDictionary)
  }
  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
