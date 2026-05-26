import Foundation

/// A simple in-memory implementation of `GrokestratorClientTransport`.
///
/// Useful for testing the client-side flow end-to-end without any real networking.
///
/// Usage in tests:
/// ```swift
/// let transport = InMemoryGrokestratorTransport()
/// let client = GrokestratorClient(transport: transport)
///
/// let serverID = client.addServer(someAddress).id
/// await client.connect(to: serverID)
///
/// // Later, simulate the server sending events back
/// transport.simulateIncomingEvent(.grokBuild(...), from: serverID)
/// ```
public actor InMemoryGrokestratorTransport: GrokestratorClientTransport {

    private var eventHandler: (@Sendable (GrokestratorEvent, UUID) -> Void)?

    /// Optional handler that is invoked when a request is sent.
    /// The handler can return events that will be immediately delivered back
    /// (simulating a synchronous server response for testing).
    private var requestHandler: (@Sendable (GrokestratorRequest, UUID) async -> [GrokestratorEvent])?

    /// Stores the last requests sent per server (useful for test assertions).
    public private(set) var sentRequests: [UUID: [GrokestratorRequest]] = [:]

    public init() {}

    public func send(_ request: GrokestratorRequest, serverID: UUID) async throws {
        var requests = sentRequests[serverID] ?? []
        requests.append(request)
        sentRequests[serverID] = requests

        if let handler = requestHandler {
            let events = await handler(request, serverID)
            for event in events {
                simulateIncomingEvent(event, from: serverID)
            }
        }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (GrokestratorEvent, UUID) -> Void) {
        self.eventHandler = handler
    }

    // MARK: - Test Helpers

    /// Sets a handler that will be called for every `send` request.
    /// The handler can return events to simulate the server's response.
    public func setRequestHandler(_ handler: @escaping @Sendable (GrokestratorRequest, UUID) async -> [GrokestratorEvent]) {
        self.requestHandler = handler
    }

    /// Manually simulates an event arriving from a server.
    /// Useful when you want full control instead of using the request handler.
    public func simulateIncomingEvent(_ event: GrokestratorEvent, from serverID: UUID) {
        eventHandler?(event, serverID)
    }

    /// Clears all recorded state (useful between tests).
    public func reset() {
        sentRequests.removeAll()
        requestHandler = nil
    }
}
```