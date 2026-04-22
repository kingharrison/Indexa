import Foundation

/// HTTP client for connecting to a remote Indexa instance's REST API.
actor RemoteIndexaService {
    let baseURL: String
    let apiKey: String?

    init(baseURL: String, apiKey: String? = nil) {
        // Strip trailing slash for consistent URL building
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
    }

    // MARK: - Public API

    /// Check if the remote server is reachable.
    func health() async throws -> Bool {
        let url = URL(string: "\(baseURL)/v1/health")!
        let data = try await get(url: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["status"] as? String == "ok"
    }

    /// List all collections on the remote server.
    func listCollections() async throws -> [RemoteCollection] {
        let url = URL(string: "\(baseURL)/v1/collections")!
        let data = try await get(url: url)
        let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

        return jsonArray.compactMap { dict in
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let name = dict["name"] as? String else { return nil }
            let isProtected = dict["protected"] as? Bool ?? false
            let documentCount = dict["document_count"] as? Int
            let protectionLevel = (dict["protection_level"] as? String).flatMap { ProtectionLevel(rawValue: $0) }
            return RemoteCollection(
                id: id,
                name: name,
                isProtected: isProtected,
                documentCount: documentCount,
                protectionLevel: protectionLevel
            )
        }
    }

    /// Query a remote collection.
    func query(
        question: String,
        collectionId: UUID? = nil,
        password: String? = nil,
        searchMode: SearchMode = .hybrid
    ) async throws -> RemoteQueryResult {
        let url = URL(string: "\(baseURL)/v1/query")!
        var body: [String: Any] = ["question": question, "search_mode": searchMode.rawValue]
        if let collectionId { body["collection_id"] = collectionId.uuidString }
        if let password { body["password"] = password }

        let data = try await post(url: url, body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let answer = json["answer"] as? String else {
            throw RemoteIndexaError.invalidResponse("Missing 'answer' in response")
        }

        let sourcesMasked = json["sources_masked"] as? Bool ?? false
        let rawSources = json["sources"] as? [[String: Any]] ?? []
        let sources: [RemoteSource] = rawSources.compactMap { s in
            guard let doc = s["document"] as? String,
                  let content = s["content"] as? String else { return nil }
            let score = (s["score"] as? Double).map { Float($0) } ?? 0
            return RemoteSource(document: doc, content: content, score: score)
        }

        return RemoteQueryResult(answer: answer, sources: sources, sourcesMasked: sourcesMasked)
    }

    // MARK: - HTTP Helpers

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RemoteIndexaError.connectionFailed
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteIndexaError.serverError(statusCode: http.statusCode, message: message)
        }
        return data
    }

    private func post(url: URL, body: [String: Any], timeout: TimeInterval = 120) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RemoteIndexaError.connectionFailed
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteIndexaError.serverError(statusCode: http.statusCode, message: message)
        }
        return data
    }
}

// MARK: - Errors

nonisolated enum RemoteIndexaError: LocalizedError {
    case connectionFailed
    case serverError(statusCode: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Cannot connect to the remote Indexa server."
        case .serverError(let code, let message):
            return "Remote server error (\(code)): \(message)"
        case .invalidResponse(let detail):
            return "Invalid response from remote server: \(detail)"
        }
    }
}
