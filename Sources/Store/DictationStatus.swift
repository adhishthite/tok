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
  var symbol: String {
    switch self {
    case .paused: "pause.circle"
    case .setup, .error: "exclamationmark.circle"
    case .ready: "waveform"
    case .starting, .processing: "ellipsis.circle"
    case .listening: "mic.fill"
    case .locked: "lock.fill"
    case .microphoneReleased: "mic.slash"
    }
  }
}
