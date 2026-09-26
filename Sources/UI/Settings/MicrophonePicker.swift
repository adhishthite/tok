// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

struct MicrophonePicker: View {
  @Binding var selection: String
  @State private var microphones = MicrophoneListStore()

  var body: some View {
    MicrophonePickerContent(selection: $selection, devices: microphones.devices)
      .onAppear { microphones.start() }
      .onDisappear { microphones.stop() }
  }
}
