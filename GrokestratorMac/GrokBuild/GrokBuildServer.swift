import Foundation
import GrokestratorCore

/// The Grok Build integration layer for the Mac hybrid app.
///
/// `GrokBuildServer` owns the low-level launchers and clients.
/// Higher-level code should usually go through `GrokBuildManager` instead.
public actor GrokBuildServer {
    let launcher = GrokBuildInstanceLauncher()
    private var clients: [UUID: GrokBuildSessionClient] = [:]
    private var instances: [UUID: ManagedInstance] = [:]

    public init() {}

    /// Starts a ManagedInstance and returns a client ready for communication.
    /// Also returns an updated `ManagedInstance` with running status.
    public func startInstance(_ config: ManagedInstance) async throws -> (GrokBuildSessionClient, ManagedInstance) {
        let handle = try await launcher.launch(config)

        let client = GrokBuildSessionClient(handle: handle)
        clients[config.id] = client

        var updated = config
        updated.status = .running
        updated.lastStartedAt = Date()
        instances[config.id] = updated

        return (client, updated)
    }

    public func stopInstance(id: UUID) async {
        await launcher.terminate(id)
        clients.removeValue(forKey: id)
        if var inst = instances[id] {
            inst.status = .stopped
            instances[id] = inst
        }
    }

    public func getClient(for id: UUID) -> GrokBuildSessionClient? {
        clients[id]
    }

    public func listRunningInstances() -> [ManagedInstance] {
        Array(instances.values)
    }

    /// Allows external observers (e.g. GrokBuildManager) to receive updated instance state.
    public func currentInstanceState(for id: UUID) -> ManagedInstance? {
        instances[id]
    }

    private var deathHandlers: [UUID: @Sendable (UUID, Int32) -> Void] = [:]

    /// Register a handler for when a specific instance's process dies.
    public func onInstanceDied(id: UUID, handler: @escaping @Sendable (UUID, Int32) -> Void) async {
        deathHandlers[id] = handler
        // Also register with the launcher
        await launcher.onInstanceDied(id: id, handler: handler)
    }
}
