import Foundation
import Observation
import GrokestratorCore

/// User-configured remote Grokestrator server (Tailscale-reachable). Persisted
/// across launches via `RemoteServerStore`.
public struct RemoteServerConfig: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Tailscale name/IP — reachable from anywhere, but lower throughput
    /// (WireGuard + ~1280 MTU).
    public var host: String
    /// Optional LAN IP (e.g. 192.168.x.x). Tried first when set: a direct
    /// same-Wi-Fi connection is much faster (full MTU, no tunnel) — important
    /// for large media. Falls back to `host` when unreachable (you're away).
    public var localHost: String?
    public var port: UInt16

    public init(id: UUID = UUID(), name: String, host: String, localHost: String? = nil, port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.localHost = localHost
        self.port = port
    }
}

struct ConnectTimeoutError: Error {}

/// Runs `op`, throwing `ConnectTimeoutError` if it doesn't finish in `seconds`.
func withConnectTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ConnectTimeoutError()
        }
        guard let result = try await group.next() else { throw ConnectTimeoutError() }
        group.cancelAll()
        return result
    }
}

/// Persists the user's list of remote servers in UserDefaults (sufficient for
/// MVP; can migrate to App Support JSON later).
@MainActor
public final class RemoteServerStore {
    private static let key = "grokestrator.remoteServers.v1"

