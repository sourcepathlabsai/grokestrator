import Foundation
import Observation
import GrokestratorCore

/// Client-only app model for the iOS Grokestrator.
///
/// Mirrors the *remote half* of the Mac's `GrokestratorModel`: a list of
/// persisted `RemoteServerConfig`s, one live `RemoteServerLink` per server,
/// and a derived `instances: [InstanceItem]` array that the UI binds to.
/// **No local launching, no listener** — iOS is purely a GKSC.
@MainActor
@Observable
final class iOSAppModel {
    var instances: [InstanceItem] = []
    var selectedInstanceID: UUID?
    private(set) var remoteLinks: [RemoteServerLink]
    /// One retry-loop task per link, so `removeRemoteServer` can cancel it.
    private var attachTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        let configs = RemoteServerStore.load()
        self.remoteLinks = configs.map { RemoteServerLink(config: $0) }
        // Auto-connect on launch so the user opens the app to a populated sidebar.
        for link in remoteLinks { attachTasks[link.id] = Task { await self.attach(link) } }
    }

    /// Saves a new remote server and connects to it.
    func addRemoteServer(name: String, host: String, localHost: String? = nil, port: UInt16) {
        let config = RemoteServerConfig(name: name, host: host, localHost: localHost, port: port)
        var saved = RemoteServerStore.load()
        saved.append(config)
        RemoteServerStore.save(saved)

        let link = RemoteServerLink(config: config)
        remoteLinks.append(link)
        attachTasks[link.id] = Task { await attach(link) }
    }

    /// Drops a remote server — cancel its retry loop, disconnect, remove its
    /// instances, persist.
    func removeRemoteServer(_ link: RemoteServerLink) {
        attachTasks[link.id]?.cancel()
        attachTasks[link.id] = nil
        Task { await link.disconnect() }
        instances.removeAll { $0.serverID == link.id }
        remoteLinks.removeAll { $0.id == link.id }
        let saved = RemoteServerStore.load().filter { $0.id != link.id }
        RemoteServerStore.save(saved)
    }

    // MARK: - Private

    /// Connect a link and reconcile its instances into the UI list. The link's
    /// `instances` array updates as `instancesUpdated` events arrive; we poll a
    /// few times to catch the initial population fast, then settle into a
    /// periodic refresh (matching the Mac behavior — small follow-up to replace
    /// with an AsyncStream from the link).
    private func attach(_ link: RemoteServerLink) async {
        // Retry loop: keep (re)connecting until this link is removed (task
        // cancelled). Without the outer loop, a link that failed once — e.g.
        // added while the Mac's server was still off — would strand forever on
        // "Failed"/"Connecting" even after the server came up.
        while !Task.isCancelled {
            await link.connect()
            while !Task.isCancelled, link.state == .connected || link.state == .connecting {
                reconcile(link: link)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if Task.isCancelled { break }
            // Dropped or failed — back off, then try again.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func reconcile(link: RemoteServerLink) {
        let serverID = link.id
        let remote = link.instances
        instances.removeAll { item in
            item.serverID == serverID && !remote.contains(where: { $0.id == item.id })
        }
        for inst in remote where !instances.contains(where: { $0.id == inst.id }) {
            // Pull a driver for this remote instance from its link.
            Task { @MainActor [weak self] in
                guard let self, let driver = await link.driver(for: inst.id) else { return }
                let item = InstanceItem(id: inst.id, name: inst.name, status: inst.status,
                                        driver: driver, serverID: serverID)
                self.instances.append(item)
            }
        }
    }
}
