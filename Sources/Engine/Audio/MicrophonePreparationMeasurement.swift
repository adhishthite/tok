public struct MicrophonePreparationMeasurement: Sendable {
  public let milliseconds: Double
  public let engineRunning: Bool
  public let audioUnitStatus: Int32
  public let audioUnitRunning: UInt32
}
