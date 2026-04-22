import Foundation
import Network
import CryptoKit

/// Thread-safe wrapper to ensure a continuation is only resumed once.
nonisolated private final class ResumeOnce: Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Void, Error>
    private nonisolated(unsafe) let _resumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    nonisolated init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        _resumed.initialize(to: false)
    }

    deinit { _resumed.deallocate() }

    nonisolated func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !_resumed.pointee else { return }
        _resumed.pointee = true
        continuation.resume()
    }

    nonisolated func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !_resumed.pointee else { return }
        _resumed.pointee = true
        continuation.resume(throwing: error)
    }
}

/// A lightweight HTTP server using Apple's Network framework.
/// Exposes Indexa's knowledge base capabilities via a REST API.
actor HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private let knowledgeEngine: KnowledgeEngine
    private let vectorStore: VectorStore
    private let apiKey: String?
    private let chatModelProvider: @Sendable () async -> String
    private let serverStatusProvider: @Sendable () async -> (llm: Bool?, embed: Bool?)
    private let cekProvider: @Sendable (UUID) async -> SymmetricKey?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    /// Rate limiting: track failed password attempts per IP-like identifier
    private var failedAttempts: [String: (count: Int, lastAttempt: Date)] = [:]
    private let maxAttempts = 10
    private let lockoutDuration: TimeInterval = 300 // 5 minutes

    /// SSE connections for MCP: session ID → connection
    private var sseConnections: [String: NWConnection] = [:]
    /// Keepalive tasks for SSE connections
    private var sseKeepAliveTasks: [String: Task<Void, Never>] = [:]

    init(
        port: UInt16,
        knowledgeEngine: KnowledgeEngine,
        vectorStore: VectorStore,
        apiKey: String? = nil,
        chatModelProvider: @Sendable @escaping () async -> String,
        serverStatusProvider: @Sendable @escaping () async -> (llm: Bool?, embed: Bool?) = { (nil, nil) },
        cekProvider: @Sendable @escaping (UUID) async -> SymmetricKey? = { _ in nil }
    ) {
        self.port = port
        self.knowledgeEngine = knowledgeEngine
        self.vectorStore = vectorStore
        self.apiKey = apiKey
        self.chatModelProvider = chatModelProvider
        self.serverStatusProvider = serverStatusProvider
        self.cekProvider = cekProvider
    }

    /// Start listening. Waits until the listener is actually ready before returning.
    func start() async throws {
        let params = NWParameters.tcp
        let newListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        // Use a continuation so we can await the listener reaching .ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ResumeOnce(continuation: continuation)

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("HTTPServer: Listening on port \(self?.port ?? 0)")
                    resumeOnce.resume()
                case .failed(let error):
                    print("HTTPServer: Listener failed: \(error)")
                    resumeOnce.resume(throwing: error)
                case .cancelled:
                    resumeOnce.resume(throwing: ServerError.cancelled)
                default:
                    break
                }
            }

            newListener.start(queue: .global(qos: .userInitiated))
        }

        self.listener = newListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        for connection in sseConnections.values {
            connection.cancel()
        }
        sseConnections.removeAll()
        for task in sseKeepAliveTasks.values {
            task.cancel()
        }
        sseKeepAliveTasks.removeAll()
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        activeConnections[ObjectIdentifier(connection)] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: connection)
            case .failed, .cancelled:
                Task { await self?.cleanupConnection(connection) }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private nonisolated func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            if let error {
                print("HTTPServer: Receive error: \(error)")
                connection.cancel()
                Task { await self?.removeConnection(connection) }
                return
            }

            guard let data, !data.isEmpty else {
                connection.cancel()
                Task { await self?.removeConnection(connection) }
                return
            }

            Task {
                await self?.processRequest(data: data, connection: connection)
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Clean up a connection from both active and SSE tracking when it disconnects.
    private func cleanupConnection(_ connection: NWConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        // Also clean up SSE state if this was an SSE connection
        for (sessionId, sseConn) in sseConnections where sseConn === connection {
            removeSSEConnection(sessionId: sessionId)
            break
        }
    }

    // MARK: - HTTP parsing & routing

    private func processRequest(data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: ["error": "Empty request"])
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: ["error": "Malformed request line"])
            return
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path: String
        let queryString: String?
        if let qIndex = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<qIndex])
            queryString = String(rawPath[rawPath.index(after: qIndex)...])
        } else {
            path = rawPath
            queryString = nil
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body (everything after the blank line separating headers from body)
        var bodyString: String? = nil
        if let blankLineIndex = lines.firstIndex(of: "") {
            let bodyLines = lines[(blankLineIndex + 1)...]
            let joined = bodyLines.joined(separator: "\r\n")
            if !joined.isEmpty {
                bodyString = joined
            }
        }

        // API key authentication (if configured)
        if let requiredKey = apiKey, !requiredKey.isEmpty {
            let providedKey = extractAPIKey(from: headers)
            // Health and MCP endpoints are always public (MCP is localhost-only and uses its own SSE session auth)
            let isPublic = path == "/v1/health" || path.hasPrefix("/mcp") || method == "OPTIONS"
            if !isPublic {
                guard let providedKey, constantTimeEqual(providedKey, requiredKey) else {
                    sendResponse(connection: connection, status: 401, body: ["error": "Unauthorized — provide API key via Authorization: Bearer <key> or X-API-Key header"])
                    return
                }
            }
        }

        // Determine allowed origin for CORS
        let origin = headers["origin"]
        let allowedOrigin = corsAllowedOrigin(for: origin)

        // Log incoming requests (skip health checks to reduce noise)
        if path != "/v1/health" {
            print("HTTPServer: \(method) \(path)\(queryString.map { "?\($0)" } ?? "")")
        }

        await route(method: method, path: path, queryString: queryString, body: bodyString, connection: connection, allowedOrigin: allowedOrigin)
    }

    private nonisolated func extractAPIKey(from headers: [String: String]) -> String? {
        // Check Authorization: Bearer <key>
        if let auth = headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2 && parts[0].lowercased() == "bearer" {
                return String(parts[1])
            }
        }
        // Check X-API-Key header
        return headers["x-api-key"]
    }

    /// Only allow CORS from localhost origins.
    private nonisolated func corsAllowedOrigin(for origin: String?) -> String {
        guard let origin else { return "http://localhost" }
        let lower = origin.lowercased()
        if lower.starts(with: "http://localhost") || lower.starts(with: "http://127.0.0.1") ||
           lower.starts(with: "https://localhost") || lower.starts(with: "https://127.0.0.1") {
            return origin
        }
        return "http://localhost"
    }

    /// Constant-time string comparison.
    private nonisolated func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }

    private func route(method: String, path: String, queryString: String?, body: String?, connection: NWConnection, allowedOrigin: String) async {
        switch (method, path) {
        case ("GET", "/v1/health"):
            handleHealth(connection: connection, allowedOrigin: allowedOrigin)

        case ("GET", "/v1/collections"):
            handleListCollections(connection: connection, allowedOrigin: allowedOrigin)

        case ("POST", "/v1/query"):
            await handleQuery(body: body, connection: connection, allowedOrigin: allowedOrigin)

        // OpenAI-compatible endpoints
        case ("GET", "/v1/models"):
            handleModels(connection: connection, allowedOrigin: allowedOrigin)

        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(body: body, connection: connection, allowedOrigin: allowedOrigin)

        // MCP endpoints (HTTP POST + SSE transport)
        case ("POST", "/mcp"):
            await handleMCP(body: body, connection: connection, allowedOrigin: allowedOrigin)

        case ("GET", "/mcp/sse"):
            handleMCPSSEConnect(connection: connection, allowedOrigin: allowedOrigin)

        case ("POST", "/mcp/message"):
            await handleMCPSSEMessage(body: body, queryString: queryString, connection: connection, allowedOrigin: allowedOrigin)

        case ("OPTIONS", _):
            sendResponse(connection: connection, status: 200, body: ["status": "ok"], allowedOrigin: allowedOrigin)

        default:
            sendResponse(connection: connection, status: 404, body: ["error": "Not found"], allowedOrigin: allowedOrigin)
        }
    }

    // MARK: - Endpoint handlers

    private func handleHealth(connection: NWConnection, allowedOrigin: String) {
        sendResponse(connection: connection, status: 200, body: [
            "status": "ok",
            "version": "1.0"
        ], allowedOrigin: allowedOrigin)
    }

    private func handleListCollections(connection: NWConnection, allowedOrigin: String) {
        do {
            let collections = try vectorStore.loadCollections()
            let result = collections.map { collection -> [String: Any] in
                let isMasked = collection.isProtected && collection.protectionLevel == .sourcesMasked
                var entry: [String: Any] = [
                    "id": collection.id.uuidString,
                    "name": collection.name,
                    "protected": collection.isProtected
                ]
                if !isMasked {
                    let docs = (try? vectorStore.loadDocuments(collectionId: collection.id)) ?? []
                    entry["document_count"] = docs.count
                }
                if let level = collection.protectionLevel {
                    entry["protection_level"] = level.rawValue
                }
                return entry
            }
            sendResponse(connection: connection, status: 200, jsonArray: result, allowedOrigin: allowedOrigin)
        } catch {
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription], allowedOrigin: allowedOrigin)
        }
    }

    private func handleQuery(body: String?, connection: NWConnection, allowedOrigin: String) async {
        guard let body,
              let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let question = json["question"] as? String else {
            sendResponse(connection: connection, status: 400, body: ["error": "Missing 'question' in request body"], allowedOrigin: allowedOrigin)
            return
        }

        // Limit query length to prevent abuse
        guard question.count <= 10_000 else {
            sendResponse(connection: connection, status: 400, body: ["error": "Question too long (max 10000 characters)"], allowedOrigin: allowedOrigin)
            return
        }

        let collectionId = (json["collection_id"] as? String).flatMap { UUID(uuidString: $0) }
        let password = json["password"] as? String
        let chatModel = await chatModelProvider()

        // Search parameters
        let searchMode: SearchMode = {
            if let modeStr = json["search_mode"] as? String, let mode = SearchMode(rawValue: modeStr) {
                return mode
            }
            return .hybrid
        }()
        let enableReranking = json["enable_reranking"] as? Bool ?? false
        let enableDecomposition = json["enable_decomposition"] as? Bool ?? false

        // Check if the target collection is protected
        // sourcesMasked is permanent — sources are never revealed, even with a password
        var sourcesAllowed = true
        if let collectionId {
            if let collection = try? vectorStore.loadCollection(id: collectionId),
               collection.isProtected,
               collection.protectionLevel == .sourcesMasked {
                sourcesAllowed = false
            }
        }

        let encKey = if let collectionId { await cekProvider(collectionId) } else { SymmetricKey?.none }
        do {
            let result = try await knowledgeEngine.query(
                question: question,
                chatModel: chatModel,
                collectionId: collectionId,
                searchMode: searchMode,
                enableReranking: enableReranking,
                enableDecomposition: enableDecomposition,
                maskSources: !sourcesAllowed,
                encryptionKey: encKey
            )

            let responseBody: [String: Any]

            if sourcesAllowed {
                let sources = result.sources.map { source -> [String: Any] in
                    [
                        "document": source.documentName,
                        "content": source.chunk.content,
                        "score": source.score
                    ]
                }
                responseBody = [
                    "answer": result.answer,
                    "sources": sources,
                    "sources_masked": false
                ]
            } else {
                responseBody = [
                    "answer": result.answer,
                    "sources": [] as [[String: Any]],
                    "sources_masked": true
                ]
            }

            sendResponse(connection: connection, status: 200, body: responseBody, allowedOrigin: allowedOrigin)
        } catch {
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription], allowedOrigin: allowedOrigin)
        }
    }

    // MARK: - OpenAI-compatible endpoints

    /// GET /v1/models — lists collections as selectable "models".
    /// "indexa" is always included as a model that searches all collections.
    private func handleModels(connection: NWConnection, allowedOrigin: String) {
        do {
            let collections = try vectorStore.loadCollections()
            let now = Int(Date().timeIntervalSince1970)

            // "indexa" model = search all collections
            var models: [[String: Any]] = [[
                "id": "indexa",
                "object": "model",
                "created": now,
                "owned_by": "indexa"
            ]]

            // Each collection as a named model
            models += collections.map { collection -> [String: Any] in
                [
                    "id": collection.name,
                    "object": "model",
                    "created": now,
                    "owned_by": "indexa"
                ]
            }

            let response: [String: Any] = [
                "object": "list",
                "data": models
            ]
            sendResponse(connection: connection, status: 200, body: response, allowedOrigin: allowedOrigin)
        } catch {
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription], allowedOrigin: allowedOrigin)
        }
    }

    /// POST /v1/chat/completions — OpenAI-compatible chat endpoint.
    /// The `model` field selects a collection by ID or name. The last user message is used as the query.
    private func handleChatCompletions(body: String?, connection: NWConnection, allowedOrigin: String) async {
        guard let body,
              let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            sendResponse(connection: connection, status: 400, body: openAIError("Missing 'messages' array in request body"), allowedOrigin: allowedOrigin)
            return
        }

        // Extract the last user message as the question
        guard let lastUserMessage = messages.last(where: { ($0["role"] as? String) == "user" }),
              let question = lastUserMessage["content"] as? String else {
            sendResponse(connection: connection, status: 400, body: openAIError("No user message found"), allowedOrigin: allowedOrigin)
            return
        }

        guard question.count <= 10_000 else {
            sendResponse(connection: connection, status: 400, body: openAIError("Message too long (max 10000 characters)"), allowedOrigin: allowedOrigin)
            return
        }

        // Resolve collection from "model" field — accepts UUID or collection name.
        // If unresolved or omitted, queries across all collections.
        let modelField = json["model"] as? String
        let collectionId = resolveCollection(modelField)

        let chatModel = await chatModelProvider()

        // Enforce sourcesMasked — sources are never revealed in the LLM context
        var maskSources = false
        if let collectionId,
           let collection = try? vectorStore.loadCollection(id: collectionId),
           collection.isProtected,
           collection.protectionLevel == .sourcesMasked {
            maskSources = true
        }

        let encKey = if let collectionId { await cekProvider(collectionId) } else { SymmetricKey?.none }
        do {
            let result = try await knowledgeEngine.query(
                question: question,
                chatModel: chatModel,
                collectionId: collectionId,
                maskSources: maskSources,
                encryptionKey: encKey
            )

            let completionId = "chatcmpl-\(UUID().uuidString.prefix(12))"
            let response: [String: Any] = [
                "id": completionId,
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelField ?? "indexa",
                "choices": [[
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": result.answer
                    ],
                    "finish_reason": "stop"
                ]],
                "usage": [
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0
                ]
            ]

            sendResponse(connection: connection, status: 200, body: response, allowedOrigin: allowedOrigin)
        } catch {
            sendResponse(connection: connection, status: 500, body: openAIError(error.localizedDescription), allowedOrigin: allowedOrigin)
        }
    }

    /// Resolve a model string to a collection ID — accepts a UUID or a collection name.
    private nonisolated func resolveCollection(_ model: String?) -> UUID? {
        guard let model, !model.isEmpty else { return nil }

        // Try UUID first
        if let uuid = UUID(uuidString: model) { return uuid }

        // Try matching by name (case-insensitive)
        let lower = model.lowercased()
        if let collections = try? vectorStore.loadCollections() {
            return collections.first(where: { $0.name.lowercased() == lower })?.id
        }
        return nil
    }

    /// Format an error in OpenAI's error response shape.
    private nonisolated func openAIError(_ message: String) -> [String: Any] {
        [
            "error": [
                "message": message,
                "type": "invalid_request_error",
                "param": NSNull(),
                "code": NSNull()
            ]
        ]
    }

    // MARK: - MCP (Model Context Protocol)

    /// Handle MCP JSON-RPC 2.0 requests (Streamable HTTP / direct POST transport).
    private func handleMCP(body: String?, connection: NWConnection, allowedOrigin: String) async {
        guard let body,
              let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method = json["method"] as? String else {
            sendResponse(connection: connection, status: 400, body: mcpError(id: nil, code: -32700, message: "Parse error"), allowedOrigin: allowedOrigin)
            return
        }

        print("HTTPServer: MCP method → \(method)")

        // Notifications don't expect a response
        if method.hasPrefix("notifications/") {
            sendResponse(connection: connection, status: 202, body: ["status": "accepted"], allowedOrigin: allowedOrigin)
            return
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]
        let response = await processMCPMethod(method: method, id: id, params: params)
        sendResponse(connection: connection, status: 200, body: response, allowedOrigin: allowedOrigin)
    }

    /// Format a JSON-RPC 2.0 success response.
    private nonisolated func mcpResult(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    /// Format a JSON-RPC 2.0 error response.
    private nonisolated func mcpError(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: - MCP SSE Transport

    /// GET /mcp/sse — establishes an SSE connection. Sends the endpoint URL, then holds the connection open.
    private func handleMCPSSEConnect(connection: NWConnection, allowedOrigin: String) {
        let sessionId = UUID().uuidString

        let headerString = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "Access-Control-Allow-Origin: \(allowedOrigin)\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type, Authorization, X-API-Key\r\n"
            + "\r\n"

        let headerData = Data(headerString.utf8)

        // Send headers, then the endpoint event
        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            // Tell the client where to POST messages
            let endpointEvent = "event: endpoint\ndata: /mcp/message?sessionId=\(sessionId)\n\n"
            connection.send(content: Data(endpointEvent.utf8), completion: .contentProcessed { [weak self] sendError in
                if sendError != nil {
                    connection.cancel()
                    Task { await self?.removeSSEConnection(sessionId: sessionId) }
                }
            })
        })

        sseConnections[sessionId] = connection
        startSSEKeepAlive(sessionId: sessionId)
        print("HTTPServer: SSE connection established (session: \(sessionId.prefix(8))…)")
    }

    /// Sends a keepalive comment every 30 seconds to prevent idle TCP timeout.
    private func startSSEKeepAlive(sessionId: String) {
        sseKeepAliveTasks[sessionId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.sendSSEKeepAlive(sessionId: sessionId)
            }
        }
    }

    /// Send a single keepalive ping on an SSE connection.
    private func sendSSEKeepAlive(sessionId: String) {
        guard let connection = sseConnections[sessionId] else { return }
        let ping = Data(": keepalive\n\n".utf8)
        connection.send(content: ping, completion: .contentProcessed { [weak self] error in
            if error != nil {
                Task { await self?.removeSSEConnection(sessionId: sessionId) }
            }
        })
    }

    /// POST /mcp/message?sessionId=... — receives a JSON-RPC message, processes it, sends result via SSE.
    private func handleMCPSSEMessage(body: String?, queryString: String?, connection: NWConnection, allowedOrigin: String) async {
        // Extract sessionId from query string
        let sessionId = queryString?.split(separator: "&")
            .first(where: { $0.hasPrefix("sessionId=") })
            .map { String($0.dropFirst("sessionId=".count)) }

        guard let body,
              let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method = json["method"] as? String else {
            print("HTTPServer: MCP parse error — body \(body == nil ? "nil" : "present (\(body!.count) chars)")")
            sendResponse(connection: connection, status: 400, body: mcpError(id: nil, code: -32700, message: "Parse error"), allowedOrigin: allowedOrigin)
            return
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]
        print("HTTPServer: MCP method → \(method)")

        // Acknowledge the POST immediately so mcp-remote doesn't time out
        sendResponse(connection: connection, status: 202, body: ["status": "accepted"], allowedOrigin: allowedOrigin)

        // Notifications don't need a response on the SSE stream
        if method.hasPrefix("notifications/") { return }

        // Process the MCP request (may take seconds for query/search)
        let response = await processMCPMethod(method: method, id: id, params: params)

        // Send the result via the SSE stream
        guard let responseData = try? JSONSerialization.data(withJSONObject: response),
              let responseString = String(data: responseData, encoding: .utf8) else { return }

        let sseEvent = "event: message\ndata: \(responseString)\n\n"
        let eventData = Data(sseEvent.utf8)

        if let sessionId, let sseConn = sseConnections[sessionId] {
            sseConn.send(content: eventData, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    Task { await self?.removeSSEConnection(sessionId: sessionId) }
                }
            })
        } else {
            for (sid, sseConn) in sseConnections {
                sseConn.send(content: eventData, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        Task { await self?.removeSSEConnection(sessionId: sid) }
                    }
                })
            }
        }
    }

    private func removeSSEConnection(sessionId: String) {
        sseConnections.removeValue(forKey: sessionId)
        sseKeepAliveTasks.removeValue(forKey: sessionId)?.cancel()
        print("HTTPServer: SSE connection closed (session: \(sessionId.prefix(8))…)")
    }

    /// Process an MCP method and return the JSON-RPC response dictionary (shared by POST /mcp and SSE transport).
    private func processMCPMethod(method: String, id: Any?, params: [String: Any]) async -> [String: Any] {
        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "indexa",
                    "version": "1.1"
                ]
            ]
            return mcpResult(id: id, result: result)

        case _ where method.hasPrefix("notifications/"):
            return mcpResult(id: id, result: [:])

        case "tools/list":
            let tools = mcpToolDefinitions()
            return mcpResult(id: id, result: ["tools": tools])

        case "tools/call":
            return await processMCPToolCall(id: id, params: params)

        default:
            return mcpError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Returns the MCP tool definitions array (shared between handlers).
    private nonisolated func mcpToolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "search",
                "description": "Search for relevant document chunks without generating an AI answer. Returns raw text passages with similarity scores. Useful for context injection.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"],
                        "collection": ["type": "string", "description": "Collection name or ID to search (optional — omit to search all)"],
                        "top_k": ["type": "integer", "description": "Number of results to return (default 10)"],
                        "search_mode": ["type": "string", "description": "Search mode: 'vector' (semantic only) or 'hybrid' (semantic + keyword). Default: hybrid"]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "list_collections",
                "description": "List all available knowledge base collections with their document counts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ]
        ]
    }

    /// Process an MCP tools/call and return the JSON-RPC response (shared between handlers).
    private func processMCPToolCall(id: Any?, params: [String: Any]) async -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            return mcpError(id: id, code: -32602, message: "Missing tool name")
        }

        let args = params["arguments"] as? [String: Any] ?? [:]
        print("HTTPServer: MCP tool call → \(toolName)")

        switch toolName {
        case "search":
            guard let query = args["query"] as? String else {
                return mcpError(id: id, code: -32602, message: "Missing 'query' argument")
            }
            let collectionId = resolveCollection(args["collection"] as? String)
            let topK = args["top_k"] as? Int ?? 10
            let searchSearchMode: SearchMode = {
                if let modeStr = args["search_mode"] as? String, let mode = SearchMode(rawValue: modeStr) { return mode }
                return .hybrid
            }()

            do {
                let searchEncKey = if let collectionId { await cekProvider(collectionId) } else { SymmetricKey?.none }
                let results = try await knowledgeEngine.search(query: query, collectionId: collectionId, topK: topK, searchMode: searchSearchMode, encryptionKey: searchEncKey)

                // sourcesMasked: hide document names in search results
                var maskSearchSources = false
                if let collectionId,
                   let collection = try? vectorStore.loadCollection(id: collectionId),
                   collection.isProtected,
                   collection.protectionLevel == .sourcesMasked {
                    maskSearchSources = true
                }

                let text = results.enumerated().map { (i, r) in
                    let label = maskSearchSources ? "Source \(i + 1)" : r.documentName
                    return "[\(i + 1)] \(label) (score: \(String(format: "%.2f", r.score)))\n\(r.chunk.content)"
                }.joined(separator: "\n\n---\n\n")
                let content: [[String: Any]] = [["type": "text", "text": text.isEmpty ? "No results found." : text]]
                print("HTTPServer: MCP search completed (\(results.count) results)")
                return mcpResult(id: id, result: ["content": content])
            } catch {
                print("HTTPServer: MCP search error: \(error.localizedDescription)")
                let errorDesc = error.localizedDescription
                let hint: String
                if errorDesc.contains("Connection refused") || errorDesc.contains("Could not connect") || errorDesc.contains("Network is unreachable") {
                    let status = await serverStatusProvider()
                    if status.embed == false {
                        hint = "The embedding server is not running. Start Ollama (or your configured embedding provider) and try again."
                    } else {
                        hint = "A server connection failed. Check that Ollama is running and the Indexa Settings are correct."
                    }
                } else {
                    hint = errorDesc
                }
                let content: [[String: Any]] = [["type": "text", "text": "Error: \(hint)"]]
                return mcpResult(id: id, result: ["content": content, "isError": true])
            }

        case "list_collections":
            do {
                let collections = try vectorStore.loadCollections()
                let lines = collections.map { c -> String in
                    let count = (try? vectorStore.documentCount(collectionId: c.id)) ?? 0
                    return "- \(c.name) (\(count) documents) [id: \(c.id.uuidString)]"
                }

                // Include server status so the LLM can inform the user
                let status = await serverStatusProvider()
                var statusLines: [String] = []
                if status.embed == false {
                    statusLines.append("⚠ Embedding server is OFFLINE — search will not work. Start Ollama or check Indexa Settings.")
                }
                if status.llm == false {
                    statusLines.append("⚠ LLM server is OFFLINE — query answering is unavailable. Start Ollama or check Indexa Settings.")
                }

                let collectionsText = lines.isEmpty ? "No collections." : lines.joined(separator: "\n")
                let fullText = (statusLines + [collectionsText]).joined(separator: "\n\n")
                let content: [[String: Any]] = [["type": "text", "text": fullText]]
                return mcpResult(id: id, result: ["content": content])
            } catch {
                let content: [[String: Any]] = [["type": "text", "text": "Error: \(error.localizedDescription)"]]
                return mcpResult(id: id, result: ["content": content, "isError": true])
            }

        default:
            return mcpError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Rate limiting

    private func isRateLimited(key: String) -> Bool {
        guard let record = failedAttempts[key] else { return false }
        if record.count >= maxAttempts {
            if Date().timeIntervalSince(record.lastAttempt) < lockoutDuration {
                return true
            }
            // Lockout expired, reset
            failedAttempts.removeValue(forKey: key)
            return false
        }
        return false
    }

    private func recordFailedAttempt(key: String) {
        let existing = failedAttempts[key]
        failedAttempts[key] = (count: (existing?.count ?? 0) + 1, lastAttempt: Date())
    }

    private func resetAttempts(key: String) {
        failedAttempts.removeValue(forKey: key)
    }

    // MARK: - Response helpers

    private nonisolated func sendResponse(connection: NWConnection, status: Int, body: [String: Any], allowedOrigin: String = "http://localhost") {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted) else {
            connection.cancel()
            return
        }
        sendRawResponse(connection: connection, status: status, jsonData: jsonData, allowedOrigin: allowedOrigin)
    }

    private nonisolated func sendResponse(connection: NWConnection, status: Int, jsonArray: [[String: Any]], allowedOrigin: String = "http://localhost") {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray, options: .prettyPrinted) else {
            connection.cancel()
            return
        }
        sendRawResponse(connection: connection, status: status, jsonData: jsonData, allowedOrigin: allowedOrigin)
    }

    private nonisolated func sendRawResponse(connection: NWConnection, status: Int, jsonData: Data, allowedOrigin: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let headerString = "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(jsonData.count)\r\n"
            + "Access-Control-Allow-Origin: \(allowedOrigin)\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type, Authorization, X-API-Key\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        var responseData = Data(headerString.utf8)
        responseData.append(jsonData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Errors

    nonisolated enum ServerError: LocalizedError {
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Server was cancelled before it could start"
            }
        }
    }
}
