import Foundation

/// HTTP client for LLM APIs — supports both Ollama and OpenAI-compatible endpoints.
actor OllamaService {
    let baseURL: String
    let apiFormat: APIFormat
    let apiKey: String?

    init(baseURL: String = "http://localhost:11434", apiFormat: APIFormat = .ollama, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.apiKey = apiKey
    }

    // MARK: - Embeddings

    /// Generate an embedding vector for the given text.
    func embed(text: String, model: String = "nomic-embed-text") async throws -> [Float] {
        do {
            switch apiFormat {
            case .ollama:
                let url = URL(string: "\(baseURL)/api/embed")!
                let body: [String: Any] = ["model": model, "input": text]
                let data = try await post(url: url, body: body)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let embeddings = json?["embeddings"] as? [[Double]],
                      let first = embeddings.first else {
                    throw OllamaError.invalidResponse("Missing embeddings in response")
                }
                return first.map { Float($0) }

            case .openAI:
                let url = URL(string: "\(baseURL)/v1/embeddings")!
                let body: [String: Any] = ["model": model, "input": text]
                let data = try await post(url: url, body: body)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let dataArray = json?["data"] as? [[String: Any]],
                      let first = dataArray.first,
                      let embedding = first["embedding"] as? [Double] else {
                    throw OllamaError.invalidResponse("Missing embedding in response")
                }
                return embedding.map { Float($0) }
            }
        } catch let error as OllamaError {
            if case .serverError(let code, _) = error, code == 404 {
                throw OllamaError.modelNotFound(model)
            }
            throw error
        }
    }

    /// Generate embeddings for multiple texts in a single request.
    func embedBatch(texts: [String], model: String = "nomic-embed-text") async throws -> [[Float]] {
        do {
            switch apiFormat {
            case .ollama:
                let url = URL(string: "\(baseURL)/api/embed")!
                let body: [String: Any] = ["model": model, "input": texts]
                let data = try await post(url: url, body: body)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let embeddings = json?["embeddings"] as? [[Double]] else {
                    throw OllamaError.invalidResponse("Missing embeddings in response")
                }
                return embeddings.map { $0.map { Float($0) } }

            case .openAI:
                let url = URL(string: "\(baseURL)/v1/embeddings")!
                let body: [String: Any] = ["model": model, "input": texts]
                let data = try await post(url: url, body: body)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let dataArray = json?["data"] as? [[String: Any]] else {
                    throw OllamaError.invalidResponse("Missing data in response")
                }

                // OpenAI returns data with index field — sort by index to match input order
                let sorted = dataArray.sorted {
                    ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
                }
                return sorted.compactMap { item in
                    (item["embedding"] as? [Double])?.map { Float($0) }
                }
            }
        } catch let error as OllamaError {
            if case .serverError(let code, _) = error, code == 404 {
                throw OllamaError.modelNotFound(model)
            }
            throw error
        }
    }

    // MARK: - Chat

    struct ChatMessage: Sendable {
        let role: String   // "system", "user", "assistant"
        let content: String

        var dict: [String: String] {
            ["role": role, "content": content]
        }
    }

    /// Send a chat completion request and return the full response text.
    func chat(messages: [ChatMessage], model: String, temperature: Double = 0.3, timeout: TimeInterval = 120) async throws -> String {
        do {
            switch apiFormat {
            case .ollama:
                let url = URL(string: "\(baseURL)/api/chat")!
                let body: [String: Any] = [
                    "model": model,
                    "messages": messages.map(\.dict),
                    "stream": false,
                    "options": ["temperature": temperature]
                ]

                let data = try await post(url: url, body: body, timeout: timeout)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let message = json?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw OllamaError.invalidResponse("Missing message content in response")
                }
                return content

            case .openAI:
                let url = URL(string: "\(baseURL)/v1/chat/completions")!
                let body: [String: Any] = [
                    "model": model,
                    "messages": messages.map(\.dict),
                    "temperature": temperature,
                    "stream": false
                ]

                let data = try await post(url: url, body: body, timeout: timeout)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                guard let choices = json?["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw OllamaError.invalidResponse("Missing choices in response")
                }
                return content
            }
        } catch let error as OllamaError {
            if case .serverError(let code, _) = error, code == 404 {
                throw OllamaError.modelNotFound(model)
            }
            throw error
        }
    }

    /// Send a streaming chat completion request, calling onToken for each chunk.
    func chatStream(
        messages: [ChatMessage],
        model: String,
        temperature: Double = 0.3,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var request: URLRequest
        let bodyDict: [String: Any]

        switch apiFormat {
        case .ollama:
            request = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
            bodyDict = [
                "model": model,
                "messages": messages.map(\.dict),
                "stream": true,
                "options": ["temperature": temperature]
            ]
        case .openAI:
            request = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
            bodyDict = [
                "model": model,
                "messages": messages.map(\.dict),
                "temperature": temperature,
                "stream": true
            ]
        }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 404 {
                throw OllamaError.modelNotFound(model)
            }
            throw OllamaError.serverError(
                statusCode: statusCode,
                message: "Stream request failed"
            )
        }

        var fullResponse = ""

        for try await line in bytes.lines {
            // OpenAI SSE format: lines start with "data: "
            let jsonString: String
            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                jsonString = payload
            } else {
                jsonString = line
            }

            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let token: String?
            switch apiFormat {
            case .ollama:
                token = (json["message"] as? [String: Any])?["content"] as? String
            case .openAI:
                if let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any] {
                    token = delta["content"] as? String
                } else {
                    token = nil
                }
            }

            if let token, !token.isEmpty {
                fullResponse += token
                onToken(token)
            }
        }

        return fullResponse
    }

    // MARK: - Model listing

    struct ModelInfo: Sendable {
        let name: String
        let size: Int64
    }

    /// List all models available on the server.
    func listModels() async throws -> [ModelInfo] {
        switch apiFormat {
        case .ollama:
            let url = URL(string: "\(baseURL)/api/tags")!
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OllamaError.connectionFailed
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]] ?? []

            return models.compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                let size = m["size"] as? Int64 ?? 0
                return ModelInfo(name: name, size: size)
            }

        case .openAI:
            let url = URL(string: "\(baseURL)/v1/models")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            if let apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OllamaError.connectionFailed
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["data"] as? [[String: Any]] ?? []

            return models.compactMap { m in
                guard let name = m["id"] as? String else { return nil }
                return ModelInfo(name: name, size: 0)
            }
        }
    }

    // MARK: - Model pulling (Ollama only)

    /// Pull (download) a model on an Ollama server. Streams progress and returns when complete.
    func pullModel(name: String, progress: @escaping @Sendable (String) -> Void) async throws {
        guard apiFormat == .ollama else {
            throw OllamaError.invalidResponse("Model pulling is only supported for Ollama providers")
        }

        let url = URL(string: "\(baseURL)/api/pull")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600 // models can be large

        let body: [String: Any] = ["name": name, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                message: "Failed to start model pull"
            )
        }

        // Stream newline-delimited JSON progress
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let status = json["status"] as? String {
                if let total = json["total"] as? Int64, let completed = json["completed"] as? Int64, total > 0 {
                    let pct = Int(Double(completed) / Double(total) * 100)
                    progress("\(status) — \(pct)%")
                } else {
                    progress(status)
                }
            }

            // Check for error in stream
            if let error = json["error"] as? String {
                throw OllamaError.serverError(statusCode: 0, message: error)
            }
        }
    }

    // MARK: - HTTP helper

    private func post(url: URL, body: [String: Any], timeout: TimeInterval = 120) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.connectionFailed
        }

        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OllamaError.serverError(statusCode: http.statusCode, message: message)
        }

        return data
    }
}

// MARK: - Errors

nonisolated enum OllamaError: LocalizedError {
    case connectionFailed
    case serverError(statusCode: Int, message: String)
    case invalidResponse(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Cannot connect to the model server. Make sure it is running."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .invalidResponse(let detail):
            return "Invalid response from server: \(detail)"
        case .modelNotFound(let model):
            return "The model '\(model)' is not available. Pull it first by running: ollama pull \(model)"
        }
    }
}
