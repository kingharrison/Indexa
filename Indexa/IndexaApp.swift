import SwiftUI
import UniformTypeIdentifiers

@main
struct IndexaApp: App {
    @State private var appState = AppState()

    init() {
        if UserDefaults.standard.bool(forKey: "hideFromDock") {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    // Handle .indexa file double-click or drag-to-dock
                    if url.pathExtension.lowercased() == "indexa" {
                        appState.pendingImportURL = url
                        appState.showImportSheet = true
                    }
                }
                // Error alert
                .alert("Error", isPresented: Binding(
                    get: { appState.alertMessage != nil },
                    set: { if !$0 { appState.alertMessage = nil } }
                )) {
                    Button("OK") { appState.alertMessage = nil }
                } message: {
                    Text(appState.alertMessage ?? "")
                }
                // Optimization report
                .alert("Optimization Complete", isPresented: Binding(
                    get: { appState.lastOptimizationReport != nil },
                    set: { if !$0 { appState.lastOptimizationReport = nil } }
                )) {
                    Button("OK") { appState.lastOptimizationReport = nil }
                } message: {
                    if let report = appState.lastOptimizationReport {
                        Text("""
                            Documents distilled: \(report.documentsDistilled)
                            Summaries generated: \(report.summariesGenerated)
                            Duplicates removed: \(report.duplicatesRemoved)
                            Chunks: \(report.chunksBefore) → \(report.chunksAfter)
                            """)
                    }
                }
                // Delete collection confirmation
                .alert("Delete Collection?", isPresented: Binding(
                    get: { appState.collectionToDelete != nil },
                    set: { if !$0 { appState.collectionToDelete = nil } }
                )) {
                    Button("Cancel", role: .cancel) { appState.collectionToDelete = nil }
                    Button("Delete", role: .destructive) {
                        if let collection = appState.collectionToDelete {
                            appState.deleteCollection(collection)
                        }
                        appState.collectionToDelete = nil
                    }
                } message: {
                    if let collection = appState.collectionToDelete {
                        Text("This will permanently delete \"\(collection.name)\" and all its documents, chunks, and embeddings. This cannot be undone.")
                    }
                }
                // Delete document confirmation
                .alert("Delete Document?", isPresented: Binding(
                    get: { appState.documentToDelete != nil },
                    set: { if !$0 { appState.documentToDelete = nil } }
                )) {
                    Button("Cancel", role: .cancel) { appState.documentToDelete = nil }
                    Button("Delete", role: .destructive) {
                        if let doc = appState.documentToDelete {
                            appState.deleteDocument(doc)
                        }
                        appState.documentToDelete = nil
                    }
                } message: {
                    if let doc = appState.documentToDelete {
                        Text("This will permanently delete \"\(doc.fileName)\" and all its chunks. This cannot be undone.")
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Replace default New menu item
            CommandGroup(replacing: .newItem) {
                Button("New Collection") {
                    appState.showNewCollection = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.chatServerConnected != true && appState.embedServerConnected != true)
            }

            // Settings menu (Cmd+,)
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appState.showSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // File menu additions
            CommandGroup(after: .newItem) {
                Divider()

                Button("Import Bundle...") {
                    openImportPanel()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export Bundle...") {
                    ExportPanel.show(appState: appState)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.collections.isEmpty)

                Button("Back Up Database") {
                    appState.backupDatabase()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Divider()

                Button("Focus Query") {
                    appState.focusQueryField = true
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appState.selectedCollectionId == nil && appState.collections.isEmpty)
            }

            // Help menu — license tier info + Ollama link
            CommandGroup(replacing: .appInfo) {
                Button("About Indexa") {
                    showAboutWindow()
                }
            }

            CommandGroup(after: .help) {
                Divider()

                Link("Ollama Website", destination: URL(string: "https://ollama.com")!)
            }
        }

        // ── Menu bar icon ─────────────────────────────────────────
        MenuBarExtra("Indexa", systemImage: "book.pages.fill") {
            menuBarContent
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        // Status
        let chatStatus = appState.chatServerConnected == true ? "LLM: Online" : (appState.chatServerConnected == false ? "LLM: Offline" : "LLM: Checking...")
        let embedStatus = appState.embedServerConnected == true ? "Embed: Online" : (appState.embedServerConnected == false ? "Embed: Offline" : "Embed: Checking...")
        let statusText = "\(chatStatus) · \(embedStatus)"

        Text(statusText)
            .font(.caption)

        Divider()

        // Collections
        if appState.collections.isEmpty {
            Text("No collections")
                .foregroundColor(.secondary)
        } else {
            Text("Collections")
                .font(.caption)
            ForEach(appState.collections) { collection in
                let count = appState.collectionDocCounts[collection.id] ?? 0
                Button("\(collection.name) (\(count))") {
                    appState.selectCollection(collection.id)
                    showMainWindow()
                }
            }
        }

        Divider()

        // Server toggle
        if appState.isServerRunning {
            Button("Stop Server (:" + String(appState.serverPort) + ")") {
                Task { await appState.stopServer() }
            }
        } else {
            Button("Start Server") {
                Task { await appState.startServer() }
            }
        }

        Divider()

        Button("Open Indexa") {
            showMainWindow()
        }
        .keyboardShortcut("o")

        Button("Settings...") {
            showMainWindow()
            appState.showSettingsSheet = true
        }

        Divider()

        Button("Quit Indexa") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func showAboutWindow() {
        let brandTeal = NSColor(red: 0.22, green: 0.75, blue: 0.91, alpha: 1.0)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About Indexa"
        panel.isReleasedWhenClosed = false
        panel.center()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let view = NSHostingController(rootView:
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.16, blue: 0.20),
                                    Color(red: 0.08, green: 0.09, blue: 0.11)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 64, height: 64)
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(brandTeal))
                }

                Text("Indexa")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Local Knowledge Base")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("© 2026 King Harrison")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 300, height: 220)
        )

        panel.contentViewController = view
        panel.makeKeyAndOrderFront(nil)
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
}
