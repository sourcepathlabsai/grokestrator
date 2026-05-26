import Foundation

/// High-level client-side representation of a session to one Grokestrator server.
/// The Mac app maintains an array of these (one per tab/server).
/// iOS typically has one active at a time.
public struct MultiServerSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let serverAddress: ServerAddress
    public var displayName: String
    public var connection: Connection
    public var lastError: GrokestratorError?

    public init(serverAddress: ServerAddress, displayName: String? = nil) {
        self.id = UUID()
        self.serverAddress = serverAddress
        self.displayName = displayName ?? serverAddress.name
        self.connection = Connection(serverAddress: serverAddress, state: .disconnected)
    }

    public mutating func updateConnectionState(_ state: ConnectionState) {
        connection.updateState(state)
        if !state.isActive {
            lastError = nil
        }
    }

    public mutating func applyServerInfo(_ info: ServerInfo) {
        connection.setServerInfo(info)
        if !displayName.isEmpty && info.name != serverAddress.name {
            displayName = info.name
        }
    }

    public var isConnected: Bool {
        connection.isConnected
    }
}
