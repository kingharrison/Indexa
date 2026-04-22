import Foundation

// MARK: - Enums

/// Whether a document came from a local file or a web URL.
nonisolated enum SourceType: String, Codable, Sendable {
    case file
    case web
}

/// How often a collection's web documents should be re-checked for new content.
nonisolated enum RefreshInterval: String, Codable, Sendable, CaseIterable {
    case never
    case hourly
    case daily
    case weekly

    var displayName: String {
        switch self {
        case .never:  return "Never"
        case .hourly: return "Hourly"
        case .daily:  return "Daily"
        case .weekly: return "Weekly"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .never:  return nil
        case .hourly: return 3600
        case .daily:  return 86400
        case .weekly: return 604800
        }
    }
}

/// Search strategy used when querying the knowledge base.
nonisolated enum SearchMode: String, Codable, Sendable, CaseIterable {
    /// Pure vector similarity (cosine) — semantic matching only.
    case vector
    /// BM25 keyword search + vector similarity merged via Reciprocal Rank Fusion.
    case hybrid

    var displayName: String {
        switch self {
        case .vector: return "Semantic"
        case .hybrid: return "Hybrid"
        }
    }
}

/// Whether a chunk contains original document text or AI-distilled content.
nonisolated enum ChunkType: String, Codable, Sendable {
    case original
    case distilled
}

/// Protection level for a password-protected collection.
/// Defines what is accessible WITHOUT entering the password.
nonisolated enum ProtectionLevel: String, Codable, Sendable, CaseIterable {
    /// Can query and get answers, but sources and document list are hidden.
    case sourcesMasked = "sources_masked"
    /// Can see documents and query with sources, but cannot add/delete/modify.
    case readOnly = "read_only"

    var displayName: String {
        switch self {
        case .sourcesMasked: return "Sources Masked"
        case .readOnly:      return "Read Only"
        }
    }

    var description: String {
        switch self {
        case .sourcesMasked: return "Users can ask questions but cannot see documents or sources"
        case .readOnly:      return "Users can view documents and sources but cannot make changes"
        }
    }
}

// MARK: - Models

/// A collection groups related documents together (e.g. "Research Papers", "Work Notes").
nonisolated struct Collection: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var dateCreated: Date
    var refreshInterval: RefreshInterval
    var sortOrder: Int

    var systemPrompt: String?

    /// SHA256 hash of the protection password, or nil if unprotected.
    var passwordHash: String?
    /// What's accessible without the password. Only meaningful when passwordHash is set.
    var protectionLevel: ProtectionLevel?

    /// Base64-encoded AES-GCM sealed box containing the CEK, encrypted with the password-derived key.
    /// nil if the collection's chunks are not cryptographically encrypted.
    var encryptionKeyWrapped: String?
    /// Hex-encoded PBKDF2 salt used to derive the key that wraps the CEK.
    var encryptionSalt: String?
    /// Whether chunk content is cryptographically encrypted (reflects actual data state, NOT a toggle).
    var isEncrypted: Bool

    /// Whether this collection is password-protected.
    var isProtected: Bool { passwordHash != nil }

    init(id: UUID = UUID(), name: String, dateCreated: Date = .now, refreshInterval: RefreshInterval = .never, systemPrompt: String? = nil, passwordHash: String? = nil, protectionLevel: ProtectionLevel? = nil, encryptionKeyWrapped: String? = nil, encryptionSalt: String? = nil, isEncrypted: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.refreshInterval = refreshInterval
        self.systemPrompt = systemPrompt
        self.passwordHash = passwordHash
        self.protectionLevel = protectionLevel
        self.encryptionKeyWrapped = encryptionKeyWrapped
        self.encryptionSalt = encryptionSalt
        self.isEncrypted = isEncrypted
        self.sortOrder = sortOrder
    }
}

