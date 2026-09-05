import Foundation

public struct MicrophoneStartupMeasurement: Sendable {
  public let readinessMilliseconds: Double
  public let synchronousSetupMilliseconds: Double
}
