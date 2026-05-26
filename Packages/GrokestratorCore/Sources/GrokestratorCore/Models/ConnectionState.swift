import Foundation

/// Represents the lifecycle state of a connection to a Grokestrator server.
public enum ConnectionState: Equatable, Hashable, Sendable, Codable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting:
            return true
        case .disconnected, .failed:
            return false
        }
    }
}
