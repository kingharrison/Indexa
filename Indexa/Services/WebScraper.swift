import Foundation

/// Fetches web pages and extracts meaningful text content.
actor WebScraper {

    nonisolated enum ScraperError: LocalizedError {
        case invalidURL(String)
        case fetchFailed(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url):  return "Invalid URL: \(url)"
            case .fetchFailed(let msg): return "Failed to fetch page: \(msg)"
            case .noContent:            return "No text content found on the page."
            }
        }
    }

    /// Fetch a URL and extract its text content.
    /// Returns the extracted text and the page title.
    func fetchAndExtract(url: URL) async throws -> (text: String, title: String) {
        let html = try await fetchHTML(url: url)
        let title = extractTitle(from: html) ?? url.host ?? url.absoluteString
        let text = DocumentParser.extractTextFromHTML(html)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScraperError.noContent
        }

        return (text: text, title: title)
    }

    /// Fetch a URL and extract text content plus all links found on the page.
    func fetchAndExtractWithLinks(url: URL) async throws -> (text: String, title: String, links: [URL]) {
        let html = try await fetchHTML(url: url)
        let title = extractTitle(from: html) ?? url.host ?? url.absoluteString
        let text = DocumentParser.extractTextFromHTML(html)
        let links = extractLinks(from: html, baseURL: url)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScraperError.noContent
        }

        return (text: text, title: title, links: links)
    }

    // MARK: - Private

    private func fetchHTML(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Indexa/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ScraperError.fetchFailed("HTTP \(code) for \(url.absoluteString)")
        }

        let encoding: String.Encoding = {
            if let encodingName = http.textEncodingName {
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
                if cfEncoding != kCFStringEncodingInvalidId {
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                }
            }
            return .utf8
        }()

        guard let html = String(data: data, encoding: encoding)
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ScraperError.noContent
        }

        return html
    }

    private func extractTitle(from html: String) -> String? {
        guard let range = html.range(
            of: "<title[^>]*>(.*?)</title>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }

        let match = String(html[range])
        return match
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractLinks(from html: String, baseURL: URL) -> [URL] {
        let pattern = "<a\\s+[^>]*href\\s*=\\s*[\"']([^\"'#]+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        var seen = Set<String>()
        var urls: [URL] = []

        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[hrefRange])

            guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            guard resolved.scheme == "http" || resolved.scheme == "https" else { continue }

            // Strip fragment and query for cleaner dedup
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
            components?.fragment = nil

            guard let clean = components?.url else { continue }
            let canonical = clean.absoluteString

            if !seen.contains(canonical) {
                seen.insert(canonical)
                urls.append(clean)
            }
        }

        return urls
    }
}
