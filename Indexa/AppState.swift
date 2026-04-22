import Foundation
import SwiftUI
import Observation
import CryptoKit
import CommonCrypto

@Observable
@MainActor
class AppState {
    // ── Provider state ───────────────────────────────────────────────────────
    var providers: [ProviderConfig] = []
    var activeProviderId: UUID? = nil
    var chatServerConnected: Bool? = nil    // nil = checking, false = failed, true = ok
    var embedServerConnected: Bool? = nil   // nil = checking, false = failed, true = ok

    /// Legacy convenience — true if chat server is connected.
    var providerConnected: Bool? { chatServerConnected }
    var availableModels: [OllamaService.ModelInfo] = []
    var showSettingsSheet = false

    var activeProvider: ProviderConfig? {
        providers.first(where: { $0.id == activeProviderId })
    }

    var activeProviderName: String {
        activeProvider?.name ?? "Ollama"
    }

    // ── Collections & documents ───────────────────────────────────────────────
    var collections: [Collection] = []
    var selectedCollectionId: UUID? = nil
    var documentsInSelectedCollection: [IndexedDocument] = []
    var collectionDocCounts: [UUID: Int] = [:]

    // ── Ingestion state ───────────────────────────────────────────────────────
    var isIngesting = false
    var ingestionPhase = ""
    var ingestionProgress: (current: Int, total: Int) = (0, 0)

    // ── Distillation state ──────────────────────────────────────────────
    var isDistilling = false
    var distillationPhase = ""
    var distillationProgress: (current: Int, total: Int) = (0, 0)
    private var distillationTask: Task<Void, Never>? = nil
    var distillationStartTime: Date? = nil

    // ── Query state ───────────────────────────────────────────────────────────
    var queryText = ""
    var isQuerying = false
    var lastResult: QueryResult? = nil
    var queryError: String? = nil
    var conversationHistory: [ConversationMessage] = []
    var streamingAnswer: String = ""

    // ── Services (initialized eagerly so no force-unwrap crashes) ─────────────
    private(set) var ollama: OllamaService
    private(set) var vectorStore: VectorStore
    private(set) var knowledgeEngine: KnowledgeEngine
    private(set) var webScraper: WebScraper
    private(set) var refreshScheduler: RefreshScheduler

    // ── Selected chat model (for generation) ─────────────────────────────────
    var selectedChatModel: String = "llama3.2"

    // ── Web URL ingestion state ───────────────────────────────────────────────
    var isAddingURL = false
    var urlIngestionError: String? = nil

    // ── Crawl state ───────────────────────────────────────────────────────────
    var isCrawling = false
    var crawlPhase = ""
    var crawlProgress: (discovered: Int, fetched: Int, ingested: Int, maxPages: Int) = (0, 0, 0, 0)
    private var crawlTask: Task<Void, Never>? = nil

    // ── Refresh state ─────────────────────────────────────────────────────────
    var refreshStatus: String? = nil

    // ── Embed model state ────────────────────────────────────────────────────
    var embedModelMissing = false
    var isPullingModel = false
    var pullModelStatus = ""

    // ── Search settings ────────────────────────────────────────────────────────
    var searchMode: SearchMode = .hybrid
    var enableReranking = false
    var enableQueryDecomposition = false
    var autoDistillOnIngest = false
    var searchTopK: Int = 10

    // ── Optimization state ────────────────────────────────────────────────────
    var isOptimizing = false
    var optimizationPhase = ""
    var optimizationProgress: (current: Int, total: Int) = (0, 0)
    var lastOptimizationReport: OptimizationReport? = nil
    private var optimizationTask: Task<Void, Never>? = nil

    // ── HTTP server state ─────────────────────────────────────────────────────
    var isServerRunning = false
    var serverPort: UInt16 = 11435
    var serverAutoStart = false
    var serverAPIKey: String = ""
    private var httpServer: HTTPServer? = nil

    // ── Remote Indexa servers ─────────────────────────────────────────────
    var remoteServers: [RemoteServer] = []
    var remoteCollections: [UUID: [RemoteCollection]] = [:]
    var selectedRemoteCollection: (serverId: UUID, collectionId: UUID)? = nil
    private var remoteServices: [UUID: RemoteIndexaService] = [:]
    var isRemoteQuerying = false
    var remoteQueryError: String? = nil
    var remoteConversationHistory: [ConversationMessage] = []
    var remoteLastSources: [RemoteSource] = []
    var remoteLastSourcesMasked: Bool = false

    // ── UI alerts & confirmations ──────────────────────────────────────────
    var alertMessage: String? = nil
    var collectionToDelete: Collection? = nil
    var documentToDelete: IndexedDocument? = nil
    var showNewCollection = false
    var focusQueryField = false

    // ── Protection state ─────────────────────────────────────────────────────
    /// Collections that have been unlocked with the correct password this session.
    var unlockedCollectionIds: Set<UUID> = []
    /// In-memory cache of decrypted Content Encryption Keys for encrypted collections.
    private var cachedCEKs: [UUID: SymmetricKey] = [:]
    /// Controls showing the password unlock modal.
    var showPasswordPrompt = false
    /// Controls showing the set/change protection sheet.
    var showProtectionSheet = false
    /// The collection ID for the protection/unlock sheet.
    var passwordPromptCollectionId: UUID? = nil

    // ── Computed ──────────────────────────────────────────────────────────────
    var selectedCollection: Collection? {
        collections.first(where: { $0.id == selectedCollectionId })
    }

    // MARK: - Initialization

    init() {
        // Load saved providers from UserDefaults
        let loadedProviders = Self.loadProviders()
        let loadedActiveId = UserDefaults.standard.string(forKey: "activeProviderId")
            .flatMap { UUID(uuidString: $0) }

        let providerList = loadedProviders.isEmpty ? [ProviderConfig.defaultOllama] : loadedProviders
        let activeId = loadedActiveId ?? providerList.first?.id

        self.providers = providerList
        self.activeProviderId = activeId

        let active = providerList.first(where: { $0.id == activeId }) ?? .defaultOllama

        let chatService = Self.makeService(from: active.chatServer)
        let embedService = Self.makeService(from: active.embedServer)
        let vectorStore = VectorStore()
        let webScraper = WebScraper()
        let knowledgeEngine = KnowledgeEngine(
            ollama: chatService,
            vectorStore: vectorStore,
            embedModel: active.embedModel,
            embedOllama: active.usesSameServer ? nil : embedService
        )
        self.ollama = chatService
        self.vectorStore = vectorStore
        self.webScraper = webScraper
        self.knowledgeEngine = knowledgeEngine
        self.refreshScheduler = RefreshScheduler(
            vectorStore: vectorStore,
            knowledgeEngine: knowledgeEngine,
            webScraper: webScraper
        )

        // Load server settings
        self.serverPort = UInt16(UserDefaults.standard.integer(forKey: "serverPort"))
        if serverPort == 0 { serverPort = 11435 }
        self.serverAutoStart = UserDefaults.standard.bool(forKey: "serverAutoStart")
        self.serverAPIKey = UserDefaults.standard.string(forKey: "serverAPIKey") ?? ""

        // Load search settings
        if let modeStr = UserDefaults.standard.string(forKey: "searchMode"),
           let mode = SearchMode(rawValue: modeStr) {
            self.searchMode = mode
        }
        self.enableReranking = UserDefaults.standard.bool(forKey: "enableReranking")
        self.enableQueryDecomposition = UserDefaults.standard.bool(forKey: "enableQueryDecomposition")
        self.autoDistillOnIngest = UserDefaults.standard.bool(forKey: "autoDistillOnIngest")
        let savedTopK = UserDefaults.standard.integer(forKey: "searchTopK")
        self.searchTopK = savedTopK > 0 ? savedTopK : 10

        // Load remote servers
        if let data = UserDefaults.standard.data(forKey: "remoteServers"),
           let servers = try? JSONDecoder().decode([RemoteServer].self, from: data) {
            self.remoteServers = servers
        }
    }

