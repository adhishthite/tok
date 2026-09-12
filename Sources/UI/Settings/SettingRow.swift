import SwiftUI
import TokEngine

struct SettingRow: View {
  let setting: SettingDefinition
  @Environment(DictationStore.self) private var store
  /// Typed text and numbers are held here until Return or focus loss. Writing every
  /// keystroke to the store restarted the engine per character (audit F30).
  @State private var textDraft = ""
  @State private var intDraft = 0
  @State private var doubleDraft = 0.0
  @FocusState private var editing: Bool
  private var overridden: Bool { store.settings.isOverridden(setting.key) }
  private var enabled: Bool {
    guard let condition = setting.enabledWhen else { return true }
    return condition.isSatisfied { store.settings.string($0) }
  }
  private var storedValue: String { store.settings.string(setting.key) }
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
      .onAppear { seedDraft() }
      // Reset, import, and the Vocabulary window replace the value under the draft.
      .onChange(of: storedValue) { seedDraft() }
      .onSubmit { commitDraft() }
      .onChange(of: editing) { if !editing { commitDraft() } }
      .onDisappear { if editing { commitDraft() } }
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
    case .integer:
      numericField {
        TextField(setting.title, value: $intDraft, format: .number.grouping(.never))
          .focused($editing)
      }
    case .decimal:
      numericField {
        TextField(
          setting.title, value: $doubleDraft,
          format: .number.grouping(.never).precision(.fractionLength(fractionDigits))
        ).focused($editing)
      }
    case .text:
      LabeledContent(setting.title) {
        TextField(setting.title, text: $textDraft, prompt: Text(setting.prompt ?? setting.title))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
          .focused($editing)
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
  private func seedDraft() {
    switch setting.kind {
    case .text: textDraft = storedValue
    case .integer(let range): intDraft = Int(storedValue) ?? range.lowerBound
    case .decimal(let range): doubleDraft = Double(storedValue) ?? range.lowerBound
    default: break
    }
  }
  /// Clamps and writes the draft, then shows what was actually stored. Numbers are
  /// compared as numbers, so leaving a field untouched never rewrites "3.50" as "3.5".
  private func commitDraft() {
    let value: String
    switch setting.kind {
    case .text:
      value = textDraft
    case .integer(let range):
      let clamped = min(range.upperBound, max(range.lowerBound, intDraft))
      guard clamped != Int(storedValue) else {
        seedDraft()
        return
      }
      value = String(clamped)
    case .decimal(let range):
      let clamped = min(range.upperBound, max(range.lowerBound, doubleDraft))
      guard clamped != Double(storedValue) else {
        seedDraft()
        return
      }
      value = String(clamped)
    default: return
    }
    if value != storedValue { store.settings.set(setting.key, value) }
    seedDraft()
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
