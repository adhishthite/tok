import AVFoundation
import ApplicationServices

enum PermissionChecker {
  static func verifyAll() -> (accessibility: Bool, microphone: Bool) {
    (AXIsProcessTrusted(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
  }
}