    /// Create an OllamaService from a ServerConfig.
    private static func makeService(from server: ServerConfig) -> OllamaService {
        OllamaService(baseURL: server.baseURL, apiFormat: server.apiFormat, apiKey: server.apiKey)
    }

    func bootstrap() async {
        // Re-create services from active provider config
        let active = activeProvider ?? .defaultOllama
        ollama = Self.makeService(from: active.chatServer)
        let embedService = active.usesSameServer ? nil : Self.makeService(from: active.embedServer)
        knowledgeEngine = KnowledgeEngine(ollama: ollama, vectorStore: vectorStore, embedModel: active.embedModel, embedOllama: embedService)
        refreshScheduler = RefreshScheduler(
            vectorStore: vectorStore,
            knowledgeEngine: knowledgeEngine,
            webScraper: webScraper,
            encryptionKeyProvider: { [weak self] collectionId in
                guard let appState = self else { return nil }
                return await MainActor.run { appState.encryptionKey(for: collectionId) }
            }
        )

        try? vectorStore.createTablesIfNeeded()

        // One-time FTS5 index migration for existing data
        if !UserDefaults.standard.bool(forKey: "fts5MigrationDone") {
            try? vectorStore.populateFTSIndex()
            UserDefaults.standard.set(true, forKey: "fts5MigrationDone")
        }

        // Rebuild FTS5 with porter stemming tokenizer
        if !UserDefaults.standard.bool(forKey: "fts5PorterMigrationDone") {
            try? vectorStore.rebuildFTSWithPorter()
            UserDefaults.standard.set(true, forKey: "fts5PorterMigrationDone")
        }

        // One-time sort_order migration for existing collections
        if !UserDefaults.standard.bool(forKey: "sortOrderMigrationDone") {
            try? vectorStore.initializeSortOrder()
            UserDefaults.standard.set(true, forKey: "sortOrderMigrationDone")
        }

        // Load saved collections
        collections = (try? vectorStore.loadCollections()) ?? []
        refreshDocCounts()

        // Load CEKs from Keychain for encrypted collections
        for collection in collections where collection.isEncrypted {
            if let cek = CryptoManager.loadCEKFromKeychain(collectionId: collection.id) {
                cachedCEKs[collection.id] = cek
            }
        }

        // Check provider connection
        await checkProviderConnection()

        // Start background refresh scheduler
        await refreshScheduler.setChatModel(selectedChatModel)
        await refreshScheduler.start()

        // Auto-start HTTP server if enabled
        if serverAutoStart {
            await startServer()
        }

        // Connect to configured remote servers
        await refreshAllRemoteServers()
    }

    // MARK: - Provider connection

    func checkProviderConnection() async {
        chatServerConnected = nil
        embedServerConnected = nil
        embedModelMissing = false
        let active = activeProvider ?? .defaultOllama

        // Check chat server
        do {
            let models = try await ollama.listModels()
            availableModels = models
            chatServerConnected = true

            if let chatModel = models.first(where: { !$0.name.contains("embed") }) {
                selectedChatModel = chatModel.name
                await refreshScheduler.setChatModel(chatModel.name)
            }
        } catch {
            chatServerConnected = false
        }

        // Check embed server (may be the same or different)
        if active.usesSameServer {
            embedServerConnected = chatServerConnected
            if chatServerConnected == true {
                let hasEmbedModel = availableModels.contains(where: { $0.name.starts(with: active.embedModel) })
                embedModelMissing = !hasEmbedModel
            }
        } else {
            do {
                let embedService = Self.makeService(from: active.embedServer)
                let embedModels = try await embedService.listModels()
                embedServerConnected = true
                let hasEmbedModel = embedModels.contains(where: { $0.name.starts(with: active.embedModel) })
                embedModelMissing = !hasEmbedModel
            } catch {
                embedServerConnected = false
            }
        }
    }

    func pullEmbedModel() async {
        let active = activeProvider ?? .defaultOllama
        let embedModel = active.embedModel
        isPullingModel = true
        pullModelStatus = "Starting download..."

        // Pull on the embed server (which may be different from chat server)
        let embedService = active.usesSameServer ? ollama : Self.makeService(from: active.embedServer)

        do {
            try await embedService.pullModel(name: embedModel) { status in
                Task { @MainActor [weak self] in
                    self?.pullModelStatus = status
                }
            }
            isPullingModel = false
            pullModelStatus = ""
            await checkProviderConnection()
        } catch {
            pullModelStatus = "Failed: \(error.localizedDescription)"
            isPullingModel = false
        }
    }

    // MARK: - Provider management

