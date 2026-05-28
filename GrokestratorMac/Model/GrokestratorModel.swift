import Foundation
import Observation
import GrokestratorCore

// `InstanceItem` moved to GrokestratorShared/Model/InstanceItem.swift so iOS
// can use the same type.

/// A sidebar grouping — "This Mac" first, then each remote server with its
/// instances. The view layer reads these and renders one `Section` per group.
struct SidebarServerGroup: Identifiable, Sendable {
    let id: UUID
    let title: String
    let isRemote: Bool
    let isConnected: Bool
    let instances: [InstanceItem]
}

/// Root application state for the Mac app.
///
/// Owns the local instance list, the remote-server links, the local-server
/// listener (for serving other Grokestrator clients over Tailscale), and the
/// current selection.
@MainActor
@Observable
final class GrokestratorModel {
    /// Local + remote instances (mixed). Use `sidebarGroups` to partition.
    var instances: [InstanceItem]
    var selectedInstanceID: InstanceItem.ID?

    /// Persistent registry of every local Connection — active *and* archived.
    /// Source of truth for the local Mac (GKSS); the `instances` array is the
    /// UI projection of the non-archived entries here. Loaded from
    /// `connections.json` on boot, saved on every mutation.
    var connections: [ManagedConnection]

    /// The local Grok Build black box (drives instances running on *this* Mac).
    let manager = GrokBuildManager()

    /// Listener that lets other Grokestrator clients drive `manager`'s instances
    /// over Tailscale. Off by default; enabled from Settings.
    let server: MacGrokestratorServer

    /// Persistent remote-server configs + their live connection state.
    var remoteLinks: [RemoteServerLink]

    // MARK: - Server settings (mirrored to UserDefaults)

    private static let serverEnabledKey = "grokestrator.server.enabled.v1"
    private static let serverPortKey = "grokestrator.server.port.v1"

