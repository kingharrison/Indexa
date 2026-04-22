import Testing
import Foundation
@testable import Indexa

@Suite("VectorStore")
struct VectorStoreTests {

    private func makeStore() throws -> VectorStore {
        let store = VectorStore.makeTestStore()
        try store.createTablesIfNeeded()
        return store
    }

    // MARK: - Collection CRUD

    @Test("Save and load a collection")
    func saveAndLoadCollection() throws {
        let store = try makeStore()
        let collection = Collection(name: "Test Collection")
        try store.saveCollection(collection)

        let loaded = try store.loadCollections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Test Collection")
        #expect(loaded.first?.id == collection.id)
    }

    @Test("Delete a collection cascades documents and chunks")
    func deleteCollectionCascade() throws {
        let store = try makeStore()
        let collection = Collection(name: "ToDelete")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "test.txt",
            filePath: "/tmp/test.txt",
            fileSize: 100
        )
        try store.saveDocument(doc)

        let chunk = DocumentChunk(
            documentId: doc.id,
            collectionId: collection.id,
            content: "Hello world",
            chunkIndex: 0,
            embedding: [1, 0, 0]
        )
        try store.saveChunks([chunk])

        try store.deleteCollection(id: collection.id)
        let collections = try store.loadCollections()
        #expect(collections.isEmpty)

        let docs = try store.loadDocuments(collectionId: collection.id)
        #expect(docs.isEmpty)

