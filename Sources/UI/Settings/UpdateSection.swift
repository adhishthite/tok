import SwiftUI

struct UpdateSection: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Section {
      LabeledContent("Version", value: version)
      Button("Check for updates…") { store.updates.check() }.disabled(!store.updates.canCheck)
      if !store.updates.configured {
        Text("Updates are unavailable in this build.").font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Updates")
    }
  }
  /// Marketing version with the build number, which support needs for update reports.
  private var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let short = info["CFBundleShortVersionString"] as? String else { return "Development" }
    guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
    return "\(short) (\(build))"
  }
}
