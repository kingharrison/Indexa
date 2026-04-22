import SwiftUI

/// Renders markdown text with block-level elements (headings, code blocks, lists, etc.)
/// that SwiftUI's built-in Text markdown doesn't support.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        case .bulletList(let items):
            listView(items: items, ordered: false)
        case .orderedList(let items):
            listView(items: items, ordered: true)
        case .paragraph(let text):
            inlineMarkdownText(text)
                .font(.body)
                .textSelection(.enabled)
        case .thematicBreak:
            Divider()
        }
    }

    private func headingView(level: Int, text: String) -> some View {
        inlineMarkdownText(text)
            .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
            .fontWeight(.semibold)
            .padding(.top, level == 1 ? 4 : 2)
    }

    private func codeBlockView(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    private func listView(items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    Text(ordered ? "\(index + 1)." : "\u{2022}")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(width: ordered ? 20 : 10, alignment: .trailing)
                    inlineMarkdownText(item)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func inlineMarkdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    // MARK: - Parser

    private enum MarkdownBlock {
        case heading(Int, String)
        case codeBlock(String, String)
        case bulletList([String])
        case orderedList([String])
        case paragraph(String)
        case thematicBreak
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Thematic break
            if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " })
                && trimmed.filter({ $0 != " " }).count >= 3
                && Set(trimmed.filter { $0 != " " }).count == 1 {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(lang, codeLines.joined(separator: "\n")))
                continue
            }

            // Heading
            if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)/) {
                let level = match.1.count
                let text = String(match.2)
                blocks.append(.heading(level, text))
                i += 1
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") {
                        items.append(String(l.dropFirst(2)))
                        i += 1
                    } else if l.isEmpty || (!l.hasPrefix("- ") && !l.hasPrefix("* ") && !l.hasPrefix("+ ") && !l.hasPrefix("#") && !l.hasPrefix("```")) {
                        // Continuation or end
                        if l.isEmpty { break }
                        // Append to last item if indented continuation
                        if !items.isEmpty && lines[i].hasPrefix("  ") {
                            items[items.count - 1] += " " + l
                            i += 1
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list
            if trimmed.firstMatch(of: /^\d+\.\s+/) != nil {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let m = l.firstMatch(of: /^\d+\.\s+(.*)/) {
                        items.append(String(m.1))
                        i += 1
                    } else if l.isEmpty {
                        break
                    } else if !items.isEmpty && lines[i].hasPrefix("   ") {
                        items[items.count - 1] += " " + l
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Empty line — skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") || t.firstMatch(of: /^\d+\.\s+/) != nil {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            }
        }

        return blocks
    }
}
