import Foundation
import CryptoKit

/// Orchestrates the knowledge base pipeline: document ingestion, embedding, and query answering.
actor KnowledgeEngine {
    private let ollama: OllamaService
    private let embedOllama: OllamaService
    private let vectorStore: VectorStore
    private let embedModel: String

    init(
        ollama: OllamaService,
        vectorStore: VectorStore,
        embedModel: String = "nomic-embed-text",
        embedOllama: OllamaService? = nil
    ) {
        self.ollama = ollama
        self.embedOllama = embedOllama ?? ollama
        self.vectorStore = vectorStore
        self.embedModel = embedModel
    }

    // MARK: - Document ingestion

    struct IngestionProgress: Sendable {
        let phase: String         // "Reading", "Chunking", "Embedding", "Storing", "Done"
        let current: Int
        let total: Int
    }

    /// Ingest a document into a collection: parse → chunk → embed → store.
    /// Supports local files and web content (pass preExtractedText for web).
    func ingestDocument(
        url: URL,
        collectionId: UUID,
        sourceType: SourceType = .file,
        preExtractedText: String? = nil,
        chatModel: String? = nil,
        crawlGroupId: UUID? = nil,
        encryptionKey: SymmetricKey? = nil,
        progress: @Sendable (IngestionProgress) -> Void = { _ in }
    ) async throws -> IndexedDocument {
        // 1. Read / parse the document
        progress(IngestionProgress(phase: "Reading", current: 0, total: 0))

        let text: String
        if let preExtractedText {
            text = preExtractedText
        } else {
            text = try DocumentParser.extractText(from: url)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeError.emptyFile(url.lastPathComponent)
        }

        // Compute content hash for change detection
        let contentHash = SHA256.hash(data: Data(text.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        // 2. Chunk the text
        progress(IngestionProgress(phase: "Chunking", current: 0, total: 0))
        let chunks = TextChunker.chunk(text: text)

        guard !chunks.isEmpty else {
            throw KnowledgeError.emptyFile(url.lastPathComponent)
        }

        // 3. Embed each chunk (in batches of 10 to avoid overloading Ollama)
        let batchSize = 10
        var allEmbeddings: [[Float]] = []

        for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, chunks.count)
            let batch = Array(chunks[batchStart..<batchEnd])

            progress(IngestionProgress(phase: "Embedding", current: batchStart, total: chunks.count))

            let embeddings = try await embedOllama.embedBatch(texts: batch, model: embedModel)
            allEmbeddings.append(contentsOf: embeddings)
        }

        progress(IngestionProgress(phase: "Storing", current: chunks.count, total: chunks.count))

        // 4. Create the document record
        let documentId = UUID()
        let fileName: String
        let filePath: String
        let fileSize: Int64

        if sourceType == .web {
            fileName = url.host ?? url.absoluteString
            filePath = url.absoluteString
            fileSize = Int64(text.utf8.count)
        } else {
            fileName = url.lastPathComponent
            filePath = url.path
            fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }

        let document = IndexedDocument(
            id: documentId,
            collectionId: collectionId,
            fileName: fileName,
            filePath: filePath,
            fileSize: fileSize,
            chunkCount: chunks.count,
            sourceType: sourceType,
            contentHash: contentHash,
            crawlGroupId: crawlGroupId
        )

        // 5. Create chunk records with embeddings
        var documentChunks: [DocumentChunk] = []
        for (index, (chunkText, embedding)) in zip(chunks, allEmbeddings).enumerated() {
            documentChunks.append(DocumentChunk(
                documentId: documentId,
                collectionId: collectionId,
                content: chunkText,
                chunkIndex: index,
                embedding: embedding
            ))
        }

        // 6. Save everything to the database
        try vectorStore.saveDocument(document)
        try vectorStore.saveChunks(documentChunks, encryptionKey: encryptionKey)

        // 7. Generate summary if chat model is available
        if let chatModel {
            progress(IngestionProgress(phase: "Summarizing", current: 0, total: 0))

            let summaryInput = String(chunks.prefix(5).joined(separator: "\n\n").prefix(2000))

            let summaryMessages: [OllamaService.ChatMessage] = [
                .init(role: "system", content: """
                    Summarize the following document content in 2-3 concise sentences. \
                    Focus on what the document is about, its main topics, and key points. \
                    Do not start with "This document" — just state the content directly.
                    """),
                .init(role: "user", content: summaryInput)
            ]

            do {
                let summary = try await ollama.chat(messages: summaryMessages, model: chatModel)
                try vectorStore.updateDocumentSummary(id: documentId, summary: summary, encryptionKey: encryptionKey)
                var docWithSummary = document
                docWithSummary.summary = summary
                progress(IngestionProgress(phase: "Done", current: chunks.count, total: chunks.count))
                return docWithSummary
            } catch {
                print("Summary generation failed: \(error.localizedDescription)")
            }
        }

        progress(IngestionProgress(phase: "Done", current: chunks.count, total: chunks.count))

        return document
    }

    // MARK: - Document distillation

    struct DistillationProgress: Sendable {
        let phase: String
        let current: Int
        let total: Int
    }

    /// Distill a document: load original chunks → LLM rewrites for AI consumption → re-chunk → embed → store.
    func distillDocument(
        documentId: UUID,
        collectionId: UUID,
        chatModel: String,
        encryptionKey: SymmetricKey? = nil,
        progress: @Sendable (DistillationProgress) -> Void = { _ in }
    ) async throws {
        // 1. Load original chunks (decrypt if encrypted)
        progress(DistillationProgress(phase: "Loading", current: 0, total: 0))
        let originalChunks = try vectorStore.loadOriginalChunks(documentId: documentId, decryptionKey: encryptionKey)

        guard !originalChunks.isEmpty else {
            throw KnowledgeError.emptyFile("No original chunks found")
        }

        // 2. Fetch document context for a better distillation prompt
        let documentName = (try? vectorStore.documentName(for: documentId)) ?? "document"
        let summary = try? vectorStore.documentSummary(for: documentId, decryptionKey: encryptionKey)
        let summaryClause = summary.flatMap({ $0.isEmpty ? nil : " (Summary: \($0))" }) ?? ""

        // 3. Process through LLM in sections of 5 chunks
        let chunkTexts = originalChunks.sorted { $0.chunkIndex < $1.chunkIndex }.map(\.content)
        let sectionSize = 5
        var distilledSections: [String] = []
        var startSectionOffset = 0

        // Check for existing checkpoint (resume after crash/quit)
        if let checkpoint = try? vectorStore.loadDistillCheckpoint(documentId: documentId, decryptionKey: encryptionKey),
           checkpoint.totalOriginalChunks == chunkTexts.count {
            distilledSections = checkpoint.sections
            startSectionOffset = checkpoint.sections.count * sectionSize
            progress(DistillationProgress(phase: "Resuming", current: startSectionOffset, total: chunkTexts.count))
        }

        for sectionStart in stride(from: startSectionOffset, to: chunkTexts.count, by: sectionSize) {
            try Task.checkCancellation()

            let sectionEnd = min(sectionStart + sectionSize, chunkTexts.count)
            let sectionText = chunkTexts[sectionStart..<sectionEnd].joined(separator: "\n\n")

            progress(DistillationProgress(phase: "Distilling", current: sectionStart, total: chunkTexts.count))

            let messages: [OllamaService.ChatMessage] = [
                .init(role: "system", content: """
                    You are a document optimization assistant. You are processing content from \
                    "\(documentName)"\(summaryClause). \
                    Rewrite the following content to be maximally useful for AI retrieval and \
                    question answering. Preserve ALL factual information, names, dates, numbers, \
                    and technical details. Restructure the content to be clear, well-organized, \
                    and information-dense. Ensure each passage can be understood independently \
                    without surrounding context — do not use phrases like "as mentioned above", \
                    "the following", or "see below". Replace pronouns and references with their \
                    concrete antecedents where possible. Remove filler words, redundancy, and \
                    formatting artifacts. Keep the same language and tone. Do NOT add information \
                    that is not in the original. Output ONLY the optimized text, no commentary.
                    """),
                .init(role: "user", content: sectionText)
            ]

            let distilled = try await ollama.chat(messages: messages, model: chatModel, timeout: 600)
            distilledSections.append(distilled)

            // Checkpoint after each section for crash recovery
            try? vectorStore.saveDistillCheckpoint(
                documentId: documentId,
                sections: distilledSections,
                totalOriginalChunks: chunkTexts.count,
                encryptionKey: encryptionKey
            )
        }

        let distilledText = distilledSections.joined(separator: "\n\n")

        // 4. Delete any existing distilled chunks (re-distill case)
        try vectorStore.deleteDistilledChunks(documentId: documentId)

        // 5. Chunk the distilled text
        progress(DistillationProgress(phase: "Chunking", current: 0, total: 0))
        let newChunks = TextChunker.chunk(text: distilledText)

        guard !newChunks.isEmpty else {
            throw KnowledgeError.emptyFile("Distillation produced empty output")
        }

        // 6. Embed the distilled chunks
        let batchSize = 10
        var allEmbeddings: [[Float]] = []

        for batchStart in stride(from: 0, to: newChunks.count, by: batchSize) {
            try Task.checkCancellation()

            let batchEnd = min(batchStart + batchSize, newChunks.count)
            let batch = Array(newChunks[batchStart..<batchEnd])

            progress(DistillationProgress(phase: "Embedding", current: batchStart, total: newChunks.count))

            let embeddings = try await embedOllama.embedBatch(texts: batch, model: embedModel)
            allEmbeddings.append(contentsOf: embeddings)
        }

        // 7. Store distilled chunks
        progress(DistillationProgress(phase: "Storing", current: newChunks.count, total: newChunks.count))

        var documentChunks: [DocumentChunk] = []
        for (index, (chunkText, embedding)) in zip(newChunks, allEmbeddings).enumerated() {
            documentChunks.append(DocumentChunk(
                documentId: documentId,
                collectionId: collectionId,
                content: chunkText,
                chunkIndex: index,
                embedding: embedding,
                chunkType: .distilled
            ))
        }

        try vectorStore.saveChunks(documentChunks, encryptionKey: encryptionKey)

        // 8. Update document flags — auto-switch to distilled
        try vectorStore.updateDocumentDistillStatus(
            id: documentId,
            hasDistilledChunks: true,
            useDistilled: true
        )

        // 9. Clear checkpoint — distillation complete
        try? vectorStore.clearDistillCheckpoint(documentId: documentId)

        progress(DistillationProgress(phase: "Done", current: newChunks.count, total: newChunks.count))
    }

    // MARK: - Query

    /// Query the knowledge base: embed the question → find similar chunks → generate an answer.
    func query(
        question: String,
        chatModel: String,
        collectionId: UUID? = nil,
        customSystemPrompt: String? = nil,
        conversationHistory: [ConversationMessage] = [],
        topK: Int = 10,
        searchMode: SearchMode = .hybrid,
        enableReranking: Bool = false,
        enableDecomposition: Bool = false,
        maskSources: Bool = false,
        encryptionKey: SymmetricKey? = nil,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> QueryResult {
        // 1. Retrieve candidates (with optional decomposition)
        let retrievalTopK = enableReranking ? max(topK, 15) : topK
        var results: [(chunkId: UUID, documentId: UUID, content: String, score: Float)]

        if enableDecomposition {
            results = try await decomposeAndSearch(
                question: question,
                chatModel: chatModel,
                collectionId: collectionId,
                topK: retrievalTopK,
                searchMode: searchMode,
                encryptionKey: encryptionKey
            )
        } else {
            results = try await retrieve(
                question: question,
                collectionId: collectionId,
                topK: retrievalTopK,
                searchMode: searchMode,
                encryptionKey: encryptionKey
            )
        }

        // 2. Re-rank if enabled
        if enableReranking && results.count > topK {
            results = await rerank(
                question: question,
                candidates: results,
                chatModel: chatModel,
                topK: topK
            )
        } else if results.count > topK {
            results = Array(results.prefix(topK))
        }

        guard !results.isEmpty else {
            return QueryResult(
                answer: "I couldn't find any relevant information in the indexed documents.",
                sources: []
            )
        }

        // 3. Build context from top chunks
        var contextParts: [String] = []
        var searchResults: [SearchResult] = []

        for (index, result) in results.enumerated() {
            let docName = try vectorStore.documentName(for: result.documentId)

            // When sources are masked, use generic labels so the LLM can't cite document names
            if maskSources {
                contextParts.append("[Source \(index + 1)]: \(result.content)")
            } else {
                contextParts.append("[\(docName)]: \(result.content)")
            }

            // Reconstruct enough info for the SearchResult
            let chunk = DocumentChunk(
                id: result.chunkId,
                documentId: result.documentId,
                collectionId: collectionId ?? UUID(),
                content: result.content,
                chunkIndex: 0,
                embedding: []  // Don't need to carry the embedding in results
            )

            searchResults.append(SearchResult(
                chunk: chunk,
                score: result.score,
                documentName: docName
            ))
        }

        let context = contextParts.joined(separator: "\n\n---\n\n")

        // 3.5 Load document summaries for richer context (skip when masked)
        var summariesSection = ""
        if !maskSources, let collectionId {
            let summaries = (try? vectorStore.loadDocumentSummaries(collectionId: collectionId, decryptionKey: encryptionKey)) ?? []
            if !summaries.isEmpty {
                let summaryLines = summaries.map { "- \($0.documentName): \($0.summary)" }
                summariesSection = "\nDocument Summaries (for overall context):\n" + summaryLines.joined(separator: "\n") + "\n"
            }
        }

        // 4. Generate answer with context
        let baseInstruction: String
        if let custom = customSystemPrompt {
            baseInstruction = custom
        } else if maskSources {
            baseInstruction = """
            You are a helpful assistant that answers questions based on the provided context. \
            Use ONLY the information from the context below to answer. If the context doesn't contain \
            enough information to answer the question, say so clearly. Do NOT reference or name any \
            specific documents, files, or sources in your answer.
            """
        } else {
            baseInstruction = """
            You are a helpful assistant that answers questions based on the provided context. \
            Use ONLY the information from the context below to answer. If the context doesn't contain \
            enough information to answer the question, say so clearly. Always cite which document(s) \
            your answer comes from.
            """
        }

        let systemPrompt = """
        \(baseInstruction)
        \(summariesSection)
        Context:
        \(context)
        """

        var messages: [OllamaService.ChatMessage] = [
            .init(role: "system", content: systemPrompt)
        ]

        // Include conversation history for multi-turn context
        for msg in conversationHistory {
            messages.append(.init(
                role: msg.role == .user ? "user" : "assistant",
                content: msg.content
            ))
        }

        messages.append(.init(role: "user", content: question))

        let answer: String
        if let onToken {
            answer = try await ollama.chatStream(messages: messages, model: chatModel, onToken: onToken)
        } else {
            answer = try await ollama.chat(messages: messages, model: chatModel)
        }

        return QueryResult(answer: answer, sources: searchResults)
    }

    /// Search for similar chunks without LLM generation — useful for context injection.
    func search(
        query: String,
        collectionId: UUID? = nil,
        topK: Int = 5,
        searchMode: SearchMode = .hybrid,
        encryptionKey: SymmetricKey? = nil
    ) async throws -> [SearchResult] {
        let results = try await retrieve(question: query, collectionId: collectionId, topK: topK, searchMode: searchMode, encryptionKey: encryptionKey)

        return try results.map { result in
            let docName = try vectorStore.documentName(for: result.documentId)
            let chunk = DocumentChunk(
                id: result.chunkId,
                documentId: result.documentId,
                collectionId: collectionId ?? UUID(),
                content: result.content,
                chunkIndex: 0,
                embedding: []
            )
            return SearchResult(chunk: chunk, score: result.score, documentName: docName)
        }
    }

    // MARK: - Private retrieval helpers

    /// Core retrieval: embed query and search using the specified mode.
    private func retrieve(
        question: String,
        collectionId: UUID?,
        topK: Int,
        searchMode: SearchMode,
        encryptionKey: SymmetricKey? = nil
    ) async throws -> [(chunkId: UUID, documentId: UUID, content: String, score: Float)] {
        let queryEmbedding = try await embedOllama.embed(text: question, model: embedModel)

        // Force vector-only search for encrypted collections (FTS5 can't search ciphertext)
        let effectiveMode = encryptionKey != nil ? .vector : searchMode

        switch effectiveMode {
        case .vector:
            return try vectorStore.searchSimilar(queryEmbedding: queryEmbedding, collectionId: collectionId, topK: topK, decryptionKey: encryptionKey)
        case .hybrid:
            return try vectorStore.searchHybrid(queryEmbedding: queryEmbedding, queryText: question, collectionId: collectionId, topK: topK, decryptionKey: encryptionKey)
        }
    }

    /// Decompose a complex question into sub-queries, retrieve for each, and merge results.
    private func decomposeAndSearch(
        question: String,
        chatModel: String,
        collectionId: UUID?,
        topK: Int,
        searchMode: SearchMode,
        encryptionKey: SymmetricKey? = nil
    ) async throws -> [(chunkId: UUID, documentId: UUID, content: String, score: Float)] {
        let subQueries = await decompose(question: question, chatModel: chatModel)

        var merged: [UUID: (documentId: UUID, content: String, score: Float)] = [:]

        for subQuery in subQueries {
            let subResults = try await retrieve(question: subQuery, collectionId: collectionId, topK: topK, searchMode: searchMode, encryptionKey: encryptionKey)
            for r in subResults {
                if let existing = merged[r.chunkId] {
                    merged[r.chunkId] = (r.documentId, r.content, max(existing.score, r.score))
                } else {
                    merged[r.chunkId] = (r.documentId, r.content, r.score)
                }
            }
        }

        return merged.map { (chunkId: $0.key, documentId: $0.value.documentId, content: $0.value.content, score: $0.value.score) }
            .sorted { $0.score > $1.score }
    }

    /// Use the LLM to break a complex question into focused sub-queries.
    private func decompose(question: String, chatModel: String) async -> [String] {
        let messages: [OllamaService.ChatMessage] = [
            .init(role: "system", content: """
                You are a query analysis assistant. Given a question, break it into 2-4 simple, \
                focused sub-questions that together answer the original. If the question is already \
                simple, return it as-is. Output ONLY a JSON array of strings. \
                Example: ["What is X?", "How does Y relate to Z?"]
                """),
            .init(role: "user", content: question)
        ]

        do {
            let response = try await ollama.chat(messages: messages, model: chatModel, temperature: 0, timeout: 30)
            // Try to parse JSON array from response
            if let data = response.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String],
               !array.isEmpty {
                return array
            }
        } catch {
            // Fall through to return original question
        }

        return [question]
    }

    /// Use the LLM to re-rank candidates by relevance to the question.
    private func rerank(
        question: String,
        candidates: [(chunkId: UUID, documentId: UUID, content: String, score: Float)],
        chatModel: String,
        topK: Int
    ) async -> [(chunkId: UUID, documentId: UUID, content: String, score: Float)] {
        // Build numbered passage list (truncate each to 500 chars)
        var passageList = ""
        for (i, candidate) in candidates.enumerated() {
            let truncated = candidate.content.count > 500
                ? String(candidate.content.prefix(500)) + "..."
                : candidate.content
            passageList += "[\(i + 1)] \(truncated)\n\n"
        }

        let messages: [OllamaService.ChatMessage] = [
            .init(role: "system", content: """
                You are a relevance scoring assistant. Given a question and numbered passages, \
                rate each passage's relevance to the question on a scale of 1-10. \
                Output ONLY a JSON array of integer scores in the same order. \
                Example: [8, 3, 9, 1, 7]
                """),
            .init(role: "user", content: "Question: \(question)\n\nPassages:\n\(passageList)")
        ]

        do {
            let response = try await ollama.chat(messages: messages, model: chatModel, temperature: 0, timeout: 30)

            // Extract JSON array from response (may have surrounding text)
            if let start = response.firstIndex(of: "["),
               let end = response.lastIndex(of: "]") {
                let jsonStr = String(response[start...end])
                if let data = jsonStr.data(using: .utf8),
                   let scores = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    // Pair candidates with LLM scores, sort by score descending
                    var scored = candidates.enumerated().map { (i, candidate) -> (candidate: (chunkId: UUID, documentId: UUID, content: String, score: Float), rerankScore: Float) in
                        let llmScore: Float
                        if i < scores.count, let s = scores[i] as? NSNumber {
                            llmScore = s.floatValue
                        } else {
                            llmScore = 0
                        }
                        return (candidate, llmScore)
                    }
                    scored.sort { $0.rerankScore > $1.rerankScore }
                    return scored.prefix(topK).map { $0.candidate }
                }
            }
        } catch {
            // Fall through to original ranking
        }

        // Fallback: return original top K
        return Array(candidates.prefix(topK))
    }

    // MARK: - Deduplication

    nonisolated struct DeduplicationProgress: Sendable {
        let phase: String
        let current: Int
        let total: Int
    }

    nonisolated struct DeduplicationResult: Sendable {
        let removedCount: Int
        let remainingCount: Int
    }

    /// Find and remove near-duplicate chunks in a collection using cosine similarity.
    func deduplicateChunks(
        collectionId: UUID,
        threshold: Float = 0.95,
        progress: @Sendable (DeduplicationProgress) -> Void = { _ in }
    ) async throws -> DeduplicationResult {
        progress(DeduplicationProgress(phase: "Loading embeddings", current: 0, total: 0))

        let embeddings = try vectorStore.loadActiveEmbeddings(collectionId: collectionId)
        let count = embeddings.count

        guard count > 1 else {
            return DeduplicationResult(removedCount: 0, remainingCount: count)
        }

        progress(DeduplicationProgress(phase: "Finding duplicates", current: 0, total: count))

        var toRemove: Set<UUID> = []

        for i in 0..<count {
            try Task.checkCancellation()

            if toRemove.contains(embeddings[i].chunkId) { continue }

            for j in (i + 1)..<count {
                if toRemove.contains(embeddings[j].chunkId) { continue }

                let sim = vectorStore.cosineSimilarity(
                    embeddings[i].embedding, embeddings[j].embedding
                )

                if sim > threshold {
                    // Keep the chunk with more content; tiebreak by newer document
                    let keepI: Bool
                    if embeddings[i].contentLength != embeddings[j].contentLength {
                        keepI = embeddings[i].contentLength >= embeddings[j].contentLength
                    } else {
                        keepI = embeddings[i].dateIndexed >= embeddings[j].dateIndexed
                    }

                    toRemove.insert(keepI ? embeddings[j].chunkId : embeddings[i].chunkId)
                    if !keepI { break }  // i was removed, skip rest of j loop
                }
            }

            if (i + 1) % 50 == 0 {
                progress(DeduplicationProgress(
                    phase: "Finding duplicates", current: i + 1, total: count
                ))
            }
        }

        if !toRemove.isEmpty {
            progress(DeduplicationProgress(
                phase: "Removing \(toRemove.count) duplicates", current: 0, total: 0
            ))
            try vectorStore.deleteChunks(ids: toRemove)
        }

        return DeduplicationResult(
            removedCount: toRemove.count,
            remainingCount: count - toRemove.count
        )
    }
}

// MARK: - Errors

nonisolated enum KnowledgeError: LocalizedError {
    case cannotReadFile(String)
    case emptyFile(String)
    case webFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotReadFile(let name):
            return "Cannot read file: \(name)"
        case .emptyFile(let name):
            return "File is empty: \(name)"
        case .webFetchFailed(let msg):
            return "Web fetch failed: \(msg)"
        }
    }
}
