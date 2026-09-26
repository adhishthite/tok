// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

// Only the disposable CI runner imports an identity. The P12 password is read
// from the environment and passed directly to Security, never a command argument.
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
  ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted",
  CommandLine.arguments.count == 2,
  let encoded = ProcessInfo.processInfo.environment["TOK_CERTIFICATE_P12_BASE64"],
  let password = ProcessInfo.processInfo.environment["TOK_CERTIFICATE_PASSWORD"],
  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
else {
  fputs("Signing identity input is unavailable.\n", stderr)
  exit(1)
}
var keychain: SecKeychain?
let opened = SecKeychainOpen(CommandLine.arguments[1], &keychain)
guard opened == errSecSuccess, let keychain else {
  fputs("Could not open the temporary signing keychain.\n", stderr)
  exit(1)
}
var items: CFArray?
let status = SecPKCS12Import(
  data as CFData,
  [kSecImportExportPassphrase as String: password, kSecImportExportKeychain as String: keychain]
    as CFDictionary,
  &items)
guard status == errSecSuccess else {
  fputs("Could not import the signing identity.\n", stderr)
  exit(1)
}
print("Imported signing identity into the temporary CI keychain.")
