import Foundation
import GrokestratorCore

/// The Grok Build integration layer for the Mac hybrid app.
///
/// This is the main entry point the rest of the Mac app (and the Grokestrator server role)
/// will use to manage and communicate with Grok Build instances.
public actor GrokBuildServer {
    private let launcher = GrokBuildInstanceLauncher()
    private var clients: [UUID: GrokBuildSessionClient] = [:]
    private var instances: [UUID: ManagedInstance] = [:]

    public init() {}

    /// Starts a ManagedInstance and returns a client ready for communication.
    public func startInstance(_ config: ManagedInstance) async throws -> GrokBuildSessionClient {
        let handle = try await launcher.launch(config)

        let client = GrokBuildSessionClient(handle: handle)
        clients[config.id] = client
        instances[config.id] = config

        // TODO: Update ServerState with the new running instance
        return client
    }

    public func stopInstance(id: UUID) async {
        await launcher.terminate(id)
        clients.removeValue(forKey: id)
        instances.removeValue(forKey: id)
    }

    public func getClient(for id: UUID) -> GrokBuildSessionClient? {
        clients[id]
    }

    public func listRunningInstances() -> [ManagedInstance] {
        Array(instances.values)
    }
}
