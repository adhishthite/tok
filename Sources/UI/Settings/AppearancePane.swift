import SwiftUI

struct AppearancePane: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Form {
      CatalogSections(group: .appearance) { setting in
        if setting.key == "HUD_REVEAL" {
          Button("Preview overlay") { store.previewHUD() }
        }
      }
    }
  }
}
