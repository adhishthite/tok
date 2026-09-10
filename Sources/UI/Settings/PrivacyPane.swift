import SwiftUI

struct PrivacyPane: View {
  var body: some View {
    Form {
      PrivacyStatementsSection()
      CatalogSections(
        group: .privacy,
        excluding: ["HISTORY_RETENTION_DAYS", "SHARE_USAGE_METRICS", "STATS", "STATS_WORDS"])
      HistoryRetentionSection()
      StatsSection()
      MetricsSection()
    }
  }
}
