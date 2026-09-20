import Foundation

/// Transport and gate-level failures from the TypeSafe judgment subsystem. Never surfaced to
/// the user; only logged (without the key or request body) and used to keep the feature
/// silently off.
enum TypeSafeError: Error {
  /// No key configured, or the probe for the current key has not succeeded (yet, or ever).
  case unavailable
  case unauthorized
  case validation
  case rateLimited
  case overloaded
  case http(Int)
  case network(Error)
  case decoding(Error)

  init(status: Int) {
    switch status {
    case 401: self = .unauthorized
    case 422: self = .validation
    case 429: self = .rateLimited
    case 529: self = .overloaded
    default: self = .http(status)
    }
  }

  /// One short line naming the failure, safe to log.
  var diagnosticDescription: String {
    switch self {
    case .unavailable: return "not configured"
    case .unauthorized: return "HTTP 401 (key rejected)"
    case .validation: return "HTTP 422 (validation)"
    case .rateLimited: return "HTTP 429 (rate limited)"
    case .overloaded: return "HTTP 529 (overloaded)"
    case .http(let status): return "HTTP \(status)"
    case .network: return "network error"
    case .decoding: return "invalid response"
    }
  }
}
