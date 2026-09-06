import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3,
  let signatureText = ProcessInfo.processInfo.environment["TOK_TEST_SIGNATURE"],
  let signature = Data(base64Encoded: signatureText),
  let plist = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil)
    as? [String: Any],
  let publicText = plist["SUPublicEDKey"] as? String,
  let publicData = Data(base64Encoded: publicText)
else {
  fputs("Signature verification inputs are unavailable.\n", stderr)
  exit(1)
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard key.isValidSignature(signature, for: payload) else {
  fputs("The signing key does not match Tok's embedded public key.\n", stderr)
  exit(1)
}
print("Signing key matches the embedded public key.")
