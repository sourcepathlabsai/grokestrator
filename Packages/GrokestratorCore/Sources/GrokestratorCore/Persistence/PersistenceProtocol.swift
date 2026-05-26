import Foundation

/// Protocol for persisting Grokestrator data (server addresses, conversations,
/// messages, configurations). Implementations can be file-based, SQLite, or
/// even remote for future multi-device sync.
///
/// The Core ships with a simple file-based implementation suitable for MVP.
public protocol PersistenceProtocol: Sendable {
    // Server addresses (the "known servers" a client talks to)
    func loadServerAddresses() async throws -> [ServerAddress]
    func saveServerAddress(_ address: ServerAddress) async throws
    func deleteServerAddress(id: UUID) async throws

    // Conversations
    func loadConversations(forServer serverID: UUID) async throws -> [Conversation]
    func saveConversation(_ conversation: Conversation) async throws
    func deleteConversation(id: UUID) async throws

    // Messages
    func loadMessages(forConversation conversationID: UUID, limit: Int?) async throws -> [Message]
    func saveMessage(_ message: Message) async throws

    // Server configuration (only meaningful on the server / Mac hybrid app)
    func loadServerConfiguration() async throws -> ServerConfiguration?
    func saveServerConfiguration(_ config: ServerConfiguration) async throws

    // Client configuration (per-device)
    func loadClientConfiguration() async throws -> ClientConfiguration
    func saveClientConfiguration(_ config: ClientConfiguration) async throws
}
