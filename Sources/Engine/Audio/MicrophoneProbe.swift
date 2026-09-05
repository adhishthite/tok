import Foundation

public enum MicrophoneProbe {
  @MainActor public static func measure() async throws -> [MicrophoneStartupMeasurement] {
    let audio = AudioCaptureEngine(preRollMs: 0)
    guard audio.setup(startImmediately: false) else {
      throw NSError(domain: "Tok.MicrophoneProbe", code: 1)
    }
    defer { audio.stopEngine() }
    var measurements: [MicrophoneStartupMeasurement] = []
    for _ in 0..<3 {
      try Task.checkCancellation()
      let start = ProcessInfo.processInfo.systemUptime
      var synchronousMilliseconds = 0.0
      let ready = await withCheckedContinuation { continuation in
        audio.ensureReady { continuation.resume(returning: $0) }
        synchronousMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
      }
      guard ready else { throw NSError(domain: "Tok.MicrophoneProbe", code: 2) }
      measurements.append(
        MicrophoneStartupMeasurement(
          readinessMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
          synchronousSetupMilliseconds: synchronousMilliseconds))
      audio.suspendEngine()
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    return measurements
  }
}
