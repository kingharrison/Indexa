import Foundation

/// The API format a provider uses — determines endpoint paths and request/response shapes.
nonisolated enum APIFormat: String, Codable, Sendable, CaseIterable {
    case ollama   // /api/embed, /api/chat, /api/tags
    case openAI   // /v1/embeddings, /v1/chat/completions, /v1/models

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI Compatible"
        }
    }
}

/// Configuration for a single server connection.
nonisolated struct ServerConfig: Codable, Sendable, Equatable {
    var baseURL: String
    var apiFormat: APIFormat
    var apiKey: String?

    static let defaultOllama = ServerConfig(
        baseURL: "http://localhost:11434",
        apiFormat: .ollama
    )

    static let defaultLMStudio = ServerConfig(
        baseURL: "http://localhost:1234",
        apiFormat: .openAI
    )
}

/// Full provider configuration with separate chat and embed roles.
nonisolated struct ProviderConfig: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var isDefault: Bool

    // Chat role — the server + model used for answering questions and distillation
    var chatServer: ServerConfig
    var chatModel: String?  // nil = auto-detect from server

    // Embed role — the server + model used for generating embeddings
    var embedServer: ServerConfig
    var embedModel: String

    /// Convenience — are chat and embed using the same server?
    var usesSameServer: Bool {
        chatServer == embedServer
    }

    // Legacy compatibility aliases
    var baseURL: String { chatServer.baseURL }
    var apiFormat: APIFormat { chatServer.apiFormat }
    var apiKey: String? { chatServer.apiKey }

    init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        chatServer: ServerConfig = .defaultOllama,
        chatModel: String? = nil,
        embedServer: ServerConfig = .defaultOllama,
        embedModel: String = "nomic-embed-text"
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.chatServer = chatServer
        self.chatModel = chatModel
        self.embedServer = embedServer
        self.embedModel = embedModel
    }

    /// The default Ollama provider — both chat and embed on the same server.
    static let defaultOllama = ProviderConfig(
        name: "Ollama",
        isDefault: true,
        chatServer: .defaultOllama,
        embedServer: .defaultOllama,
        embedModel: "nomic-embed-text"
    )
}
