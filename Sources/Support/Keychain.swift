import Foundation
import Security

enum Keychain {
  enum Account: String {
    case gemini = "gemini-api-key"
    case typesafe = "typesafe-api-key"
  }
  private static let service = "com.adhishthite.tok"
  static func readAPIKey(_ account: Account = .gemini) throws -> String? {
    var query = baseQuery(account)
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
  static func saveAPIKey(_ value: String, account: Account = .gemini) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery(account)
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }
  private static func baseQuery(_ account: Account) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account.rawValue,
    ]
  }
}
