import Foundation

enum HarnessError: Error, CustomStringConvertible {
  case usage(String?)
  case setup(String)

  var description: String {
    switch self {
    case .usage(let message):
      return [message, HarnessOptions.usage].compactMap { $0 }.joined(separator: "\n")
    case .setup(let message): return message
    }
  }
}