    private static func loadProviders() -> [ProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: "providers") else { return [] }
        return (try? JSONDecoder().decode([ProviderConfig].self, from: data)) ?? []
    }

    func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "providers")
        }
        if let activeId = activeProviderId {
            UserDefaults.standard.set(activeId.uuidString, forKey: "activeProviderId")
        }
    }

    func addProvider(_ config: ProviderConfig) {
        providers.append(config)
        saveProviders()
    }

    func updateProvider(_ config: ProviderConfig) {
        if let index = providers.firstIndex(where: { $0.id == config.id }) {
            providers[index] = config
            saveProviders()
            // Reconnect if this is the active provider
            if config.id == activeProviderId {
                Task { await reconnectActiveProvider() }
            }
        }
    }

    func deleteProvider(id: UUID) {
        guard providers.count > 1 else { return }
        guard id != activeProviderId else { return }
        providers.removeAll(where: { $0.id == id })
        saveProviders()
    }

    func switchProvider(to id: UUID) {
        guard providers.contains(where: { $0.id == id }) else { return }
        activeProviderId = id
        saveProviders()
        Task { await reconnectActiveProvider() }
    }

    /// Public entry point to reconnect after settings changes.
    func reconnect() async {
        await reconnectActiveProvider()
    }

    private func reconnectActiveProvider() async {
        let active = activeProvider ?? .defaultOllama
        ollama = Self.makeService(from: active.chatServer)
        let embedService = active.usesSameServer ? nil : Self.makeService(from: active.embedServer)
        knowledgeEngine = KnowledgeEngine(ollama: ollama, vectorStore: vectorStore, embedModel: active.embedModel, embedOllama: embedService)
        refreshScheduler = RefreshScheduler(
            vectorStore: vectorStore,
            knowledgeEngine: knowledgeEngine,
            webScraper: webScraper,
            encryptionKeyProvider: { [weak self] collectionId in
                guard let appState = self else { return nil }
                return await MainActor.run { appState.encryptionKey(for: collectionId) }
            }
        )
        await checkProviderConnection()
        await refreshScheduler.setChatModel(selectedChatModel)
        await refreshScheduler.start()
    }

    func testProviderConnection(_ config: ProviderConfig) async -> Bool {
        let testService = Self.makeService(from: config.chatServer)
        do {
            _ = try await testService.listModels()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Collections

    func createCollection(name: String) {
        // Shift existing sort orders to make room at top
        for i in collections.indices {
            collections[i].sortOrder += 1
        }
        let collection = Collection(name: name, sortOrder: 0)
        try? vectorStore.saveCollection(collection)
        collections.insert(collection, at: 0)
        persistCollectionOrder()
        selectedCollectionId = collection.id
    }

    func duplicateCollection(_ collection: Collection) {
        // If the source collection is encrypted, the duplicate must carry encryption state.
        // Generate a new CEK for the copy so it has independent key material.
        let sourceIsEncrypted = collection.isEncrypted
        let sourceCEK = cachedCEKs[collection.id]

        // Block duplicating encrypted collections if we don't have the CEK (can't decrypt chunks)
        if sourceIsEncrypted && sourceCEK == nil {
            alertMessage = "Cannot duplicate an encrypted collection without unlocking it first."
            return
        }

        var newCollection = Collection(
            name: "\(collection.name) Copy",
            refreshInterval: collection.refreshInterval,
            systemPrompt: collection.systemPrompt
        )

        do {
            // If source is encrypted, create a new CEK for the duplicate
            var newCEK: SymmetricKey? = nil
            if sourceIsEncrypted, let oldCEK = sourceCEK,
               let passwordHash = collection.passwordHash {
                newCEK = CryptoManager.generateCEK()
                // We can't wrap with the original password (we don't have it), so use the same
                // wrapped key + salt — the duplicate shares the same password for unlocking.
                newCollection.encryptionKeyWrapped = collection.encryptionKeyWrapped
                newCollection.encryptionSalt = collection.encryptionSalt
                newCollection.isEncrypted = true
                newCollection.passwordHash = passwordHash
                newCollection.protectionLevel = collection.protectionLevel
                // Actually, we must re-encrypt with the NEW CEK, so we need to wrap it.
                // Since we share the same password, re-wrap the new CEK using data from
                // the source. But we don't have the plaintext password. Instead, copy the
                // wrapped old CEK — the duplicate will use the SAME CEK as the source.
                // This is safe: both copies are independently protected, and if one is
                // deleted, the other still has its own wrapped CEK in the DB.
                newCEK = oldCEK  // Use same CEK so the wrapped key in DB matches
            }

            try vectorStore.saveCollection(newCollection)

            // Copy all documents with new IDs, mapping old doc IDs to new ones
            let docs = try vectorStore.loadDocuments(collectionId: collection.id)
            var docIdMap: [UUID: UUID] = [:]

            for doc in docs {
                let newDocId = UUID()
                docIdMap[doc.id] = newDocId
                let newDoc = IndexedDocument(
                    id: newDocId,
                    collectionId: newCollection.id,
                    fileName: doc.fileName,
                    filePath: doc.filePath,
                    fileSize: doc.fileSize,
                    dateIndexed: doc.dateIndexed,
                    chunkCount: doc.chunkCount,
                    sourceType: doc.sourceType,
                    contentHash: doc.contentHash,
                    crawlGroupId: doc.crawlGroupId,
                    summary: doc.summary,
                    enabled: doc.enabled,
                    hasDistilledChunks: doc.hasDistilledChunks,
                    useDistilled: doc.useDistilled
                )
                try vectorStore.saveDocument(newDoc)
            }

            // Copy all chunks with new IDs — content is already encrypted if source was encrypted
            let chunks = try vectorStore.loadChunks(collectionId: collection.id)
            var newChunks: [DocumentChunk] = []
            for chunk in chunks {
                guard let newDocId = docIdMap[chunk.documentId] else { continue }
                newChunks.append(DocumentChunk(
                    documentId: newDocId,
                    collectionId: newCollection.id,
                    content: chunk.content,
                    chunkIndex: chunk.chunkIndex,
                    embedding: chunk.embedding,
                    chunkType: chunk.chunkType
                ))
            }
            if !newChunks.isEmpty {
                // Skip FTS for encrypted collections (content is ciphertext)
                try vectorStore.saveChunks(newChunks, skipFTS: sourceIsEncrypted)
            }

            // Cache the CEK for the new collection and store in Keychain
            if sourceIsEncrypted, let cek = newCEK {
                cachedCEKs[newCollection.id] = cek
                try? CryptoManager.storeCEKInKeychain(cek, collectionId: newCollection.id)
                unlockedCollectionIds.insert(newCollection.id)
            }

            collections.insert(newCollection, at: 0)
            selectedCollectionId = newCollection.id
            refreshDocuments()
        } catch {
            alertMessage = "Failed to duplicate collection: \(error.localizedDescription)"
        }
    }

    func renameCollection(_ collection: Collection, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? vectorStore.renameCollection(id: collection.id, name: name)
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index].name = name
        }
    }

    func updateSystemPrompt(for collectionId: UUID, prompt: String?) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try? vectorStore.updateCollectionSystemPrompt(id: collectionId, systemPrompt: value)
        if let index = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[index].systemPrompt = value
        }
    }

    func deleteCollection(_ collection: Collection) {
        // Clean up encryption key from Keychain and cache
        if collection.isEncrypted {
            CryptoManager.removeCEKFromKeychain(collectionId: collection.id)
            cachedCEKs.removeValue(forKey: collection.id)
        }
        try? vectorStore.deleteCollection(id: collection.id)
        collections.removeAll(where: { $0.id == collection.id })
        unlockedCollectionIds.remove(collection.id)
        if selectedCollectionId == collection.id {
            selectedCollectionId = collections.first?.id
        }
        refreshDocuments()
    }

    func selectCollection(_ id: UUID?) {
        selectedCollectionId = id
        selectedRemoteCollection = nil
        refreshDocuments()
        // Clear previous query results and conversation when switching collections
        clearConversation()
        clearRemoteConversation()
    }

    func refreshDocuments() {
        guard let collectionId = selectedCollectionId else {
            documentsInSelectedCollection = []
            return
        }
        documentsInSelectedCollection = (try? vectorStore.loadDocuments(collectionId: collectionId)) ?? []
        refreshDocCounts()
    }

    func refreshDocCounts() {
        var counts: [UUID: Int] = [:]
        for collection in collections {
            counts[collection.id] = (try? vectorStore.documentCount(collectionId: collection.id)) ?? 0
        }
        collectionDocCounts = counts
    }

    // MARK: - Document ingestion

    func ingestFiles(urls: [URL], collectionId: UUID) async {
        isIngesting = true
        defer {
            isIngesting = false
            ingestionPhase = ""
            ingestionProgress = (0, 0)
        }

        var ingestedDocs: [IndexedDocument] = []

        for url in urls {
            do {
                // Start accessing the security-scoped resource
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let encKey = encryptionKey(for: collectionId)
                let doc = try await knowledgeEngine.ingestDocument(
                    url: url,
                    collectionId: collectionId,
                    chatModel: selectedChatModel,
                    encryptionKey: encKey
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.ingestionPhase = progress.phase
                        self?.ingestionProgress = (progress.current, progress.total)
                    }
                }
                ingestedDocs.append(doc)
            } catch {
                alertMessage = "Failed to ingest \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        refreshDocuments()

        if autoDistillOnIngest, !ingestedDocs.isEmpty {
            autoDistillDocuments(ingestedDocs)
        }
    }

    // MARK: - Query

    func runQuery() async {
        let question = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        queryText = ""
        isQuerying = true
        queryError = nil
        lastResult = nil
        streamingAnswer = ""

        // Add user message to history
        conversationHistory.append(ConversationMessage(role: .user, content: question))

        do {
            let encKey = selectedCollectionId.flatMap { encryptionKey(for: $0) }
            let result = try await knowledgeEngine.query(
                question: question,
                chatModel: selectedChatModel,
                collectionId: selectedCollectionId,
                customSystemPrompt: selectedCollection?.systemPrompt,
                conversationHistory: Array(conversationHistory.dropLast()),
                topK: searchTopK,
                searchMode: searchMode,
                enableReranking: enableReranking,
                enableDecomposition: enableQueryDecomposition,
                maskSources: !canViewSources,
                encryptionKey: encKey,
                onToken: { token in
                    Task { @MainActor [weak self] in
                        self?.streamingAnswer += token
                    }
                }
            )
            streamingAnswer = ""
            lastResult = result
            conversationHistory.append(ConversationMessage(role: .assistant, content: result.answer, sources: result.sources))
        } catch {
            queryError = error.localizedDescription
            streamingAnswer = ""
            if conversationHistory.last?.role == .user {
                conversationHistory.removeLast()
            }
            await checkProviderConnection()
        }

        isQuerying = false
    }

    func clearConversation() {
        conversationHistory.removeAll()
        lastResult = nil
        queryError = nil
    }

    // MARK: - Reset all data

    func resetAllData() {
        // Stop server if running
        Task { await stopServer() }

        // Remove all Keychain entries for encrypted collections
        for collection in collections where collection.isEncrypted {
            CryptoManager.removeCEKFromKeychain(collectionId: collection.id)
        }
        cachedCEKs.removeAll()

        // Clear in-memory state
        clearConversation()
        selectedCollectionId = nil
        documentsInSelectedCollection = []
        collections = []
        collectionDocCounts = [:]
        unlockedCollectionIds.removeAll()

        // Delete the database file
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("Indexa", isDirectory: true).appendingPathComponent("indexa.db").path
        try? FileManager.default.removeItem(atPath: dbPath)

        // Recreate empty tables
        try? vectorStore.createTablesIfNeeded()
    }

    // MARK: - Database Backup

    private var backupDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Indexa", isDirectory: true)
    }

    private var databaseURL: URL {
        backupDirectory.appendingPathComponent("indexa.db")
    }

    /// Create a timestamped backup of the database. Returns the backup URL on success.
    @discardableResult
    func backupDatabase() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let backupURL = backupDirectory.appendingPathComponent("indexa_backup_\(timestamp).db")

        do {
            try FileManager.default.copyItem(at: databaseURL, to: backupURL)
            alertMessage = "Backup created: \(backupURL.lastPathComponent)"
            return backupURL
        } catch {
            alertMessage = "Backup failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// List available backup files, sorted newest first.
    func listBackups() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("indexa_backup_") && $0.pathExtension == "db" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA > dateB
            }
    }

    /// Restore from a backup file. Replaces the current database and reloads state.
    func restoreFromBackup(_ backupURL: URL) {
        Task { await stopServer() }

        clearConversation()
        selectedCollectionId = nil
        documentsInSelectedCollection = []
        collections = []
        collectionDocCounts = [:]
        unlockedCollectionIds.removeAll()
        cachedCEKs.removeAll()

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: databaseURL.path) {
                try fm.removeItem(at: databaseURL)
            }
            try fm.copyItem(at: backupURL, to: databaseURL)

            try? vectorStore.createTablesIfNeeded()
            collections = (try? vectorStore.loadCollections()) ?? []
            refreshDocCounts()
            alertMessage = "Restored from: \(backupURL.lastPathComponent)"
        } catch {
            alertMessage = "Restore failed: \(error.localizedDescription)"
            try? vectorStore.createTablesIfNeeded()
        }
    }

    // MARK: - Collection Reorder

    /// Move collections in the sidebar (called by drag reorder).
    func moveCollections(from source: IndexSet, to destination: Int) {
        collections.move(fromOffsets: source, toOffset: destination)
        persistCollectionOrder()
    }

    private func persistCollectionOrder() {
        let orders = collections.enumerated().map { (index, collection) in
            (id: collection.id, sortOrder: index)
        }
        try? vectorStore.updateCollectionSortOrders(orders)
        for i in collections.indices {
            collections[i].sortOrder = i
        }
    }

    // MARK: - Helpers

    /// Look up a collection's name by ID.
    func collectionName(for collectionId: UUID) -> String? {
        collections.first(where: { $0.id == collectionId })?.name
    }

    // MARK: - Toggle document enabled

    func toggleDocumentEnabled(_ doc: IndexedDocument) {
        let newValue = !doc.enabled
        try? vectorStore.updateDocumentEnabled(id: doc.id, enabled: newValue)
        if let index = documentsInSelectedCollection.firstIndex(where: { $0.id == doc.id }) {
            documentsInSelectedCollection[index].enabled = newValue
        }
    }

    // MARK: - Distillation

    func distillDocument(_ doc: IndexedDocument) {
        guard !isDistilling else { return }

        isDistilling = true
        distillationStartTime = Date()
        distillationPhase = "Starting..."
        distillationProgress = (0, 0)

        let knowledgeEngine = self.knowledgeEngine
        let chatModel = self.selectedChatModel
        let vectorStore = self.vectorStore
        let documentId = doc.id
        let collectionId = doc.collectionId
        let encKey = encryptionKey(for: collectionId)

        distillationTask = Task {
            do {
                try await knowledgeEngine.distillDocument(
                    documentId: documentId,
                    collectionId: collectionId,
                    chatModel: chatModel,
                    encryptionKey: encKey
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.distillationPhase = progress.phase
                        self?.distillationProgress = (progress.current, progress.total)
                    }
                }
            } catch is CancellationError {
                // Clean up partial distilled chunks and checkpoint on cancellation
                try? vectorStore.deleteDistilledChunks(documentId: documentId)
                try? vectorStore.clearDistillCheckpoint(documentId: documentId)
                try? vectorStore.updateDocumentDistillStatus(
                    id: documentId,
                    hasDistilledChunks: false,
                    useDistilled: false
                )
                // Cancelled — no alert needed
            } catch {
                self.alertMessage = "Distillation failed for \(doc.fileName): \(error.localizedDescription)"
            }

            self.isDistilling = false
            self.distillationStartTime = nil
            self.distillationPhase = ""
            self.distillationProgress = (0, 0)
            self.distillationTask = nil
            self.refreshDocuments()
        }
    }

    func cancelDistillation() {
        distillationTask?.cancel()
        distillationPhase = "Cancelling..."
    }

    /// Distill all undistilled documents in a collection.
    func distillAllDocuments(_ collectionId: UUID) {
        let docs = documentsInSelectedCollection.filter { !$0.hasDistilledChunks && $0.enabled }
        guard !isDistilling, !docs.isEmpty else { return }

        isDistilling = true
        distillationStartTime = Date()
        distillationPhase = "Starting distillation..."
        distillationProgress = (0, docs.count)

        let knowledgeEngine = self.knowledgeEngine
        let chatModel = self.selectedChatModel
        let vectorStore = self.vectorStore
        let encKey = encryptionKey(for: collectionId)

        distillationTask = Task {
            for (index, doc) in docs.enumerated() {
                guard !Task.isCancelled else { break }
                self.distillationPhase = "Distilling \(index + 1) of \(docs.count)..."
                self.distillationProgress = (index, docs.count)

                do {
                    try await knowledgeEngine.distillDocument(
                        documentId: doc.id,
                        collectionId: doc.collectionId,
                        chatModel: chatModel,
                        encryptionKey: encKey
                    )
                } catch is CancellationError {
                    try? vectorStore.deleteDistilledChunks(documentId: doc.id)
                    try? vectorStore.clearDistillCheckpoint(documentId: doc.id)
                    try? vectorStore.updateDocumentDistillStatus(
                        id: doc.id, hasDistilledChunks: false, useDistilled: false
                    )
                    break
                } catch {
                    self.alertMessage = "Distillation failed for \(doc.fileName): \(error.localizedDescription)"
                }
            }

            self.isDistilling = false
            self.distillationStartTime = nil
            self.distillationPhase = ""
            self.distillationProgress = (0, 0)
            self.distillationTask = nil
            self.refreshDocuments()
        }
    }

    /// Auto-distill documents after ingestion (when auto-distill is enabled).
    private func autoDistillDocuments(_ docs: [IndexedDocument]) {
        guard !isDistilling else { return }

        isDistilling = true
        distillationStartTime = Date()
        distillationPhase = "Auto-distilling..."
        distillationProgress = (0, docs.count)

        let knowledgeEngine = self.knowledgeEngine
        let chatModel = self.selectedChatModel
        let vectorStore = self.vectorStore
        let encKey = docs.first.flatMap { encryptionKey(for: $0.collectionId) }

        distillationTask = Task {
            for (index, doc) in docs.enumerated() {
                guard !Task.isCancelled else { break }
                self.distillationPhase = "Auto-distilling \(doc.fileName) (\(index + 1)/\(docs.count))"
                self.distillationProgress = (index, docs.count)

                do {
                    try await knowledgeEngine.distillDocument(
                        documentId: doc.id,
                        collectionId: doc.collectionId,
                        chatModel: chatModel,
                        encryptionKey: encKey
                    )
                } catch is CancellationError {
                    try? vectorStore.deleteDistilledChunks(documentId: doc.id)
                    try? vectorStore.clearDistillCheckpoint(documentId: doc.id)
                    try? vectorStore.updateDocumentDistillStatus(
                        id: doc.id, hasDistilledChunks: false, useDistilled: false
                    )
                    break
                } catch {
                    print("Auto-distillation failed for \(doc.fileName): \(error)")
                }
            }

            self.isDistilling = false
            self.distillationStartTime = nil
            self.distillationPhase = ""
            self.distillationProgress = (0, 0)
            self.distillationTask = nil
            self.refreshDocuments()
        }
    }

    func toggleUseDistilled(_ doc: IndexedDocument, useDistilled: Bool) {
        try? vectorStore.updateDocumentUseDistilled(id: doc.id, useDistilled: useDistilled)
        if let index = documentsInSelectedCollection.firstIndex(where: { $0.id == doc.id }) {
            documentsInSelectedCollection[index].useDistilled = useDistilled
        }
    }

    func removeDistillation(_ doc: IndexedDocument) {
        try? vectorStore.deleteDistilledChunks(documentId: doc.id)
        try? vectorStore.clearDistillCheckpoint(documentId: doc.id)
        try? vectorStore.updateDocumentDistillStatus(id: doc.id, hasDistilledChunks: false, useDistilled: false)
        refreshDocuments()
    }

    // MARK: - Delete document

    func deleteDocument(_ doc: IndexedDocument) {
        try? vectorStore.deleteDocument(id: doc.id)
        refreshDocuments()
    }

    // MARK: - Batch operations

    func batchDeleteDocuments(_ ids: Set<UUID>) {
        for id in ids {
            try? vectorStore.deleteDocument(id: id)
        }
        refreshDocuments()
    }

    func batchToggleEnabled(_ ids: Set<UUID>, enabled: Bool) {
        for id in ids {
            try? vectorStore.updateDocumentEnabled(id: id, enabled: enabled)
        }
        refreshDocuments()
    }

    func batchDistillDocuments(_ ids: Set<UUID>) {
        let docs = documentsInSelectedCollection.filter { ids.contains($0.id) }
        guard let first = docs.first else { return }
        // Start distilling the first one; user can queue more after
        distillDocument(first)
    }

    // MARK: - Website bundle operations

    /// Documents organized for display — groups crawled pages into bundles.
    var groupedDocuments: [DocumentListItem] {
        var items: [DocumentListItem] = []
        var processedGroupIds: Set<UUID> = []

        for doc in documentsInSelectedCollection {
            if let groupId = doc.crawlGroupId {
                guard !processedGroupIds.contains(groupId) else { continue }
                processedGroupIds.insert(groupId)
                let pages = documentsInSelectedCollection.filter { $0.crawlGroupId == groupId }
                items.append(.bundle(groupId: groupId, pages: pages))
            } else {
                items.append(.single(doc))
            }
        }
        return items
    }

    func toggleBundleEnabled(groupId: UUID) {
        let pages = documentsInSelectedCollection.filter { $0.crawlGroupId == groupId }
        let allEnabled = pages.allSatisfy(\.enabled)
        let newValue = !allEnabled
        try? vectorStore.updateDocumentsEnabled(crawlGroupId: groupId, enabled: newValue)
        for i in documentsInSelectedCollection.indices {
            if documentsInSelectedCollection[i].crawlGroupId == groupId {
                documentsInSelectedCollection[i].enabled = newValue
            }
        }
    }

    func distillBundle(groupId: UUID) {
        let pages = documentsInSelectedCollection.filter { $0.crawlGroupId == groupId }
        guard !isDistilling, !pages.isEmpty else { return }

        isDistilling = true
        distillationStartTime = Date()
        distillationPhase = "Starting bundle distillation..."
        distillationProgress = (0, pages.count)

        let knowledgeEngine = self.knowledgeEngine
        let chatModel = self.selectedChatModel
        let vectorStore = self.vectorStore
        let encKey = pages.first.flatMap { encryptionKey(for: $0.collectionId) }

        distillationTask = Task {
            for (index, page) in pages.enumerated() {
                guard !Task.isCancelled else { break }
                self.distillationPhase = "Distilling page \(index + 1) of \(pages.count)..."
                self.distillationProgress = (index, pages.count)

                do {
                    try await knowledgeEngine.distillDocument(
                        documentId: page.id,
                        collectionId: page.collectionId,
                        chatModel: chatModel,
                        encryptionKey: encKey
                    )
                } catch is CancellationError {
                    try? vectorStore.deleteDistilledChunks(documentId: page.id)
                    try? vectorStore.clearDistillCheckpoint(documentId: page.id)
                    try? vectorStore.updateDocumentDistillStatus(
                        id: page.id, hasDistilledChunks: false, useDistilled: false
                    )
                    break
                } catch {
                    self.alertMessage = "Distillation failed for \(page.fileName): \(error.localizedDescription)"
                }
            }

            self.isDistilling = false
            self.distillationStartTime = nil
            self.distillationPhase = ""
            self.distillationProgress = (0, 0)
            self.distillationTask = nil
            self.refreshDocuments()
        }
    }

    func deleteBundleGroup(groupId: UUID) {
        try? vectorStore.deleteDocumentGroup(crawlGroupId: groupId)
        refreshDocuments()
    }

    func removeDistillationFromBundle(groupId: UUID) {
        let pages = documentsInSelectedCollection.filter { $0.crawlGroupId == groupId }
        for page in pages {
            try? vectorStore.deleteDistilledChunks(documentId: page.id)
            try? vectorStore.clearDistillCheckpoint(documentId: page.id)
            try? vectorStore.updateDocumentDistillStatus(
                id: page.id, hasDistilledChunks: false, useDistilled: false
            )
        }
        refreshDocuments()
    }

    // MARK: - Web URL ingestion

    func ingestURL(_ urlString: String, collectionId: UUID) async {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else {
            urlIngestionError = "Invalid URL. Please enter a valid http or https URL."
            return
        }

        isIngesting = true
        urlIngestionError = nil
        defer {
            isIngesting = false
            ingestionPhase = ""
            ingestionProgress = (0, 0)
        }

        var ingestedDoc: IndexedDocument?

        do {
            ingestionPhase = "Fetching webpage..."
            let (text, _) = try await webScraper.fetchAndExtract(url: url)

            let encKey = encryptionKey(for: collectionId)
            ingestedDoc = try await knowledgeEngine.ingestDocument(
                url: url,
                collectionId: collectionId,
                sourceType: .web,
                preExtractedText: text,
                chatModel: selectedChatModel,
                encryptionKey: encKey
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.ingestionPhase = progress.phase
                    self?.ingestionProgress = (progress.current, progress.total)
                }
            }
        } catch {
            urlIngestionError = error.localizedDescription
        }

        refreshDocuments()

        if autoDistillOnIngest, let doc = ingestedDoc {
            autoDistillDocuments([doc])
        }
    }

    // MARK: - Web crawling

    func crawlSite(seedURL: String, collectionId: UUID, maxDepth: Int, maxPages: Int) {
        guard !isCrawling, !isIngesting else { return }

        guard let url = URL(string: seedURL),
              url.scheme == "http" || url.scheme == "https",
              let seedHost = url.host?.lowercased() else {
            urlIngestionError = "Invalid URL. Please enter a valid http or https URL."
            return
        }

        isCrawling = true
        crawlPhase = "Starting crawl..."
        crawlProgress = (0, 0, 0, maxPages)
        urlIngestionError = nil

        let webScraper = self.webScraper
        let knowledgeEngine = self.knowledgeEngine
        let chatModel = self.selectedChatModel
        let crawlGroupId = UUID()
        let encKey = encryptionKey(for: collectionId)

        crawlTask = Task {
            var queue: [(url: URL, depth: Int)] = [(url, 0)]
            var visited: Set<String> = [url.absoluteString]
            var pagesFetched = 0
            var pagesIngested = 0

            while !queue.isEmpty, pagesFetched < maxPages {
                guard !Task.isCancelled else { break }

                let (currentURL, currentDepth) = queue.removeFirst()

                pagesFetched += 1
                self.crawlPhase = "Fetching page \(pagesFetched)..."
                self.crawlProgress.fetched = pagesFetched

                do {
                    let result = try await webScraper.fetchAndExtractWithLinks(url: currentURL)

                    // Discover links if we haven't hit max depth
                    if currentDepth < maxDepth {
                        for link in result.links {
                            guard let linkHost = link.host?.lowercased(),
                                  linkHost == seedHost else { continue }
                            let canonical = link.absoluteString
                            if !visited.contains(canonical) {
                                visited.insert(canonical)
                                queue.append((link, currentDepth + 1))
                            }
                        }
                        self.crawlProgress.discovered = visited.count - 1
                    }

                    // Ingest the page
                    guard !Task.isCancelled else { break }
                    self.crawlPhase = "Ingesting page \(pagesFetched)..."

                    _ = try await knowledgeEngine.ingestDocument(
                        url: currentURL,
                        collectionId: collectionId,
                        sourceType: .web,
                        preExtractedText: result.text,
                        chatModel: chatModel,
                        crawlGroupId: crawlGroupId,
                        encryptionKey: encKey
                    )

                    pagesIngested += 1
                    self.crawlProgress.ingested = pagesIngested

                    // Rate limiting
                    try? await Task.sleep(for: .milliseconds(500))

                } catch is CancellationError {
                    break
                } catch {
                    self.alertMessage = "Crawl failed for \(currentURL.absoluteString): \(error.localizedDescription)"
                }
            }

            self.isCrawling = false
            self.crawlPhase = ""
            self.crawlProgress = (0, 0, 0, 0)
            self.crawlTask = nil
            self.refreshDocuments()
        }
    }

    func cancelCrawl() {
        crawlTask?.cancel()
        crawlPhase = "Cancelling..."
    }

    // MARK: - Refresh interval

    func updateRefreshInterval(for collectionId: UUID, interval: RefreshInterval) {
        try? vectorStore.updateCollectionRefreshInterval(id: collectionId, interval: interval)
        if let index = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[index].refreshInterval = interval
        }
    }

    func manualRefresh(collectionId: UUID) async {
        refreshStatus = "Refreshing..."
        await refreshScheduler.refreshCollection(collectionId) { status in
            Task { @MainActor [weak self] in
                self?.refreshStatus = status
            }
        }
        refreshStatus = nil
        refreshDocuments()
    }

    // MARK: - Export / Import bundles

    /// Export state
    var isExporting = false
    var exportError: String? = nil

    /// Import state
    var isImporting = false
    var showImportSheet = false
    var pendingImportURL: URL? = nil
    var importError: String? = nil
    var lastImportResult: BundleManager.ImportResult? = nil

    func exportBundle(
        collectionIds: [UUID],
        password: String?,
        to url: URL
    ) {
        isExporting = true
        exportError = nil

        do {
            _ = try BundleManager.exportBundle(
                selection: .collections(collectionIds),
                to: url,
                password: password,
                vectorStore: vectorStore
            )
        } catch {
            exportError = error.localizedDescription
        }

        isExporting = false
    }

    func exportDocuments(
        documentIds: [UUID],
        collectionId: UUID,
        password: String?,
        to url: URL
    ) {
        isExporting = true
        exportError = nil

        do {
            _ = try BundleManager.exportBundle(
                selection: .documents(documentIds, collectionId: collectionId),
                to: url,
                password: password,
                vectorStore: vectorStore
            )
        } catch {
            exportError = error.localizedDescription
        }

        isExporting = false
    }

    func importBundle(from url: URL, password: String?) {
        isImporting = true
        importError = nil
        lastImportResult = nil

        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let result = try BundleManager.importBundle(
                from: url,
                password: password,
                vectorStore: vectorStore
            )
            lastImportResult = result

            // Refresh collections list
            collections = (try? vectorStore.loadCollections()) ?? []

            // Ensure imported protected collections appear locked
            // (remove from unlocked set so they require password)
            // and load CEKs from Keychain for encrypted collections (mirrors bootstrap)
            for collection in collections {
                print("Import: \(collection.name) — isProtected=\(collection.isProtected), protectionLevel=\(collection.protectionLevel?.rawValue ?? "nil"), passwordHash=\(collection.passwordHash != nil ? "SET" : "nil")")
                if collection.isProtected {
                    unlockedCollectionIds.remove(collection.id)
                }
            }
            for collection in collections where collection.isEncrypted {
                if cachedCEKs[collection.id] == nil,
                   let cek = CryptoManager.loadCEKFromKeychain(collectionId: collection.id) {
                    cachedCEKs[collection.id] = cek
                }
            }
        } catch {
            importError = error.localizedDescription
        }

        isImporting = false
    }

    func peekBundle(at url: URL) -> BundleManager.BundleManifest? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        return try? BundleManager.peekManifest(from: url)
    }

    // MARK: - HTTP Server

    var serverError: String? = nil

    func startServer() async {
        guard !isServerRunning else { return }
        serverError = nil

        let apiKey = serverAPIKey.isEmpty ? nil : serverAPIKey
        let server = HTTPServer(
            port: serverPort,
            knowledgeEngine: knowledgeEngine,
            vectorStore: vectorStore,
            apiKey: apiKey,
            chatModelProvider: { [weak self] in
                guard let appState = self else { return "llama3.2" }
                return await MainActor.run { appState.selectedChatModel }
            },
            serverStatusProvider: { [weak self] in
                guard let appState = self else { return (nil, nil) }
                return await MainActor.run { (appState.chatServerConnected, appState.embedServerConnected) }
            },
            cekProvider: { [weak self] collectionId in
                guard let appState = self else { return nil }
                return await MainActor.run { appState.encryptionKey(for: collectionId) }
            }
        )

        do {
            try await server.start()
            httpServer = server
            isServerRunning = true
            print("HTTP server started on port \(serverPort)")
        } catch {
            serverError = error.localizedDescription
            print("Failed to start HTTP server: \(error.localizedDescription)")
        }
    }

    func stopServer() async {
        await httpServer?.stop()
        httpServer = nil
        isServerRunning = false
    }

    func toggleServer() async {
        if isServerRunning {
            await stopServer()
        } else {
            await startServer()
        }
    }

    func saveServerSettings() {
        UserDefaults.standard.set(Int(serverPort), forKey: "serverPort")
        UserDefaults.standard.set(serverAutoStart, forKey: "serverAutoStart")
        UserDefaults.standard.set(serverAPIKey, forKey: "serverAPIKey")
    }

    func saveSearchSettings() {
        UserDefaults.standard.set(searchMode.rawValue, forKey: "searchMode")
        UserDefaults.standard.set(enableReranking, forKey: "enableReranking")
        UserDefaults.standard.set(enableQueryDecomposition, forKey: "enableQueryDecomposition")
        UserDefaults.standard.set(autoDistillOnIngest, forKey: "autoDistillOnIngest")
        UserDefaults.standard.set(searchTopK, forKey: "searchTopK")
    }

    // MARK: - Remote Servers

    func saveRemoteServers() {
        if let data = try? JSONEncoder().encode(remoteServers) {
            UserDefaults.standard.set(data, forKey: "remoteServers")
        }
    }

    func addRemoteServer(_ server: RemoteServer) {
        remoteServers.append(server)
        saveRemoteServers()
        Task { await connectRemoteServer(server.id) }
    }

    func updateRemoteServer(_ server: RemoteServer) {
        guard let index = remoteServers.firstIndex(where: { $0.id == server.id }) else { return }
        remoteServers[index] = server
        saveRemoteServers()
        remoteServices[server.id] = RemoteIndexaService(baseURL: server.baseURL, apiKey: server.apiKey)
        Task { await connectRemoteServer(server.id) }
    }

    func deleteRemoteServer(_ id: UUID) {
        remoteServers.removeAll(where: { $0.id == id })
        remoteCollections.removeValue(forKey: id)
        remoteServices.removeValue(forKey: id)
        saveRemoteServers()
        if selectedRemoteCollection?.serverId == id {
            selectedRemoteCollection = nil
            clearRemoteConversation()
        }
    }

    func connectRemoteServer(_ serverId: UUID) async {
        guard let index = remoteServers.firstIndex(where: { $0.id == serverId }) else { return }
        let server = remoteServers[index]

        let service = RemoteIndexaService(baseURL: server.baseURL, apiKey: server.apiKey)
        remoteServices[serverId] = service

        do {
            let healthy = try await service.health()
            remoteServers[index].isConnected = healthy
            if healthy {
                let collections = try await service.listCollections()
                remoteCollections[serverId] = collections
            }
        } catch {
            remoteServers[index].isConnected = false
            remoteCollections[serverId] = []
        }
    }

    func refreshAllRemoteServers() async {
        for server in remoteServers {
            await connectRemoteServer(server.id)
        }
    }

    func testRemoteServer(baseURL: String, apiKey: String?) async -> Bool {
        let service = RemoteIndexaService(baseURL: baseURL, apiKey: apiKey)
        do {
            return try await service.health()
        } catch {
            return false
        }
    }

    func selectRemoteCollection(serverId: UUID, collectionId: UUID) {
        selectedCollectionId = nil
        selectedRemoteCollection = (serverId: serverId, collectionId: collectionId)
        clearConversation()
        clearRemoteConversation()
    }

    func remoteCollectionName(serverId: UUID, collectionId: UUID) -> String? {
        remoteCollections[serverId]?.first(where: { $0.id == collectionId })?.name
    }

    func remoteServerName(for serverId: UUID) -> String? {
        remoteServers.first(where: { $0.id == serverId })?.name
    }

    func runRemoteQuery() async {
        guard let remote = selectedRemoteCollection else { return }
        let question = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        queryText = ""
        isRemoteQuerying = true
        remoteQueryError = nil
        remoteLastSources = []
        remoteLastSourcesMasked = false

        remoteConversationHistory.append(ConversationMessage(role: .user, content: question))

        guard let service = remoteServices[remote.serverId] else {
            remoteQueryError = "Remote server not connected"
            isRemoteQuerying = false
            return
        }

        do {
            let result = try await service.query(
                question: question,
                collectionId: remote.collectionId,
                searchMode: searchMode
            )
            remoteLastSources = result.sources
            remoteLastSourcesMasked = result.sourcesMasked
            remoteConversationHistory.append(
                ConversationMessage(role: .assistant, content: result.answer)
            )
        } catch {
            remoteQueryError = error.localizedDescription
            if remoteConversationHistory.last?.role == .user {
                remoteConversationHistory.removeLast()
            }
        }

        isRemoteQuerying = false
    }

    func clearRemoteConversation() {
        remoteConversationHistory.removeAll()
        remoteLastSources = []
        remoteLastSourcesMasked = false
        remoteQueryError = nil
    }

    // MARK: - Collection Optimization

    func optimizeCollection(_ collectionId: UUID) {
        guard !isOptimizing, !isDistilling, !isIngesting else { return }

        isOptimizing = true
        optimizationPhase = "Preparing..."
        optimizationProgress = (0, 0)
        lastOptimizationReport = nil

        let knowledgeEngine = self.knowledgeEngine
        let vectorStore = self.vectorStore
        let chatModel = self.selectedChatModel
        let ollama = self.ollama
        let encKey = encryptionKey(for: collectionId)

        optimizationTask = Task {
            var documentsDistilled = 0
            var summariesGenerated = 0
            var duplicatesRemoved = 0
            let chunksBefore = (try? vectorStore.chunkCount(collectionId: collectionId)) ?? 0

            do {
                let docs = try vectorStore.loadDocuments(collectionId: collectionId)

                // Phase 1: Distill undistilled documents
                let undistilled = docs.filter { !$0.hasDistilledChunks && $0.enabled }
                if !undistilled.isEmpty {
                    for (index, doc) in undistilled.enumerated() {
                        guard !Task.isCancelled else { break }

                        self.optimizationPhase = "Distilling \(doc.fileName) (\(index + 1)/\(undistilled.count))"
                        self.optimizationProgress = (index, undistilled.count)

                        do {
                            try await knowledgeEngine.distillDocument(
                                documentId: doc.id,
                                collectionId: collectionId,
                                chatModel: chatModel,
                                encryptionKey: encKey
                            )
                            documentsDistilled += 1
                        } catch is CancellationError {
                            try? vectorStore.deleteDistilledChunks(documentId: doc.id)
                            try? vectorStore.clearDistillCheckpoint(documentId: doc.id)
                            try? vectorStore.updateDocumentDistillStatus(
                                id: doc.id, hasDistilledChunks: false, useDistilled: false
                            )
                            break
                        } catch {
                            print("Optimization: distillation failed for \(doc.fileName): \(error)")
                        }
                    }
                }

                // Phase 2: Generate missing summaries
                guard !Task.isCancelled else { throw CancellationError() }
                let missingSummary = docs.filter { $0.summary == nil && $0.enabled }
                if !missingSummary.isEmpty {
                    for (index, doc) in missingSummary.enumerated() {
                        guard !Task.isCancelled else { break }

                        self.optimizationPhase = "Summarizing \(doc.fileName) (\(index + 1)/\(missingSummary.count))"
                        self.optimizationProgress = (index, missingSummary.count)

                        let chunks = try vectorStore.loadOriginalChunks(documentId: doc.id, decryptionKey: encKey)
                        let summaryInput = String(chunks.prefix(5).map(\.content).joined(separator: "\n\n").prefix(2000))

                        let messages: [OllamaService.ChatMessage] = [
                            .init(role: "system", content: """
                                Summarize the following document content in 2-3 concise sentences. \
                                Focus on what the document is about, its main topics, and key points. \
                                Do not start with "This document" — just state the content directly.
                                """),
                            .init(role: "user", content: summaryInput)
                        ]

                        do {
                            let summary = try await ollama.chat(messages: messages, model: chatModel)
                            try vectorStore.updateDocumentSummary(id: doc.id, summary: summary, encryptionKey: encKey)
                            summariesGenerated += 1
                        } catch {
                            print("Optimization: summary failed for \(doc.fileName): \(error)")
                        }
                    }
                }

                // Phase 3: Deduplicate chunks
                guard !Task.isCancelled else { throw CancellationError() }
                self.optimizationPhase = "Deduplicating chunks..."
                self.optimizationProgress = (0, 0)

                let dedupResult = try await knowledgeEngine.deduplicateChunks(
                    collectionId: collectionId
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.optimizationPhase = progress.phase
                        self?.optimizationProgress = (progress.current, progress.total)
                    }
                }
                duplicatesRemoved = dedupResult.removedCount

                // Phase 4: FTS5 optimize
                guard !Task.isCancelled else { throw CancellationError() }
                self.optimizationPhase = "Optimizing search index..."
                self.optimizationProgress = (0, 0)
                try? vectorStore.fts5Optimize()

                // Phase 5: Compact database
                guard !Task.isCancelled else { throw CancellationError() }
                self.optimizationPhase = "Compacting database..."
                try? vectorStore.vacuumDatabase()

            } catch is CancellationError {
                // User cancelled — fall through to report
            } catch {
                print("Optimization error: \(error)")
            }

            let chunksAfter = (try? vectorStore.chunkCount(collectionId: collectionId)) ?? 0

            self.lastOptimizationReport = OptimizationReport(
                documentsDistilled: documentsDistilled,
                summariesGenerated: summariesGenerated,
                duplicatesRemoved: duplicatesRemoved,
                chunksBefore: chunksBefore,
                chunksAfter: chunksAfter
            )

            self.isOptimizing = false
            self.optimizationPhase = ""
            self.optimizationProgress = (0, 0)
            self.optimizationTask = nil
            self.refreshDocuments()
        }
    }

    func cancelOptimization() {
        optimizationTask?.cancel()
        optimizationPhase = "Cancelling..."
    }

    // MARK: - Collection Protection

    /// Hash a password using PBKDF2-HMAC-SHA256 with a random salt.
    /// Format: "pbkdf2$100000$<salt_hex>$<hash_hex>"
    nonisolated static func hashPassword(_ password: String) -> String {
        let iterations: UInt32 = 100_000
        let salt = generateRandomSalt()
        let hash = derivePBKDF2Key(from: password, salt: salt, iterations: iterations)
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        return "pbkdf2$\(iterations)$\(saltHex)$\(hashHex)"
    }

    /// Verify a password against a stored hash (supports both PBKDF2 and legacy SHA256).
    nonisolated static func verifyPassword(_ password: String, against storedHash: String) -> Bool {
        if storedHash.hasPrefix("pbkdf2$") {
            // New PBKDF2 format: "pbkdf2$iterations$salt_hex$hash_hex"
            let parts = storedHash.split(separator: "$")
            guard parts.count == 4,
                  let iterations = UInt32(parts[1]) else { return false }
            let saltHex = String(parts[2])
            let expectedHashHex = String(parts[3])

            guard let salt = Data(hexString: saltHex) else { return false }
            let derived = derivePBKDF2Key(from: password, salt: salt, iterations: iterations)
            let derivedHex = derived.map { String(format: "%02x", $0) }.joined()

            // Constant-time comparison
            return constantTimeEqual(derivedHex, expectedHashHex)
        } else {
            // Legacy SHA256 format (backward compatibility)
            let data = Data(password.utf8)
            let hash = SHA256.hash(data: data)
            let computed = hash.map { String(format: "%02x", $0) }.joined()
            return constantTimeEqual(computed, storedHash)
        }
    }

    /// Constant-time string comparison to prevent timing attacks.
    private nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }

    private nonisolated static func generateRandomSalt(length: Int = 16) -> Data {
        var salt = Data(count: length)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!) }
        return salt
    }

    private nonisolated static func derivePBKDF2Key(from password: String, salt: Data, iterations: UInt32) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32)
        _ = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return derivedKey
    }

    /// Whether a collection is currently unlocked (either unprotected or password entered).
    func isCollectionUnlocked(_ collectionId: UUID) -> Bool {
        guard let collection = collections.first(where: { $0.id == collectionId }) else { return true }
        if !collection.isProtected { return true }
        return unlockedCollectionIds.contains(collectionId)
    }

    /// Get the Content Encryption Key for a collection, or nil if not encrypted or unavailable.
    func encryptionKey(for collectionId: UUID) -> SymmetricKey? {
        cachedCEKs[collectionId]
    }

    /// The effective protection level for the current view.
    /// Returns nil if unprotected or fully unlocked.
    /// sourcesMasked is permanent — entering the password enables querying
    /// but never reveals sources. Use "Remove Protection" for full access.
    func effectiveProtection(for collectionId: UUID) -> ProtectionLevel? {
        guard let collection = collections.first(where: { $0.id == collectionId }) else { return nil }
        if !collection.isProtected { return nil }
        if unlockedCollectionIds.contains(collectionId) {
            // sourcesMasked persists even after password entry — sources stay hidden
            return collection.protectionLevel == .sourcesMasked ? .sourcesMasked : nil
        }
        return collection.protectionLevel
    }

    /// Whether editing (add/delete docs) is allowed for the selected collection.
    var canEditSelectedCollection: Bool {
        guard let id = selectedCollectionId else { return false }
        let protection = effectiveProtection(for: id)
        // Blocked when sourcesMasked or readOnly (both disallow editing)
        return protection == nil
    }

    /// Whether sources should be shown in query results for the selected collection.
    var canViewSources: Bool {
        guard let id = selectedCollectionId else { return true }
        let protection = effectiveProtection(for: id)
        return protection != .sourcesMasked
    }

    /// Whether the document list should be visible for the selected collection.
    var canViewDocuments: Bool {
        guard let id = selectedCollectionId else { return true }
        let protection = effectiveProtection(for: id)
        return protection != .sourcesMasked
    }

    /// Attempt to unlock a collection with the given password.
    func unlockCollection(_ collectionId: UUID, password: String) -> Bool {
        guard let collection = collections.first(where: { $0.id == collectionId }),
              let hash = collection.passwordHash else { return false }

        if Self.verifyPassword(password, against: hash) {
            unlockedCollectionIds.insert(collectionId)

            // Unwrap and cache the CEK if this collection is encrypted
            if collection.isEncrypted,
               let wrappedKey = collection.encryptionKeyWrapped,
               let salt = collection.encryptionSalt {
                if let cek = try? CryptoManager.unwrapCEK(
                    wrappedKey: wrappedKey, salt: salt, password: password
                ) {
                    cachedCEKs[collectionId] = cek
                    // Store in Keychain for future passwordless access (sourcesMasked)
                    try? CryptoManager.storeCEKInKeychain(cek, collectionId: collectionId)
                }
            }
            return true
        }
        return false
    }

    /// Lock a collection again (re-enable protection).
    func lockCollection(_ collectionId: UUID) {
        unlockedCollectionIds.remove(collectionId)
    }

    /// Set or update password protection on a collection with cryptographic chunk encryption.
    func setProtection(collectionId: UUID, password: String, level: ProtectionLevel) {
        let hash = Self.hashPassword(password)

        // Check if the collection is already encrypted (e.g., changing password or level)
        let existingCEK = cachedCEKs[collectionId]
        let isAlreadyEncrypted = existingCEK != nil

        if isAlreadyEncrypted, let cek = existingCEK {
            // Already encrypted — just re-wrap the CEK with the new password and update metadata
            if let (wrappedKey, salt) = try? CryptoManager.wrapCEK(cek, password: password) {
                try? vectorStore.updateCollectionEncryption(
                    id: collectionId,
                    encryptionKeyWrapped: wrappedKey,
                    encryptionSalt: salt,
                    isEncrypted: true
                )
                if let index = collections.firstIndex(where: { $0.id == collectionId }) {
                    collections[index].encryptionKeyWrapped = wrappedKey
                    collections[index].encryptionSalt = salt
                }
            }
        } else {
            // New encryption — generate CEK, encrypt all chunks
            let cek = CryptoManager.generateCEK()

            do {
                let (wrappedKey, salt) = try CryptoManager.wrapCEK(cek, password: password)

                // Encrypt all existing chunks in place
                try vectorStore.encryptAllChunks(collectionId: collectionId, key: cek)

                // Store wrapped key and salt in DB
                try vectorStore.updateCollectionEncryption(
                    id: collectionId,
                    encryptionKeyWrapped: wrappedKey,
                    encryptionSalt: salt,
                    isEncrypted: true
                )

                // Store raw CEK in Keychain
                try CryptoManager.storeCEKInKeychain(cek, collectionId: collectionId)

                // Update local collection state
                if let index = collections.firstIndex(where: { $0.id == collectionId }) {
                    collections[index].encryptionKeyWrapped = wrappedKey
                    collections[index].encryptionSalt = salt
                    collections[index].isEncrypted = true
                }

                cachedCEKs[collectionId] = cek
            } catch {
                alertMessage = "Failed to encrypt collection: \(error.localizedDescription)"
                return
            }
        }

        // Update protection metadata
        try? vectorStore.updateCollectionProtection(id: collectionId, passwordHash: hash, protectionLevel: level)
        if let index = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[index].passwordHash = hash
            collections[index].protectionLevel = level
        }
        // Auto-unlock for the person who set it
        unlockedCollectionIds.insert(collectionId)
    }

    /// Remove password protection from a collection and decrypt all chunks.
    func removeProtection(collectionId: UUID) {
        // Decrypt all chunks if encrypted
        if let cek = cachedCEKs[collectionId] {
            do {
                try vectorStore.decryptAllChunks(collectionId: collectionId, key: cek)
                try vectorStore.updateCollectionEncryption(
                    id: collectionId,
                    encryptionKeyWrapped: nil,
                    encryptionSalt: nil,
                    isEncrypted: false
                )
                CryptoManager.removeCEKFromKeychain(collectionId: collectionId)
                cachedCEKs.removeValue(forKey: collectionId)
            } catch {
                alertMessage = "Failed to decrypt collection: \(error.localizedDescription)"
                return
            }
        }

        try? vectorStore.updateCollectionProtection(id: collectionId, passwordHash: nil, protectionLevel: nil)
        if let index = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[index].passwordHash = nil
            collections[index].protectionLevel = nil
            collections[index].encryptionKeyWrapped = nil
            collections[index].encryptionSalt = nil
            collections[index].isEncrypted = false
        }
        unlockedCollectionIds.remove(collectionId)
    }
}

// MARK: - Data hex helper

nonisolated extension Data {
    init?(hexString: String) {
        let len = hexString.count
        guard len % 2 == 0 else { return nil }
        var data = Data(capacity: len / 2)
        var index = hexString.startIndex
        for _ in 0..<len / 2 {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