    var serverEnabled: Bool {
        didSet {
            UserDefaults.standard.set(serverEnabled, forKey: Self.serverEnabledKey)
            applyServerToggle()
        }
    }
    var serverPort: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(serverPort), forKey: Self.serverPortKey)
            if serverEnabled { applyServerToggle() }
        }
    }

    init(instances: [InstanceItem] = [], connections: [ManagedConnection] = []) {
        self.instances = instances
        self.connections = connections
        self.selectedInstanceID = instances.first?.id
        self.server = MacGrokestratorServer(manager: manager)
        let remoteConfigs = RemoteServerStore.load()
        self.remoteLinks = remoteConfigs.map { RemoteServerLink(config: $0) }
        self.serverEnabled = UserDefaults.standard.bool(forKey: Self.serverEnabledKey)
        let storedPort = UserDefaults.standard.integer(forKey: Self.serverPortKey)
        self.serverPort = storedPort == 0 ? 7847 : UInt16(storedPort)
        // Start listener immediately if the user had it enabled last run; also
        // kick off auto-connect for any saved remote servers.
        if serverEnabled { applyServerToggle() }
        for link in remoteLinks { Task { await self.connectAndAttach(link) } }
    }

    /// Default app state: load the persisted Connection registry and build UI
    /// items for the non-archived entries. Connections with `autoRestart == true`
    /// are launched in the background. First run shows an empty sidebar; the
    /// "+" button creates the first real Connection.
    convenience init() {
        // Drop any legacy mock entries from an older build's first-run seed
        // (`command == "/mock/grok"`). MockConversationDriver is gone; trying
        // to launch a fake binary would just fail.
        let registry = ConnectionStore.load().filter { $0.command != "/mock/grok" }
        // If we removed something, rewrite so we don't keep filtering forever.
        if registry.count != ConnectionStore.load().count {
            ConnectionStore.save(registry)
        }

        let seededInstances: [InstanceItem] = registry
            .filter { !$0.archived }
            .map { conn in
                InstanceItem(
                    id: conn.id, name: conn.name, status: .stopped,
                    driver: LiveConversationDriver(manager: GrokBuildManager(), instanceID: conn.id)   // re-bound below
                )
            }
        self.init(instances: seededInstances, connections: registry)

        // Re-bind LiveConversationDrivers to the actual manager (the items
        // above used a throwaway manager because `self` wasn't ready yet).
        for (idx, item) in instances.enumerated() {
            instances[idx] = InstanceItem(
                id: item.id, name: item.name, status: .stopped,
                driver: LiveConversationDriver(manager: manager, instanceID: item.id)
            )
        }
        if selectedInstanceID == nil { selectedInstanceID = instances.first?.id }

        // Auto-launch every non-archived Connection with autoRestart == true.
        for conn in registry where !conn.archived && conn.autoRestart {
            Task { [weak self] in await self?.launchConnection(conn) }
        }
    }

    var selectedInstance: InstanceItem? {
        guard let id = selectedInstanceID else { return nil }
        return instances.first { $0.id == id }
    }

    /// Sidebar grouping: "This Mac" with all local instances, then one section
    /// per remote server with its instances.
    var sidebarGroups: [SidebarServerGroup] {
        let localGroup = SidebarServerGroup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "This Mac",
            isRemote: false,
            isConnected: true,
            instances: instances.filter { $0.serverID == nil }
        )
        let remoteGroups = remoteLinks.map { link in
            SidebarServerGroup(
                id: link.id,
                title: link.config.name,
                isRemote: true,
                isConnected: link.state == .connected,
                instances: instances.filter { $0.serverID == link.id }
            )
        }
        return [localGroup] + remoteGroups
    }

    // MARK: - Local Connections

    func addRealConnection(name: String, command: String, arguments: [String], workingDirectory: String?,
                           autoRestart: Bool = true, shared: Bool = true) {
        let config = ManagedConnection(
            name: name,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            autoRestart: autoRestart,
            shared: shared
        )
        connections.append(config)
        ConnectionStore.save(connections)

        let item = InstanceItem(
            id: config.id,
            name: name,
            status: .starting,
            driver: LiveConversationDriver(manager: manager, instanceID: config.id)
        )
        instances.append(item)
        selectedInstanceID = item.id

        Task { [weak self] in await self?.launchConnection(config, startingItem: item) }
    }

    /// Launches a Connection's grok process and reflects status on its UI item.
    /// Shared launch path used both by `addRealConnection` and the boot-time
    /// auto-restart pass.
    private func launchConnection(_ config: ManagedConnection, startingItem: InstanceItem? = nil) async {
        let item = startingItem ?? instances.first(where: { $0.id == config.id })
        item?.status = .starting
        do {
            let updated = try await manager.startInstance(config)
            item?.status = updated.status
            await server.broadcastInstancesIfChanged()
        } catch {
            item?.status = .errored
            item?.conversation.appendSystem("Failed to launch: \(error.localizedDescription)", isError: true)
        }
    }

    /// Stops a real local instance, or disconnects/removes a remote link's
    /// session for a remote-tagged item (the underlying remote process is
    /// the remote Mac's concern).
    func stop(_ item: InstanceItem) {
        item.status = .stopping
        let server = self.server
        Task {
            if item.serverID == nil {
                await manager.stopInstance(id: item.id)
                await server.broadcastInstancesIfChanged()
            }
            item.status = .stopped
        }
    }

    // MARK: - Archive / Restore / Delete Permanently

    /// Connections currently in the archived state (hidden from sidebar + remote).
    var archivedConnections: [ManagedConnection] {
        connections.filter { $0.archived }
    }

    /// Archive a local Connection: stop its process if running, hide it from the
    /// main sidebar and from every remote GKSC. Reversible via `restore`.
    func archive(_ item: InstanceItem) {
        guard let idx = connections.firstIndex(where: { $0.id == item.id }) else { return }
        let server = self.server
        Task {
            await manager.stopInstance(id: item.id)
            await server.broadcastInstancesIfChanged()
        }
        connections[idx].archived = true
        ConnectionStore.save(connections)
        instances.removeAll { $0.id == item.id }
        if selectedInstanceID == item.id { selectedInstanceID = instances.first?.id }
    }

    /// Restore an archived Connection — bring it back into the main sidebar in a
    /// stopped state. We do NOT auto-launch even if `autoRestart` is true;
    /// the user launches manually, or the next GKSS boot honors the flag.
    func restore(_ connection: ManagedConnection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx].archived = false
        ConnectionStore.save(connections)
        let item = InstanceItem(
            id: connection.id, name: connection.name, status: .stopped,
            driver: LiveConversationDriver(manager: manager, instanceID: connection.id)
        )
        instances.append(item)
    }

    /// Permanently delete an archived Connection — drops config and history dir.
    /// Caller (the UI) is responsible for the destructive confirmation.
    func deletePermanently(_ connection: ManagedConnection) {
        connections.removeAll { $0.id == connection.id }
        ConnectionStore.save(connections)
        ConnectionStore.deleteHistoryDirectory(for: connection.id)
    }

    // MARK: - Remote servers

    /// Saves a new remote server, connects to it, and adds any returned
    /// instances to the sidebar.
    func addRemoteServer(name: String, host: String, port: UInt16) {
        let config = RemoteServerConfig(name: name, host: host, port: port)
        var saved = RemoteServerStore.load()
        saved.append(config)
        RemoteServerStore.save(saved)

        let link = RemoteServerLink(config: config)
        remoteLinks.append(link)
        Task { await connectAndAttach(link) }
    }

    /// Removes a remote server: disconnects, drops its instances, persists.
    func removeRemoteServer(_ link: RemoteServerLink) {
        Task { await link.disconnect() }
        instances.removeAll { $0.serverID == link.id }
        remoteLinks.removeAll { $0.id == link.id }
        let saved = RemoteServerStore.load().filter { $0.id != link.id }
        RemoteServerStore.save(saved)
    }

    /// Connect to a link and mirror its instances into the sidebar's mixed list.
    private func connectAndAttach(_ link: RemoteServerLink) async {
        await link.connect()
        // Observe its `instances` array on the MainActor by polling once after
        // connect (the link mutates it via @Observable; here we eagerly create
        // matching InstanceItems for what came back so the UI populates fast).
        // The link continues to update `instances` as events arrive; we'll
        // refresh by re-syncing on a small repeat for v1.
        await syncRemoteInstances(for: link)
    }

    /// One-shot sync — for v1. Future: an AsyncStream from the link.
    private func syncRemoteInstances(for link: RemoteServerLink) async {
        // Re-run the sync periodically until disconnected.
        while !Task.isCancelled, link.state == .connected || link.state == .connecting {
            await reconcileInstanceItems(link: link)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Bring the sidebar's `instances` in sync with `link.instances`: add new,
    /// remove gone; each remote item gets its own `RemoteConversationDriver`.
    private func reconcileInstanceItems(link: RemoteServerLink) async {
        let serverID = link.id
        let remote = link.instances
        // Remove items for this server that no longer exist remotely.
        instances.removeAll { item in
            item.serverID == serverID && !remote.contains(where: { $0.id == item.id })
        }
        // Add items for new remote instances.
        for inst in remote where !instances.contains(where: { $0.id == inst.id }) {
            guard let driver = await link.driver(for: inst.id) else { continue }
            let item = InstanceItem(id: inst.id, name: inst.name, status: inst.status,
                                    driver: driver, serverID: serverID)
            instances.append(item)
        }
    }

    // MARK: - Local listener

    private func applyServerToggle() {
        let server = self.server
        let port = self.serverPort
        let enabled = self.serverEnabled
        Task {
            if enabled {
                try? await server.start(port: port)
            } else {
                await server.stop()
            }
        }
    }

    // MARK: - App-quit cleanup

    /// Single entry point for clean shutdown. Stops the local listener (releases
    /// the port), disconnects every remote link, and terminates every running
    /// grok child process this Mac launched (SIGTERM → wait → SIGKILL survivors).
    /// Called from `AppDelegate.applicationWillTerminate` under a bounded
    /// semaphore so the OS doesn't yank us before we finish.
    func shutdownAll(timeout: TimeInterval = 1.0) async {
        await server.stop()
        for link in remoteLinks { await link.disconnect() }
        await manager.terminateAll(timeout: timeout)
    }
}
