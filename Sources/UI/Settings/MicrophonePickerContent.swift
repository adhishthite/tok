import SwiftUI
import TokEngine

struct MicrophonePickerContent: View {
  @Binding var selection: String
  let devices: [InputDeviceCatalog.Device]

  private var choices: [MicrophoneChoice] {
    MicrophoneChoice.options(devices: devices, selection: selection)
  }

  var body: some View {
    Picker("Microphone", selection: $selection) {
      ForEach(choices) { choice in Text(choice.label).tag(choice.id) }
    }
  }
}