        let chunks = try store.loadChunks(documentId: doc.id)
        #expect(chunks.isEmpty)
    }

    @Test("Rename a collection")
    func renameCollection() throws {
        let store = try makeStore()
        let collection = Collection(name: "Original")
        try store.saveCollection(collection)
        try store.renameCollection(id: collection.id, name: "Renamed")

        let loaded = try store.loadCollections()
        #expect(loaded.first?.name == "Renamed")
    }

    // MARK: - Document CRUD

    @Test("Save and load documents for a collection")
    func saveAndLoadDocuments() throws {
        let store = try makeStore()
        let collection = Collection(name: "Docs Test")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "paper.pdf",
            filePath: "/tmp/paper.pdf",
            fileSize: 5000,
            chunkCount: 10
        )
        try store.saveDocument(doc)

        let docs = try store.loadDocuments(collectionId: collection.id)
        #expect(docs.count == 1)
        #expect(docs.first?.fileName == "paper.pdf")
        #expect(docs.first?.chunkCount == 10)
    }

    @Test("Delete document removes its chunks")
    func deleteDocument() throws {
        let store = try makeStore()
        let collection = Collection(name: "DocDel")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "test.txt",
            filePath: "/tmp/test.txt",
            fileSize: 100
        )
        try store.saveDocument(doc)

        let chunk = DocumentChunk(
            documentId: doc.id,
            collectionId: collection.id,
            content: "Content here",
            chunkIndex: 0,
            embedding: [1, 0, 0]
        )
        try store.saveChunks([chunk])

        try store.deleteDocument(id: doc.id)
        let chunks = try store.loadChunks(documentId: doc.id)
        #expect(chunks.isEmpty)
    }

    // MARK: - Chunk operations

    @Test("Save and load chunks with embeddings")
    func saveAndLoadChunks() throws {
        let store = try makeStore()
        let collection = Collection(name: "Chunks")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "doc.txt",
            filePath: "/tmp/doc.txt",
            fileSize: 200
        )
        try store.saveDocument(doc)

        let chunks = [
            DocumentChunk(documentId: doc.id, collectionId: collection.id,
                          content: "First chunk", chunkIndex: 0, embedding: [1, 0, 0]),
            DocumentChunk(documentId: doc.id, collectionId: collection.id,
                          content: "Second chunk", chunkIndex: 1, embedding: [0, 1, 0]),
            DocumentChunk(documentId: doc.id, collectionId: collection.id,
                          content: "Third chunk", chunkIndex: 2, embedding: [0, 0, 1]),
        ]
        try store.saveChunks(chunks)

        let loaded = try store.loadChunks(documentId: doc.id)
        #expect(loaded.count == 3)
        #expect(loaded[0].content == "First chunk")
        #expect(loaded[1].chunkIndex == 1)
        #expect(loaded[2].embedding == [0, 0, 1])
    }

    @Test("Load chunks paginated with filters")
    func loadChunksPaginated() throws {
        let store = try makeStore()
        let collection = Collection(name: "Paginate")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "doc.txt",
            filePath: "/tmp/doc.txt",
            fileSize: 200
        )
        try store.saveDocument(doc)

        var chunks: [DocumentChunk] = []
        for i in 0..<10 {
            chunks.append(DocumentChunk(
                documentId: doc.id, collectionId: collection.id,
                content: "Chunk number \(i)", chunkIndex: i,
                embedding: [Float(i), 0, 0]
            ))
        }
        try store.saveChunks(chunks)

        // Page 1 (first 5)
        let page1 = try store.loadChunksPaginated(
            collectionId: collection.id, offset: 0, limit: 5
        )
        #expect(page1.count == 5)

        // Page 2 (next 5)
        let page2 = try store.loadChunksPaginated(
            collectionId: collection.id, offset: 5, limit: 5
        )
        #expect(page2.count == 5)

        // Search filter
        let filtered = try store.loadChunksPaginated(
            collectionId: collection.id, offset: 0, limit: 50,
            searchText: "number 3"
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.content == "Chunk number 3")
    }

    @Test("Chunk count filtered")
    func chunkCountFiltered() throws {
        let store = try makeStore()
        let collection = Collection(name: "Count")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "doc.txt",
            filePath: "/tmp/doc.txt",
            fileSize: 200
        )
        try store.saveDocument(doc)

        let chunks = (0..<7).map { i in
            DocumentChunk(
                documentId: doc.id, collectionId: collection.id,
                content: "Chunk \(i)", chunkIndex: i,
                embedding: [Float(i), 0, 0]
            )
        }
        try store.saveChunks(chunks)

        let total = try store.chunkCountFiltered(collectionId: collection.id)
        #expect(total == 7)

        let withSearch = try store.chunkCountFiltered(
            collectionId: collection.id, searchText: "Chunk 5"
        )
        #expect(withSearch == 1)
    }

    @Test("Delete specific chunks by ID")
    func deleteChunksByIds() throws {
        let store = try makeStore()
        let collection = Collection(name: "DelChunks")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "doc.txt",
            filePath: "/tmp/doc.txt",
            fileSize: 200
        )
        try store.saveDocument(doc)

        let chunk1 = DocumentChunk(
            documentId: doc.id, collectionId: collection.id,
            content: "Keep this", chunkIndex: 0, embedding: [1, 0, 0]
        )
        let chunk2 = DocumentChunk(
            documentId: doc.id, collectionId: collection.id,
            content: "Delete this", chunkIndex: 1, embedding: [0, 1, 0]
        )
        try store.saveChunks([chunk1, chunk2])

        try store.deleteChunks(ids: Set([chunk2.id]))

        let remaining = try store.loadChunks(documentId: doc.id)
        #expect(remaining.count == 1)
        #expect(remaining.first?.content == "Keep this")
    }

    // MARK: - Search

    @Test("Vector search returns top-K results sorted by score")
    func vectorSearch() throws {
        let store = try makeStore()
        let collection = Collection(name: "Search")
        try store.saveCollection(collection)

        let doc = IndexedDocument(
            collectionId: collection.id,
            fileName: "doc.txt",
            filePath: "/tmp/doc.txt",
            fileSize: 200,
            enabled: true
        )
        try store.saveDocument(doc)

        let chunks = [
            DocumentChunk(documentId: doc.id, collectionId: collection.id,
                          content: "About cats", chunkIndex: 0, embedding: [1, 0, 0]),
            DocumentChunk(documentId: doc.id, collectionId: collection.id,
                          content: "About dogs", chunkIndex: 1, embedding: [0, 1, 0]),
            DocumentChunk(documentId: doc.id, collectionId: collection.id,
                          content: "Mix of both", chunkIndex: 2, embedding: [0.7, 0.7, 0]),
        ]
        try store.saveChunks(chunks)

        // Query close to [1, 0, 0] should rank "About cats" highest
        let results = try store.searchSimilar(
            queryEmbedding: [0.9, 0.1, 0],
            collectionId: collection.id,
            topK: 3
        )
        #expect(results.count == 3)
        #expect(results.first?.content == "About cats")
    }

    @Test("Search with nil collectionId searches all collections")
    func globalSearch() throws {
        let store = try makeStore()

        let col1 = Collection(name: "Collection A")
        let col2 = Collection(name: "Collection B")
        try store.saveCollection(col1)
        try store.saveCollection(col2)

        let doc1 = IndexedDocument(
            collectionId: col1.id, fileName: "a.txt",
            filePath: "/tmp/a.txt", fileSize: 100, enabled: true
        )
        let doc2 = IndexedDocument(
            collectionId: col2.id, fileName: "b.txt",
            filePath: "/tmp/b.txt", fileSize: 100, enabled: true
        )
        try store.saveDocument(doc1)
        try store.saveDocument(doc2)

        try store.saveChunks([
            DocumentChunk(documentId: doc1.id, collectionId: col1.id,
                          content: "Alpha", chunkIndex: 0, embedding: [1, 0, 0]),
            DocumentChunk(documentId: doc2.id, collectionId: col2.id,
                          content: "Beta", chunkIndex: 0, embedding: [0, 1, 0]),
        ])

        // Global search (nil collectionId) should find chunks from both
        let results = try store.searchSimilar(
            queryEmbedding: [0.5, 0.5, 0],
            collectionId: nil,
            topK: 10
        )
        #expect(results.count == 2)
    }

    // MARK: - Edge cases

    @Test("Empty database returns empty results")
    func emptyDatabase() throws {
        let store = try makeStore()
        let collections = try store.loadCollections()
        #expect(collections.isEmpty)
    }

    // MARK: - Sort order

    @Test("Collections load in sort order")
    func sortOrder() throws {
        let store = try makeStore()
        let c1 = Collection(name: "Third", sortOrder: 2)
        let c2 = Collection(name: "First", sortOrder: 0)
        let c3 = Collection(name: "Second", sortOrder: 1)
        try store.saveCollection(c1)
        try store.saveCollection(c2)
        try store.saveCollection(c3)

        let loaded = try store.loadCollections()
        #expect(loaded[0].name == "First")
        #expect(loaded[1].name == "Second")
        #expect(loaded[2].name == "Third")
    }

    @Test("Batch update sort orders")
    func batchSortOrder() throws {
        let store = try makeStore()
        let c1 = Collection(name: "A", sortOrder: 0)
        let c2 = Collection(name: "B", sortOrder: 1)
        try store.saveCollection(c1)
        try store.saveCollection(c2)

        // Swap order
        try store.updateCollectionSortOrders([
            (id: c1.id, sortOrder: 1),
            (id: c2.id, sortOrder: 0),
        ])

        let loaded = try store.loadCollections()
        #expect(loaded[0].name == "B")
        #expect(loaded[1].name == "A")
    }
}
