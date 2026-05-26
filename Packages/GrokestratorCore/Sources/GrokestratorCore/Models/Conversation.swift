import Foundation

/// Represents a conversation thread with a specific Grok Build instance.
public struct Conversation: Identifiable, Codable, Sendable {
    public let id: UUID
    public let serverID: UUID          // Which server this conversation belongs to
    public let instanceID: UUID?       // Which specific Grok instance (if pinned)
    public let title: String
    public let createdAt: Date
    public var lastUpdatedAt: Date

    public init(
        id: UUID = UUID(),
        serverID: UUID,
        instanceID: UUID? = nil,
        title: String,
        createdAt: Date = Date(),
        lastUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.instanceID = instanceID
        self.title = title
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}