/// An indexed document — tracks metadata about a file that has been ingested.
nonisolated struct IndexedDocument: Identifiable, Codable, Sendable {
    let id: UUID
    let collectionId: UUID
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let dateIndexed: Date
    var chunkCount: Int
    let sourceType: SourceType
    let contentHash: String?
    var crawlGroupId: UUID?
    var summary: String?
    var enabled: Bool
    var hasDistilledChunks: Bool
    var useDistilled: Bool

    init(
        id: UUID = UUID(),
        collectionId: UUID,
        fileName: String,
        filePath: String,
        fileSize: Int64,
        dateIndexed: Date = .now,
        chunkCount: Int = 0,
        sourceType: SourceType = .file,
        contentHash: String? = nil,
        crawlGroupId: UUID? = nil,
        summary: String? = nil,
        enabled: Bool = true,
        hasDistilledChunks: Bool = false,
        useDistilled: Bool = false
    ) {
        self.id = id
        self.collectionId = collectionId
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.dateIndexed = dateIndexed
        self.chunkCount = chunkCount
        self.sourceType = sourceType
        self.contentHash = contentHash
        self.crawlGroupId = crawlGroupId
        self.summary = summary
        self.enabled = enabled
        self.hasDistilledChunks = hasDistilledChunks
        self.useDistilled = useDistilled
    }
}

/// Represents either a single document or a group of crawled pages for display.
nonisolated enum DocumentListItem: Identifiable, Sendable {
    case single(IndexedDocument)
    case bundle(groupId: UUID, pages: [IndexedDocument])

    var id: UUID {
        switch self {
        case .single(let doc): return doc.id
        case .bundle(let groupId, _): return groupId
        }
    }
}

/// A chunk of text from a document, along with its embedding vector.
nonisolated struct DocumentChunk: Identifiable, Sendable {
    let id: UUID
    let documentId: UUID
    let collectionId: UUID
    let content: String
    let chunkIndex: Int
    let embedding: [Float]
    let chunkType: ChunkType

    init(
        id: UUID = UUID(),
        documentId: UUID,
        collectionId: UUID,
        content: String,
        chunkIndex: Int,
        embedding: [Float],
        chunkType: ChunkType = .original
    ) {
        self.id = id
        self.documentId = documentId
        self.collectionId = collectionId
        self.content = content
        self.chunkIndex = chunkIndex
        self.embedding = embedding
        self.chunkType = chunkType
    }
}

/// A search result returned from a similarity query.
nonisolated struct SearchResult: Identifiable, Sendable {
    let id: UUID
    let chunk: DocumentChunk
    let score: Float       // cosine similarity score (0–1, higher = more similar)
    let documentName: String

    init(chunk: DocumentChunk, score: Float, documentName: String) {
        self.id = chunk.id
        self.chunk = chunk
        self.score = score
        self.documentName = documentName
    }
}

/// The result of a knowledge base query — includes the generated answer and the source chunks used.
nonisolated struct QueryResult: Sendable {
    let answer: String
    let sources: [SearchResult]
}

/// A single message in the conversation history.
nonisolated struct ConversationMessage: Identifiable, Sendable {
    let id = UUID()
    let role: ConversationRole
    let content: String
    let sources: [SearchResult]

    init(role: ConversationRole, content: String, sources: [SearchResult] = []) {
        self.role = role
        self.content = content
        self.sources = sources
    }
}

nonisolated enum ConversationRole: Sendable {
    case user
    case assistant
}

/// Report from a collection optimization run.
nonisolated struct OptimizationReport: Sendable {
    let documentsDistilled: Int
    let summariesGenerated: Int
    let duplicatesRemoved: Int
    let chunksBefore: Int
    let chunksAfter: Int
}

/// Lightweight chunk representation for browsing (no embedding data).
nonisolated struct ChunkBrowseItem: Identifiable, Sendable {
    let id: UUID
    let documentId: UUID
    let documentName: String
    let content: String
    let chunkIndex: Int
    let chunkType: ChunkType
}

// MARK: - Remote Indexa

/// A remote Indexa server that this client connects to.
nonisolated struct RemoteServer: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var baseURL: String
    var apiKey: String?
    var isConnected: Bool

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String? = nil, isConnected: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.isConnected = isConnected
    }
}

/// A collection on a remote Indexa server.
nonisolated struct RemoteCollection: Identifiable, Sendable {
    let id: UUID
    let name: String
    let isProtected: Bool
    let documentCount: Int?
    let protectionLevel: ProtectionLevel?
}

/// The result of a query against a remote Indexa server.
nonisolated struct RemoteQueryResult: Sendable {
    let answer: String
    let sources: [RemoteSource]
    let sourcesMasked: Bool
}

/// A single source from a remote query result.
nonisolated struct RemoteSource: Identifiable, Sendable {
    let id = UUID()
    let document: String
    let content: String
    let score: Float
}
