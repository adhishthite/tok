import SwiftUI

struct UpdateSection: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    @Bindable var updates = store.updates
    Section {
      LabeledContent("Version", value: BuildIdentity.version)
      Button("Check for updates…") { store.updates.check() }.disabled(!store.updates.canCheck)
      if updates.configured {
        // No SettingCatalog entry: Sparkle owns this preference and persists it
        // itself, so a second store of truth would only drift.
        Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
      } else {
        Text("Updates are unavailable in this build.").font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Updates")
    }
  }
}
