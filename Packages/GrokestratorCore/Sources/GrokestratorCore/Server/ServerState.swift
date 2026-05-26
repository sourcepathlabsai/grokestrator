import Foundation

/// Live runtime state of the Grokestrator server (owned by the Mac hybrid app).
/// Published to connected clients via the protocol.
public struct ServerState: Codable, Sendable, Equatable {
    public var isRunning: Bool
    public var serverInfo: ServerInfo
    public var managedInstances: [ManagedInstance]
    public var connectedClients: Int
    public var uptime: TimeInterval?

    public init(
        isRunning: Bool = false,
        serverInfo: ServerInfo,
        managedInstances: [ManagedInstance] = [],
        connectedClients: Int = 0,
        uptime: TimeInterval? = nil
    ) {
        self.isRunning = isRunning
        self.serverInfo = serverInfo
        self.managedInstances = managedInstances
        self.connectedClients = connectedClients
        self.uptime = uptime
    }

    /// Convenience for tests / initial state
    public static func initial(serverName: String, address: ServerAddress) -> ServerState {
        let info = ServerInfo(name: serverName, address: address)
        return ServerState(
            isRunning: false,
            serverInfo: info,
            managedInstances: [],
            connectedClients: 0
        )
    }
}
