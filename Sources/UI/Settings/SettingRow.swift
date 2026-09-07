import SwiftUI
import TokEngine

struct SettingRow: View {
  let setting: SettingDefinition
  @Environment(DictationStore.self) private var store
  private var overridden: Bool { store.settings.isOverridden(setting.key) }
  private var enabled: Bool {
    guard let condition = setting.enabledWhen else { return true }
    return condition.holds(store.settings.string(condition.key))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      control
        .accessibilityHint(setting.help)
        .disabled(overridden || !enabled)
      Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      if overridden {
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
      numericField {
        TextField(
          setting.title,
          value: Binding(
            get: { Int(store.settings.string(setting.key)) ?? range.lowerBound },
            set: {
              store.settings.set(
                setting.key, String(min(range.upperBound, max(range.lowerBound, $0))))
            }), format: .number.grouping(.never))
      }
    case .decimal(let range):
      numericField {
        TextField(
          setting.title,
          value: Binding(
            get: { Double(store.settings.string(setting.key)) ?? range.lowerBound },
            set: {
              store.settings.set(
                setting.key, String(min(range.upperBound, max(range.lowerBound, $0))))
            }),
          format: .number.grouping(.never).precision(.fractionLength(fractionDigits)))
      }
    case .text:
      LabeledContent(setting.title) {
        TextField(setting.title, text: stringBinding, prompt: Text(setting.prompt ?? setting.title))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
      }
    case .microphone:
      MicrophonePicker(selection: stringBinding)
    }
  }
  /// A right-aligned bordered value field with its unit beside it, so an editable
  /// number is visibly different from a read-only value.
  private func numericField(@ViewBuilder field: () -> some View) -> some View {
    LabeledContent(setting.title) {
      HStack(spacing: 6) {
        field().labelsHidden().multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder).frame(width: 96)
        if let unit = setting.unit {
          Text(unit.label).foregroundStyle(.secondary).frame(minWidth: 30, alignment: .leading)
        }
      }
    }
  }
  private var fractionDigits: ClosedRange<Int> { setting.unit?.fractionDigits ?? 0...2 }
  /// The catalog help plus the allowed range, shown before a value is rejected.
  private var caption: String {
    switch setting.kind {
    case .integer(let range):
      "\(setting.help) Range \(range.lowerBound) to \(range.upperBound)\(unitSuffix)."
    case .decimal(let range):
      "\(setting.help) Range \(bound(range.lowerBound)) to \(bound(range.upperBound))\(unitSuffix)."
    default: setting.help
    }
  }
  private var unitSuffix: String { setting.unit.map { " \($0.label)" } ?? "" }
  private func bound(_ value: Double) -> String {
    value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
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
