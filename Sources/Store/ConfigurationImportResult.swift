enum ConfigurationImportResult {
  case settingsOnly
  case vocabularyAdded
  case vocabularyStaged
  case chooseVocabulary

  var message: String {
    switch self {
    case .settingsOnly: "Settings imported. No vocabulary file was found in this folder."
    case .vocabularyAdded: "Settings imported. New vocabulary was added to your existing terms."
    case .vocabularyStaged:
      "Settings imported. Vocabulary was added to the open editor; save there to use it."
    case .chooseVocabulary: "Settings imported. Choose the vocabulary file separately to add it."
    }
  }
}
