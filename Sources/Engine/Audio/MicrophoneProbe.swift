import Foundation

public enum MicrophoneProbe {
  @MainActor public static func measure() async throws -> [Double] {
    let audio = AudioCaptureEngine(preRollMs: 0)
    guard audio.setup(startImmediately: false) else {
      throw NSError(domain: "Tok.MicrophoneProbe", code: 1)
    }
    defer { audio.stopEngine() }
    var measurements: [Double] = []
    for _ in 0..<3 {
      try Task.checkCancellation()
      let start = ProcessInfo.processInfo.systemUptime
      let ready = await withCheckedContinuation { continuation in
        audio.ensureReady { continuation.resume(returning: $0) }
      }
      guard ready else { throw NSError(domain: "Tok.MicrophoneProbe", code: 2) }
      measurements.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      audio.suspendEngine()
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    return measurements
  }
}
