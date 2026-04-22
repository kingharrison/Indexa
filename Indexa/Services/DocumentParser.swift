import Foundation
import PDFKit
import AppKit

/// Extracts plain text from various document formats.
/// Supports: TXT, MD, PDF, RTF, RTFD, DOCX, HTML, and other text-based files.
nonisolated enum DocumentParser {

    enum ParseError: LocalizedError {
        case cannotRead(String)
        case emptyContent(String)

        var errorDescription: String? {
            switch self {
            case .cannotRead(let name):  return "Cannot read file: \(name)"
            case .emptyContent(let name): return "No text content found in: \(name)"
            }
        }
    }

    /// Determine the document type from the file extension and extract text.
    static func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()

        let text: String
        switch ext {
        case "pdf":
            text = try extractPDFText(from: url)
        case "rtf", "rtfd":
            text = try extractAttributedText(from: url)
        case "docx":
            text = try extractAttributedText(from: url)
        case "xlsx":
            text = try extractXLSXText(from: url)
        case "pptx":
            text = try extractPPTXText(from: url)
        case "html", "htm":
            text = try extractHTMLFromFile(from: url)
        default:
            // Plain text fallback (txt, md, csv, json, xml, yaml, log, source code, etc.)
            text = try extractPlainText(from: url)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyContent(url.lastPathComponent)
        }

        return text
    }

    /// Extract text from raw HTML string (used by web scraper).
    static func extractTextFromHTML(_ html: String) -> String {
        // First strip script/style blocks, then let NSAttributedString handle the rest
        var cleaned = html
        // Remove <script>...</script>
        cleaned = cleaned.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "", options: .regularExpression
        )
        // Remove <style>...</style>
        cleaned = cleaned.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "", options: .regularExpression
        )
        // Remove <nav>...</nav>
        cleaned = cleaned.replacingOccurrences(
            of: "<nav[^>]*>[\\s\\S]*?</nav>",
            with: "", options: .regularExpression
        )
        // Remove <footer>...</footer>
        cleaned = cleaned.replacingOccurrences(
            of: "<footer[^>]*>[\\s\\S]*?</footer>",
            with: "", options: .regularExpression
        )
        // Remove <header>...</header>
        cleaned = cleaned.replacingOccurrences(
            of: "<header[^>]*>[\\s\\S]*?</header>",
            with: "", options: .regularExpression
        )

        // Use NSAttributedString to convert remaining HTML to plain text
        if let data = cleaned.data(using: .utf8),
           let attributed = NSAttributedString(
               html: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ) {
            return collapseWhitespace(attributed.string)
        }

        // Fallback: strip all remaining tags with regex
        return stripAllTags(cleaned)
    }

    // MARK: - Private extractors

    private static func extractPlainText(from url: URL) throws -> String {
        // Try UTF-8 first, then fall back to ASCII / ISO-Latin1
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard let data = try? Data(contentsOf: url),
                  let decoded = String(data: data, encoding: .ascii)
                      ?? String(data: data, encoding: .isoLatin1) else {
                throw ParseError.cannotRead(url.lastPathComponent)
            }
            return decoded
        }
    }

    private static func extractPDFText(from url: URL) throws -> String {
        guard let pdfDoc = PDFDocument(url: url) else {
            throw ParseError.cannotRead(url.lastPathComponent)
        }
        var pages: [String] = []
        for i in 0..<pdfDoc.pageCount {
            if let page = pdfDoc.page(at: i), let text = page.string {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func extractAttributedText(from url: URL) throws -> String {
        // NSAttributedString auto-detects RTF, RTFD, and DOCX from the file extension
        do {
            let attributed = try NSAttributedString(
                url: url,
                options: [:],
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            throw ParseError.cannotRead(url.lastPathComponent)
        }
    }

    private static func extractHTMLFromFile(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw ParseError.cannotRead(url.lastPathComponent)
        }
        guard let attributed = NSAttributedString(
            html: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) else {
            throw ParseError.cannotRead(url.lastPathComponent)
        }
        return attributed.string
    }

    // MARK: - Text cleaning helpers

    private static func stripAllTags(_ html: String) -> String {
        var result = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        result = collapseWhitespace(result)
        return result
    }

    private static func collapseWhitespace(_ text: String) -> String {
        // Collapse runs of spaces/tabs (but preserve newlines for paragraph structure)
        var result = text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
        // Collapse 3+ newlines into 2
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Office Open XML extractors (XLSX, PPTX)

    private static func extractXLSXText(from url: URL) throws -> String {
        // XLSX files contain text in xl/sharedStrings.xml (<t> elements)
        // and inline strings in sheet XML (<is><t> elements)
        var allText: [String] = []

        // Extract shared strings
        if let data = try? unzipEntry(archive: url, entry: "xl/sharedStrings.xml") {
            let texts = extractOfficeXMLText(data: data, textElements: ["t"])
            allText.append(contentsOf: texts)
        }

        // Also check individual sheets for inline strings
        let sheetEntries = (try? listZipEntries(archive: url, prefix: "xl/worksheets/sheet")) ?? []
        for entry in sheetEntries {
            if let data = try? unzipEntry(archive: url, entry: entry) {
                let texts = extractOfficeXMLText(data: data, textElements: ["t"])
                allText.append(contentsOf: texts)
            }
        }

        guard !allText.isEmpty else {
            throw ParseError.emptyContent(url.lastPathComponent)
        }
        return allText.joined(separator: "\n")
    }

    private static func extractPPTXText(from url: URL) throws -> String {
        // PPTX files contain slide text in ppt/slides/slide*.xml (<a:t> elements)
        let slideEntries = (try? listZipEntries(archive: url, prefix: "ppt/slides/slide")) ?? []
        guard !slideEntries.isEmpty else {
            throw ParseError.emptyContent(url.lastPathComponent)
        }

        var allText: [String] = []
        for entry in slideEntries.sorted() {
            if let data = try? unzipEntry(archive: url, entry: entry) {
                let texts = extractOfficeXMLText(data: data, textElements: ["a:t"])
                if !texts.isEmpty {
                    allText.append(texts.joined(separator: " "))
                }
            }
        }

        guard !allText.isEmpty else {
            throw ParseError.emptyContent(url.lastPathComponent)
        }
        return allText.joined(separator: "\n\n")
    }

    // MARK: - ZIP helpers (using /usr/bin/unzip)

    /// Extract a single file from a ZIP archive.
    private static func unzipEntry(archive: URL, entry: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw ParseError.cannotRead(entry)
        }
        return data
    }

    /// List entries in a ZIP archive matching a prefix.
    private static func listZipEntries(archive: URL, prefix: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", archive.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse unzip -l output: lines contain the entry path as the last column
        return output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Entry lines in unzip -l have the path as the last space-separated field
            guard let lastComponent = trimmed.split(separator: " ").last else { return nil }
            let entry = String(lastComponent)
            return entry.hasPrefix(prefix) && entry.hasSuffix(".xml") ? entry : nil
        }
    }

    /// Parse Office Open XML and extract text from specified elements.
    private static func extractOfficeXMLText(data: Data, textElements: Set<String>) -> [String] {
        let parser = OfficeXMLTextParser(targetElements: textElements)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.collectedTexts
    }
}

// MARK: - Office XML parser delegate

private nonisolated class OfficeXMLTextParser: NSObject, XMLParserDelegate {
    let targetElements: Set<String>
    var collectedTexts: [String] = []
    private var currentText: String?
    private var isInTargetElement = false

    init(targetElements: Set<String>) {
        self.targetElements = targetElements
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        // Match both qualified (a:t) and local name (t)
        if targetElements.contains(elementName) {
            isInTargetElement = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTargetElement {
            currentText?.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if targetElements.contains(elementName), let text = currentText, !text.isEmpty {
            collectedTexts.append(text)
        }
        if targetElements.contains(elementName) {
            isInTargetElement = false
            currentText = nil
        }
    }
}
