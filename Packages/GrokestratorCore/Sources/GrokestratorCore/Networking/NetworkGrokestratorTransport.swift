import Foundation
import Network

/// Network implementation of `GrokestratorClientTransport`.
///
/// Speaks newline-delimited JSON of `GrokestratorMessage` envelopes over a plain
/// TCP socket via `Network.framework`. Tailscale provides transport security
/// (WireGuard tunnel) + peer authentication (tailnet ACLs), so we deliberately
/// do not add TLS or app-level auth at this layer — a personal tailnet IS the
/// trust boundary. A per-server shared token could be layered on later via a
/// hello frame; the protocol is forward-compatible.
public actor NetworkGrokestratorTransport: GrokestratorClientTransport {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let serverID: UUID
    private var connection: NWConnection?
    private var eventHandler: (@Sendable (GrokestratorEvent, UUID) async -> Void)?
    private var buffer = LineFrameBuffer()
    private var readerTask: Task<Void, Never>?

    /// Creates a transport bound to a single remote server. `serverID` is the
    /// `MultiServerSession.id` the parent `GrokestratorClient` uses for routing.
    public init(host: String, port: UInt16, serverID: UUID) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(integerLiteral: port)
        self.serverID = serverID
    }

    /// Opens the TCP connection and starts streaming inbound frames. Idempotent.
    public func connect() async throws {
        if connection != nil { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.preferNoProxies = true

        let connection = NWConnection(host: host, port: port, using: params)
        self.connection = connection

        // Bridge NWConnection state changes into an async waitForReady.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:                  once.fire { cont.resume() }
                case .failed(let err):        once.fire { cont.resume(throwing: err) }
                case .cancelled:              once.fire { cont.resume(throwing: GrokestratorError.transportError("cancelled")) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        // After ready, switch to a quieter state handler that logs failures.
        connection.stateUpdateHandler = { _ in }
        startReceiveLoop(connection)
    }

    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        connection?.cancel()
        connection = nil
    }

    public func setEventHandler(_ handler: @escaping @Sendable (GrokestratorEvent, UUID) async -> Void) {
        eventHandler = handler
    }

    /// Sends a request as a `GrokestratorMessage(payload: .request(...))` frame.
    public func send(_ request: GrokestratorRequest, serverID _: UUID) async throws {
        guard let connection else { throw GrokestratorError.transportError("not connected") }
        let frame = try LineFramedJSONCodec.encode(GrokestratorMessage(payload: .request(request)))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    // MARK: - Receive loop

    /// Schedules repeated receives on the connection, feeding bytes into the
    /// frame buffer and dispatching decoded events to the handler.
    private func startReceiveLoop(_ connection: NWConnection) {
        readerTask = Task { [weak self, serverID] in
            while !Task.isCancelled {
                let chunk: Data
                do {
                    chunk = try await Self.receive(on: connection)
                } catch {
                    await self?.eventHandler?(.error(.transportError(error.localizedDescription)), serverID)
                    return
                }
                if chunk.isEmpty { return }   // EOF
                await self?.handleBytes(chunk, serverID: serverID)
            }
        }
    }

    private func handleBytes(_ chunk: Data, serverID: UUID) async {
        let frames = buffer.append(chunk)
        for frame in frames {
            guard let message = try? LineFramedJSONCodec.decode(frame) else { continue }
            if case .event(let event) = message.payload {
                await eventHandler?(event, serverID)
            }
            // Responses are not delivered through this transport's event handler;
            // the current protocol uses events for streaming + caps/usage delivery.
        }
    }

    /// One-shot bridge from NWConnection's callback API to async.
    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: Data()); return }
                cont.resume(returning: Data())
            }
        }
    }
}
