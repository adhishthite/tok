import Foundation

/// Command-line options. Defaults run three arms, 60 turns each, in interleaved blocks.
struct HarnessOptions {
  var arms = ["baseline", "warm90", "aligned"]
  var turnsPerArm = 60
  var blockSize = 6
  var seed: UInt64 = 38
  var maxMinutes = 360.0
  /// Multiplies every sampled idle gap (never below 1 s). Below 1 it shifts warm90 turns
  /// out of the cold regime, so use it only for arms that keep the microphone warm-off,
  /// where every turn is cold whatever the gap.
  var gapScale = 1.0
  /// Skips the quiet-room gate. Results then include noise-driven tail caps.
  var allowNoisy = false
  /// Stream clips straight into the Live client, many at once, instead of playing them.
  var direct = false
  var workers = 6
  /// How many times direct mode sends each clip on each arm.
  var repeats = 1
  private var armsGiven = false
  var root = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["TOK_PROJECT_ROOT"]
      ?? FileManager.default.currentDirectoryPath)

  static let usage = """
    Usage: TokHarness [--arms a,b,c] [--turns-per-arm N] [--block N] [--seed N]
                      [--max-minutes M] [--gap-scale X] [--allow-noisy] [--smoke]
           TokHarness --direct [--arms a,b] [--workers N] [--repeats N] [--seed N]
    Arms: \(HarnessArm.catalog.map(\.name).joined(separator: ", "))
    --smoke   two turns per arm with short gaps, to check the setup end to end.
    --direct  every clip on every arm, streamed to the Live client in parallel. Measures
              the end signal, round trip, and accuracy; not capture start or the tail.
              Default arms: baseline, aligned.
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
        options.armsGiven = true
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
      case "--direct":
        options.direct = true
      case "--workers":
        options.workers = try Self.positive(value(argument), argument)
      case "--repeats":
        options.repeats = try Self.positive(value(argument), argument)
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
    // Warm-microphone arms mean nothing without a microphone.
    if options.direct, !options.armsGiven { options.arms = ["baseline", "aligned"] }
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
