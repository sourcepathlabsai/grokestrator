import Foundation

/// Represents a Grok Build instance that the user can interact with.
public struct Agent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let serverID: UUID
    public let name: String
    public let status: Status

    public enum Status: String, Codable, Sendable {
        case running
        case stopped
        case error
    }

    public init(id: UUID = UUID(), serverID: UUID, name: String, status: Status) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.status = status
    }
}
