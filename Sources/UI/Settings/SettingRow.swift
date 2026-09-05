import SwiftUI
import TokEngine

struct SettingRow: View {
  let setting: SettingDefinition
  @Environment(DictationStore.self) private var store
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      control
        .disabled(store.settings.isOverridden(setting.key))
      Text(setting.help).font(.caption).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      if store.settings.isOverridden(setting.key) {
        Label("Set by environment", systemImage: "terminal").font(.caption).foregroundStyle(
          .secondary)
      }
    }.padding(.vertical, 4)
  }
  @ViewBuilder private var control: some View {
    switch setting.kind {
    case .toggle:
      Toggle(
        setting.title,
        isOn: Binding(
          get: { store.settings.bool(setting.key) },
          set: { store.settings.set(setting.key, String($0)) }))
    case .choice(let options):
      Picker(setting.title, selection: stringBinding) {
        ForEach(options, id: \.self) { option in Text(label(option)).tag(option) }
      }
    case .integer(let range):
      LabeledContent(setting.title) {
        TextField(
          setting.title,
          value: Binding(
            get: { Int(store.settings.string(setting.key)) ?? range.lowerBound },
            set: {
              store.settings.set(
                setting.key, String(min(range.upperBound, max(range.lowerBound, $0))))
            }), format: .number
        )
        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 85)
      }
    case .decimal(let range):
      LabeledContent(setting.title) {
        TextField(
          setting.title,
          value: Binding(
            get: { Double(store.settings.string(setting.key)) ?? range.lowerBound },
            set: {
              store.settings.set(
                setting.key, String(min(range.upperBound, max(range.lowerBound, $0))))
            }), format: .number
        )
        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 85)
      }
    case .text:
      TextField(setting.title, text: stringBinding)
    }
  }
  private var stringBinding: Binding<String> {
    Binding(
      get: { store.settings.string(setting.key) }, set: { store.settings.set(setting.key, $0) })
  }
  private func label(_ value: String) -> String {
    switch value {
    case "fn": "Fn / Globe"
    case "push_to_talk": "Hold to speak"
    case "toggle": "Press to start and stop"
    default: value.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}
