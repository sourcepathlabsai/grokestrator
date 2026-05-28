import Foundation
import Observation
import GrokestratorCore

/// User-configured remote Grokestrator server (Tailscale-reachable). Persisted
/// across launches via `RemoteServerStore`.
public struct RemoteServerConfig: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: UInt16

    public init(id: UUID = UUID(), name: String, host: String, port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
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
public final class RemoteServerLink: @preconcurrency Identifiable {
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

    private let client: GrokestratorClient
    private let transport: NetworkGrokestratorTransport
    private var serverSession: MultiServerSession?
    private var eventLoopTask: Task<Void, Never>?

    public init(config: RemoteServerConfig) {
        self.config = config
        self.client = GrokestratorClient()
        self.transport = NetworkGrokestratorTransport(host: config.host, port: config.port, serverID: config.id)
    }

    /// Opens the TCP connection, registers the transport, and asks for the
    /// initial instance list.
    public func connect() async {
        guard state != .connected, state != .connecting else { return }
        state = .connecting
        let address = ServerAddress(name: config.name, tailscaleAddress: config.host, port: Int(config.port))
        let session = await client.addServer(address, displayName: config.name, transport: transport)
        serverSession = session

        do {
            try await transport.connect()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        await client.connect(to: session.id)
        startEventLoop()
        state = .connected
        // Ask for the instance list right away so the sidebar can populate.
        try? await transport.send(.listInstances, serverID: session.id)
    }

    public func disconnect() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        await transport.disconnect()
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
    private func startEventLoop() {
        // Re-route the transport handler to also catch link-level events
        // (instancesUpdated, instanceStatusChanged, etc.). grokBuild events are
        // forwarded into the parent client so they reach the GrokBuildClientSession.
        let configID = config.id
        let transport = self.transport
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
