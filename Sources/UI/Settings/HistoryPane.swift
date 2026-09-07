import SwiftUI

struct HistoryPane: View {
  var body: some View {
    Form {
      CatalogSections(group: .history, excluding: ["HISTORY_RETENTION_DAYS"])
      HistoryRetentionSection()
    }
  }
}
