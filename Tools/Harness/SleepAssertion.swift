import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping for the length of a run. The display may still sleep;
/// capture and playback do not need it. A closed lid still disables the built-in mic.
final class SleepAssertion {
  private var id = IOPMAssertionID(0)
  private var held = false

  init(reason: String) {
    held =
      IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
  }

  func release() {
    guard held else { return }
    IOPMAssertionRelease(id)
    held = false
  }

  deinit { release() }
}
