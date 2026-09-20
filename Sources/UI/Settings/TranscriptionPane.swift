import SwiftUI

struct TranscriptionPane: View {
  var body: some View {
    Form {
      APIKeySection()
      TypeSafeKeySection()
      CatalogSections(group: .transcription)
    }
  }
}
