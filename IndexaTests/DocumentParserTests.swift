import Testing
import Foundation
@testable import Indexa

@Suite("DocumentParser")
struct DocumentParserTests {

    /// Get the URL for a test fixture file.
    private func fixtureURL(_ name: String) -> URL {
        // Find the fixtures relative to the test bundle
        let testBundle = Bundle(for: BundleMarker.self)
        if let url = testBundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
            return url
        }
        // Fallback: try the project directory structure
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return projectDir
    }

    @Test("Extract text from plain text file")
    func plainText() throws {
        let url = fixtureURL("sample.txt")
        let text = try DocumentParser.extractText(from: url)
        #expect(text.contains("quick brown fox"))
        #expect(text.contains("document parsing"))
    }

    @Test("Extract text from markdown file")
    func markdown() throws {
        let url = fixtureURL("sample.md")
        let text = try DocumentParser.extractText(from: url)
        #expect(text.contains("Document Title"))
        #expect(text.contains("Section One"))
        #expect(text.contains("Section Two"))
    }

    @Test("Extract text from HTML string strips scripts and styles")
    func htmlStripping() {
        let html = """
        <html>
        <script>var x = 1;</script>
        <style>body { color: red; }</style>
        <p>Visible content here.</p>
        </html>
        """
        let text = DocumentParser.extractTextFromHTML(html)
        #expect(text.contains("Visible content"))
        #expect(!text.contains("var x"))
        #expect(!text.contains("color: red"))
    }

    @Test("Extract text from HTML string strips nav and footer")
    func htmlNavFooter() {
        let html = """
        <nav>Navigation</nav>
        <p>Main content.</p>
        <footer>Footer stuff</footer>
        """
        let text = DocumentParser.extractTextFromHTML(html)
        #expect(text.contains("Main content"))
        #expect(!text.contains("Navigation"))
        #expect(!text.contains("Footer stuff"))
    }

    @Test("Empty file throws emptyContent error")
    func emptyFile() {
        let url = fixtureURL("empty.txt")
        #expect(throws: DocumentParser.ParseError.self) {
            try DocumentParser.extractText(from: url)
        }
    }

    @Test("Nonexistent file throws cannotRead error")
    func nonexistentFile() {
        let url = URL(fileURLWithPath: "/tmp/this_file_does_not_exist_\(UUID()).txt")
        #expect(throws: (any Error).self) {
            try DocumentParser.extractText(from: url)
        }
    }

    @Test("Unknown extension treated as plain text")
    func unknownExtension() throws {
        // Create a temp file with .xyz extension
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("test_\(UUID()).xyz")
        try "Some plain content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try DocumentParser.extractText(from: url)
        #expect(text.contains("Some plain content"))
    }
}

/// Marker class to find the test bundle at runtime.
private class BundleMarker {}
