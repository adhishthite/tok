public enum SettingGroup: String, CaseIterable, Identifiable, Sendable {
  case general = "General"
  case transcription = "Transcription"
  case audio = "Audio"
  case appearance = "Appearance"
  case vocabulary = "Vocabulary"
  case history = "History"
  case advanced = "Advanced"
  public var id: String { rawValue }
  public var symbol: String {
    switch self {
    case .general: "gearshape"
    case .transcription: "text.bubble"
    case .audio: "mic"
    case .appearance: "circle.lefthalf.filled"
    case .vocabulary: "character.book.closed"
    case .history: "clock"
    case .advanced: "slider.horizontal.3"
    }
  }
}
