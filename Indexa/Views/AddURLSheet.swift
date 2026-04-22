import SwiftUI

/// Sheet for adding a web URL to be scraped and indexed, with optional site crawling.
struct AddURLSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss
    @State private var urlString = ""
    @State private var isCrawlMode = false
    @State private var maxDepth = 2
    @State private var maxPages = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isCrawlMode ? "Crawl Site" : "Add Web Page")
                .font(.title2)
                .fontWeight(.bold)

            Text(isCrawlMode
                 ? "Enter a seed URL. The crawler will follow links on the same domain."
                 : "Enter a URL to fetch and index its content.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("https://example.com/docs", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addURL() }

            Toggle("Crawl site (follow links)", isOn: $isCrawlMode)
                .toggleStyle(.switch)

            if isCrawlMode {
                HStack(spacing: 16) {
                    Picker("Depth:", selection: $maxDepth) {
                        Text("1 level").tag(1)
                        Text("2 levels").tag(2)
                        Text("3 levels").tag(3)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)

                    Picker("Max pages:", selection: $maxPages) {
                        Text("10 pages").tag(10)
                        Text("25 pages").tag(25)
                        Text("50 pages").tag(50)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                Text("Only follows links on the same domain. Pages are fetched with a short delay between requests.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if appState.isIngesting && !isCrawlMode {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.ingestionPhase.isEmpty ? "Fetching..." : appState.ingestionPhase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = appState.urlIngestionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCrawlMode ? "Start Crawl" : "Add") { addURL() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        urlString.trimmingCharacters(in: .whitespaces).isEmpty
                        || appState.isIngesting
                        || appState.isCrawling
                    )
            }
        }
        .padding(24)
        .frame(width: 480)
        .onDisappear {
            appState.urlIngestionError = nil
        }
    }

    private func addURL() {
        guard let collectionId = appState.selectedCollectionId else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if isCrawlMode {
            appState.crawlSite(
                seedURL: trimmed,
                collectionId: collectionId,
                maxDepth: maxDepth,
                maxPages: maxPages
            )
            dismiss()
        } else {
            Task {
                await appState.ingestURL(trimmed, collectionId: collectionId)
                if appState.urlIngestionError == nil {
                    dismiss()
                }
            }
        }
    }
}
