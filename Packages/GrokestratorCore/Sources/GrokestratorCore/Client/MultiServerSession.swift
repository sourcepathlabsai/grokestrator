import Foundation

/// High-level client-side representation of a session to one Grokestrator server.
/// The Mac app maintains an array of these (one per tab/server).
/// iOS typically has one active at a time.
///
/// In early development this also holds a `sendRequest` closure that is wired
/// by the owning `GrokestratorClient`.
public struct MultiServerSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let serverAddress: ServerAddress
    public var displayName: String
    public var connection: Connection
    public var lastError: GrokestratorError?

    private var requestSender: (@Sendable (GrokestratorRequest) async throws -> Void)?

    public init(serverAddress: ServerAddress, displayName: String? = nil) {
        self.id = UUID()
        self.serverAddress = serverAddress
        self.displayName = displayName ?? serverAddress.name
        self.connection = Connection(serverAddress: serverAddress, state: .disconnected)
    }

    /// Sends a control-plane request through the owning `GrokestratorClient`.
    ///
    /// This is the recommended way to send requests for this server session.
    public func send(_ request: GrokestratorRequest) async throws {
        guard let sender = requestSender else {
            throw GrokestratorError.configurationError("No request sender configured for this MultiServerSession")
        }
        try await sender(request)
    }

    /// Internal: called by `GrokestratorClient` to wire the actual sending mechanism.
    internal mutating func setRequestSender(_ sender: @escaping @Sendable (GrokestratorRequest) async throws -> Void) {
        self.requestSender = sender
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
