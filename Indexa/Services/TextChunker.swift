import Foundation

/// Splits documents into overlapping chunks suitable for embedding.
/// Uses heading-aware chunking: detects document structure (markdown headings, ALL CAPS headings,
/// underlined headings) and keeps sections together. Each chunk is prefixed with its heading path
/// so the embedding model knows the context.
nonisolated enum TextChunker {

    /// Target chunk size in characters (~250-400 tokens).
    /// Smaller chunks produce more focused embeddings and better retrieval.
    static let defaultChunkSize = 800
    /// Overlap to preserve context across chunk boundaries.
    static let defaultOverlap = 100

    // MARK: - Public API

    /// Smart chunking: tries heading-aware first, falls back to basic overlap chunking.
    static func chunk(
        text: String,
        chunkSize: Int = defaultChunkSize,
        overlap: Int = defaultOverlap
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // If the entire text fits in one chunk, return it as-is
        if trimmed.count <= chunkSize {
            return [trimmed]
        }

        // Try heading-aware chunking first
        let sections = parseSections(trimmed)
        if sections.count > 1 {
            return chunkSections(sections, chunkSize: chunkSize, overlap: overlap)
        }

        // No headings found — use basic overlap chunking
        return basicChunk(text: trimmed, chunkSize: chunkSize, overlap: overlap)
    }

    // MARK: - Section parsing

    /// A section of a document with its heading hierarchy and body text.
    private struct Section {
        let headingPath: [String]   // e.g. ["Introduction", "Background"]
        let body: String            // The text content under this heading
    }

    /// Parse text into sections based on detected headings.
    private static func parseSections(_ text: String) -> [Section] {
        let lines = text.components(separatedBy: "\n")
        var sections: [Section] = []
        var headingStack: [(level: Int, title: String)] = []
        var currentBody: [String] = []
        var foundAnyHeading = false

        for i in 0..<lines.count {
            let line = lines[i]

            if let heading = detectHeading(line: line, nextLine: i + 1 < lines.count ? lines[i + 1] : nil) {
                foundAnyHeading = true

                // Flush the current body into a section
                let bodyText = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !bodyText.isEmpty {
                    let path = headingStack.map(\.title)
                    sections.append(Section(headingPath: path, body: bodyText))
                }
                currentBody = []

                // Update the heading stack — pop headings at same or deeper level
                while let last = headingStack.last, last.level >= heading.level {
                    headingStack.removeLast()
                }
                headingStack.append((level: heading.level, title: heading.title))

            } else if isUnderline(line) {
                // Skip underline-style heading markers (=== or ---), the heading was already captured
                continue
            } else {
                currentBody.append(line)
            }
        }

        // Flush remaining body
        let bodyText = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !bodyText.isEmpty {
            let path = headingStack.map(\.title)
            sections.append(Section(headingPath: path, body: bodyText))
        }

        // Only use sections if we actually found headings
        return foundAnyHeading ? sections : []
    }

    /// Detect if a line is a heading. Returns (level, title) or nil.
    private static func detectHeading(line: String, nextLine: String?) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Markdown headings: # Title, ## Title, ### Title, etc.
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let level = hashes.count
            if level <= 6 {
                let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    return (level: level, title: String(title))
                }
            }
        }

        // Underline-style headings:
        //   Title
        //   =====  (level 1)
        //   Title
        //   -----  (level 2)
        if let next = nextLine?.trimmingCharacters(in: .whitespaces) {
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if next.count >= 3 && next.allSatisfy({ $0 == "=" }) {
                    return (level: 1, title: trimmed)
                }
                if next.count >= 3 && next.allSatisfy({ $0 == "-" }) {
                    return (level: 2, title: trimmed)
                }
            }
        }

        // ALL CAPS headings (common in PDFs and plain text docs)
        // Must be short (< 80 chars), all uppercase letters, and not just a single word
        if trimmed.count >= 3 && trimmed.count < 80 {
            let letters = trimmed.filter { $0.isLetter }
            if !letters.isEmpty && letters == letters.uppercased() && trimmed.contains(" ") {
                // Make sure it's not just an acronym line or data
                let wordCount = trimmed.split(separator: " ").count
                if wordCount >= 2 && wordCount <= 12 {
                    return (level: 2, title: trimmed.capitalized)
                }
            }
        }

        return nil
    }

    /// Check if a line is just === or --- (underline heading marker).
    private static func isUnderline(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && (trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }))
    }

    // MARK: - Section-aware chunking

    /// Chunk sections, prefixing each chunk with its heading path.
    private static func chunkSections(
        _ sections: [Section],
        chunkSize: Int,
        overlap: Int
    ) -> [String] {
        var chunks: [String] = []

        for section in sections {
            // Build the heading prefix: [Heading > Subheading]
            let prefix: String
            if section.headingPath.isEmpty {
                prefix = ""
            } else {
                prefix = "[" + section.headingPath.joined(separator: " > ") + "]\n"
            }

            let availableSize = chunkSize - prefix.count
            guard availableSize > 100 else {
                // Heading path is too long — just use the body directly
                chunks.append(contentsOf: basicChunk(text: section.body, chunkSize: chunkSize, overlap: overlap))
                continue
            }

            if section.body.count <= availableSize {
                // Whole section fits in one chunk
                chunks.append(prefix + section.body)
            } else {
                // Section is too large — sub-chunk it, each prefixed with the heading
                let subChunks = basicChunk(text: section.body, chunkSize: availableSize, overlap: overlap)
                for sub in subChunks {
                    chunks.append(prefix + sub)
                }
            }
        }

        return chunks
    }

    // MARK: - Basic overlap chunking (fallback)

    /// Fixed-size overlapping chunks with smart break points.
    private static func basicChunk(
        text: String,
        chunkSize: Int,
        overlap: Int
    ) -> [String] {
        var chunks: [String] = []
        var startIndex = text.startIndex

        while startIndex < text.endIndex {
            let maxEnd = text.index(startIndex, offsetBy: chunkSize, limitedBy: text.endIndex)
                ?? text.endIndex

            var endIndex = maxEnd

            // Try to break at a natural boundary
            if endIndex < text.endIndex {
                endIndex = findBreakPoint(in: text, from: startIndex, maxEnd: maxEnd)
            }

            let chunk = String(text[startIndex..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunk.isEmpty {
                chunks.append(chunk)
            }

            if endIndex >= text.endIndex { break }

            let overlapStart = text.index(endIndex, offsetBy: -overlap, limitedBy: startIndex)
                ?? startIndex
            startIndex = overlapStart
        }

        return chunks
    }

    // MARK: - Break point detection

    /// Find the best break point — prefer paragraph breaks, then sentences, then words.
    private static func findBreakPoint(
        in text: String,
        from start: String.Index,
        maxEnd: String.Index
    ) -> String.Index {
        let substring = text[start..<maxEnd]
        let minDistance = text.distance(from: start, to: maxEnd) * 4 / 10
        let minPoint = text.index(start, offsetBy: minDistance)

        // 1. Paragraph break (double newline)
        if let range = substring.range(of: "\n\n", options: .backwards) {
            if range.upperBound >= minPoint {
                return range.upperBound
            }
        }

        // 2. Sentence boundary — look for ". ", "! ", "? " but skip common abbreviations
        var lastSentenceEnd: String.Index?
        var idx = substring.startIndex
        while idx < substring.endIndex {
            let char = substring[idx]
            if char == "." || char == "!" || char == "?" {
                let next = substring.index(after: idx)
                if next >= substring.endIndex || substring[next].isWhitespace || substring[next].isNewline {
                    // Skip likely abbreviations: single uppercase letter before period (e.g. "U.S.")
                    var isAbbreviation = false
                    if char == "." && idx > substring.startIndex {
                        let prev = substring.index(before: idx)
                        let prevChar = substring[prev]
                        if prevChar.isUppercase {
                            // Check if it's a single letter (like "U." in "U.S.")
                            if prev == substring.startIndex || !substring[substring.index(before: prev)].isLetter {
                                isAbbreviation = true
                            }
                        }
                    }
                    if !isAbbreviation {
                        lastSentenceEnd = next
                    }
                }
            }
            idx = substring.index(after: idx)
        }

        if let sentenceEnd = lastSentenceEnd, sentenceEnd >= minPoint {
            return sentenceEnd
        }

        // 3. Single newline
        if let range = substring.range(of: "\n", options: .backwards) {
            if range.upperBound >= minPoint {
                return range.upperBound
            }
        }

        // 4. Word boundary (space)
        if let range = substring.range(of: " ", options: .backwards) {
            return range.upperBound
        }

        // 5. Hard break
        return maxEnd
    }
}
