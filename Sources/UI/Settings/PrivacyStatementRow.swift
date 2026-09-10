import SwiftUI

/// One privacy fact: a small emoji for a visual anchor, a short claim, a
/// one-line detail, and an optional way to check the claim.
struct PrivacyStatementRow: View {
  let emoji: String
  let title: String
  let detail: String
  var action: String? = nil
  var perform: () -> Void = {}
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(emoji)
        .font(.title3)
        .frame(width: 26, alignment: .center)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.medium)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 12)
      if let action {
        Button(action, action: perform).controlSize(.small).fixedSize()
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}
