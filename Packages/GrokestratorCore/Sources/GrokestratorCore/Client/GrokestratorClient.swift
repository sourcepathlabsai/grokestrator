import Foundation

/// Abstract transport used by `GrokestratorClient` to send requests and receive events.
///
/// This protocol allows the client to remain independent of the actual networking
/// implementation (WebSocket, in-process for hybrid Mac, mock for tests, etc.).
public protocol GrokestratorClientTransport: Sendable {
    /// Sends a request to a specific server.
    func send(_ request: GrokestratorRequest, serverID: UUID) async throws

    /// Attaches a handler that will be called when events arrive from any server.
    ///
    /// The handler is `async` so that a transport can await full processing of an
    /// event before delivering the next one — giving deterministic ordering and
    /// making tests reliable. The handler is expected to call back into
    /// `GrokestratorClient.handleIncoming`.
    func setEventHandler(_ handler: @escaping @Sendable (GrokestratorEvent, UUID) async -> Void) async
}

/// Top-level client for communicating with one or more Grokestrator servers.
///
/// This actor owns server connections, manages higher-level sessions (such as
/// `GrokBuildClientSession`), and provides centralized event routing and
/// connection lifecycle management.
public actor GrokestratorClient {

    // MARK: - Types

    public enum ClientEvent: Sendable {
        case serverConnected(serverID: UUID)
        case serverDisconnected(serverID: UUID, reason: String?)
        case serverError(serverID: UUID, error: GrokestratorError)
        case grokBuildSessionInvalidated(instanceID: UUID, reason: String)
    }

    public struct ServerStatus: Sendable, Equatable {
        public let serverID: UUID
        public let state: ConnectionState
        public let lastError: GrokestratorError?
        public let connectedAt: Date?
    }

    // MARK: - State

    private var serverSessions: [UUID: MultiServerSession] = [:]
    private var grokBuildSessions: [UUID: GrokBuildClientSession] = [:]   // keyed by instanceID

    /// Maps promptID → instanceID for precise event routing of prompt-scoped events
    private var promptToInstance: [UUID: UUID] = [:]

    private let (eventStream, eventContinuation) = AsyncStream<ClientEvent>.makeStream()

    /// Per-server event streams for clients that want to observe only one server
    private var perServerContinuations: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]

    /// Transports keyed by serverID. This allows different servers to use different
    /// transports (e.g. real WebSocket for one, in-memory mock for another during tests).
    private var transports: [UUID: GrokestratorClientTransport] = [:]

    public init() {}

    // MARK: - Server Management & Lifecycle

    /// Adds a server. You can optionally provide a transport for this specific server.
    public func addServer(
        _ address: ServerAddress,
        displayName: String? = nil,
        transport: GrokestratorClientTransport? = nil
    ) -> MultiServerSession {
        var session = MultiServerSession(serverAddress: address, displayName: displayName)
        let sessionID = session.id

        if let transport = transport {
            transports[sessionID] = transport
        }

        session.setRequestSender { [weak self] request in
            await self?.sendRequest(request, serverID: sessionID)
        }

        serverSessions[sessionID] = session
        return session
    }

    public func removeServer(id: UUID) {
        serverSessions.removeValue(forKey: id)

        // Invalidate all GrokBuild sessions for instances on this server
        for (instanceID, buildSession) in grokBuildSessions {
            Task { await buildSession.invalidate(reason: "Server removed") }
            grokBuildSessions.removeValue(forKey: instanceID)
        }

        // Clean up prompt mappings
        promptToInstance = promptToInstance.filter { $0.value != id } // rough cleanup
    }

    /// Attempts to connect to a server.
    public func connect(to serverID: UUID) async {
        guard var session = serverSessions[serverID] else { return }

        session.updateConnectionState(.connecting)
        serverSessions[serverID] = session

        // Wire the event handler if a transport is registered for this server
        if let transport = transports[serverID] {
            await transport.setEventHandler { [weak self] event, sid in
                await self?.handleIncoming(event: event, from: sid)
            }
        }

        // In a real implementation this would trigger the actual transport connect.
        session.updateConnectionState(.connected)
        serverSessions[serverID] = session

        yield(.serverConnected(serverID: serverID))
    }

    /// Disconnects from a server and cleans up dependent sessions.
    public func disconnect(from serverID: UUID, reason: String? = nil) async {
        guard var session = serverSessions[serverID] else { return }

        session.updateConnectionState(.disconnected)
        serverSessions[serverID] = session

        // Invalidate GrokBuild sessions
        for (instanceID, buildSession) in grokBuildSessions {
            await buildSession.invalidate(reason: reason ?? "Server disconnected")
            grokBuildSessions.removeValue(forKey: instanceID)
        }

        // Clean prompt mappings for this server
        promptToInstance = promptToInstance.filter { _ in false } // simplistic for now

        yield(.serverDisconnected(serverID: serverID, reason: reason))
    }

    /// Basic reconnection attempt.
    public func reconnect(to serverID: UUID) async {
        await disconnect(from: serverID, reason: "Reconnecting")
        await connect(to: serverID)
    }

    // MARK: - Status Observation

    /// Returns the current status for a server.
    public func status(for serverID: UUID) -> ServerStatus? {
        guard let session = serverSessions[serverID] else { return nil }
        return ServerStatus(
            serverID: serverID,
            state: session.connection.state,
            lastError: session.lastError,
            connectedAt: session.connection.connectedAt
        )
    }

    /// Stream of high-level client events (connection lifecycle, errors, etc.).
    public var events: AsyncStream<ClientEvent> {
        eventStream
    }

    /// Returns a lightweight event stream scoped to a single server.
    public func events(for serverID: UUID) -> AsyncStream<ClientEvent> {
        let (stream, continuation) = AsyncStream<ClientEvent>.makeStream()

        if let existing = perServerContinuations[serverID] {
            // If one already exists we replace it (simple policy)
            existing.finish()
        }
        perServerContinuations[serverID] = continuation

        return stream
    }

    // MARK: - Grok Build Sessions

    public func grokBuildSession(
        for instanceID: UUID,
        on serverSession: MultiServerSession
    ) -> GrokBuildClientSession {
        if let existing = grokBuildSessions[instanceID] {
            return existing
        }

        let send: @Sendable (GrokestratorRequest) async throws -> Void = { [weak self] request in
            await self?.sendRequest(request, serverID: serverSession.id)
        }

        let register: @Sendable (UUID, UUID) -> Void = { [weak self] promptID, instID in
            Task {
                await self?.registerActivePrompt(promptID: promptID, instanceID: instID)
            }
        }

        let newSession = GrokBuildClientSession(
            instanceID: instanceID,
            sendRequest: send,
            registerPrompt: register
        )
        grokBuildSessions[instanceID] = newSession
        return newSession
    }

    // MARK: - Event Routing (Improved)

    /// Central entry point for all incoming events from the transport layer.
    public func handleIncoming(event: GrokestratorEvent, from serverID: UUID) async {
        // Route GrokBuildEvents intelligently
        if case .grokBuild(let buildEvent) = event {
            await routeGrokBuildEvent(buildEvent)
        }

        // Future: react to serverStateChanged, errors, etc. for serverSessions[serverID]
    }

    private func routeGrokBuildEvent(_ event: GrokBuildEvent) async {
        let targetInstanceID: UUID? = {
            switch event {
            case .conversationUpdate(let instID, _, _): return instID
            case .promptCompleted(let instID, _, _): return instID
            case .instanceDied(let instID, _): return instID
            case .pendingToolCallsChanged(let instID, _, _): return instID
            case .permissionRequested(let instID, _, _): return instID
            case .error(let instID, _, _): return instID
            case .capabilitiesUpdated(let instID, _): return instID
            case .usageUpdated(let instID, _): return instID
            case .historySnapshot(let instID, _): return instID
            case .mediaData(let instID, _, _): return instID
            }
        }()

        if let instID = targetInstanceID,
           let buildSession = grokBuildSessions[instID] {
            await buildSession.handle(event: event)
            return
        }

        // Fallback: broadcast to all sessions (useful during early development)
        for (_, session) in grokBuildSessions {
            await session.handle(event: event)
        }
    }

    // MARK: - Prompt Tracking (for improved routing)

    /// Called by `GrokBuildClientSession` when it successfully starts a prompt.
    /// This enables precise routing of prompt-scoped events.
    internal func registerActivePrompt(promptID: UUID, instanceID: UUID) {
        promptToInstance[promptID] = instanceID
    }

    internal func unregisterPrompt(promptID: UUID) {
        promptToInstance.removeValue(forKey: promptID)
    }

    // MARK: - Private

    private func sendRequest(_ request: GrokestratorRequest, serverID: UUID) async {
        guard let session = serverSessions[serverID] else { return }

        if let transport = transports[serverID] {
            do {
                try await transport.send(request, serverID: serverID)
            } catch {
                yield(.serverError(serverID: serverID, error: GrokestratorError.transportError(error.localizedDescription)))
            }
        } else {
            // Fallback when no transport is configured for this server
            print("[GrokestratorClient] (no transport) Sending to \(session.displayName): \(request)")
        }
    }

    private func yield(_ event: ClientEvent) {
        eventContinuation.yield(event)

        // Also forward to any per-server listener
        switch event {
        case .serverConnected(let id),
             .serverDisconnected(let id, _),
             .serverError(let id, _):
            perServerContinuations[id]?.yield(event)
        case .grokBuildSessionInvalidated:
            break
        }
    }
}
