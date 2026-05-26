import Foundation

public enum GrokestratorError: Error, LocalizedError, Sendable, Equatable, Codable {
    case connectionFailed(String)
    case serverNotFound
    case invalidResponse
    case configurationError(String)
    case instanceManagementError(String)
    case persistenceError(String)
    case protocolError(String)
    case unauthorized
    case transportError(String)
    case sessionInvalidated

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .serverNotFound:
            return "Server not found"
        case .invalidResponse:
            return "Invalid response from server"
        case .configurationError(let reason):
            return "Configuration error: \(reason)"
        case .instanceManagementError(let reason):
            return "Instance management error: \(reason)"
        case .persistenceError(let reason):
            return "Persistence error: \(reason)"
        case .protocolError(let reason):
            return "Protocol error: \(reason)"
        case .unauthorized:
            return "Unauthorized"
        case .transportError(let message):
            return "Transport error: \(message)"
        case .sessionInvalidated:
            return "Session has been invalidated"
        }
    }
}
