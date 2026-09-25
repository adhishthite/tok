import Foundation

/// Command-line options. Defaults run three arms, 60 turns each, in interleaved blocks.
struct HarnessOptions {
  var arms = ["baseline", "warm90", "aligned"]
  var turnsPerArm = 60
  var blockSize = 6
  var seed: UInt64 = 38
  var maxMinutes = 360.0
  /// Multiplies every sampled idle gap. Below 1 only for smoke runs: it shifts turns out
  /// of the cold regime, so warm-versus-cold results no longer match real use.
  var gapScale = 1.0
  /// Skips the quiet-room gate. Results then include noise-driven tail caps.
  var allowNoisy = false
  var root = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["TOK_PROJECT_ROOT"]
      ?? FileManager.default.currentDirectoryPath)

  static let usage = """
    Usage: TokHarness [--arms a,b,c] [--turns-per-arm N] [--block N] [--seed N]
                      [--max-minutes M] [--gap-scale X] [--allow-noisy] [--smoke]
    Arms: \(HarnessArm.catalog.map(\.name).joined(separator: ", "))
    --smoke  two turns per arm with short gaps, to check the setup end to end.
    """

  static func parse(_ arguments: [String]) throws -> HarnessOptions {
    var options = HarnessOptions()
    var iterator = arguments.makeIterator()
    func value(_ flag: String) throws -> String {
      guard let next = iterator.next() else { throw HarnessError.usage("\(flag) needs a value") }
      return next
    }
    while let argument = iterator.next() {
      switch argument {
      case "--arms":
        options.arms = try value(argument).split(separator: ",").map(String.init)
      case "--turns-per-arm":
        options.turnsPerArm = try Self.positive(value(argument), argument)
      case "--block":
        options.blockSize = try Self.positive(value(argument), argument)
      case "--seed":
        guard let seed = UInt64(try value(argument)) else {
          throw HarnessError.usage("--seed needs an integer")
        }
        options.seed = seed
      case "--max-minutes":
        guard let minutes = Double(try value(argument)), minutes > 0 else {
          throw HarnessError.usage("--max-minutes needs a positive number")
        }
        options.maxMinutes = minutes
      case "--gap-scale":
        guard let scale = Double(try value(argument)), scale > 0 else {
          throw HarnessError.usage("--gap-scale needs a positive number")
        }
        options.gapScale = scale
      case "--allow-noisy":
        options.allowNoisy = true
      case "--smoke":
        options.turnsPerArm = 2
        options.blockSize = 2
        options.gapScale = 0.05
      case "-h", "--help":
        throw HarnessError.usage(nil)
      default:
        throw HarnessError.usage("unknown argument \(argument)")
      }
    }
    for arm in options.arms where HarnessArm.named(arm) == nil {
      throw HarnessError.usage("unknown arm \(arm)")
    }
    return options
  }

  private static func positive(_ text: String, _ flag: String) throws -> Int {
    guard let number = Int(text), number > 0 else {
      throw HarnessError.usage("\(flag) needs a positive integer")
    }
    return number
  }
}
