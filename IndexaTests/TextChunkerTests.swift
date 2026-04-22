import Testing
import Foundation
@testable import Indexa

@Suite("TextChunker")
struct TextChunkerTests {

    @Test("Empty text returns empty array")
    func emptyText() {
        let result = TextChunker.chunk(text: "")
        #expect(result.isEmpty)
    }

    @Test("Whitespace-only text returns empty array")
    func whitespaceOnly() {
        let result = TextChunker.chunk(text: "   \n\n  \t  ")
        #expect(result.isEmpty)
    }

    @Test("Short text returns single chunk")
    func shortText() {
        let text = "This is a short piece of text."
        let result = TextChunker.chunk(text: text, chunkSize: 200, overlap: 20)
        #expect(result.count == 1)
        #expect(result.first == text)
    }

    @Test("Long text splits into multiple chunks")
    func longText() {
        // Generate text longer than one chunk
        let sentence = "This is a sentence that takes up some space. "
        let text = String(repeating: sentence, count: 50)
        let result = TextChunker.chunk(text: text, chunkSize: 200, overlap: 20)
        #expect(result.count > 1)

        // No empty chunks
        for chunk in result {
            #expect(!chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("Markdown headings create heading-prefixed chunks")
    func markdownHeadings() {
        let text = """
        # Introduction

        This is the intro section with enough text to be meaningful. It contains several sentences about the introduction and provides important context for the reader to understand.

        # Methods

        This is the methods section with enough text to be meaningful. It describes the methodology used in the research and provides details about the experimental setup and approach.
        """
        let result = TextChunker.chunk(text: text, chunkSize: 300, overlap: 30)
        #expect(result.count >= 2)

        // At least one chunk should contain "Introduction"
        let hasIntro = result.contains { $0.contains("Introduction") }
        #expect(hasIntro)

        // At least one chunk should contain "Methods"
        let hasMethods = result.contains { $0.contains("Methods") }
        #expect(hasMethods)
    }

    @Test("ALL CAPS headings detected")
    func allCapsHeadings() {
        let text = """
        INTRODUCTION

        This is the intro section with enough content to matter for chunking purposes and quality.

        CONCLUSION

        This is the conclusion section with enough content to matter for chunking purposes and quality.
        """
        let result = TextChunker.chunk(text: text, chunkSize: 100, overlap: 10)
        #expect(result.count >= 1)

        let hasIntro = result.contains { $0.contains("INTRODUCTION") }
        #expect(hasIntro)
    }

    @Test("Custom chunk size respected")
    func customChunkSize() {
        let sentence = "Word "
        let text = String(repeating: sentence, count: 200) // 1000 chars
        let smallChunks = TextChunker.chunk(text: text, chunkSize: 100, overlap: 10)
        let bigChunks = TextChunker.chunk(text: text, chunkSize: 500, overlap: 50)
        #expect(smallChunks.count > bigChunks.count)
    }

    @Test("No chunks exceed target size excessively")
    func chunkSizeLimit() {
        let text = String(repeating: "Hello world. ", count: 200)
        let chunks = TextChunker.chunk(text: text, chunkSize: 200, overlap: 20)

        for chunk in chunks {
            // Allow 50% overhead for heading paths and boundary adjustments
            #expect(chunk.count < 400, "Chunk too large: \(chunk.count) chars")
        }
    }
}
