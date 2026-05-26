import Foundation

/// Abstraction for the underlying transport used to communicate with a Grokestrator server.
/// This allows us to swap implementations (e.g., WebSocket, mock for testing) without changing higher layers.
public protocol GrokestratorTransport: Sendable {
    /// Establishes a connection to the given server address.
    func connect(to address: ServerAddress) async throws

    /// Disconnects from the current server.
    func disconnect() async

    /// Sends raw data to the connected server.
    func send(_ data: Data) async throws

    /// Stream of incoming data from the server.
    var incomingData: AsyncStream<Data> { get }
}
