import SwiftUI
import UniformTypeIdentifiers

/// The main content area when a collection is selected — shows documents, allows drops, and has a query field.
struct CollectionDetailView: View {
    @Environment(AppState.self) var appState
    @State private var isDragTargeted = false
    @State private var activeTab: ContentTab = .documents

    private enum ContentTab { case documents, chunks }

    var body: some View {
        VStack(spacing: 0) {
            // ── Collection header ────────────────────────────────────
            if let collection = appState.selectedCollection {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(.title2)
                            .fontWeight(.bold)

                        if appState.canViewDocuments {
                            Text("\(appState.documentsInSelectedCollection.count) document(s)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    // Refresh interval picker
                    Picker("Refresh", selection: Binding(
                        get: { collection.refreshInterval },
                        set: { appState.updateRefreshInterval(for: collection.id, interval: $0) }
                    )) {
                        ForEach(RefreshInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .help("Auto-refresh web sources on this interval")
                    .disabled(!appState.canEditSelectedCollection)

                    // Manual refresh (visible when collection has web documents)
                    if appState.documentsInSelectedCollection.contains(where: { $0.sourceType == .web }) {
                        Button {
                            Task { await appState.manualRefresh(collectionId: collection.id) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(appState.refreshStatus != nil || !appState.canEditSelectedCollection)
                    }

                    // Optimize for distribution
                    Button {
                        if let id = appState.selectedCollectionId {
                            appState.optimizeCollection(id)
                        }
                    } label: {
                        Label("Optimize", systemImage: "wand.and.stars.inverse")
                    }
                    .disabled(appState.isOptimizing || appState.isDistilling || appState.isIngesting
                        || appState.documentsInSelectedCollection.isEmpty || !appState.canEditSelectedCollection)
                    .help("Distill, deduplicate, and compact this collection for distribution")

                    // Distill all undistilled documents
                    Button {
                        if let id = appState.selectedCollectionId {
                            appState.distillAllDocuments(id)
                        }
                    } label: {
                        Label("Distill All", systemImage: "wand.and.stars")
                    }
                    .disabled(appState.isOptimizing || appState.isDistilling || appState.isIngesting
                        || appState.documentsInSelectedCollection.isEmpty || !appState.canEditSelectedCollection)
                    .help("Distill all undistilled documents with AI")

                    // Export this collection
                    Button {
                        ExportPanel.show(appState: appState)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(appState.documentsInSelectedCollection.isEmpty)

                    // Add URL button
                    Button {
                        appState.isAddingURL = true
                    } label: {
                        Label("Add URL", systemImage: "globe")
                    }
                    .disabled(appState.isIngesting || appState.isCrawling || !appState.canEditSelectedCollection)

                    // Add files button
                    Button {
                        openFilePicker()
                    } label: {
                        Label("Add Files", systemImage: "plus.circle")
                    }
                    .disabled(appState.isIngesting || appState.isCrawling || !appState.canEditSelectedCollection)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                // Show refresh status if active
                if let status = appState.refreshStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }

                Divider()

                // ── Tab selector ─────────────────────────────────
                if appState.canViewDocuments && !appState.documentsInSelectedCollection.isEmpty {
                    Picker("", selection: $activeTab) {
                        Text("Documents").tag(ContentTab.documents)
                        Text("Chunks").tag(ContentTab.chunks)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }

            // ── Main area: documents + drop zone + query ─────────────
            if appState.isCrawling {
                CrawlProgressView()
            } else if appState.isOptimizing {
                OptimizationProgressView()
            } else if appState.isIngesting {
                IngestionProgressView()
            } else if appState.isDistilling {
                DistillationProgressView()
            } else if !appState.canViewDocuments {
                // Sources masked — locked graphic + query
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange.opacity(0.7), .orange.opacity(0.4)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        Text("This Collection is Locked")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        Text("Documents and sources are hidden.\nYou can still ask questions below.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    Divider()

                    QueryView()
                }
            } else if appState.documentsInSelectedCollection.isEmpty {
                DropZoneView(isDragTargeted: $isDragTargeted)
                    .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
            } else {
                VStack(spacing: 0) {
                    if activeTab == .chunks {
                        ChunkBrowserView()
                    } else {
                        // Document list
                        DocumentListView()
                    }

                    Divider()

                    // Query area
                    QueryView()
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            guard appState.canEditSelectedCollection else { return false }
            handleDrop(providers: providers)
            return true
        }
        .sheet(isPresented: Binding(
            get: { appState.isAddingURL },
            set: { appState.isAddingURL = $0 }
        )) {
            AddURLSheet()
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .text, .plainText, .utf8PlainText,
            .pdf,
            .rtf, .rtfd,
            .html,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "pptx") ?? .data,
            UTType(filenameExtension: "md") ?? .text
        ]
        panel.message = "Choose files to index"

        guard panel.runModal() == .OK else { return }

        if let collectionId = appState.selectedCollectionId {
            Task {
                await appState.ingestFiles(urls: panel.urls, collectionId: collectionId)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []

        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            guard let collectionId = appState.selectedCollectionId, !urls.isEmpty else { return }
            Task {
                await appState.ingestFiles(urls: urls, collectionId: collectionId)
            }
        }
    }
}

// MARK: - Drop zone (empty collection state)

struct DropZoneView: View {
    @Binding var isDragTargeted: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundColor(isDragTargeted ? .accentColor : .secondary)

            Text("Drop files here to index")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(isDragTargeted ? .accentColor : .primary)

            Text("Supports PDF, TXT, MD, RTF, DOCX, XLSX, PPTX, and HTML")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .padding(24)
        )
    }
}

// MARK: - Ingestion progress

struct IngestionProgressView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text(appState.ingestionPhase)
                .font(.headline)

            if appState.ingestionProgress.total > 0 {
                Text("\(appState.ingestionProgress.current) / \(appState.ingestionProgress.total) chunks")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ProgressView(
                    value: Double(appState.ingestionProgress.current),
                    total: Double(max(appState.ingestionProgress.total, 1))
                )
                .frame(width: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Optimization progress

struct OptimizationProgressView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Optimizing Collection...")
                .font(.headline)

            Text(appState.optimizationPhase)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if appState.optimizationProgress.total > 0 {
                Text("\(appState.optimizationProgress.current) / \(appState.optimizationProgress.total)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ProgressView(
                    value: Double(appState.optimizationProgress.current),
                    total: Double(max(appState.optimizationProgress.total, 1))
                )
                .frame(width: 200)
            }

            Button("Cancel") {
                appState.cancelOptimization()
            }
            .buttonStyle(.bordered)
            .disabled(appState.optimizationPhase == "Cancelling...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Distillation progress

struct DistillationProgressView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = appState.distillationStartTime.map { context.date.timeIntervalSince($0) } ?? 0
            let current = appState.distillationProgress.current
            let total = appState.distillationProgress.total

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)

                Text("Distilling...")
                    .font(.headline)

                Text(appState.distillationPhase)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if total > 0 {
                    Text("\(current) / \(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ProgressView(
                        value: Double(current),
                        total: Double(max(total, 1))
                    )
                    .frame(width: 200)
                }

                // Elapsed time and ETA
                if elapsed > 0 {
                    VStack(spacing: 4) {
                        Text("Elapsed: \(formatDuration(elapsed))")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if current > 0, total > current {
                            let remaining = (elapsed / Double(current)) * Double(total - current)
                            Text("\(formatETA(remaining)) remaining")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button("Cancel") {
                    appState.cancelDistillation()
                }
                .buttonStyle(.bordered)
                .disabled(appState.distillationPhase == "Cancelling...")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 30 {
            return "Less than a minute"
        } else if seconds < 60 {
            return "~\(Int(seconds))s"
        } else {
            let mins = Int(ceil(seconds / 60))
            return "~\(mins) min"
        }
    }
}

// MARK: - Crawl progress

struct CrawlProgressView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Crawling site...")
                .font(.headline)

            Text(appState.crawlPhase)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 24) {
                CrawlStat(value: "\(appState.crawlProgress.discovered)", label: "Discovered")
                CrawlStat(value: "\(appState.crawlProgress.fetched)", label: "Fetched")
                CrawlStat(value: "\(appState.crawlProgress.ingested)", label: "Ingested")
            }

            if appState.crawlProgress.maxPages > 0 {
                ProgressView(
                    value: Double(appState.crawlProgress.fetched),
                    total: Double(appState.crawlProgress.maxPages)
                )
                .frame(width: 200)
            }

            Button("Cancel Crawl") {
                appState.cancelCrawl()
            }
            .buttonStyle(.bordered)
            .disabled(appState.crawlPhase == "Cancelling...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CrawlStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Document list

struct DocumentListView: View {
    @Environment(AppState.self) var appState
    @State private var selectedDocIds: Set<UUID> = []
    @State private var isSelecting = false
    @State private var searchText = ""

    private var filteredGroupedDocuments: [DocumentListItem] {
        guard !searchText.isEmpty else { return appState.groupedDocuments }
        let query = searchText.lowercased()
        return appState.groupedDocuments.compactMap { item in
            switch item {
            case .single(let doc):
                return doc.fileName.lowercased().contains(query) ? item : nil
            case .bundle(let groupId, let pages):
                let filtered = pages.filter { $0.fileName.lowercased().contains(query) }
                if filtered.isEmpty { return nil }
                return .bundle(groupId: groupId, pages: filtered)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Batch action bar ──────────────────────────────────
            if isSelecting {
                HStack(spacing: 12) {
                    Text("\(selectedDocIds.count) selected")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Enable") {
                        appState.batchToggleEnabled(selectedDocIds, enabled: true)
                        selectedDocIds.removeAll()
                    }
                    .font(.caption)
                    .disabled(selectedDocIds.isEmpty)

                    Button("Disable") {
                        appState.batchToggleEnabled(selectedDocIds, enabled: false)
                        selectedDocIds.removeAll()
                    }
                    .font(.caption)
                    .disabled(selectedDocIds.isEmpty)

                    Button("Delete", role: .destructive) {
                        appState.batchDeleteDocuments(selectedDocIds)
                        selectedDocIds.removeAll()
                    }
                    .font(.caption)
                    .disabled(selectedDocIds.isEmpty)

                    Divider().frame(height: 16)

                    Button("Select All") {
                        selectedDocIds = Set(appState.documentsInSelectedCollection.map(\.id))
                    }
                    .font(.caption)

                    Button("Done") {
                        isSelecting = false
                        selectedDocIds.removeAll()
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.06))
            }

            // ── Search bar ────────────────────────────────────
            if appState.documentsInSelectedCollection.count > 5 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Filter documents...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.03))
            }

            List {
                ForEach(filteredGroupedDocuments) { item in
                    switch item {
                    case .single(let doc):
                        if isSelecting {
                            SelectableDocumentRow(doc: doc, isSelected: selectedDocIds.contains(doc.id)) {
                                if selectedDocIds.contains(doc.id) {
                                    selectedDocIds.remove(doc.id)
                                } else {
                                    selectedDocIds.insert(doc.id)
                                }
                            }
                        } else {
                            DocumentRow(doc: doc)
                        }
                    case .bundle(let groupId, let pages):
                        if isSelecting {
                            ForEach(pages) { page in
                                SelectableDocumentRow(doc: page, isSelected: selectedDocIds.contains(page.id)) {
                                    if selectedDocIds.contains(page.id) {
                                        selectedDocIds.remove(page.id)
                                    } else {
                                        selectedDocIds.insert(page.id)
                                    }
                                }
                            }
                        } else {
                            WebsiteBundleRow(groupId: groupId, pages: pages)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .contextMenu {
                if !isSelecting && appState.canEditSelectedCollection {
                    Button("Select Documents...") {
                        isSelecting = true
                    }
                }
            }
        }
    }
}

// MARK: - Selectable document row (batch mode)

private struct SelectableDocumentRow: View {
    let doc: IndexedDocument
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.body)

            Image(systemName: doc.sourceType == .web ? "globe" : "doc.text")
                .foregroundColor(doc.enabled
                    ? (doc.sourceType == .web ? .blue : .accentColor)
                    : .secondary.opacity(0.5))

            Text(doc.fileName)
                .font(.callout)
                .foregroundColor(doc.enabled ? .primary : .secondary)
                .lineLimit(1)

            Spacer()

            Text("\(doc.chunkCount) chunks")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

// MARK: - Single document row

private struct DocumentRow: View {
    @Environment(AppState.self) var appState
    let doc: IndexedDocument

    private var isReadOnlyLocked: Bool {
        appState.effectiveProtection(for: doc.collectionId) == .readOnly
    }

    var body: some View {
        Group {
            if isReadOnlyLocked {
                documentLabel
            } else {
                DisclosureGroup {
                    if let summary = doc.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                            .padding(.vertical, 4)
                            .textSelection(.enabled)
                    } else {
                        Text("No summary available")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.6))
                            .italic()
                            .padding(.leading, 4)
                            .padding(.vertical, 4)
                    }
                } label: {
                    documentLabel
                }
            }
        }
        .contextMenu {
            Button(doc.enabled ? "Disable for queries" : "Enable for queries") {
                appState.toggleDocumentEnabled(doc)
            }

            Divider()

            if doc.hasDistilledChunks {
                Button(doc.useDistilled ? "Use Original Chunks" : "Use Distilled Chunks") {
                    appState.toggleUseDistilled(doc, useDistilled: !doc.useDistilled)
                }
                .disabled(!appState.canEditSelectedCollection)
                Button("Re-Distill") {
                    appState.distillDocument(doc)
                }
                .disabled(appState.isDistilling || appState.isIngesting || !appState.canEditSelectedCollection)
                Button("Remove Distillation", role: .destructive) {
                    appState.removeDistillation(doc)
                }
                .disabled(!appState.canEditSelectedCollection)
            } else {
                Button("Distill with AI") {
                    appState.distillDocument(doc)
                }
                .disabled(appState.isDistilling || appState.isIngesting || !appState.canEditSelectedCollection)
            }

            Divider()

            Button("Delete", role: .destructive) {
                appState.documentToDelete = doc
            }
            .disabled(!appState.canEditSelectedCollection)
        }
    }

    private var documentLabel: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { doc.enabled },
                set: { _ in appState.toggleDocumentEnabled(doc) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(doc.enabled ? "Disable for queries" : "Enable for queries")

            Image(systemName: doc.sourceType == .web ? "globe" : "doc.text")
                .foregroundColor(doc.enabled
                    ? (doc.sourceType == .web ? .blue : .accentColor)
                    : .secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.fileName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(doc.enabled ? .primary : .secondary)

                Text("\(doc.chunkCount) chunks · \(formattedSize(doc.fileSize))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !isReadOnlyLocked {
                if doc.hasDistilledChunks {
                    Picker("", selection: Binding(
                        get: { doc.useDistilled },
                        set: { appState.toggleUseDistilled(doc, useDistilled: $0) }
                    )) {
                        Text("Original").tag(false)
                        Text("Distilled").tag(true)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .font(.caption)
                }

                if doc.hasDistilledChunks {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundColor(.purple.opacity(0.7))
                        .help(doc.useDistilled ? "Using distilled version" : "Distilled version available")
                }

                if doc.summary != nil {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                        .help("Has AI summary")
                }
            }

            Text(doc.dateIndexed.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Website bundle row

private struct WebsiteBundleRow: View {
    @Environment(AppState.self) var appState
    let groupId: UUID
    let pages: [IndexedDocument]

    private var domainName: String {
        if let url = URL(string: pages.first?.filePath ?? ""),
           let host = url.host {
            return host
        }
        return "Website"
    }

    private var allEnabled: Bool { pages.allSatisfy(\.enabled) }
    private var someEnabled: Bool { pages.contains(where: \.enabled) }
    private var totalChunks: Int { pages.reduce(0) { $0 + $1.chunkCount } }
    private var totalSize: Int64 { pages.reduce(0) { $0 + $1.fileSize } }
    private var anyDistilled: Bool { pages.contains(where: \.hasDistilledChunks) }
    private var allDistilled: Bool { pages.allSatisfy(\.hasDistilledChunks) }

    var body: some View {
        DisclosureGroup {
            ForEach(pages) { page in
                DocumentRow(doc: page)
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { allEnabled },
                    set: { _ in appState.toggleBundleEnabled(groupId: groupId) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(allEnabled ? "Disable all pages" : "Enable all pages")

                Image(systemName: "globe.badge.chevron.backward")
                    .foregroundColor(someEnabled ? .blue : .secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(domainName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(someEnabled ? .primary : .secondary)

                    Text("\(pages.count) pages · \(totalChunks) chunks · \(formattedSize(totalSize))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if anyDistilled {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundColor(.purple.opacity(0.7))
                        .help(allDistilled ? "All pages distilled" : "Some pages distilled")
                }

                if let latest = pages.map(\.dateIndexed).max() {
                    Text(latest.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contextMenu {
            Button(allEnabled ? "Disable All Pages" : "Enable All Pages") {
                appState.toggleBundleEnabled(groupId: groupId)
            }

            Divider()

            if allDistilled {
                Button("Re-Distill All Pages") {
                    appState.distillBundle(groupId: groupId)
                }
                .disabled(appState.isDistilling || appState.isIngesting)
                Button("Remove All Distillation", role: .destructive) {
                    appState.removeDistillationFromBundle(groupId: groupId)
                }
            } else {
                Button("Distill All Pages") {
                    appState.distillBundle(groupId: groupId)
                }
                .disabled(appState.isDistilling || appState.isIngesting)
            }

            Divider()

            Button("Delete All Pages", role: .destructive) {
                appState.deleteBundleGroup(groupId: groupId)
            }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
