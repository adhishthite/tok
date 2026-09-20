public enum SettingGroup: String, CaseIterable, Identifiable, Sendable {
  case general = "General"
  case transcription = "Transcription"
  case audio = "Audio"
  case appearance = "Appearance"
  case vocabulary = "Vocabulary"
  case privacy = "Privacy"
  case advanced = "Advanced"
  case experimental = "Experimental"
  case about = "About"
  public var id: String { rawValue }
  public var symbol: String {
    switch self {
    case .general: "gearshape"
    case .transcription: "text.bubble"
    case .audio: "mic"
    case .appearance: "circle.lefthalf.filled"
    case .vocabulary: "character.book.closed"
    case .privacy: "lock.shield"
    case .advanced: "slider.horizontal.3"
    case .experimental: "flask"
    case .about: "info.circle"
    }
  }
}
