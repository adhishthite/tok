import AppKit

final class SoundManager {
  private static let queue = DispatchQueue(label: "com.adhishthite.tok.sounds", qos: .userInitiated)
  private static let sounds: [String: NSSound] = {
    var loaded: [String: NSSound] = [:]
    for name in ["ready", "end", "complete", "lock", "error"] {
      let url =
        Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
        ?? Bundle.main.url(forResource: name, withExtension: "wav")
      if let url, let sound = NSSound(contentsOf: url, byReference: false) { loaded[name] = sound }
    }
    return loaded
  }()

  static func prepare() { queue.async { _ = sounds } }
  static func playStartSound() { play("ready", volume: 0.35) }
  static func playReleaseSound(volumeScale: Float = 1) {
    play("end", volume: min(0.6, 0.25 * volumeScale))
  }
  static func playLockSound(volumeScale: Float = 1) {
    play("lock", volume: min(0.7, 0.35 * volumeScale))
  }
  static func playCommitSound() { play("complete", volume: 0.25) }
  static func playErrorSound() { play("error", volume: 0.4) }

  private static func play(_ name: String, volume: Float) {
    queue.async {
      guard let sound = sounds[name] else { return }
      sound.stop()
      sound.volume = volume
      sound.play()
    }
  }
}
