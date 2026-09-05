import AVFoundation
import ApplicationServices
import CoreGraphics

struct PermissionStatus: Equatable {
  let microphone: Bool
  let accessibility: Bool
  let inputMonitoring: Bool
  var allGranted: Bool { microphone && accessibility && inputMonitoring }
  static func current() -> PermissionStatus {
    PermissionStatus(
      microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
  }
}
