import Foundation

/// Represents a connection address to a Grokestrator server.
/// Used by clients to connect to either a local or remote server.
public struct ServerAddress: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String          // User-friendly name, e.g. "Dev Mac" or "Work Machine"
    public let tailscaleAddress: String
    public let port: Int

    public init(
        id: UUID = UUID(),
        name: String,
        tailscaleAddress: String,
        port: Int = 8080
    ) {
        self.id = id
        self.name = name
        self.tailscaleAddress = tailscaleAddress
        self.port = port
    }
}
