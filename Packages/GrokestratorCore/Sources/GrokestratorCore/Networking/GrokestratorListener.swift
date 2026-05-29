import Foundation
import Network
import os

private let netLog = Logger(subsystem: "ai.sourcepathlabs.grokestrator", category: "net")

/// Server-side counterpart of `NetworkGrokestratorTransport`. Accepts inbound
/// TCP connections on a configurable port, parses incoming `GrokestratorMessage`
/// frames, dispatches requests through an injectable handler, and broadcasts
/// events to every connected client.
///
/// One listener serves all clients (Mac running grok + iOS, or another Mac).
/// Each accepted connection is its own actor so per-client state stays isolated.
/// Tailscale handles encryption + peer auth; nothing additional at this layer.
public actor GrokestratorListener {
    /// What an accepted client looks like from the outside — used by event
    /// broadcast to selectively skip the sender or address a specific client.
    public typealias ClientID = UUID

    /// Handler invoked for every incoming request. Receives the request, the
    /// originating client's id, and an `emit` closure for sending events back
    /// (e.g. push streaming `conversationUpdate`s to that client).
    public typealias RequestHandler = @Sendable (GrokestratorRequest, ClientID, ListenerOutbox) async -> Void

    /// Snapshot of capabilities a handler can use to push events without
    /// reaching back into the listener actor's private state.
    public struct ListenerOutbox: Sendable {
        public let toClient: @Sendable (GrokestratorEvent, ClientID) async -> Void
        public let broadcast: @Sendable (GrokestratorEvent) async -> Void
    }

    public enum State: Sendable, Equatable {
        case stopped, starting, listening(port: UInt16), failed(String)
    }

    private(set) public var state: State = .stopped
    private var listener: NWListener?
    private var clients: [ClientID: ClientConnection] = [:]
    private let handler: RequestHandler

    public init(handler: @escaping RequestHandler) {
        self.handler = handler
    }

    /// Binds and starts listening. Throws if the port can't be bound.
    public func start(port: UInt16) async throws {
        guard listener == nil else { return }
        state = .starting

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        // Surface the actual listening port (useful when callers pass 0).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceGuard()
            listener.stateUpdateHandler = { [weak self] s in
                Task { await self?.handleListenerState(s, port: port, resume: { result in
                    once.fire {
                        switch result {
                        case .success: cont.resume()
                        case .failure(let e): cont.resume(throwing: e)
                        }
                    }
                }) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Stops the listener and disconnects every client.
    public func stop() async {
        listener?.cancel()
        listener = nil
        for (_, client) in clients { await client.close() }
        clients.removeAll()
        state = .stopped
    }

    /// Pushes an event to every connected client.
    public func broadcast(_ event: GrokestratorEvent) async {
        let frame: Data
        do { frame = try LineFramedJSONCodec.encode(GrokestratorMessage(payload: .event(event))) }
        catch { return }
        for (_, client) in clients { await client.send(frame) }
    }

    /// Pushes an event to one specific client.
    public func send(_ event: GrokestratorEvent, to clientID: ClientID) async {
        guard let client = clients[clientID] else { return }
        let frame: Data
        do { frame = try LineFramedJSONCodec.encode(GrokestratorMessage(payload: .event(event))) }
        catch { return }
        await client.send(frame)
    }

    // MARK: - Private

    private func handleListenerState(_ s: NWListener.State, port: UInt16,
                                     resume: @escaping @Sendable (Result<Void, Error>) -> Void) {
        switch s {
        case .ready:
            let bound = listener?.port?.rawValue ?? port
            state = .listening(port: bound)
            resume(.success(()))
        case .failed(let err):
            state = .failed(err.localizedDescription)
            resume(.failure(err))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let outbox = ListenerOutbox(
            toClient: { [weak self] event, cid in await self?.send(event, to: cid) },
            broadcast: { [weak self] event in await self?.broadcast(event) }
        )
        let client = ClientConnection(id: id, connection: connection) { [weak self] request in
            guard let self else { return }
            await self.handler(request, id, outbox)
        } onClose: { [weak self] in
            await self?.removeClient(id)
        }
        clients[id] = client
        Task { await client.start() }
    }

    private func removeClient(_ id: ClientID) {
        clients.removeValue(forKey: id)
    }
}

/// One accepted client connection. Reads frames, decodes requests, forwards
/// them up to the listener's handler. `send` writes a pre-encoded frame.
private actor ClientConnection {
    let id: GrokestratorListener.ClientID
    private let connection: NWConnection
    private var buffer = LineFrameBuffer()
    private var readerTask: Task<Void, Never>?
    private let onRequest: @Sendable (GrokestratorRequest) async -> Void
    private let onClose: @Sendable () async -> Void

    init(id: UUID, connection: NWConnection,
         onRequest: @escaping @Sendable (GrokestratorRequest) async -> Void,
         onClose: @escaping @Sendable () async -> Void) {
        self.id = id
        self.connection = connection
        self.onRequest = onRequest
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: .global(qos: .userInitiated))
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func send(_ frame: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { netLog.error("client.send FAILED \(frame.count)B: \(String(describing: error), privacy: .public)") }
                cont.resume()
            })
        }
    }

    func close() async {
        readerTask?.cancel()
        readerTask = nil
        connection.cancel()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            let chunk: Data
            do { chunk = try await Self.receive(on: connection) }
            catch { await onClose(); return }
            if chunk.isEmpty { await onClose(); return }
            for frame in buffer.append(chunk) {
                guard let message = try? LineFramedJSONCodec.decode(frame) else { continue }
                if case .request(let req) = message.payload {
                    await onRequest(req)
                }
            }
        }
    }

    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: Data()); return }
                cont.resume(returning: Data())
            }
        }
    }
}
