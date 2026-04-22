import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) var appState
    @State private var newCollectionName = ""
    @State private var isCreatingCollection = false
    @State private var renamingCollectionId: UUID? = nil
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "book.pages.fill")
                    .font(.body)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.33, green: 0.83, blue: 0.97),
                                     Color(red: 0.22, green: 0.75, blue: 0.91)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Indexa")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // ── Collections header + add button ─────────────────────
            HStack {
                Text("Collections")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    isCreatingCollection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(appState.chatServerConnected != true && appState.embedServerConnected != true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // ── New collection text field ────────────────────────────
            if isCreatingCollection {
                HStack(spacing: 6) {
                    TextField("Name...", text: $newCollectionName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit {
                            createCollection()
                        }

                    Button("Add") {
                        createCollection()
                    }
                    .font(.caption)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // ── Collection list ─────────────────────────────────────
            List {
                // Global search row
                AllCollectionsRow(
                    isSelected: appState.selectedCollectionId == nil,
                    totalDocs: appState.collectionDocCounts.values.reduce(0, +)
                )
                .onTapGesture {
                    appState.selectCollection(nil)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                ForEach(appState.collections) { collection in
                    if renamingCollectionId == collection.id {
                        HStack(spacing: 6) {
                            TextField("Name...", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    commitRename(collection)
                                }
                                .onExitCommand {
                                    renamingCollectionId = nil
                                }
                        }
                    } else {
                        CollectionRow(
                            collection: collection,
                            isSelected: appState.selectedCollectionId == collection.id
                        )
                        .onTapGesture {
                            appState.selectCollection(collection.id)
                        }
                        .contextMenu {
                            Button("Rename...") {
                                renameText = collection.name
                                renamingCollectionId = collection.id
                            }
                            .disabled(!appState.isCollectionUnlocked(collection.id))
                            Button("Export...") {
                                exportCollection(collection)
                            }

                            Divider()

                            if collection.isProtected {
                                if appState.isCollectionUnlocked(collection.id) {
                                    Button("Change Protection...") {
                                        appState.passwordPromptCollectionId = collection.id
                                        appState.showProtectionSheet = true
                                    }
                                    Button("Lock Now") {
                                        appState.lockCollection(collection.id)
                                    }
                                } else {
                                    Button("Unlock...") {
                                        appState.selectCollection(collection.id)
                                        appState.passwordPromptCollectionId = collection.id
                                        appState.showPasswordPrompt = true
                                    }
                                }
                            } else {
                                Button("Set Protection...") {
                                    appState.passwordPromptCollectionId = collection.id
                                    appState.showProtectionSheet = true
                                }
                            }

                            Button("Duplicate") {
                                appState.duplicateCollection(collection)
                            }
                            .disabled(!appState.isCollectionUnlocked(collection.id))

                            Divider()

                            Button("Optimize for Distribution...") {
                                appState.optimizeCollection(collection.id)
                            }
                            .disabled(appState.isOptimizing || appState.isDistilling || appState.isIngesting
                                || !appState.isCollectionUnlocked(collection.id))

                            Divider()
                            Button("Delete", role: .destructive) {
                                appState.collectionToDelete = collection
                            }
                        }
                    }
                }
                .onMove { source, destination in
                    appState.moveCollections(from: source, to: destination)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                // Remote servers
                ForEach(appState.remoteServers) { server in
                    Section {
                        if let collections = appState.remoteCollections[server.id], !collections.isEmpty {
                            ForEach(collections) { collection in
                                RemoteCollectionRow(
                                    collection: collection,
                                    isSelected: appState.selectedRemoteCollection?.serverId == server.id
                                        && appState.selectedRemoteCollection?.collectionId == collection.id
                                )
                                .onTapGesture {
                                    appState.selectRemoteCollection(serverId: server.id, collectionId: collection.id)
                                }
                            }
                        } else if !server.isConnected {
                            Text("Not connected")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                        } else {
                            Text("No collections")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(server.isConnected ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Image(systemName: "network")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(server.name)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            .listStyle(.sidebar)

            if appState.collections.isEmpty && !isCreatingCollection {
                Text("No collections yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }

            Spacer()

            Divider()

            // ── Export / Import buttons ──────────────────────────────
            HStack(spacing: 8) {
                Button {
                    ExportPanel.show(appState: appState)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(appState.collections.isEmpty)

                Button {
                    openImportPanel()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // ── Status panel (read-only) ─────────────────────────────
            VStack(alignment: .leading, spacing: 5) {
                let active = appState.activeProvider ?? .defaultOllama

                StatusRow(label: "LLM", status: appState.chatServerConnected) {
                    Text(shortenURL(active.chatServer.baseURL))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                StatusRow(label: "Embed", status: appState.embedServerConnected) {
                    Text(shortenURL(active.embedServer.baseURL))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                StatusRow(label: "API / MCP", status: appState.isServerRunning ? true : nil) {
                    Text(verbatim: appState.isServerRunning ? "localhost:\(appState.serverPort)" : "Off")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(appState.isServerRunning ? .primary : .secondary)
                        .lineLimit(1)
                }

                HStack {
                    Spacer()
                    Button {
                        appState.showSettingsSheet = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: appState.showNewCollection) {
            if appState.showNewCollection {
                isCreatingCollection = true
                appState.showNewCollection = false
            }
        }
    }

    /// Shorten a URL like "http://localhost:11434" to "localhost:11434"
    private func shortenURL(_ url: String) -> String {
        url.replacingOccurrences(of: "http://", with: "")
           .replacingOccurrences(of: "https://", with: "")
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType("com.kingharrison.indexa.bundle") ?? .data
        ]
        panel.message = "Select an .indexa bundle to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        appState.pendingImportURL = url
        appState.showImportSheet = true
    }

    private func exportCollection(_ collection: Collection) {
        // Select this collection first so the panel pre-selects it
        appState.selectCollection(collection.id)
        ExportPanel.show(appState: appState)
    }

    private func commitRename(_ collection: Collection) {
        appState.renameCollection(collection, to: renameText)
        renamingCollectionId = nil
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        appState.createCollection(name: name)
        newCollectionName = ""
        isCreatingCollection = false
    }
}

// MARK: - All Collections row

struct AllCollectionsRow: View {
    let isSelected: Bool
    let totalDocs: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(isSelected ? .white : .accentColor)

            Text("All Collections")
                .font(.callout)
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)

            Spacer()

            if totalDocs > 0 {
                Text("\(totalDocs)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Collection row

struct CollectionRow: View {
    @Environment(AppState.self) var appState
    let collection: Collection
    let isSelected: Bool

    private var isUnlocked: Bool {
        appState.isCollectionUnlocked(collection.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: collection.isProtected
                  ? (isUnlocked
                      ? (appState.effectiveProtection(for: collection.id) == .sourcesMasked
                          ? "eye.slash.fill" : "lock.open.fill")
                      : "lock.fill")
                  : "folder.fill")
                .font(.caption)
                .foregroundColor(isSelected ? .white
                    : (appState.effectiveProtection(for: collection.id) != nil ? .orange : .accentColor))

            Text(collection.name)
                .font(.callout)
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)

            Spacer()

            if let count = appState.collectionDocCounts[collection.id], count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                    .cornerRadius(8)
            }

            if let protection = appState.effectiveProtection(for: collection.id) {
                Text(protection == .sourcesMasked ? "Masked" : "Read Only")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Status Row

private struct StatusRow<Content: View>: View {
    let label: String
    var status: Bool? = nil
    @ViewBuilder let content: Content

    private var dotColor: Color {
        switch status {
        case true: return .green
        case false: return .red
        case nil: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Remote Collection Row

struct RemoteCollectionRow: View {
    let collection: RemoteCollection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.fill")
                .font(.caption)
                .foregroundColor(isSelected ? .white : .accentColor)

            Text(collection.name)
                .font(.callout)
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)

            Spacer()

            if let count = collection.documentCount, count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                    .cornerRadius(8)
            }

            if collection.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
    }
}
