// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// Holds Core Audio registrations for the lifetime of the visible device picker.
final class AudioDeviceChanges {
  private let listener: AudioObjectPropertyListenerBlock
  private let selectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
  ]

  init(onChange: @escaping @Sendable () -> Void) {
    listener = { _, _ in onChange() }
    for selector in selectors {
      var address = Self.address(selector)
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
  }

  deinit {
    for selector in selectors {
      var address = Self.address(selector)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
  }

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
}
