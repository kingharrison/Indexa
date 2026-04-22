import SwiftUI

/// Search-only view shown when "All Collections" is selected.
/// Queries across all enabled documents in all collections.
struct CrossCollectionSearchView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All Collections")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Search across \(appState.collections.count) collection\(appState.collections.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            QueryView()
        }
    }
}
