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
    private var readerTask: Task<Void, Never>?
    /// Frames are pushed here by the socket reader and consumed by a separate
    /// task, so decoding/dispatch never backpressures (or stalls) socket reads.
    private var framesContinuation: AsyncStream<Data>.Continuation?

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
        framesContinuation?.finish()
        framesContinuation = nil
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

    /// Two decoupled tasks: a **reader** that drains the socket as fast as bytes
    /// arrive (only ever buffering + emitting frames — never awaiting downstream
    /// work), and a **consumer** that decodes + dispatches frames at its own
    /// pace. Decoupling matters for bulk transfers (e.g. streamed media): if
    /// decode/dispatch is even slightly slower than the network, an inline loop
    /// backpressures the socket and the sender stalls — which is exactly why a
    /// large file used to die after the first chunk.
    private func startReceiveLoop(_ connection: NWConnection) {
        let (frameStream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        framesContinuation = cont
        let serverID = self.serverID

        // Consumer: decode + dispatch at its own pace (actor-isolated).
        Task { [weak self] in
            for await frame in frameStream {
                await self?.dispatch(frame, serverID: serverID)
            }
        }

        // Reader: a *pure* socket drain — a LOCAL frame buffer + the Sendable
        // stream continuation, touching neither the actor nor downstream work.
        // This is the crucial bit: an earlier version routed each chunk through
        // an actor method, which serialized with the consumer and let the TCP
        // window fill (sender stalled after ~1 chunk on a fast link). Reading on
        // its own keeps the window open so bulk transfers stream at full speed.
        readerTask = Task {
            var buffer = LineFrameBuffer()
            defer { cont.finish() }
            while !Task.isCancelled {
                let result: (data: Data, done: Bool)
                do {
                    result = try await Self.receive(on: connection)
                } catch {
                    cont.yield(Self.errorFrame(error))
                    break
                }
                if !result.data.isEmpty {
                    for frame in buffer.append(result.data) { cont.yield(frame) }
                }
                if result.done { break }   // genuine EOF (isComplete) — NOT a spurious empty read
            }
        }
    }

    /// Sentinel frame the reader emits on a transport error, decoded by the
    /// consumer into a `.serverError` event (so the reader never has to await
    /// the actor).
    private static let errorFramePrefix = "\u{0}GKERR\u{0}"
    private static func errorFrame(_ error: Error) -> Data {
        Data((errorFramePrefix + error.localizedDescription).utf8)
    }

    /// Decode one frame and dispatch its event downstream.
    private func dispatch(_ frame: Data, serverID: UUID) async {
        // Reader-injected transport error sentinel.
        let prefix = Data(Self.errorFramePrefix.utf8)
        if frame.starts(with: prefix) {
            let msg = String(decoding: frame.dropFirst(prefix.count), as: UTF8.self)
            await eventHandler?(.error(.transportError(msg)), serverID)
            return
        }
        guard let message = try? LineFramedJSONCodec.decode(frame) else { return }
        if case .event(let event) = message.payload {
            await eventHandler?(event, serverID)
        }
        // Responses aren't delivered via the event handler; the protocol uses
        // events for streaming + caps/usage delivery.
    }

    /// One-shot bridge from NWConnection's callback API to async. Returns the
    /// received bytes plus whether the stream is complete; only `done == true`
    /// means EOF (a zero-byte, non-complete callback must NOT end the loop).
    private static func receive(on connection: NWConnection) async throws -> (data: Data, done: Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(data: Data, done: Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }
}
