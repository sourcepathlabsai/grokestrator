import Foundation

/// Client-side preferences and connection settings.
/// Stored per client (Mac tabs remember their servers, iOS remembers last used).
public struct ClientConfiguration: Codable, Sendable, Equatable {
    public var knownServers: [ServerAddress]
    public var lastActiveServerID: UUID?
    public var autoReconnect: Bool
    public var connectionTimeoutSeconds: TimeInterval

    public init(
        knownServers: [ServerAddress] = [],
        lastActiveServerID: UUID? = nil,
        autoReconnect: Bool = true,
        connectionTimeoutSeconds: TimeInterval = 15.0
    ) {
        self.knownServers = knownServers
        self.lastActiveServerID = lastActiveServerID
        self.autoReconnect = autoReconnect
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
    }
}
