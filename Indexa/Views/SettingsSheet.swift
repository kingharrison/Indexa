import SwiftUI

struct SettingsSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    @State private var showResetConfirmation = false
    @State private var hasUnsavedChanges = false

    // LLM server fields
    @State private var chatURL: String = ""
    @State private var chatFormat: APIFormat = .ollama
    @State private var chatAPIKey: String = ""
    @State private var isChatTesting = false
    @State private var chatTestResult: Bool? = nil

    // Remote server fields
    @State private var isAddingRemoteServer = false
    @State private var editingRemoteServerId: UUID? = nil
    @State private var remoteServerName: String = ""
    @State private var remoteServerURL: String = ""
    @State private var remoteServerAPIKey: String = ""
    @State private var isRemoteTesting = false
    @State private var remoteTestResult: Bool? = nil

    // Embed server fields
    @State private var embedURL: String = ""
    @State private var embedFormat: APIFormat = .ollama
    @State private var embedAPIKey: String = ""
    @State private var embedModel: String = ""
    @State private var isEmbedTesting = false
    @State private var embedTestResult: Bool? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar ──────────────────────────────────────────────
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 1. CHAT SERVER
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        chatSection
                    }

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 2. EMBED SERVER
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        embedSection
                    }

                    // Save button for Chat + Embed changes
                    HStack {
                        if hasUnsavedChanges {
                            Text("Unsaved changes")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Button("Save & Reconnect") {
                            saveToProvider()
                            hasUnsavedChanges = false
                            Task { await appState.reconnect() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasUnsavedChanges)
                    }

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 3. HTTP API SERVER
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        httpAPISection
                    }

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 4. MCP SERVER
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        mcpSection
                    }

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 5. REMOTE SERVERS
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        remoteServersSection
                    }

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 6. SEARCH
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        searchSection
                    }

                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    // 6. DATA
                    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    SettingsCard {
                        dataSection
                    }

                    // ── Other ────────────────────────────────────────
                    Divider()
                    appearanceSection
                    Divider()
                    dangerZoneSection
                }
                .padding(20)
            }
        }
        .frame(width: 540, height: 750)
        .onAppear { loadFromProvider() }
    }

    // MARK: - Load / Save

    private func loadFromProvider() {
        let active = appState.activeProvider ?? .defaultOllama
        chatURL = active.chatServer.baseURL
        chatFormat = active.chatServer.apiFormat
        chatAPIKey = active.chatServer.apiKey ?? ""
        embedURL = active.embedServer.baseURL
        embedFormat = active.embedServer.apiFormat
        embedAPIKey = active.embedServer.apiKey ?? ""
        embedModel = active.embedModel
    }

    private func saveToProvider() {
        let active = appState.activeProvider ?? .defaultOllama
        let updated = ProviderConfig(
            id: active.id,
            name: active.name,
            isDefault: active.isDefault,
            chatServer: ServerConfig(
                baseURL: chatURL,
                apiFormat: chatFormat,
                apiKey: chatAPIKey.isEmpty ? nil : chatAPIKey
            ),
            embedServer: ServerConfig(
                baseURL: embedURL,
                apiFormat: embedFormat,
                apiKey: embedAPIKey.isEmpty ? nil : embedAPIKey
            ),
            embedModel: embedModel
        )
        appState.updateProvider(updated)
    }

    private func testChatConnection() {
        isChatTesting = true
        chatTestResult = nil
        let server = ServerConfig(baseURL: chatURL, apiFormat: chatFormat, apiKey: chatAPIKey.isEmpty ? nil : chatAPIKey)
        Task {
            let service = OllamaService(baseURL: server.baseURL, apiFormat: server.apiFormat, apiKey: server.apiKey)
            do {
                _ = try await service.listModels()
                chatTestResult = true
            } catch {
                chatTestResult = false
            }
            isChatTesting = false
        }
    }

    private func testEmbedConnection() {
        isEmbedTesting = true
        embedTestResult = nil
        let server = ServerConfig(baseURL: embedURL, apiFormat: embedFormat, apiKey: embedAPIKey.isEmpty ? nil : embedAPIKey)
        Task {
            let service = OllamaService(baseURL: server.baseURL, apiFormat: server.apiFormat, apiKey: server.apiKey)
            do {
                _ = try await service.listModels()
                embedTestResult = true
            } catch {
                embedTestResult = false
            }
            isEmbedTesting = false
        }
    }

    // MARK: - 1. LLM Server

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                icon: "bubble.left.and.text.bubble.right",
                title: "LLM Server",
                subtitle: "Connects to an LLM for answering questions and distillation.",
                status: appState.chatServerConnected
            )

            LabeledField("Server URL") {
                TextField("http://localhost:11434", text: $chatURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: chatURL) { hasUnsavedChanges = true }
            }

            LabeledField("API Format") {
                Picker("", selection: $chatFormat) {
                    ForEach(APIFormat.allCases, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: chatFormat) { hasUnsavedChanges = true }
            }

            if chatFormat == .openAI {
                LabeledField("API Key") {
                    SecureField("sk-... (optional)", text: $chatAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: chatAPIKey) { hasUnsavedChanges = true }
                }
            }

            TestConnectionButton(
                label: "Test Connection",
                isTesting: isChatTesting,
                result: chatTestResult,
                isDisabled: chatURL.isEmpty
            ) {
                testChatConnection()
            }
        }
    }

    // MARK: - 2. Embed Server

    private var embedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                icon: "arrow.triangle.branch",
                title: "Embed Server",
                subtitle: "Connects to a model for generating document embeddings.",
                status: appState.embedServerConnected
            )

            LabeledField("Server URL") {
                TextField("http://localhost:11434", text: $embedURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: embedURL) { hasUnsavedChanges = true }
            }

            LabeledField("API Format") {
                Picker("", selection: $embedFormat) {
                    ForEach(APIFormat.allCases, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: embedFormat) { hasUnsavedChanges = true }
            }

            if embedFormat == .openAI {
                LabeledField("API Key") {
                    SecureField("sk-... (optional)", text: $embedAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: embedAPIKey) { hasUnsavedChanges = true }
                }
            }

            LabeledField("Embed Model") {
                TextField("nomic-embed-text", text: $embedModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: embedModel) { hasUnsavedChanges = true }
            }

            TestConnectionButton(
                label: "Test Connection",
                isTesting: isEmbedTesting,
                result: embedTestResult,
                isDisabled: embedURL.isEmpty
            ) {
                testEmbedConnection()
            }
        }
    }

    // MARK: - 3. HTTP API Server

    private var httpAPISection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                icon: "network",
                title: "HTTP API Server",
                subtitle: "Exposes your knowledge base as a REST API and OpenAI-compatible endpoint for other apps.",
                status: appState.isServerRunning ? true : nil
            )

            HStack(spacing: 12) {
                Toggle("Enable", isOn: Binding(
                    get: { appState.isServerRunning },
                    set: { newValue in
                        Task {
                            if newValue { await appState.startServer() }
                            else { await appState.stopServer() }
                        }
                    }
                ))
                .toggleStyle(.switch)

                Spacer()

                if appState.isServerRunning {
                    Text(verbatim: "Running on port \(appState.serverPort)")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("Port:")
                    .font(.callout)
                TextField("11435", text: Binding(
                    get: { String(appState.serverPort) },
                    set: { if let val = UInt16($0) { appState.serverPort = val } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .disabled(appState.isServerRunning)
                .onChange(of: appState.serverPort) {
                    appState.saveServerSettings()
                }

                Toggle("Auto-start", isOn: $state.serverAutoStart)
                    .font(.callout)
                    .onChange(of: appState.serverAutoStart) {
                        appState.saveServerSettings()
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Key (optional):")
                    .font(.callout)
                HStack(spacing: 8) {
                    SecureField("Leave empty for no auth", text: $state.serverAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isServerRunning)
                        .onChange(of: appState.serverAPIKey) {
                            appState.saveServerSettings()
                        }
                    Button("Generate") {
                        appState.serverAPIKey = UUID().uuidString.lowercased()
                        appState.saveServerSettings()
                    }
                    .font(.caption)
                    .disabled(appState.isServerRunning)
                }
                Text("When set, clients must send Authorization: Bearer <key>")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = appState.serverError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if appState.isServerRunning {
                let base = "http://localhost:" + String(appState.serverPort)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoints:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    EndpointRow(method: "GET", path: "\(base)/v1/health")
                    EndpointRow(method: "GET", path: "\(base)/v1/collections")
                    EndpointRow(method: "POST", path: "\(base)/v1/query")
                    Divider()
                    Text("OpenAI-Compatible:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    EndpointRow(method: "GET", path: "\(base)/v1/models")
                    EndpointRow(method: "POST", path: "\(base)/v1/chat/completions")
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - 4. MCP Server

    @State private var lmStudioCopied = false
    @State private var mcpURLCopied = false

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                icon: "cpu",
                title: "MCP Server",
                subtitle: "Connect AI tools to your knowledge base via the Model Context Protocol.",
                status: appState.isServerRunning ? true : nil
            )

            if appState.isServerRunning {
                let base = "http://localhost:" + String(appState.serverPort)

                // ── LM Studio / Claude Desktop ───────────────────
                VStack(alignment: .leading, spacing: 10) {
                    Label("LM Studio / Claude Desktop", systemImage: "sparkle")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            stepBadge("1")
                            Text("Make sure **Node.js** is installed (needed for the MCP bridge)")
                                .font(.caption)
                        }
                        HStack(alignment: .top, spacing: 6) {
                            stepBadge("2")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("**LM Studio**: Open the **Program** tab → **Install → Edit mcp.json**")
                                    .font(.caption)
                                Text("**Claude Desktop**: Open **Settings → Developer → Edit Config**")
                                    .font(.caption)
                            }
                        }
                        HStack(alignment: .top, spacing: 6) {
                            stepBadge("3")
                            Text("Paste this inside the `\"mcpServers\"` block:")
                                .font(.caption)
                        }
                    }

                    let bridgeConfig = """
                    "indexa": {
                      "command": "npx",
                      "args": ["-y", "mcp-remote", "\(base)/mcp/sse"]
                    }
                    """

                    HStack(alignment: .top, spacing: 0) {
                        Text(bridgeConfig)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bridgeConfig, forType: .string)
                            lmStudioCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                lmStudioCopied = false
                            }
                        } label: {
                            Image(systemName: lmStudioCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(lmStudioCopied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    HStack(alignment: .top, spacing: 6) {
                        stepBadge("4")
                        Text("Save the file and restart the app")
                            .font(.caption)
                    }

                    Text("This uses **mcp-remote** to bridge Indexa's SSE endpoint to the stdio transport these apps require. Your models will have access to **query**, **search**, and **list_collections** tools.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
                )

                // ── Cursor / SSE-compatible Clients ──────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cursor / Other SSE Clients")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("For apps that support SSE transport directly (like Cursor), use this endpoint:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text(verbatim: "\(base)/mcp/sse")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Spacer()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(base)/mcp/sse", forType: .string)
                            mcpURLCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                mcpURLCopied = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mcpURLCopied ? "checkmark" : "doc.on.doc")
                                Text(mcpURLCopied ? "Copied" : "Copy")
                            }
                            .font(.caption)
                            .foregroundColor(mcpURLCopied ? .green : .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    Text("Tools: **query** · **search** · **list_collections**")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Enable the HTTP API Server above to activate MCP.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func stepBadge(_ number: String) -> some View {
        Text(number)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 18, height: 18)
            .background(Color.accentColor)
            .clipShape(Circle())
    }

    // MARK: - 5. Remote Servers

    private var remoteServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Remote Servers", systemImage: "network")
                .font(.headline)

            Text("Connect to other Indexa instances to query their collections remotely.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(appState.remoteServers) { server in
                HStack(spacing: 8) {
                    Circle()
                        .fill(server.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(server.baseURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    let collectionCount = appState.remoteCollections[server.id]?.count ?? 0
                    if server.isConnected && collectionCount > 0 {
                        Text("\(collectionCount) collection\(collectionCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        editingRemoteServerId = server.id
                        remoteServerName = server.name
                        remoteServerURL = server.baseURL
                        remoteServerAPIKey = server.apiKey ?? ""
                        isAddingRemoteServer = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button {
                        appState.deleteRemoteServer(server.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red.opacity(0.7))

                    Button {
                        Task { await appState.connectRemoteServer(server.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            if isAddingRemoteServer {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledField("Server Name") {
                        TextField("Home Mac Mini", text: $remoteServerName)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledField("Server URL") {
                        TextField("http://192.168.1.100:11435", text: $remoteServerURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledField("API Key") {
                        SecureField("Leave empty if none", text: $remoteServerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 12) {
                        Button {
                            isRemoteTesting = true
                            remoteTestResult = nil
                            Task {
                                let result = await appState.testRemoteServer(
                                    baseURL: remoteServerURL,
                                    apiKey: remoteServerAPIKey.isEmpty ? nil : remoteServerAPIKey
                                )
                                remoteTestResult = result
                                isRemoteTesting = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isRemoteTesting {
                                    ProgressView().controlSize(.small)
                                } else if let result = remoteTestResult {
                                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(result ? .green : .red)
                                }
                                Text("Test Connection")
                            }
                            .font(.caption)
                        }
                        .disabled(remoteServerURL.isEmpty || isRemoteTesting)

                        Spacer()

                        Button("Cancel") {
                            isAddingRemoteServer = false
                            editingRemoteServerId = nil
                            remoteServerName = ""
                            remoteServerURL = ""
                            remoteServerAPIKey = ""
                            remoteTestResult = nil
                        }
                        .font(.caption)

                        Button(editingRemoteServerId != nil ? "Update" : "Add Server") {
                            if let editId = editingRemoteServerId {
                                appState.updateRemoteServer(RemoteServer(
                                    id: editId,
                                    name: remoteServerName,
                                    baseURL: remoteServerURL,
                                    apiKey: remoteServerAPIKey.isEmpty ? nil : remoteServerAPIKey
                                ))
                            } else {
                                appState.addRemoteServer(RemoteServer(
                                    name: remoteServerName,
                                    baseURL: remoteServerURL,
                                    apiKey: remoteServerAPIKey.isEmpty ? nil : remoteServerAPIKey
                                ))
                            }
                            isAddingRemoteServer = false
                            editingRemoteServerId = nil
                            remoteServerName = ""
                            remoteServerURL = ""
                            remoteServerAPIKey = ""
                            remoteTestResult = nil
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .disabled(remoteServerName.isEmpty || remoteServerURL.isEmpty)
                    }
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.05))
                .cornerRadius(8)
            } else {
                Button {
                    isAddingRemoteServer = true
                    editingRemoteServerId = nil
                    remoteServerName = ""
                    remoteServerURL = ""
                    remoteServerAPIKey = ""
                    remoteTestResult = nil
                } label: {
                    Label("Add Remote Server", systemImage: "plus")
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 6. Search

    private var searchSection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 12) {
            Label("Search", systemImage: "magnifyingglass")
                .font(.headline)

            Text("Configure how Indexa retrieves relevant documents when answering questions.")
                .font(.caption)
                .foregroundColor(.secondary)

            LabeledField("Search Mode") {
                Picker("", selection: $state.searchMode) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: appState.searchMode) {
                    appState.saveSearchSettings()
                }
            }

            Text(appState.searchMode == .hybrid
                 ? "Combines keyword matching (BM25) with semantic similarity for better results on names, acronyms, and technical terms."
                 : "Uses vector embeddings to find semantically similar content. Best for natural language questions.")
                .font(.caption2)
                .foregroundColor(.secondary)

            LabeledField("Results per Query") {
                TextField("10", value: $state.searchTopK, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: appState.searchTopK) {
                        appState.searchTopK = max(1, min(100, appState.searchTopK))
                        appState.saveSearchSettings()
                    }
            }

            Text("Number of chunks retrieved per query (1–100). Higher values find more sources but increase latency. Default: 10.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            Toggle("Re-ranking", isOn: $state.enableReranking)
                .font(.callout)
                .onChange(of: appState.enableReranking) {
                    appState.saveSearchSettings()
                }

            Text("Retrieves extra candidates and uses the LLM to score them for relevance. Improves accuracy but adds 5–15 seconds of latency.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Toggle("Query Decomposition", isOn: $state.enableQueryDecomposition)
                .font(.callout)
                .onChange(of: appState.enableQueryDecomposition) {
                    appState.saveSearchSettings()
                }

            Text("Breaks complex questions into sub-queries for broader retrieval. Best for compound questions like \"What is X and how does it compare to Y?\" Adds one extra LLM call.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            Toggle("Auto-distill on Ingest", isOn: $state.autoDistillOnIngest)
                .font(.callout)
                .onChange(of: appState.autoDistillOnIngest) {
                    appState.saveSearchSettings()
                }

            Text("Automatically distill every new document after ingestion. Optimizes chunks for retrieval but adds processing time per document.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 6. Data Management

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Data", systemImage: "externaldrive")
                .font(.headline)

            Text("Back up your knowledge base or restore from a previous backup.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Back Up Now") {
                    appState.backupDatabase()
                }
                .buttonStyle(.bordered)
            }

            let backups = appState.listBackups()
            if !backups.isEmpty {
                Text("Recent backups:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                ForEach(backups.prefix(5), id: \.absoluteString) { backup in
                    HStack {
                        Text(backup.lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button("Restore") {
                            appState.restoreFromBackup(backup)
                            dismiss()
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "paintbrush")
                .font(.headline)

            Toggle("Hide Dock icon (menu bar only)", isOn: Binding(
                get: { NSApplication.shared.activationPolicy() == .accessory },
                set: { hideFromDock in
                    NSApplication.shared.setActivationPolicy(hideFromDock ? .accessory : .regular)
                    UserDefaults.standard.set(hideFromDock, forKey: "hideFromDock")
                    if !hideFromDock {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
            ))
            .font(.callout)

            Text("When enabled, Indexa only appears in the menu bar. Use the menu bar icon to open the window.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.red)

            Text("Permanently delete all collections, documents, embeddings, and settings. This cannot be undone.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Delete All Data...", role: .destructive) {
                showResetConfirmation = true
            }
            .buttonStyle(.bordered)
            .alert("Delete All Data?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Everything", role: .destructive) {
                    appState.resetAllData()
                    dismiss()
                }
            } message: {
                Text("This will permanently delete all collections, documents, chunks, and embeddings. Your license key and provider settings will be preserved. This cannot be undone.")
            }
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let status: Bool?

    private var statusColor: Color {
        switch status {
        case true: return .green
        case false: return .red
        case nil: return .gray
        }
    }

    private var statusText: String {
        switch status {
        case true: return "Online"
        case false: return "Offline"
        case nil: return "Off"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Settings Card

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Test Connection Button

private struct TestConnectionButton: View {
    let label: String
    let isTesting: Bool
    let result: Bool?
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                action()
            } label: {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Text(label)
                }
            }
            .font(.caption)
            .disabled(isDisabled || isTesting)

            if let result {
                HStack(spacing: 4) {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(result ? "Connected" : "Failed")
                }
                .font(.caption)
                .foregroundColor(result ? .green : .red)
            }
        }
    }
}

// MARK: - Endpoint Row

private struct EndpointRow: View {
    let method: String
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Text(method)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .leading)

            if let url = URL(string: path) {
                Link(destination: url) {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .underline()
                }
            } else {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy URL")
        }
    }
}

// MARK: - Helper

private struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            content
        }
    }
}
