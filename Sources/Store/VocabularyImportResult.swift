enum VocabularyImportResult {
  case saved
  case staged

  var message: String {
    switch self {
    case .saved: "New vocabulary was added to your existing terms."
    case .staged: "Vocabulary added to the open editor. Save there to use the changes."
    }
  }
}
