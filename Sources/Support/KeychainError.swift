import Foundation
import Security

struct KeychainError: LocalizedError {
  let status: OSStatus
  var errorDescription: String? { "Keychain could not access the API key (status \(status))." }
}
