// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum MicrophoneProbe {
  @MainActor public static func measure(prepareInput: Bool = false) async throws
    -> (startup: [MicrophoneStartupMeasurement], preparation: MicrophonePreparationMeasurement?)
  {
    let audio = AudioCaptureEngine(preRollMs: 0)
    guard audio.setup(startImmediately: false) else {
      throw NSError(domain: "Tok.MicrophoneProbe", code: 1)
    }
    defer { audio.stopEngine() }
    let preparation: MicrophonePreparationMeasurement?
    if prepareInput {
      preparation = await withCheckedContinuation { continuation in
        audio.prepareInput { continuation.resume(returning: $0) }
      }
    } else {
      preparation = nil
    }
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
    return (measurements, preparation)
  }
}
