import Foundation

/// Represents an active (or attempted) connection from a client to one Grokestrator server.
/// The Mac client holds one per server/tab. iOS clients hold one (or more in future).
public struct Connection: Sendable, Equatable {
    public let serverAddress: ServerAddress
    public private(set) var state: ConnectionState
    public private(set) var serverInfo: ServerInfo?
    public private(set) var connectedAt: Date?

    public init(serverAddress: ServerAddress, state: ConnectionState = .disconnected) {
        self.serverAddress = serverAddress
        self.state = state
        self.serverInfo = nil
        self.connectedAt = nil
    }

    public mutating func updateState(_ newState: ConnectionState) {
        self.state = newState
        if case .connected = newState {
            self.connectedAt = Date()
        }
    }

    public mutating func setServerInfo(_ info: ServerInfo) {
        self.serverInfo = info
    }

    public var isConnected: Bool {
        state.isConnected
    }
}
