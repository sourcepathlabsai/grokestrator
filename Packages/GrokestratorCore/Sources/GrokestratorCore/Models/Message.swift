import Foundation

public struct Message: Identifiable, Codable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let role: Role
    public let content: String
    public let createdAt: Date

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: Role,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}
