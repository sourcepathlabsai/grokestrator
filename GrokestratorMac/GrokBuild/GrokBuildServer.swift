import Foundation
import GrokestratorCore

/// The Grok Build integration layer for the Mac hybrid app.
///
/// `GrokBuildServer` owns the low-level launchers and clients.
/// Higher-level code should usually go through `GrokBuildManager` instead.
public actor GrokBuildServer {
    let launcher = GrokBuildInstanceLauncher()
    // Holds whichever brain backs a Node (`any AgentSession`) — grok over ACP/stdio,
    // or a model-agnostic backend (OpenAI-compatible, …). See design/12.
    private var clients: [UUID: any AgentSession] = [:]
    private var instances: [UUID: ManagedInstance] = [:]

    public init() {}

    /// Starts a ManagedInstance and returns its brain (an `AgentSession`) ready for
    /// communication, plus an updated `ManagedInstance` with running status. The
    /// brain is chosen by `config.brain`: `.grokACP` launches a grok process;
    /// `.openAICompatible` opens an in-process API session (no child process).
    public func startInstance(_ config: ManagedInstance) async throws -> (any AgentSession, ManagedInstance) {
        let session: any AgentSession
        // Resolve the concrete backend through the host tier map: a pinned binding is
        // its own backend; a dynamic one resolves its default tier (per-task routing
        // is Phase D). Read fresh so tier-map edits apply on the next (re)start.
        let backend = ConnectionStore.loadTierMap().backend(for: config.brain)
        switch backend {
        case .grokACP:
            let handle = try await launcher.launch(config)
            session = GrokBuildSessionClient(handle: handle)
        case .openAICompatible(let baseURL, let model, let apiKeyRef):
            // Secrets are referenced by name, never stored inline. Resolved from the
            // process env or the host-local gitignored .env.local_llm (LM Studio needs none).
            let key = apiKeyRef.flatMap { Secrets.value(for: $0) }
            session = OpenAICompatSession(instanceID: config.id, baseURL: baseURL,
                                          model: model, apiKey: key, cwd: config.workingDirectory,
                                          policy: config.toolPolicy)
        case .gemini, .onboard:
            throw GrokBuildError.instanceManagementError("backend not implemented yet for \(config.name)")
        }
        clients[config.id] = session

        var updated = config
        updated.status = .running
        updated.lastStartedAt = Date()
        instances[config.id] = updated

        return (session, updated)
    }

    public func stopInstance(id: UUID) async {
        await launcher.terminate(id)
        clients.removeValue(forKey: id)
        if var inst = instances[id] {
            inst.status = .stopped
            instances[id] = inst
        }
    }

    /// Terminates every running instance. Called from app-quit cleanup.
    public func stopAll(timeout: TimeInterval = 1.0) async {
        await launcher.terminateAll(timeout: timeout)
        clients.removeAll()
        for (id, var inst) in instances {
            inst.status = .stopped
            instances[id] = inst
        }
    }

    public func getClient(for id: UUID) -> (any AgentSession)? {
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
