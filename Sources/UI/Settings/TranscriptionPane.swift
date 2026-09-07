import SwiftUI

struct TranscriptionPane: View {
  var body: some View {
    Form {
      APIKeySection()
      CatalogSections(group: .transcription)
    }
  }
}
