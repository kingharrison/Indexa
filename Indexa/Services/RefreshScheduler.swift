import Foundation
import CryptoKit

/// Periodically checks web documents for content changes and re-ingests them.
actor RefreshScheduler {
    private let vectorStore: VectorStore
    private let knowledgeEngine: KnowledgeEngine
    private let webScraper: WebScraper
    private var timerTask: Task<Void, Never>?
    private var isRunning = false
    private var chatModel: String?
    private let encryptionKeyProvider: @Sendable (UUID) async -> SymmetricKey?

    func setChatModel(_ model: String) {
        self.chatModel = model
    }

    /// Check every 15 minutes whether any collection needs a refresh.
    private let checkInterval: TimeInterval = 900

    init(
        vectorStore: VectorStore,
        knowledgeEngine: KnowledgeEngine,
        webScraper: WebScraper,
        encryptionKeyProvider: @Sendable @escaping (UUID) async -> SymmetricKey? = { _ in nil }
    ) {
        self.vectorStore = vectorStore
        self.knowledgeEngine = knowledgeEngine
        self.webScraper = webScraper
        self.encryptionKeyProvider = encryptionKeyProvider
    }

    /// Start the background scheduler loop.
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.checkInterval ?? 900))
                await self?.checkAndRefresh()
            }
        }
    }

    /// Stop the scheduler.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Manually trigger a refresh for a specific collection.
    func refreshCollection(
        _ collectionId: UUID,
        progress: @Sendable (String) -> Void = { _ in }
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        await refreshWebDocuments(in: collectionId, progress: progress)
    }

    // MARK: - Private

    private func checkAndRefresh() async {
        guard let collections = try? vectorStore.loadCollections() else { return }

        for collection in collections {
            guard collection.refreshInterval != .never,
                  let interval = collection.refreshInterval.timeInterval else { continue }

            // Check if enough time has passed since the most recent web document was indexed
            let docs = (try? vectorStore.loadWebDocuments(collectionId: collection.id)) ?? []
            guard let mostRecent = docs.map(\.dateIndexed).max() else { continue }

            if Date.now.timeIntervalSince(mostRecent) >= interval {
                await refreshWebDocuments(in: collection.id, progress: { _ in })
            }
        }
    }

    private func refreshWebDocuments(
        in collectionId: UUID,
        progress: @Sendable (String) -> Void
    ) async {
        let docs = (try? vectorStore.loadWebDocuments(collectionId: collectionId)) ?? []

        for doc in docs {
            guard let url = URL(string: doc.filePath) else { continue }

            progress("Checking \(doc.fileName)...")

            do {
                let (text, _) = try await webScraper.fetchAndExtract(url: url)

                // Compute new hash
                let newHash = SHA256.hash(data: Data(text.utf8))
                    .compactMap { String(format: "%02x", $0) }.joined()

                // Compare with stored hash — re-ingest if changed
                if newHash != doc.contentHash {
                    progress("Re-indexing \(doc.fileName)...")

                    // Delete old document and its chunks
                    try? vectorStore.deleteDocument(id: doc.id)

                    // Re-ingest with fresh content, preserving crawl group
                    let encKey = await encryptionKeyProvider(collectionId)
                    _ = try await knowledgeEngine.ingestDocument(
                        url: url,
                        collectionId: collectionId,
                        sourceType: .web,
                        preExtractedText: text,
                        chatModel: chatModel,
                        crawlGroupId: doc.crawlGroupId,
                        encryptionKey: encKey
                    )
                }
            } catch {
                print("Refresh failed for \(doc.fileName): \(error.localizedDescription)")
            }
        }
    }
}
