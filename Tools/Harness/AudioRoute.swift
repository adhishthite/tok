// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// The default output device, read before every turn. Clips reach the microphone through
/// the speakers, so headphones or a muted output would record nothing but room tone.
struct AudioRoute {
  let name: String
  let builtIn: Bool
  let muted: Bool
  let volume: Float?

  var problem: String? {
    if !builtIn { return "output is \(name), not the built-in speakers" }
    if muted { return "built-in speakers are muted" }
    // At 25% the clips reached the microphone about 15 dB down and every turn came back
    // empty (2026-09-26), so the floor sits well above that.
    if let volume, volume < 0.4 { return "output volume is \(Int(volume * 100))%, below 40%" }
    return nil
  }

  static func current() -> AudioRoute? {
    var device = AudioDeviceID(0)
    guard
      read(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, &device)
    else { return nil }
    var transport: UInt32 = 0
    _ = read(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
    var mute: UInt32 = 0
    let hasMute = read(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, &mute)
    var volume: Float32 = 0
    var hasVolume = read(
      device, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, &volume)
    if !hasVolume {
      hasVolume = read(
        device, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, &volume,
        element: 1)
    }
    return AudioRoute(
      name: name(of: device) ?? "unknown device",
      builtIn: transport == kAudioDeviceTransportTypeBuiltIn,
      muted: hasMute && mute != 0,
      volume: hasVolume ? volume : nil)
  }

  private static func name(of device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
      let value = name?.takeRetainedValue()
    else { return nil }
    return value as String
  }

  private static func read<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope, _ value: inout T,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(object, &address) else { return false }
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
  }
}
