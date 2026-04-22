import Foundation
import SQLite3
import CryptoKit

/// SQLite-backed storage for collections, documents, and chunk embeddings.
/// Performs cosine similarity search in-memory for vector queries.
nonisolated final class VectorStore: Sendable {
    private let dbPath: String

    init() {
        // Store the database in the app's Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let indexaDir = appSupport.appendingPathComponent("Indexa", isDirectory: true)
        try? FileManager.default.createDirectory(at: indexaDir, withIntermediateDirectories: true)
        self.dbPath = indexaDir.appendingPathComponent("indexa.db").path
    }

    /// Testable initializer — use a temp file path for isolated tests.
    init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Create a VectorStore backed by a temporary file for testing.
    static func makeTestStore() -> VectorStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexa_test_\(UUID().uuidString).db").path
        return VectorStore(dbPath: path)
    }

    // MARK: - Database setup

    func createTablesIfNeeded() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE IF NOT EXISTS collections (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            date_created REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            collection_id TEXT NOT NULL,
            file_name TEXT NOT NULL,
            file_path TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            date_indexed REAL NOT NULL,
            chunk_count INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            collection_id TEXT NOT NULL,
            content TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
            FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_collection ON chunks(collection_id);
        CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id);
        CREATE INDEX IF NOT EXISTS idx_documents_collection ON documents(collection_id);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw VectorStoreError.databaseError(msg)
        }

        // Schema migrations — add new columns (safe no-op if they already exist)
        let migrations = [
            "ALTER TABLE documents ADD COLUMN source_type TEXT NOT NULL DEFAULT 'file'",
            "ALTER TABLE documents ADD COLUMN content_hash TEXT",
            "ALTER TABLE collections ADD COLUMN refresh_interval TEXT NOT NULL DEFAULT 'never'",
            "ALTER TABLE documents ADD COLUMN summary TEXT",
            "ALTER TABLE documents ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1",
            "ALTER TABLE chunks ADD COLUMN chunk_type TEXT NOT NULL DEFAULT 'original'",
            "ALTER TABLE documents ADD COLUMN has_distilled_chunks INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE documents ADD COLUMN use_distilled INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE documents ADD COLUMN crawl_group_id TEXT",
            "ALTER TABLE collections ADD COLUMN system_prompt TEXT",
            "ALTER TABLE collections ADD COLUMN password_hash TEXT",
            "ALTER TABLE collections ADD COLUMN protection_level TEXT",
            "ALTER TABLE collections ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE documents ADD COLUMN distill_checkpoint TEXT",
            "ALTER TABLE collections ADD COLUMN encryption_key_wrapped TEXT",
            "ALTER TABLE collections ADD COLUMN encryption_salt TEXT",
            "ALTER TABLE collections ADD COLUMN is_encrypted INTEGER NOT NULL DEFAULT 0"
        ]
        for migrationSQL in migrations {
            var migErr: UnsafeMutablePointer<CChar>?
            let migResult = sqlite3_exec(db, migrationSQL, nil, nil, &migErr)
            if migResult != SQLITE_OK {
                let migMsg = migErr.map { String(cString: $0) } ?? ""
                sqlite3_free(migErr)
                // Ignore "duplicate column" errors — column already exists
                if !migMsg.contains("duplicate column") {
                    throw VectorStoreError.databaseError(migMsg)
                }
            }
        }

        // Additional indexes
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chunks_type ON chunks(document_id, chunk_type)", nil, nil, nil)

        // FTS5 full-text index for hybrid (keyword + vector) search
        // Porter stemming: "diverter" matches "diverters", "diverting", etc.
        let ftsSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            content,
            chunk_id UNINDEXED,
            document_id UNINDEXED,
            collection_id UNINDEXED,
            tokenize='porter unicode61'
        );
        """
        sqlite3_exec(db, ftsSQL, nil, nil, nil)
    }

    /// Drop and recreate FTS5 table with porter stemming tokenizer, then repopulate.
    func rebuildFTSWithPorter() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "DROP TABLE IF EXISTS chunks_fts", nil, nil, nil)

        let ftsSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            content,
            chunk_id UNINDEXED,
            document_id UNINDEXED,
            collection_id UNINDEXED,
            tokenize='porter unicode61'
        );
        """
        sqlite3_exec(db, ftsSQL, nil, nil, nil)

        // Exclude encrypted collections (their content is ciphertext)
        let sql = "INSERT INTO chunks_fts (chunk_id, document_id, collection_id, content) SELECT c.id, c.document_id, c.collection_id, c.content FROM chunks c JOIN collections col ON c.collection_id = col.id WHERE col.is_encrypted = 0"
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw VectorStoreError.databaseError(msg)
        }
    }

    /// Backfill the FTS5 index from existing chunks. Run once during migration.
    func populateFTSIndex() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        // Clear and rebuild
        sqlite3_exec(db, "DELETE FROM chunks_fts", nil, nil, nil)

        // Exclude encrypted collections (their content is ciphertext)
        let sql = "INSERT INTO chunks_fts (chunk_id, document_id, collection_id, content) SELECT c.id, c.document_id, c.collection_id, c.content FROM chunks c JOIN collections col ON c.collection_id = col.id WHERE col.is_encrypted = 0"
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw VectorStoreError.databaseError(msg)
        }
    }

    // MARK: - Collections

    func saveCollection(_ collection: Collection) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "INSERT OR REPLACE INTO collections (id, name, date_created, refresh_interval, system_prompt, password_hash, protection_level, sort_order, encryption_key_wrapped, encryption_salt, is_encrypted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, collection.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, collection.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, collection.dateCreated.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, collection.refreshInterval.rawValue, -1, SQLITE_TRANSIENT)
        if let prompt = collection.systemPrompt {
            sqlite3_bind_text(stmt, 5, prompt, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let hash = collection.passwordHash {
            sqlite3_bind_text(stmt, 6, hash, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let level = collection.protectionLevel {
            sqlite3_bind_text(stmt, 7, level.rawValue, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int(stmt, 8, Int32(collection.sortOrder))
        if let wrappedKey = collection.encryptionKeyWrapped {
            sqlite3_bind_text(stmt, 9, wrappedKey, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let salt = collection.encryptionSalt {
            sqlite3_bind_text(stmt, 10, salt, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_bind_int(stmt, 11, collection.isEncrypted ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func loadCollections() throws -> [Collection] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, name, date_created, refresh_interval, system_prompt, password_hash, protection_level, sort_order, encryption_key_wrapped, encryption_salt, is_encrypted FROM collections ORDER BY sort_order ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var collections: [Collection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let dateCreated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let refreshStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "never"
            let refreshInterval = RefreshInterval(rawValue: refreshStr) ?? .never
            let systemPrompt = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let passwordHash = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let protectionStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let protectionLevel = protectionStr.flatMap { ProtectionLevel(rawValue: $0) }
            let sortOrder = Int(sqlite3_column_int(stmt, 7))
            let encryptionKeyWrapped = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let encryptionSalt = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let isEncrypted = sqlite3_column_int(stmt, 10) != 0

            if let id = UUID(uuidString: idStr) {
                collections.append(Collection(id: id, name: name, dateCreated: dateCreated, refreshInterval: refreshInterval, systemPrompt: systemPrompt, passwordHash: passwordHash, protectionLevel: protectionLevel, encryptionKeyWrapped: encryptionKeyWrapped, encryptionSalt: encryptionSalt, isEncrypted: isEncrypted, sortOrder: sortOrder))
            }
        }
        return collections
    }

    func deleteCollection(id: UUID) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        // Clean FTS5 before CASCADE deletes chunks
        sqlite3_exec(db, "DELETE FROM chunks_fts WHERE collection_id = '\(id.uuidString)'", nil, nil, nil)

        // Foreign keys with ON DELETE CASCADE handle chunks and documents
        let pragmaResult = sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        guard pragmaResult == SQLITE_OK else {
            throw VectorStoreError.databaseError("Failed to enable foreign keys")
        }

        let sql = "DELETE FROM collections WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Documents

    func saveDocument(_ doc: IndexedDocument) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
        INSERT OR REPLACE INTO documents (id, collection_id, file_name, file_path, file_size, date_indexed, chunk_count, source_type, content_hash, crawl_group_id, summary, enabled, has_distilled_chunks, use_distilled)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, doc.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, doc.collectionId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, doc.fileName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, doc.filePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, doc.fileSize)
        sqlite3_bind_double(stmt, 6, doc.dateIndexed.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 7, Int32(doc.chunkCount))
        sqlite3_bind_text(stmt, 8, doc.sourceType.rawValue, -1, SQLITE_TRANSIENT)
        if let hash = doc.contentHash {
            sqlite3_bind_text(stmt, 9, hash, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let groupId = doc.crawlGroupId {
            sqlite3_bind_text(stmt, 10, groupId.uuidString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if let summary = doc.summary {
            sqlite3_bind_text(stmt, 11, summary, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_int(stmt, 12, doc.enabled ? 1 : 0)
        sqlite3_bind_int(stmt, 13, doc.hasDistilledChunks ? 1 : 0)
        sqlite3_bind_int(stmt, 14, doc.useDistilled ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func documentCount(collectionId: UUID) throws -> Int {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM documents WHERE collection_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func loadDocuments(collectionId: UUID) throws -> [IndexedDocument] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, collection_id, file_name, file_path, file_size, date_indexed, chunk_count, source_type, content_hash, crawl_group_id, summary, enabled, has_distilled_chunks, use_distilled FROM documents WHERE collection_id = ? ORDER BY date_indexed DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return try readDocumentRows(stmt: stmt!)
    }

    /// Load only web-sourced documents for a collection (used by refresh scheduler).
    func loadWebDocuments(collectionId: UUID) throws -> [IndexedDocument] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, collection_id, file_name, file_path, file_size, date_indexed, chunk_count, source_type, content_hash, crawl_group_id, summary, enabled, has_distilled_chunks, use_distilled FROM documents WHERE collection_id = ? AND source_type = 'web' ORDER BY date_indexed DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return try readDocumentRows(stmt: stmt!)
    }

    /// Update a collection's refresh interval.
    func renameCollection(id: UUID, name: String) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE collections SET name = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateCollectionSystemPrompt(id: UUID, systemPrompt: String?) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE collections SET system_prompt = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let prompt = systemPrompt, !prompt.isEmpty {
            sqlite3_bind_text(stmt, 1, prompt, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateCollectionProtection(id: UUID, passwordHash: String?, protectionLevel: ProtectionLevel?) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE collections SET password_hash = ?, protection_level = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let hash = passwordHash {
            sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        if let level = protectionLevel {
            sqlite3_bind_text(stmt, 2, level.rawValue, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateCollectionRefreshInterval(id: UUID, interval: RefreshInterval) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE collections SET refresh_interval = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, interval.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Helper to read document rows from a prepared statement.
    private func readDocumentRows(stmt: OpaquePointer) throws -> [IndexedDocument] {
        var docs: [IndexedDocument] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let colIdStr = String(cString: sqlite3_column_text(stmt, 1))
            let fileName = String(cString: sqlite3_column_text(stmt, 2))
            let filePath = String(cString: sqlite3_column_text(stmt, 3))
            let fileSize = sqlite3_column_int64(stmt, 4)
            let dateIndexed = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let chunkCount = Int(sqlite3_column_int(stmt, 6))
            let sourceStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "file"
            let sourceType = SourceType(rawValue: sourceStr) ?? .file
            let contentHash = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let crawlGroupIdStr = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let crawlGroupId = crawlGroupIdStr.flatMap { UUID(uuidString: $0) }
            let summary = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let enabled = sqlite3_column_int(stmt, 11) != 0
            let hasDistilledChunks = sqlite3_column_int(stmt, 12) != 0
            let useDistilled = sqlite3_column_int(stmt, 13) != 0

            if let id = UUID(uuidString: idStr), let colId = UUID(uuidString: colIdStr) {
                docs.append(IndexedDocument(
                    id: id, collectionId: colId, fileName: fileName,
                    filePath: filePath, fileSize: fileSize,
                    dateIndexed: dateIndexed, chunkCount: chunkCount,
                    sourceType: sourceType, contentHash: contentHash,
                    crawlGroupId: crawlGroupId,
                    summary: summary, enabled: enabled,
                    hasDistilledChunks: hasDistilledChunks, useDistilled: useDistilled
                ))
            }
        }
        return docs
    }

    func deleteDocument(id: UUID) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        // Clean FTS5 before CASCADE deletes chunks
        sqlite3_exec(db, "DELETE FROM chunks_fts WHERE document_id = '\(id.uuidString)'", nil, nil, nil)

        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)

        let sql = "DELETE FROM documents WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Crawl group operations

    func updateDocumentsEnabled(crawlGroupId: UUID, enabled: Bool) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE documents SET enabled = ? WHERE crawl_group_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        sqlite3_bind_text(stmt, 2, crawlGroupId.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func deleteDocumentGroup(crawlGroupId: UUID) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        // Clean FTS5 for all chunks in documents of this crawl group
        sqlite3_exec(db, "DELETE FROM chunks_fts WHERE document_id IN (SELECT id FROM documents WHERE crawl_group_id = '\(crawlGroupId.uuidString)')", nil, nil, nil)

        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)

        let sql = "DELETE FROM documents WHERE crawl_group_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, crawlGroupId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Chunks

    func saveChunks(_ chunks: [DocumentChunk], encryptionKey: SymmetricKey? = nil, skipFTS: Bool = false) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = "INSERT INTO chunks (id, document_id, collection_id, content, chunk_index, embedding, chunk_type) VALUES (?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for chunk in chunks {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, chunk.documentId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, chunk.collectionId.uuidString, -1, SQLITE_TRANSIENT)

            // Encrypt content if an encryption key is provided
            let contentToStore: String
            if let key = encryptionKey {
                contentToStore = try CryptoManager.encryptContent(chunk.content, using: key)
            } else {
                contentToStore = chunk.content
            }
            sqlite3_bind_text(stmt, 4, contentToStore, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(chunk.chunkIndex))

            // Store embedding as raw float bytes (unencrypted — vectors don't reveal text)
            let embeddingData = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = embeddingData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(embeddingData.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_text(stmt, 7, chunk.chunkType.rawValue, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
            }
        }

        // Skip FTS5 for encrypted collections (ciphertext is not searchable)
        if encryptionKey == nil && !skipFTS {
            let ftsSql = "INSERT INTO chunks_fts (chunk_id, document_id, collection_id, content) VALUES (?, ?, ?, ?)"
            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, ftsSql, -1, &ftsStmt, nil) == SQLITE_OK {
                for chunk in chunks {
                    sqlite3_reset(ftsStmt)
                    sqlite3_bind_text(ftsStmt, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(ftsStmt, 2, chunk.documentId.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(ftsStmt, 3, chunk.collectionId.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(ftsStmt, 4, chunk.content, -1, SQLITE_TRANSIENT)
                    sqlite3_step(ftsStmt)
                }
                sqlite3_finalize(ftsStmt)
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Document updates

    func updateDocumentSummary(id: UUID, summary: String, encryptionKey: SymmetricKey? = nil) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE documents SET summary = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let summaryToStore: String
        if let key = encryptionKey {
            summaryToStore = try CryptoManager.encryptContent(summary, using: key)
        } else {
            summaryToStore = summary
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, summaryToStore, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateDocumentEnabled(id: UUID, enabled: Bool) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE documents SET enabled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateDocumentDistillStatus(id: UUID, hasDistilledChunks: Bool, useDistilled: Bool) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE documents SET has_distilled_chunks = ?, use_distilled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, hasDistilledChunks ? 1 : 0)
        sqlite3_bind_int(stmt, 2, useDistilled ? 1 : 0)
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateDocumentUseDistilled(id: UUID, useDistilled: Bool) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE documents SET use_distilled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, useDistilled ? 1 : 0)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func loadOriginalChunks(documentId: UUID, decryptionKey: SymmetricKey? = nil) throws -> [DocumentChunk] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, document_id, collection_id, content, chunk_index, embedding, chunk_type FROM chunks WHERE document_id = ? AND chunk_type = 'original' ORDER BY chunk_index"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return try readChunkRows(stmt: stmt!, decryptionKey: decryptionKey)
    }

    func deleteDistilledChunks(documentId: UUID) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        // Clean FTS5 for distilled chunks
        sqlite3_exec(db, "DELETE FROM chunks_fts WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = '\(documentId.uuidString)' AND chunk_type = 'distilled')", nil, nil, nil)

        let sql = "DELETE FROM chunks WHERE document_id = ? AND chunk_type = 'distilled'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Distillation checkpoints

    /// Save distilled section texts as a JSON checkpoint for crash recovery.
    func saveDistillCheckpoint(documentId: UUID, sections: [String], totalOriginalChunks: Int, encryptionKey: SymmetricKey? = nil) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let payload: [String: Any] = ["sections": sections, "total": totalOriginalChunks]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let stringToStore: String
        if let key = encryptionKey {
            stringToStore = try CryptoManager.encryptContent(jsonString, using: key)
        } else {
            stringToStore = jsonString
        }

        let sql = "UPDATE documents SET distill_checkpoint = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, stringToStore, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, documentId.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Load an existing distillation checkpoint. Returns nil if none exists.
    func loadDistillCheckpoint(documentId: UUID, decryptionKey: SymmetricKey? = nil) throws -> (sections: [String], totalOriginalChunks: Int)? {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT distill_checkpoint FROM documents WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }

        let rawString = String(cString: cStr)
        let jsonString: String
        if let key = decryptionKey {
            jsonString = (try? CryptoManager.decryptContent(rawString, using: key)) ?? rawString
        } else {
            jsonString = rawString
        }
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = obj["sections"] as? [String],
              let total = obj["total"] as? Int else {
            return nil
        }

        return (sections: sections, totalOriginalChunks: total)
    }

    /// Clear a document's distillation checkpoint.
    func clearDistillCheckpoint(documentId: UUID) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE documents SET distill_checkpoint = NULL WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Clear all distillation checkpoints (used by Reset All Data).
    func clearAllDistillCheckpoints() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "UPDATE documents SET distill_checkpoint = NULL WHERE distill_checkpoint IS NOT NULL", nil, nil, nil)
    }

    func loadDocumentSummaries(collectionId: UUID, decryptionKey: SymmetricKey? = nil) throws -> [(documentName: String, summary: String)] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT file_name, summary FROM documents WHERE collection_id = ? AND enabled = 1 AND summary IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(documentName: String, summary: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let rawSummary = String(cString: sqlite3_column_text(stmt, 1))
            let summary: String
            if let key = decryptionKey {
                summary = (try? CryptoManager.decryptContent(rawSummary, using: key)) ?? rawSummary
            } else {
                summary = rawSummary
            }
            results.append((documentName: name, summary: summary))
        }
        return results
    }

    // MARK: - Similarity search

    /// Search for the most similar chunks to a query embedding.
    /// Uses cosine similarity computed in-memory.
    func searchSimilar(
        queryEmbedding: [Float],
        collectionId: UUID? = nil,
        topK: Int = 5,
        decryptionKey: SymmetricKey? = nil
    ) throws -> [(chunkId: UUID, documentId: UUID, content: String, score: Float)] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql: String
        if collectionId != nil {
            sql = "SELECT c.id, c.document_id, c.content, c.embedding FROM chunks c JOIN documents d ON c.document_id = d.id WHERE c.collection_id = ? AND d.enabled = 1 AND c.chunk_type = CASE WHEN d.use_distilled = 1 AND d.has_distilled_chunks = 1 THEN 'distilled' ELSE 'original' END"
        } else {
            // Cross-collection search: exclude encrypted collections when no decryption key is available
            // (encrypted chunk content is ciphertext and would be useless to the LLM)
            sql = "SELECT c.id, c.document_id, c.content, c.embedding FROM chunks c JOIN documents d ON c.document_id = d.id JOIN collections col ON c.collection_id = col.id WHERE d.enabled = 1 AND col.is_encrypted = 0 AND c.chunk_type = CASE WHEN d.use_distilled = 1 AND d.has_distilled_chunks = 1 THEN 'distilled' ELSE 'original' END"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if let collectionId {
            sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        // Top-K heap: only keep the best topK results in memory instead of all chunks.
        // For large KBs (100K+ chunks), this avoids accumulating hundreds of MB of results.
        var topResults: [(chunkId: UUID, documentId: UUID, content: String, score: Float)] = []
        var minScore: Float = -.infinity

        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let docIdStr = String(cString: sqlite3_column_text(stmt, 1))

            guard let chunkId = UUID(uuidString: idStr),
                  let docId = UUID(uuidString: docIdStr) else { continue }

            // Read embedding blob
            let blobBytes = sqlite3_column_bytes(stmt, 3)
            guard let blobPtr = sqlite3_column_blob(stmt, 3), blobBytes > 0 else { continue }

            let floatCount = Int(blobBytes) / MemoryLayout<Float>.size
            let score: Float = blobPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                cosineSimilarity(queryEmbedding, Array(UnsafeBufferPointer(start: ptr, count: floatCount)))
            }

            // Early skip: if heap is full and this score can't beat the minimum, skip reading content
            if topResults.count >= topK && score <= minScore { continue }

            let rawContent = String(cString: sqlite3_column_text(stmt, 2))
            let content: String
            if let key = decryptionKey {
                content = (try? CryptoManager.decryptContent(rawContent, using: key)) ?? rawContent
            } else {
                content = rawContent
            }
            let entry = (chunkId: chunkId, documentId: docId, content: content, score: score)

            if topResults.count < topK {
                topResults.append(entry)
                if topResults.count == topK {
                    minScore = topResults.min(by: { $0.score < $1.score })?.score ?? -.infinity
                }
            } else {
                // Replace the minimum-scoring element
                if let minIdx = topResults.firstIndex(where: { $0.score == minScore }) {
                    topResults[minIdx] = entry
                }
                minScore = topResults.min(by: { $0.score < $1.score })?.score ?? -.infinity
            }
        }

        topResults.sort { $0.score > $1.score }
        return topResults
    }

    // MARK: - FTS5 keyword search

    /// Search using BM25 keyword matching via FTS5.
    func searchFTS(
        query: String,
        collectionId: UUID? = nil,
        topK: Int = 20,
        isCollectionEncrypted: Bool = false
    ) throws -> [(chunkId: UUID, documentId: UUID, content: String, score: Double)] {
        // FTS5 cannot search encrypted ciphertext — return empty for encrypted collections
        if isCollectionEncrypted { return [] }
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }

        // FTS always searches original chunks for keyword accuracy.
        // Distilled chunks are AI-rewritten and may not contain the exact query terms.
        let sql: String
        if collectionId != nil {
            sql = """
            SELECT f.chunk_id, f.document_id, f.content, bm25(chunks_fts) as score
            FROM chunks_fts f
            JOIN documents d ON f.document_id = d.id
            JOIN chunks c ON f.chunk_id = c.id
            WHERE chunks_fts MATCH ?
              AND f.collection_id = ?
              AND d.enabled = 1
              AND c.chunk_type = 'original'
            ORDER BY score
            LIMIT ?
            """
        } else {
            sql = """
            SELECT f.chunk_id, f.document_id, f.content, bm25(chunks_fts) as score
            FROM chunks_fts f
            JOIN documents d ON f.document_id = d.id
            JOIN chunks c ON f.chunk_id = c.id
            WHERE chunks_fts MATCH ?
              AND d.enabled = 1
              AND c.chunk_type = 'original'
            ORDER BY score
            LIMIT ?
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // FTS5 may not exist yet or query may be malformed — return empty
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sanitized, -1, SQLITE_TRANSIENT)
        if let collectionId {
            sqlite3_bind_text(stmt, 2, collectionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(topK))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(topK))
        }

        var results: [(chunkId: UUID, documentId: UUID, content: String, score: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkIdStr = String(cString: sqlite3_column_text(stmt, 0))
            let docIdStr = String(cString: sqlite3_column_text(stmt, 1))
            let content = String(cString: sqlite3_column_text(stmt, 2))
            let score = sqlite3_column_double(stmt, 3)

            if let chunkId = UUID(uuidString: chunkIdStr), let docId = UUID(uuidString: docIdStr) {
                results.append((chunkId: chunkId, documentId: docId, content: content, score: score))
            }
        }
        return results
    }

    /// Common English stop words that add noise to keyword search.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "must",
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "it",
        "they", "them", "their", "this", "that", "these", "those",
        "what", "which", "who", "whom", "how", "when", "where", "why",
        "in", "on", "at", "to", "for", "of", "with", "by", "from",
        "about", "into", "through", "during", "before", "after",
        "and", "or", "but", "not", "no", "if", "then", "so", "than",
        "too", "very", "just", "also", "only", "all", "any", "each",
        "both", "few", "more", "most", "some", "such", "other"
    ]

    /// Escape FTS5 special characters, remove stop words, and join with OR.
    /// Each keyword contributes independently to BM25 scoring —
    /// chunks matching more terms rank higher, but partial matches still surface.
    private func sanitizeFTSQuery(_ query: String) -> String {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { $0.lowercased() }
            .filter { !Self.stopWords.contains($0) && $0.count > 1 }
        guard !words.isEmpty else { return "" }
        return words.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    // MARK: - Hybrid search (vector + keyword via RRF)

    /// Combine vector similarity and BM25 keyword search using Reciprocal Rank Fusion.
    func searchHybrid(
        queryEmbedding: [Float],
        queryText: String,
        collectionId: UUID? = nil,
        topK: Int = 5,
        decryptionKey: SymmetricKey? = nil
    ) throws -> [(chunkId: UUID, documentId: UUID, content: String, score: Float)] {
        // 6x multiplier compensates for chunk_type filtering that removes
        // ~50% of FTS candidates (both original+distilled are indexed but only one type is used)
        let candidateCount = topK * 6
        let isEncrypted = decryptionKey != nil

        // Get candidates from both retrieval methods
        let vectorResults = try searchSimilar(queryEmbedding: queryEmbedding, collectionId: collectionId, topK: candidateCount, decryptionKey: decryptionKey)
        let ftsResults = try searchFTS(query: queryText, collectionId: collectionId, topK: candidateCount, isCollectionEncrypted: isEncrypted)

        // Reciprocal Rank Fusion: score = 1/(k + rank)
        let k: Float = 60.0
        var scores: [UUID: Float] = [:]
        var contents: [UUID: (documentId: UUID, content: String)] = [:]

        for (rank, result) in vectorResults.enumerated() {
            let rrf = 1.0 / (k + Float(rank + 1))
            scores[result.chunkId, default: 0] += rrf
            contents[result.chunkId] = (result.documentId, result.content)
        }

        for (rank, result) in ftsResults.enumerated() {
            let rrf = 1.0 / (k + Float(rank + 1))
            scores[result.chunkId, default: 0] += rrf
            contents[result.chunkId] = (result.documentId, result.content)
        }

        // Keyword match boost: chunks containing actual query terms get a score bonus.
        // This ensures "bullet" search returns chunks with the word "bullet" above
        // chunks that are only semantically similar.
        let queryWords = queryText.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !Self.stopWords.contains($0) && $0.count > 1 }

        if !queryWords.isEmpty {
            for (chunkId, info) in contents {
                let lower = info.content.lowercased()
                let matchCount = queryWords.filter { lower.contains($0) }.count
                if matchCount > 0 {
                    let boost = Float(matchCount) / Float(queryWords.count) * 0.02
                    scores[chunkId, default: 0] += boost
                }
            }
        }

        // Sort by combined RRF score
        let sorted = scores.sorted { $0.value > $1.value }
        
        // Document diversity: ensure at least one chunk per document appears
        // before filling remaining slots by pure score
        var selected: [(chunkId: UUID, documentId: UUID, content: String, score: Float)] = []
        var seenDocuments: Set<UUID> = []
        var remainders: [(chunkId: UUID, documentId: UUID, content: String, score: Float)] = []
        
        for (chunkId, score) in sorted {
            guard let info = contents[chunkId] else { continue }
            let entry = (chunkId: chunkId, documentId: info.documentId, content: info.content, score: score)
            if !seenDocuments.contains(info.documentId) {
                seenDocuments.insert(info.documentId)
                selected.append(entry)
            } else {
                remainders.append(entry)
            }
        }
        
        // Fill remaining slots with highest-scoring chunks from any document
        if selected.count < topK {
            selected.append(contentsOf: remainders.prefix(topK - selected.count))
        }
        
        // Sort final results by score and truncate to topK
        return Array(selected.sorted { $0.score > $1.score }.prefix(topK))
    }

    /// Look up a document's file name by its ID.
    func documentName(for documentId: UUID) throws -> String {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT file_name FROM documents WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return "Unknown"
    }

    /// Look up a document's summary by its ID.
    func documentSummary(for documentId: UUID, decryptionKey: SymmetricKey? = nil) throws -> String? {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT summary FROM documents WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return nil }
            if let key = decryptionKey {
                return (try? CryptoManager.decryptContent(raw, using: key)) ?? raw
            }
            return raw
        }
        return nil
    }

    // MARK: - Bulk export helpers

    /// Load a single collection by ID.
    func loadCollection(id: UUID) throws -> Collection? {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, name, date_created, refresh_interval, system_prompt, password_hash, protection_level, encryption_key_wrapped, encryption_salt, is_encrypted FROM collections WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let dateCreated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let refreshStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "never"
            let refreshInterval = RefreshInterval(rawValue: refreshStr) ?? .never
            let systemPrompt = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let passwordHash = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let protectionStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let protectionLevel = protectionStr.flatMap { ProtectionLevel(rawValue: $0) }
            let encryptionKeyWrapped = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let encryptionSalt = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let isEncrypted = sqlite3_column_int(stmt, 9) != 0
            if let uuid = UUID(uuidString: idStr) {
                return Collection(id: uuid, name: name, dateCreated: dateCreated, refreshInterval: refreshInterval, systemPrompt: systemPrompt, passwordHash: passwordHash, protectionLevel: protectionLevel, encryptionKeyWrapped: encryptionKeyWrapped, encryptionSalt: encryptionSalt, isEncrypted: isEncrypted)
            }
        }
        return nil
    }

    /// Load all chunks for a given document, including embeddings.
    func loadChunks(documentId: UUID, decryptionKey: SymmetricKey? = nil) throws -> [DocumentChunk] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, document_id, collection_id, content, chunk_index, embedding, chunk_type FROM chunks WHERE document_id = ? ORDER BY chunk_index"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, documentId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return try readChunkRows(stmt: stmt!, decryptionKey: decryptionKey)
    }

    /// Load all chunks for a given collection, including embeddings.
    func loadChunks(collectionId: UUID, decryptionKey: SymmetricKey? = nil) throws -> [DocumentChunk] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, document_id, collection_id, content, chunk_index, embedding, chunk_type FROM chunks WHERE collection_id = ? ORDER BY chunk_index"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return try readChunkRows(stmt: stmt!, decryptionKey: decryptionKey)
    }

    /// Helper to read chunk rows from a prepared statement.
    private func readChunkRows(stmt: OpaquePointer, decryptionKey: SymmetricKey? = nil) throws -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let docIdStr = String(cString: sqlite3_column_text(stmt, 1))
            let colIdStr = String(cString: sqlite3_column_text(stmt, 2))
            let rawContent = String(cString: sqlite3_column_text(stmt, 3))
            let content: String
            if let key = decryptionKey {
                content = (try? CryptoManager.decryptContent(rawContent, using: key)) ?? rawContent
            } else {
                content = rawContent
            }
            let chunkIndex = Int(sqlite3_column_int(stmt, 4))

            guard let id = UUID(uuidString: idStr),
                  let docId = UUID(uuidString: docIdStr),
                  let colId = UUID(uuidString: colIdStr) else { continue }

            let blobBytes = sqlite3_column_bytes(stmt, 5)
            guard let blobPtr = sqlite3_column_blob(stmt, 5), blobBytes > 0 else { continue }

            let floatCount = Int(blobBytes) / MemoryLayout<Float>.size
            let embedding = Array(UnsafeBufferPointer(
                start: blobPtr.assumingMemoryBound(to: Float.self),
                count: floatCount
            ))

            let chunkTypeStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "original"
            let chunkType = ChunkType(rawValue: chunkTypeStr) ?? .original

            chunks.append(DocumentChunk(
                id: id, documentId: docId, collectionId: colId,
                content: content, chunkIndex: chunkIndex, embedding: embedding,
                chunkType: chunkType
            ))
        }

        return chunks
    }

    // MARK: - Private helpers

    private func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw VectorStoreError.databaseError("Cannot open database at \(dbPath)")
        }
        return db
    }

    /// Cosine similarity between two vectors.
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }

        return dot / denom
    }

    // MARK: - Collection sort order

    /// Initialize sort_order for existing collections based on current date ordering (newest first = 0).
    func initializeSortOrder() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
            UPDATE collections SET sort_order = (
                SELECT COUNT(*) FROM collections c2
                WHERE c2.date_created > collections.date_created
            )
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw VectorStoreError.databaseError(msg)
        }
    }

    /// Batch-update sort_order for multiple collections in a single transaction.
    func updateCollectionSortOrders(_ orders: [(id: UUID, sortOrder: Int)]) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = "UPDATE collections SET sort_order = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for order in orders {
            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(order.sortOrder))
            sqlite3_bind_text(stmt, 2, order.id.uuidString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Chunk browsing (paginated, no embeddings)

    /// Load chunks for browsing with optional filters. Returns lightweight items without embeddings.
    func loadChunksPaginated(
        collectionId: UUID,
        offset: Int,
        limit: Int,
        chunkType: ChunkType? = nil,
        documentId: UUID? = nil,
        searchText: String? = nil,
        decryptionKey: SymmetricKey? = nil
    ) throws -> [ChunkBrowseItem] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        var conditions = ["c.collection_id = ?"]
        var binds: [Any] = [collectionId.uuidString]

        if let chunkType {
            conditions.append("c.chunk_type = ?")
            binds.append(chunkType.rawValue)
        }
        if let documentId {
            conditions.append("c.document_id = ?")
            binds.append(documentId.uuidString)
        }
        if let searchText, !searchText.isEmpty {
            conditions.append("c.content LIKE ?")
            binds.append("%\(searchText)%")
        }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = """
            SELECT c.id, c.document_id, d.file_name, c.content, c.chunk_index, c.chunk_type
            FROM chunks c JOIN documents d ON c.document_id = d.id
            WHERE \(whereClause)
            ORDER BY d.file_name, c.chunk_index ASC
            LIMIT ? OFFSET ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var idx: Int32 = 1
        for bind in binds {
            sqlite3_bind_text(stmt, idx, "\(bind)", -1, SQLITE_TRANSIENT)
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))
        sqlite3_bind_int(stmt, idx + 1, Int32(offset))

        var results: [ChunkBrowseItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let docIdStr = String(cString: sqlite3_column_text(stmt, 1))
            let docName = String(cString: sqlite3_column_text(stmt, 2))
            let rawContent = String(cString: sqlite3_column_text(stmt, 3))
            let chunkIndex = Int(sqlite3_column_int(stmt, 4))
            let typeStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "original"

            guard let id = UUID(uuidString: idStr),
                  let docId = UUID(uuidString: docIdStr) else { continue }

            let content: String
            if let key = decryptionKey {
                content = (try? CryptoManager.decryptContent(rawContent, using: key)) ?? rawContent
            } else {
                content = rawContent
            }

            results.append(ChunkBrowseItem(
                id: id,
                documentId: docId,
                documentName: docName,
                content: content,
                chunkIndex: chunkIndex,
                chunkType: ChunkType(rawValue: typeStr) ?? .original
            ))
        }
        return results
    }

    /// Count chunks matching the given filters (for pagination).
    func chunkCountFiltered(
        collectionId: UUID,
        chunkType: ChunkType? = nil,
        documentId: UUID? = nil,
        searchText: String? = nil
    ) throws -> Int {
        let db = try openDB()
        defer { sqlite3_close(db) }

        var conditions = ["c.collection_id = ?"]
        var binds: [Any] = [collectionId.uuidString]

        if let chunkType {
            conditions.append("c.chunk_type = ?")
            binds.append(chunkType.rawValue)
        }
        if let documentId {
            conditions.append("c.document_id = ?")
            binds.append(documentId.uuidString)
        }
        if let searchText, !searchText.isEmpty {
            conditions.append("c.content LIKE ?")
            binds.append("%\(searchText)%")
        }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "SELECT COUNT(*) FROM chunks c WHERE \(whereClause)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var idx: Int32 = 1
        for bind in binds {
            sqlite3_bind_text(stmt, idx, "\(bind)", -1, SQLITE_TRANSIENT)
            idx += 1
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Deduplication & Optimization

    /// Lightweight struct for deduplication — avoids loading full chunk content.
    nonisolated struct ChunkEmbeddingInfo: Sendable {
        let chunkId: UUID
        let documentId: UUID
        let contentLength: Int
        let dateIndexed: Date
        let embedding: [Float]
    }

    /// Load active embeddings for a collection (respects enabled/use_distilled flags).
    func loadActiveEmbeddings(collectionId: UUID) throws -> [ChunkEmbeddingInfo] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT c.id, c.document_id, LENGTH(c.content), d.date_indexed, c.embedding
            FROM chunks c JOIN documents d ON c.document_id = d.id
            WHERE c.collection_id = ? AND d.enabled = 1
              AND c.chunk_type = CASE
                  WHEN d.use_distilled = 1 AND d.has_distilled_chunks = 1 THEN 'distilled'
                  ELSE 'original'
              END
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [ChunkEmbeddingInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let docIdStr = String(cString: sqlite3_column_text(stmt, 1))
            let contentLength = Int(sqlite3_column_int(stmt, 2))
            let dateIndexed = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))

            guard let chunkId = UUID(uuidString: idStr),
                  let docId = UUID(uuidString: docIdStr) else { continue }

            let blobBytes = sqlite3_column_bytes(stmt, 4)
            guard let blobPtr = sqlite3_column_blob(stmt, 4), blobBytes > 0 else { continue }

            let floatCount = Int(blobBytes) / MemoryLayout<Float>.size
            let embedding = Array(UnsafeBufferPointer(
                start: blobPtr.assumingMemoryBound(to: Float.self),
                count: floatCount
            ))

            results.append(ChunkEmbeddingInfo(
                chunkId: chunkId, documentId: docId,
                contentLength: contentLength, dateIndexed: dateIndexed,
                embedding: embedding
            ))
        }
        return results
    }

    /// Delete specific chunks by ID from both chunks table and FTS5 index.
    func deleteChunks(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let db = try openDB()
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for chunkId in ids {
            let idStr = chunkId.uuidString

            // Delete from FTS5
            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM chunks_fts WHERE chunk_id = ?", -1, &ftsStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(ftsStmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(ftsStmt)
                sqlite3_finalize(ftsStmt)
            }

            // Delete from chunks
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Run FTS5 optimize to merge b-tree segments for faster searches.
    func fts5Optimize() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let result = sqlite3_exec(db, "INSERT INTO chunks_fts(chunks_fts) VALUES('optimize')", nil, nil, nil)
        guard result == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Run VACUUM to reclaim disk space from deleted rows.
    func vacuumDatabase() throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let result = sqlite3_exec(db, "VACUUM", nil, nil, nil)
        guard result == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Encryption operations

    /// Update collection encryption metadata in the database.
    func updateCollectionEncryption(
        id: UUID,
        encryptionKeyWrapped: String?,
        encryptionSalt: String?,
        isEncrypted: Bool
    ) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "UPDATE collections SET encryption_key_wrapped = ?, encryption_salt = ?, is_encrypted = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let wrappedKey = encryptionKeyWrapped {
            sqlite3_bind_text(stmt, 1, wrappedKey, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        if let salt = encryptionSalt {
            sqlite3_bind_text(stmt, 2, salt, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, isEncrypted ? 1 : 0)
        sqlite3_bind_text(stmt, 4, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Encrypt all existing plaintext chunks for a collection in place.
    /// Used when adding protection to an existing unprotected collection.
    func encryptAllChunks(collectionId: UUID, key: SymmetricKey) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Select all chunks for this collection
        let selectSql = "SELECT id, content FROM chunks WHERE collection_id = ?"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(selectStmt, 1, collectionId.uuidString, -1, SQLITE_TRANSIENT)

        // Prepare update statement
        let updateSql = "UPDATE chunks SET content = ? WHERE id = ?"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(selectStmt)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        // Encrypt each chunk
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let chunkId = String(cString: sqlite3_column_text(selectStmt, 0))
            let plaintext = String(cString: sqlite3_column_text(selectStmt, 1))

            let ciphertext: String
            do {
                ciphertext = try CryptoManager.encryptContent(plaintext, using: key)
            } catch {
                sqlite3_finalize(selectStmt)
                sqlite3_finalize(updateStmt)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }

            sqlite3_reset(updateStmt)
            sqlite3_bind_text(updateStmt, 1, ciphertext, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(updateStmt, 2, chunkId, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                sqlite3_finalize(selectStmt)
                sqlite3_finalize(updateStmt)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
            }
        }

        sqlite3_finalize(selectStmt)
        sqlite3_finalize(updateStmt)

        // Remove FTS5 entries for this collection (ciphertext is not searchable)
        sqlite3_exec(db, "DELETE FROM chunks_fts WHERE collection_id = '\(collectionId.uuidString)'", nil, nil, nil)

        // Encrypt document summaries and distill checkpoints
        let docSelectSql = "SELECT id, summary, distill_checkpoint FROM documents WHERE collection_id = ?"
        var docSelectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, docSelectSql, -1, &docSelectStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(docSelectStmt, 1, collectionId.uuidString, -1, SQLITE_TRANSIENT)

            let docUpdateSql = "UPDATE documents SET summary = ?, distill_checkpoint = ? WHERE id = ?"
            var docUpdateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, docUpdateSql, -1, &docUpdateStmt, nil) == SQLITE_OK {
                while sqlite3_step(docSelectStmt) == SQLITE_ROW {
                    let docId = String(cString: sqlite3_column_text(docSelectStmt, 0))

                    let encSummary: String?
                    if sqlite3_column_type(docSelectStmt, 1) != SQLITE_NULL {
                        let rawSummary = String(cString: sqlite3_column_text(docSelectStmt, 1))
                        encSummary = try? CryptoManager.encryptContent(rawSummary, using: key)
                    } else {
                        encSummary = nil
                    }

                    let encCheckpoint: String?
                    if sqlite3_column_type(docSelectStmt, 2) != SQLITE_NULL {
                        let rawCheckpoint = String(cString: sqlite3_column_text(docSelectStmt, 2))
                        encCheckpoint = try? CryptoManager.encryptContent(rawCheckpoint, using: key)
                    } else {
                        encCheckpoint = nil
                    }

                    sqlite3_reset(docUpdateStmt)
                    if let s = encSummary {
                        sqlite3_bind_text(docUpdateStmt, 1, s, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(docUpdateStmt, 1)
                    }
                    if let c = encCheckpoint {
                        sqlite3_bind_text(docUpdateStmt, 2, c, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(docUpdateStmt, 2)
                    }
                    sqlite3_bind_text(docUpdateStmt, 3, docId, -1, SQLITE_TRANSIENT)
                    sqlite3_step(docUpdateStmt)
                }
                sqlite3_finalize(docUpdateStmt)
            }
            sqlite3_finalize(docSelectStmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Decrypt all chunks for a collection back to plaintext and rebuild FTS5.
    /// Used when removing protection from a collection.
    func decryptAllChunks(collectionId: UUID, key: SymmetricKey) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Select all chunks for this collection
        let selectSql = "SELECT id, content FROM chunks WHERE collection_id = ?"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(selectStmt, 1, collectionId.uuidString, -1, SQLITE_TRANSIENT)

        // Prepare update statement
        let updateSql = "UPDATE chunks SET content = ? WHERE id = ?"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(selectStmt)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        // Collect decrypted content for FTS5 rebuild
        var decryptedChunks: [(id: String, documentId: String, content: String)] = []

        // Decrypt each chunk
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let chunkId = String(cString: sqlite3_column_text(selectStmt, 0))
            let ciphertext = String(cString: sqlite3_column_text(selectStmt, 1))

            let plaintext: String
            do {
                plaintext = try CryptoManager.decryptContent(ciphertext, using: key)
            } catch {
                sqlite3_finalize(selectStmt)
                sqlite3_finalize(updateStmt)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }

            sqlite3_reset(updateStmt)
            sqlite3_bind_text(updateStmt, 1, plaintext, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(updateStmt, 2, chunkId, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                sqlite3_finalize(selectStmt)
                sqlite3_finalize(updateStmt)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
            }

            decryptedChunks.append((id: chunkId, documentId: "", content: plaintext))
        }

        sqlite3_finalize(selectStmt)
        sqlite3_finalize(updateStmt)

        // Decrypt document summaries and distill checkpoints
        let docSelectSql = "SELECT id, summary, distill_checkpoint FROM documents WHERE collection_id = ?"
        var docSelectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, docSelectSql, -1, &docSelectStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(docSelectStmt, 1, collectionId.uuidString, -1, SQLITE_TRANSIENT)

            let docUpdateSql = "UPDATE documents SET summary = ?, distill_checkpoint = ? WHERE id = ?"
            var docUpdateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, docUpdateSql, -1, &docUpdateStmt, nil) == SQLITE_OK {
                while sqlite3_step(docSelectStmt) == SQLITE_ROW {
                    let docId = String(cString: sqlite3_column_text(docSelectStmt, 0))

                    let decSummary: String?
                    if sqlite3_column_type(docSelectStmt, 1) != SQLITE_NULL {
                        let rawSummary = String(cString: sqlite3_column_text(docSelectStmt, 1))
                        decSummary = (try? CryptoManager.decryptContent(rawSummary, using: key)) ?? rawSummary
                    } else {
                        decSummary = nil
                    }

                    let decCheckpoint: String?
                    if sqlite3_column_type(docSelectStmt, 2) != SQLITE_NULL {
                        let rawCheckpoint = String(cString: sqlite3_column_text(docSelectStmt, 2))
                        decCheckpoint = (try? CryptoManager.decryptContent(rawCheckpoint, using: key)) ?? rawCheckpoint
                    } else {
                        decCheckpoint = nil
                    }

                    sqlite3_reset(docUpdateStmt)
                    if let s = decSummary {
                        sqlite3_bind_text(docUpdateStmt, 1, s, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(docUpdateStmt, 1)
                    }
                    if let c = decCheckpoint {
                        sqlite3_bind_text(docUpdateStmt, 2, c, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(docUpdateStmt, 2)
                    }
                    sqlite3_bind_text(docUpdateStmt, 3, docId, -1, SQLITE_TRANSIENT)
                    sqlite3_step(docUpdateStmt)
                }
                sqlite3_finalize(docUpdateStmt)
            }
            sqlite3_finalize(docSelectStmt)
        }

        // Rebuild FTS5 entries for this collection
        // First delete any stale entries
        sqlite3_exec(db, "DELETE FROM chunks_fts WHERE collection_id = '\(collectionId.uuidString)'", nil, nil, nil)

        // Re-read chunks with document_id for FTS5 insertion
        let ftsSql = "SELECT id, document_id, content FROM chunks WHERE collection_id = ?"
        var ftsSelectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsSql, -1, &ftsSelectStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(ftsSelectStmt, 1, collectionId.uuidString, -1, SQLITE_TRANSIENT)

            let insertSql = "INSERT INTO chunks_fts (chunk_id, document_id, collection_id, content) VALUES (?, ?, ?, ?)"
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
                while sqlite3_step(ftsSelectStmt) == SQLITE_ROW {
                    let cId = String(cString: sqlite3_column_text(ftsSelectStmt, 0))
                    let dId = String(cString: sqlite3_column_text(ftsSelectStmt, 1))
                    let content = String(cString: sqlite3_column_text(ftsSelectStmt, 2))

                    sqlite3_reset(insertStmt)
                    sqlite3_bind_text(insertStmt, 1, cId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 2, dId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 3, collectionId.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 4, content, -1, SQLITE_TRANSIENT)
                    sqlite3_step(insertStmt)
                }
                sqlite3_finalize(insertStmt)
            }
            sqlite3_finalize(ftsSelectStmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Count total chunks in a collection (all types).
    func chunkCount(collectionId: UUID) throws -> Int {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM chunks WHERE collection_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VectorStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

// MARK: - Errors

nonisolated enum VectorStoreError: LocalizedError {
    case databaseError(String)

    var errorDescription: String? {
        switch self {
        case .databaseError(let msg):
            return "Database error: \(msg)"
        }
    }
}
