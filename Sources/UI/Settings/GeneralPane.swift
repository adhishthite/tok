import SwiftUI

struct GeneralPane: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Form {
      LoginItemSection()
      UpdateSection()
      CatalogSections(group: .general)
      Section("Permissions") {
        Button("Review permissions") { store.showSetup?() }
      }
    }
  }
}
