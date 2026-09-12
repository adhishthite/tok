enum DictationStatus: String {
  case paused = "Paused"
  case setup = "Setup required"
  case ready = "Ready"
  case starting = "Starting microphone"
  case listening = "Listening"
  case locked = "Locked"
  case processing = "Transcribing"
  case microphoneReleased = "Microphone released"
  case error = "Needs attention"
  // A quiet clip is not a fault, so the menu bar shows a muted waveform, not an alarm.
  case noSpeech = "No speech detected"
  var symbol: String {
    switch self {
    case .paused: "pause.circle"
    case .setup, .error: "exclamationmark.circle"
    case .ready: "waveform"
    case .starting, .processing: "ellipsis.circle"
    case .listening: "mic.fill"
    case .locked: "lock.fill"
    case .microphoneReleased: "mic.slash"
    case .noSpeech: "waveform.slash"
    }
  }
}
