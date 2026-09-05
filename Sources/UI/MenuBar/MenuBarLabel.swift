import SwiftUI

struct MenuBarLabel: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Image(systemName: store.status.symbol)
      .accessibilityLabel("Tok, \(store.status.rawValue)")
  }
}
