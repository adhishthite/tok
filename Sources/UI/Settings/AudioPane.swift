import SwiftUI

struct AudioPane: View {
  var body: some View {
    Form { CatalogSections(group: .audio) }
  }
}
