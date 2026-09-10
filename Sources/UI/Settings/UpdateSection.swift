import SwiftUI

struct UpdateSection: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Section {
      LabeledContent("Version", value: BuildIdentity.version)
      Button("Check for updates…") { store.updates.check() }.disabled(!store.updates.canCheck)
      if !store.updates.configured {
        Text("Updates are unavailable in this build.").font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Updates")
    }
  }
}
