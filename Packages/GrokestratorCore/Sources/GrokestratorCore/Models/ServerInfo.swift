import Foundation

/// Lightweight information about a Grokestrator server returned after connection
/// or during discovery. Used by clients to display server details in tabs/panes.
public struct ServerInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let version: String?
    public let address: ServerAddress
    public let capabilities: Set<ServerCapability>
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        version: String? = nil,
        address: ServerAddress,
        capabilities: Set<ServerCapability> = [],
        startedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.address = address
        self.capabilities = capabilities
        self.startedAt = startedAt
    }
}

public enum ServerCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case instanceManagement
    case conversationPersistence
    case autoRestart
    case multiClient
}
