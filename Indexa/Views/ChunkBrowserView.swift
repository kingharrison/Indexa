import SwiftUI

/// Browse, search, and inspect all chunks in the selected collection.
struct ChunkBrowserView: View {
    @Environment(AppState.self) var appState
    @State private var searchText = ""
    @State private var selectedChunkType: ChunkType? = nil
    @State private var selectedDocId: UUID? = nil
    @State private var currentPage = 0
    @State private var totalChunks = 0
    @State private var chunks: [ChunkBrowseItem] = []
    @State private var selectedChunk: ChunkBrowseItem? = nil

    private let pageSize = 50

    private var totalPages: Int {
        max(1, (totalChunks + pageSize - 1) / pageSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Filter bar ──────────────────────────────────────────
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Search chunks...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)

                Picker("Type", selection: $selectedChunkType) {
                    Text("All Types").tag(nil as ChunkType?)
                    Text("Original").tag(ChunkType.original as ChunkType?)
                    Text("Distilled").tag(ChunkType.distilled as ChunkType?)
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Picker("Document", selection: $selectedDocId) {
                    Text("All Documents").tag(nil as UUID?)
                    ForEach(appState.documentsInSelectedCollection) { doc in
                        Text(doc.fileName).tag(doc.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // ── Chunk list ──────────────────────────────────────────
            if chunks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(totalChunks == 0 ? "No chunks found" : "No matching chunks")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(chunks) { chunk in
                        ChunkRow(chunk: chunk)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedChunk = chunk
                            }
                    }
                }
                .listStyle(.plain)
            }

            // ── Pagination ──────────────────────────────────────────
            if totalChunks > pageSize {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        currentPage = max(0, currentPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentPage == 0)

                    Text("Page \(currentPage + 1) of \(totalPages)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        currentPage = min(totalPages - 1, currentPage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentPage >= totalPages - 1)

                    Spacer()

                    Text("\(totalChunks) chunks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task { loadChunks() }
        .onChange(of: searchText) {
            currentPage = 0
            loadChunks()
        }
        .onChange(of: selectedChunkType) {
            currentPage = 0
            loadChunks()
        }
        .onChange(of: selectedDocId) {
            currentPage = 0
            loadChunks()
        }
        .onChange(of: currentPage) { loadChunks() }
        .onChange(of: appState.selectedCollectionId) {
            currentPage = 0
            searchText = ""
            selectedChunkType = nil
            selectedDocId = nil
            loadChunks()
        }
        .sheet(item: $selectedChunk) { chunk in
            ChunkDetailSheet(chunk: chunk)
        }
    }

    private func loadChunks() {
        guard let collectionId = appState.selectedCollectionId else {
            chunks = []
            totalChunks = 0
            return
        }

        let search = searchText.isEmpty ? nil : searchText

        do {
            totalChunks = try appState.vectorStore.chunkCountFiltered(
                collectionId: collectionId,
                chunkType: selectedChunkType,
                documentId: selectedDocId,
                searchText: search
            )
            chunks = try appState.vectorStore.loadChunksPaginated(
                collectionId: collectionId,
                offset: currentPage * pageSize,
                limit: pageSize,
                chunkType: selectedChunkType,
                documentId: selectedDocId,
                searchText: search,
                decryptionKey: appState.encryptionKey(for: collectionId)
            )
        } catch {
            chunks = []
            totalChunks = 0
        }
    }
}

// MARK: - Chunk row

private struct ChunkRow: View {
    let chunk: ChunkBrowseItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("#\(chunk.chunkIndex)")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)

            Text(chunk.chunkType == .distilled ? "Distilled" : "Original")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(chunk.chunkType == .distilled
                    ? Color.purple.opacity(0.15)
                    : Color.primary.opacity(0.06))
                .foregroundColor(chunk.chunkType == .distilled ? .purple : .secondary)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(chunk.content)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Text(chunk.documentName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chunk detail sheet

private struct ChunkDetailSheet: View {
    let chunk: ChunkBrowseItem
    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chunk #\(chunk.chunkIndex)")
                        .font(.headline)
                    Text(chunk.documentName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(chunk.chunkType == .distilled ? "Distilled" : "Original")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(chunk.chunkType == .distilled
                        ? Color.purple.opacity(0.15)
                        : Color.primary.opacity(0.06))
                    .foregroundColor(chunk.chunkType == .distilled ? .purple : .secondary)
                    .cornerRadius(6)
            }

            Divider()

            ScrollView {
                Text(chunk.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("\(chunk.content.count) characters")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chunk.content, forType: .string)
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                } label: {
                    Label(showCopied ? "Copied!" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 550, height: 420)
    }
}