    public static func load() -> [RemoteServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RemoteServerConfig].self, from: data)
        else { return [] }
        return list
    }

    public static func save(_ list: [RemoteServerConfig]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// A live connection to one remote server. Owns the transport + the
/// `GrokestratorClient` session for that server; exposes the current instance
/// list (kept in sync via `instancesUpdated` events) and creates
/// `RemoteConversationDriver`s for each remote instance on demand.
@MainActor
@Observable
public final class RemoteServerLink: Identifiable {
    public enum LinkState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public let config: RemoteServerConfig
    nonisolated public var id: UUID { config.id }
    public private(set) var state: LinkState = .disconnected
    /// Bumped on every successful (re)connect. The model watches this to rebuild
    /// the server's Connection items against the fresh session after a reconnect
    /// (the old drivers point at an invalidated session).
    public private(set) var generation: Int = 0
    public private(set) var instances: [ManagedInstance] = []
    /// Which address actually connected ("LAN" or "Tailscale"), for the UI.
    public private(set) var activePath: String?
    /// The actual host (IP/MagicDNS) that connected — used to address the
    /// host's media HTTP server.
    public private(set) var activeHostName: String?

    private let client: GrokestratorClient
    private var transport: NetworkGrokestratorTransport?
    private var serverSession: MultiServerSession?
    private var eventLoopTask: Task<Void, Never>?
    /// True while a `connect()` attempt is in flight. Tracked separately from
    /// `state` so an interrupted attempt can't wedge the link in `.connecting`
    /// forever — which previously blocked every retry and left a server that
    /// couldn't be reconnected (and was hard to delete).
    private var isConnecting = false

    public init(config: RemoteServerConfig) {
        self.config = config
        self.client = GrokestratorClient()
    }

    /// Connects, preferring the LAN address (fast, full-MTU) and falling back to
    /// Tailscale (works anywhere). Tries each candidate with a timeout so an
    /// unreachable LAN IP fails over quickly instead of hanging.
    public func connect() async {
        guard state != .connected, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        state = .connecting

        // Tear down any transport left over from a previous (dropped) connection
        // before opening a new one — otherwise the old NWConnection lingers in
        // CLOSE_WAIT and connections pile up across auto-reconnects.
        if let old = transport { await old.disconnect(); transport = nil }

        // (host, timeout, label) — LAN first if configured, then Tailscale.
        var candidates: [(host: String, timeout: Double, label: String)] = []
        if let lan = config.localHost?.trimmingCharacters(in: .whitespaces), !lan.isEmpty, lan != config.host {
            candidates.append((lan, 3, "LAN"))
        }
        candidates.append((config.host, 12, "Tailscale"))

        for cand in candidates {
            let t = NetworkGrokestratorTransport(host: cand.host, port: config.port, serverID: config.id)
            do {
                try await withConnectTimeout(seconds: cand.timeout) { try await t.connect() }
            } catch {
                await t.disconnect()
                continue   // try the next candidate
            }

            transport = t
            activePath = cand.label
            activeHostName = cand.host
            let address = ServerAddress(name: config.name, tailscaleAddress: cand.host, port: Int(config.port))
            let session = await client.addServer(address, displayName: config.name, transport: t)
            serverSession = session
            await client.connect(to: session.id)
            startEventLoop(transport: t)
            generation += 1
            state = .connected
            try? await t.send(.listInstances, serverID: session.id)
            return
        }

        state = .failed("Couldn't reach \(config.name) on the LAN or over Tailscale")
    }

    /// The connection dropped (server quit / network died). Marks the link failed
    /// and invalidates the underlying grok-build sessions so every Connection's
    /// subscription receives a terminal `.error` — which clears the stuck "working"
    /// spinner and shows a "lost connection" note. We deliberately KEEP `instances`
    /// so the sidebar can still list the sessions (greyed/red) under the failed
    /// server; a manual reconnect restores them. Idempotent.
    private func handleDropped(_ reason: String) async {
        guard state == .connected || state == .connecting else { return }
        state = .failed(reason)
        eventLoopTask?.cancel(); eventLoopTask = nil
        // Invalidate sessions first (emits `.error` to conversation subscribers),
        // then tear down the socket so a later reconnect starts clean.
        if let session = serverSession {
            await client.disconnect(from: session.id, reason: reason)
        }
        await transport?.disconnect(); transport = nil
        activePath = nil
        activeHostName = nil
    }

    public func disconnect() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        await transport?.disconnect()
        transport = nil
        activePath = nil
        activeHostName = nil
        state = .disconnected
        instances = []
    }

    /// Returns a `ConversationDriver` for a specific remote instance — the same
    /// seam the local UI uses, so `ConversationView` / `InstanceInspectorView`
    /// don't care whether they're driving local or remote.
    public func driver(for instanceID: UUID) async -> RemoteConversationDriver? {
        guard let session = serverSession else { return nil }
        let buildSession = await client.grokBuildSession(for: instanceID, on: session)
        // Media HTTP server runs on control port + 1, on whichever host connected.
        let host = activeHostName ?? config.host
        let mediaBase = URL(string: "http://\(host):\(config.port &+ 1)")
        return RemoteConversationDriver(session: buildSession, mediaBaseURL: mediaBase)
    }

    // MARK: - Private

    /// Watches the underlying transport's events. The transport delivers them
    /// via `setEventHandler`, but we don't have a stream-shaped read — so we
    /// route via the client's `handleIncoming` and listen for its own event
    /// stream too (for connection lifecycle). For inbound `instancesUpdated`
    /// we hook into the transport handler directly via `client.connect`'s wiring.
    private func startEventLoop(transport: NetworkGrokestratorTransport) {
        // Re-route the transport handler to also catch link-level events
        // (instancesUpdated, instanceStatusChanged, etc.). grokBuild events are
        // forwarded into the parent client so they reach the GrokBuildClientSession.
        let configID = config.id
        let client = self.client
        eventLoopTask = Task {
            await transport.setEventHandler { [weak self] event, _ in
                if case .grokBuild = event {
                    await client.handleIncoming(event: event, from: configID)
                } else {
                    await self?.handleLinkEvent(event)
                }
            }
        }
    }

    /// MainActor handler for link-level events (everything that isn't grokBuild,
    /// which the parent client routes directly to a GrokBuildClientSession).
    private func handleLinkEvent(_ event: GrokestratorEvent) async {
        // A transport `.error` means the connection dropped (EOF or socket error);
        // route it through the full drop handler so sessions are invalidated and
        // spinners clear — not just a state flip.
        if case .error = event {
            await handleDropped("Lost connection to \(config.name)")
            return
        }
        applyEvent(event)
    }

    private func applyEvent(_ event: GrokestratorEvent) {
        switch event {
        case .instancesUpdated(let list):
            instances = list
        case .instanceStatusChanged(let inst):
            if let idx = instances.firstIndex(where: { $0.id == inst.id }) {
                instances[idx] = inst
            } else {
                instances.append(inst)
            }
        default:
            break
        }
    }
}
