import SwiftUI

struct AboutPane: View {
  @Environment(DictationStore.self) private var store
  @State private var copiedReport = false
  var body: some View {
    Form {
      Section {
        HStack(alignment: .center, spacing: 18) {
          Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable().interpolation(.high).frame(width: 84, height: 84)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text("Tok").font(.title.weight(.semibold))
            Text("Push-to-talk dictation for macOS.").foregroundStyle(.secondary)
            Text("Version \(BuildIdentity.version)")
              .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            Text("Source revision \(BuildIdentity.revision)")
              .font(.caption).foregroundStyle(.tertiary)
              .textSelection(.enabled)
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
      }
      Section("Support") {
        Button("Check for updates…") { store.updates.check() }.disabled(!store.updates.canCheck)
        LabeledContent {
          Button(copiedReport ? "Copied" : "Copy") { copyReport() }
        } label: {
          Text("Build details")
          Text(BuildIdentity.report).font(.caption).foregroundStyle(.secondary)
        }
        Link(
          "Release notes",
          destination: URL(string: "https://github.com/adhishthite/tok-releases/releases")!)
      }
      Section("Developer") {
        LabeledContent("Made by", value: "Adhish Thite")
        Link("GitHub", destination: URL(string: "https://github.com/adhishthite")!)
      }
      Section("License") {
        LabeledContent("License", value: "Apache License 2.0")
        LabeledContent {
          Button("Read") { open(license: "Tok-LICENSE") }
        } label: {
          Text(BuildIdentity.copyright)
        }
      }
      Section("Acknowledgements") {
        Text("Transcription is provided by the Gemini API. Tok is not a Google product.")
          .foregroundStyle(.secondary)
        LabeledContent {
          Button("Read") { open(license: "Sparkle-LICENSE") }
        } label: {
          Text("Sparkle")
          Text("Software updates. MIT License.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func copyReport() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(BuildIdentity.report, forType: .string)
    copiedReport = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      copiedReport = false
    }
  }
  /// Opens the bundled license text in the user's text editor.
  private func open(license name: String) {
    guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return }
    NSWorkspace.shared.open(url)
  }
}
