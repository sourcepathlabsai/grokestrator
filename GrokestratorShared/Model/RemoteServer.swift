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
    public private(set) var instances: [ManagedInstance] = []
    /// Which address actually connected ("LAN" or "Tailscale"), for the UI.
    public private(set) var activePath: String?

    private let client: GrokestratorClient
    private var transport: NetworkGrokestratorTransport?
    private var serverSession: MultiServerSession?
    private var eventLoopTask: Task<Void, Never>?

    public init(config: RemoteServerConfig) {
        self.config = config
        self.client = GrokestratorClient()
    }

    /// Connects, preferring the LAN address (fast, full-MTU) and falling back to
    /// Tailscale (works anywhere). Tries each candidate with a timeout so an
    /// unreachable LAN IP fails over quickly instead of hanging.
    public func connect() async {
        guard state != .connected, state != .connecting else { return }
        state = .connecting

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
            let address = ServerAddress(name: config.name, tailscaleAddress: cand.host, port: Int(config.port))
            let session = await client.addServer(address, displayName: config.name, transport: t)
            serverSession = session
            await client.connect(to: session.id)
            startEventLoop(transport: t)
            state = .connected
            try? await t.send(.listInstances, serverID: session.id)
            return
        }

        state = .failed("Couldn't reach \(config.name) on the LAN or over Tailscale")
    }

    public func disconnect() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        await transport?.disconnect()
        transport = nil
        activePath = nil
        state = .disconnected
        instances = []
    }

    /// Returns a `ConversationDriver` for a specific remote instance — the same
    /// seam the local UI uses, so `ConversationView` / `InstanceInspectorView`
    /// don't care whether they're driving local or remote.
    public func driver(for instanceID: UUID) async -> RemoteConversationDriver? {
        guard let session = serverSession else { return nil }
        let buildSession = await client.grokBuildSession(for: instanceID, on: session)
        return RemoteConversationDriver(session: buildSession)
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
        await MainActor.run { self.applyEvent(event) }
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
        case .error(let err):
            state = .failed(err.errorDescription ?? "error")
        default:
            break
        }
    }
}
