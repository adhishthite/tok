// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

struct KeychainError: LocalizedError {
  let status: OSStatus
  var errorDescription: String? { "Keychain could not access the API key (status \(status))." }
}
