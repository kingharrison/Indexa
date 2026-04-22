import Foundation
import CryptoKit
import CommonCrypto

/// Manages exporting and importing `.indexa` knowledge base bundles.
/// Bundle format: JSON payload → compressed with gzip → optionally encrypted with AES-GCM.
nonisolated enum BundleManager {

    // MARK: - Bundle data structures (Codable for JSON serialization)

    struct BundleManifest: Codable {
        let version: Int
        let createdAt: Date
        let isEncrypted: Bool
        let collectionCount: Int
        let documentCount: Int
        let chunkCount: Int

        // V2 — Access control (nil = unrestricted, no server check needed)
        let bundleId: String?
        let accessControl: BundleAccessControl?

        /// Number of collections that have password protection (read-only or masked). Nil in older bundles.
        let protectedCollectionCount: Int?

        init(
            version: Int,
            createdAt: Date,
            isEncrypted: Bool,
            collectionCount: Int,
            documentCount: Int,
            chunkCount: Int,
            bundleId: String? = nil,
            accessControl: BundleAccessControl? = nil,
            protectedCollectionCount: Int? = nil
        ) {
            self.version = version
            self.createdAt = createdAt
            self.isEncrypted = isEncrypted
            self.collectionCount = collectionCount
            self.documentCount = documentCount
            self.chunkCount = chunkCount
            self.bundleId = bundleId
            self.accessControl = accessControl
            self.protectedCollectionCount = protectedCollectionCount
        }
    }

    /// Describes how a bundle's access should be validated.
    /// When present, the app must check with the server before allowing use.
    struct BundleAccessControl: Codable {
        let serverURL: String          // e.g. "https://api.indexa.app/v1/access"
        let issuer: String             // who created this bundle (org/user identifier)
        let policy: AccessPolicy       // what kind of check to perform

        enum AccessPolicy: String, Codable {
            case onEveryOpen        // check server each time bundle is opened
            case oncePerDay         // cache access for 24h
            case oncePerSession     // cache until app restart
        }
    }

    struct BundleCollection: Codable {
        let id: String
        let name: String
        let dateCreated: Double  // timeIntervalSince1970
        let refreshInterval: String?    // RefreshInterval raw value — nil in older bundles
        let systemPrompt: String?       // custom system prompt — nil in older bundles
        let passwordHash: String?       // PBKDF2 hash — nil if unprotected
        let protectionLevel: String?    // ProtectionLevel raw value — nil if unprotected
        // V3 — Cryptographic chunk encryption
        let encryptionKeyWrapped: String?  // AES-GCM sealed box of CEK, Base64
        let encryptionSalt: String?        // PBKDF2 salt, hex
        let isChunkEncrypted: Bool?        // whether chunk content is ciphertext
    }

    struct BundleDocument: Codable {
        let id: String
        let collectionId: String
        let fileName: String
        let filePath: String
        let fileSize: Int64
        let dateIndexed: Double
        let chunkCount: Int
        let sourceType: String?       // "file" or "web" — nil in older bundles
        let contentHash: String?      // SHA256 hex — nil in older bundles
        let crawlGroupId: String?     // crawl group UUID — nil for non-crawled docs
        let summary: String?          // AI-generated summary — nil in older bundles
        let enabled: Bool?            // whether doc is active for queries — nil in older bundles (treated as true)
        let hasDistilledChunks: Bool? // whether distilled version exists — nil in older bundles
        let useDistilled: Bool?       // whether to use distilled for queries — nil in older bundles
    }

    struct BundleChunk: Codable {
        let id: String
        let documentId: String
        let collectionId: String
        let content: String
        let chunkIndex: Int
        let embedding: String  // Base64-encoded raw float bytes
        let chunkType: String? // "original" or "distilled" — nil in older bundles
    }

    struct BundlePayload: Codable {
        let manifest: BundleManifest
        let collections: [BundleCollection]
        let documents: [BundleDocument]
        let chunks: [BundleChunk]
    }

    // MARK: - What to export

    enum ExportSelection {
        case collections([UUID])                         // Export entire collections
        case documents([UUID], collectionId: UUID)       // Export specific docs from a collection
    }

    // MARK: - Export

    /// Export selected data into a `.indexa` bundle file.
    /// Returns the URL of the created bundle.
    static func exportBundle(
        selection: ExportSelection,
        to destinationURL: URL,
        password: String?,
        vectorStore: VectorStore
    ) throws -> URL {
        // 1. Gather all the data
        var collections: [Collection] = []
        var documents: [IndexedDocument] = []
        var chunks: [DocumentChunk] = []

        switch selection {
        case .collections(let collectionIds):
            for colId in collectionIds {
                guard let col = try vectorStore.loadCollection(id: colId) else { continue }
                collections.append(col)
                let docs = try vectorStore.loadDocuments(collectionId: colId)
                documents.append(contentsOf: docs)
                let colChunks = try vectorStore.loadChunks(collectionId: colId)
                chunks.append(contentsOf: colChunks)
            }

        case .documents(let docIds, let collectionId):
            // Include the parent collection
            if let col = try vectorStore.loadCollection(id: collectionId) {
                collections.append(col)
            }
            let allDocs = try vectorStore.loadDocuments(collectionId: collectionId)
            for doc in allDocs where docIds.contains(doc.id) {
                documents.append(doc)
                let docChunks = try vectorStore.loadChunks(documentId: doc.id)
                chunks.append(contentsOf: docChunks)
            }
        }

        // 2. Convert to bundle format
        let bundleCollections = collections.map { col in
            BundleCollection(
                id: col.id.uuidString,
                name: col.name,
                dateCreated: col.dateCreated.timeIntervalSince1970,
                refreshInterval: col.refreshInterval.rawValue,
                systemPrompt: col.systemPrompt,
                passwordHash: col.passwordHash,
                protectionLevel: col.protectionLevel?.rawValue,
                encryptionKeyWrapped: col.encryptionKeyWrapped,
                encryptionSalt: col.encryptionSalt,
                isChunkEncrypted: col.isEncrypted ? true : nil
            )
        }

        let bundleDocuments = documents.map { doc in
            BundleDocument(
                id: doc.id.uuidString, collectionId: doc.collectionId.uuidString,
                fileName: doc.fileName, filePath: doc.filePath,
                fileSize: doc.fileSize, dateIndexed: doc.dateIndexed.timeIntervalSince1970,
                chunkCount: doc.chunkCount,
                sourceType: doc.sourceType.rawValue,
                contentHash: doc.contentHash,
                crawlGroupId: doc.crawlGroupId?.uuidString,
                summary: doc.summary,
                enabled: doc.enabled,
                hasDistilledChunks: doc.hasDistilledChunks,
                useDistilled: doc.useDistilled
            )
        }

        let bundleChunks = chunks.map { chunk in
            let embeddingData = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            return BundleChunk(
                id: chunk.id.uuidString, documentId: chunk.documentId.uuidString,
                collectionId: chunk.collectionId.uuidString, content: chunk.content,
                chunkIndex: chunk.chunkIndex, embedding: embeddingData.base64EncodedString(),
                chunkType: chunk.chunkType.rawValue
            )
        }

        let protectedCount = collections.filter { $0.passwordHash != nil }.count

        // Refuse to export protected collections without encryption —
        // older Indexa versions would silently strip the protection
        if protectedCount > 0 && (password == nil || password?.isEmpty == true) {
            throw BundleError.protectedExportRequiresEncryption
        }

        // Version 4 for protected/encrypted collections — ensures older Indexa versions
        // (which don't enforce sourcesMasked) reject the bundle instead of silently stripping protection.
        // Version 1 for unprotected bundles (backward compatible with all versions).
        let bundleVersion = protectedCount > 0 || collections.contains(where: { $0.isEncrypted }) ? 4 : 1
        let manifest = BundleManifest(
            version: bundleVersion,
            createdAt: .now,
            isEncrypted: password != nil,
            collectionCount: collections.count,
            documentCount: documents.count,
            chunkCount: chunks.count,
            protectedCollectionCount: protectedCount > 0 ? protectedCount : nil
        )

        let payload = BundlePayload(
            manifest: manifest,
            collections: bundleCollections,
            documents: bundleDocuments,
            chunks: bundleChunks
        )

        // 3. Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let jsonData = try encoder.encode(payload)

        // 4. Compress with gzip
        let compressedData = try compress(jsonData)

        // 5. Optionally encrypt
        // Protected bundles use magic byte 0x02 so old Indexa versions can't import them.
        let finalData: Data
        if let password, !password.isEmpty {
            let magic = protectedCount > 0 ? magicProtected : magicEncrypted
            finalData = try encrypt(data: compressedData, password: password, magicByte: magic)
        } else {
            var unencrypted = Data([magicUnencrypted])
            unencrypted.append(compressedData)
            finalData = unencrypted
        }

        // 6. Write to disk
        try finalData.write(to: destinationURL)
        return destinationURL
    }

    // MARK: - Import

    /// Import a `.indexa` bundle into the local database.
    /// Returns the number of collections imported.
    static func importBundle(
        from url: URL,
        password: String?,
        vectorStore: VectorStore
    ) throws -> ImportResult {
        let fileData = try Data(contentsOf: url)
        guard !fileData.isEmpty else {
            throw BundleError.invalidBundle("File is empty")
        }

        // Check magic byte: 0x00 = not encrypted, 0x01 = encrypted, 0x02 = encrypted + protected
        let isEncrypted = fileData[0] == magicEncrypted || fileData[0] == magicProtected

        let compressedData: Data
        if isEncrypted {
            guard let password, !password.isEmpty else {
                throw BundleError.passwordRequired
            }
            compressedData = try decrypt(data: fileData.dropFirst(), password: password)
        } else {
            compressedData = fileData.dropFirst()
        }

        // Decompress
        let jsonData = try decompress(compressedData)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let payload = try decoder.decode(BundlePayload.self, from: jsonData)

        // Version check — this app supports up to version 4
        // (version 4 = enforced protection; older apps reject this)
        if payload.manifest.version > 4 {
            throw BundleError.unsupportedVersion(payload.manifest.version)
        }

        // Import collections — track which are crypto-encrypted for FTS skip
        var encryptedCollectionIds: Set<String> = []
        for bc in payload.collections {
            guard let id = UUID(uuidString: bc.id) else { continue }
            let refreshInterval = bc.refreshInterval.flatMap { RefreshInterval(rawValue: $0) } ?? .never
            let protectionLevel = bc.protectionLevel.flatMap { ProtectionLevel(rawValue: $0) }
            let isChunkEncrypted = bc.isChunkEncrypted ?? false
            if isChunkEncrypted { encryptedCollectionIds.insert(bc.id) }
            let collection = Collection(
                id: id, name: bc.name,
                dateCreated: Date(timeIntervalSince1970: bc.dateCreated),
                refreshInterval: refreshInterval,
                systemPrompt: bc.systemPrompt,
                passwordHash: bc.passwordHash,
                protectionLevel: protectionLevel,
                encryptionKeyWrapped: bc.encryptionKeyWrapped,
                encryptionSalt: bc.encryptionSalt,
                isEncrypted: isChunkEncrypted
            )
            try vectorStore.saveCollection(collection)
        }

        // Import documents
        for bd in payload.documents {
            guard let id = UUID(uuidString: bd.id),
                  let colId = UUID(uuidString: bd.collectionId) else { continue }
            let sourceType = SourceType(rawValue: bd.sourceType ?? "file") ?? .file
            let doc = IndexedDocument(
                id: id, collectionId: colId, fileName: bd.fileName,
                filePath: bd.filePath, fileSize: bd.fileSize,
                dateIndexed: Date(timeIntervalSince1970: bd.dateIndexed),
                chunkCount: bd.chunkCount,
                sourceType: sourceType,
                contentHash: bd.contentHash,
                crawlGroupId: bd.crawlGroupId.flatMap { UUID(uuidString: $0) },
                summary: bd.summary,
                enabled: bd.enabled ?? true,
                hasDistilledChunks: bd.hasDistilledChunks ?? false,
                useDistilled: bd.useDistilled ?? false
            )
            try vectorStore.saveDocument(doc)
        }

        // Import chunks in batches — separate encrypted and plaintext for FTS handling
        var plaintextBatch: [DocumentChunk] = []
        var encryptedBatch: [DocumentChunk] = []

        for bc in payload.chunks {
            guard let id = UUID(uuidString: bc.id),
                  let docId = UUID(uuidString: bc.documentId),
                  let colId = UUID(uuidString: bc.collectionId),
                  let embeddingData = Data(base64Encoded: bc.embedding) else { continue }

            let floatCount = embeddingData.count / MemoryLayout<Float>.size
            let embedding: [Float] = embeddingData.withUnsafeBytes { ptr in
                Array(UnsafeBufferPointer(start: ptr.baseAddress?.assumingMemoryBound(to: Float.self), count: floatCount))
            }

            let chunk = DocumentChunk(
                id: id, documentId: docId, collectionId: colId,
                content: bc.content, chunkIndex: bc.chunkIndex,
                embedding: embedding,
                chunkType: ChunkType(rawValue: bc.chunkType ?? "original") ?? .original
            )

            if encryptedCollectionIds.contains(bc.collectionId) {
                encryptedBatch.append(chunk)
                if encryptedBatch.count >= 100 {
                    try vectorStore.saveChunks(encryptedBatch, skipFTS: true)
                    encryptedBatch.removeAll()
                }
            } else {
                plaintextBatch.append(chunk)
                if plaintextBatch.count >= 100 {
                    try vectorStore.saveChunks(plaintextBatch)
                    plaintextBatch.removeAll()
                }
            }
        }
        if !encryptedBatch.isEmpty {
            try vectorStore.saveChunks(encryptedBatch, skipFTS: true)
        }
        if !plaintextBatch.isEmpty {
            try vectorStore.saveChunks(plaintextBatch)
        }

        let protectedCount = payload.collections.filter { $0.passwordHash != nil }.count
        let encryptedCount = encryptedCollectionIds.count

        return ImportResult(
            collectionsImported: payload.manifest.collectionCount,
            documentsImported: payload.manifest.documentCount,
            chunksImported: payload.manifest.chunkCount,
            protectedCollectionCount: protectedCount,
            encryptedCollectionCount: encryptedCount
        )
    }

    /// Peek at a bundle's manifest without fully importing it.
    static func peekManifest(from url: URL) throws -> BundleManifest {
        let fileData = try Data(contentsOf: url)
        guard !fileData.isEmpty else {
            throw BundleError.invalidBundle("File is empty")
        }

        let isEncryptedPeek = fileData[0] == magicEncrypted || fileData[0] == magicProtected
        if isEncryptedPeek {
            // Return a minimal manifest indicating encryption
            return BundleManifest(
                version: 1, createdAt: .now, isEncrypted: true,
                collectionCount: 0, documentCount: 0, chunkCount: 0
            )
        }

        let compressedData = fileData.dropFirst()
        let jsonData = try decompress(compressedData)

        // Only decode the manifest portion (decode full payload since manifest is embedded)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let payload = try decoder.decode(BundlePayload.self, from: jsonData)
        return payload.manifest
    }

    // MARK: - Compression (using Apple's built-in Compression framework via NSData)

    private static func compress(_ data: Data) throws -> Data {
        let nsData = data as NSData
        guard let compressed = try? nsData.compressed(using: .lzfse) else {
            throw BundleError.compressionFailed
        }
        return compressed as Data
    }

    private static func decompress(_ data: Data) throws -> Data {
        let nsData = data as NSData
        guard let decompressed = try? nsData.decompressed(using: .lzfse) else {
            throw BundleError.decompressionFailed
        }
        return decompressed as Data
    }

    // MARK: - Encryption (AES-GCM with password-derived key)

    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let saltSize = 16

    // Magic bytes: 0x00 = unencrypted, 0x01 = encrypted, 0x02 = encrypted + enforced protection
    // Old Indexa versions only recognize 0x00 and 0x01. Using 0x02 for protected bundles
    // ensures old versions fail to import them (they'll try to decompress ciphertext and fail).
    private static let magicUnencrypted: UInt8 = 0x00
    private static let magicEncrypted: UInt8 = 0x01
    private static let magicProtected: UInt8 = 0x02

    private static func encrypt(data: Data, password: String, magicByte: UInt8 = magicEncrypted) throws -> Data {
        // Generate a random salt
        var salt = Data(count: saltSize)
        salt.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, saltSize, ptr.baseAddress!)
        }

        let key = try deriveKey(from: password, salt: salt)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw BundleError.encryptionFailed
        }
        // Format: magic byte + salt (16 bytes) + AES-GCM sealed box
        var result = Data([magicByte])
        result.append(salt)
        result.append(combined)
        return result
    }

    private static func decrypt(data: Data, password: String) throws -> Data {
        guard data.count > saltSize else {
            throw BundleError.decryptionFailed
        }
        let salt = data.prefix(saltSize)
        let sealedData = data.dropFirst(saltSize)

        let key = try deriveKey(from: password, salt: salt)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: sealedData)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw BundleError.decryptionFailed
        }
    }

    /// Derive a 256-bit key from a password using PBKDF2-HMAC-SHA256 with 100k iterations.
    private static func deriveKey(from password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32) // 256 bits

        let status = derivedKey.withUnsafeMutableBytes { derivedPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw BundleError.encryptionFailed
        }
        return SymmetricKey(data: derivedKey)
    }

    // MARK: - Types

    struct ImportResult: Sendable {
        let collectionsImported: Int
        let documentsImported: Int
        let chunksImported: Int
        let protectedCollectionCount: Int
        let encryptedCollectionCount: Int
    }
}

// MARK: - Errors

nonisolated enum BundleError: LocalizedError {
    case invalidBundle(String)
    case passwordRequired
    case compressionFailed
    case decompressionFailed
    case encryptionFailed
    case decryptionFailed
    case unsupportedVersion(Int)
    case protectedExportRequiresEncryption

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let msg): return "Invalid bundle: \(msg)"
        case .passwordRequired: return "This bundle is encrypted. A password is required."
        case .compressionFailed: return "Failed to compress bundle data."
        case .decompressionFailed: return "Failed to decompress bundle. The file may be corrupted."
        case .encryptionFailed: return "Failed to encrypt bundle."
        case .decryptionFailed: return "Failed to decrypt bundle. Wrong password?"
        case .unsupportedVersion(let v): return "This bundle requires a newer version of Indexa (bundle version \(v)). Please update the app."
        case .protectedExportRequiresEncryption: return "Protected collections must be exported with a password to prevent older versions of Indexa from bypassing the protection."
        }
    }
}
