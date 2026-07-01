import Foundation

/// How Grokestrator coordinates helpers for a Node's brain binding.
/// See `design/10` §direction, `design/12` §ACP vs API.
public enum OrchestrationMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// ACP harness (`task` / native subagents). Grokestrator supervises the parent only.
    case supervisedAgent
    /// API/local brain. Grokestrator orchestrates via `delegate` + child Connections.
    case orchestratedFleet
}

public enum OrchestrationSupport {
    /// Whether a resolved backend is an ACP agent (harness owns coordination).
    public static func isACPBackend(_ backend: AgentBackend) -> Bool {
        switch backend {
        case .grokACP, .acpStdio: return true
        case .openAICompatible, .gemini, .onboard: return false
        }
    }

    /// Derive orchestration mode from a Node's brain binding.
    public static func mode(
        for brain: BrainBinding,
        catalog: BrainCatalog,
        tierMap: HostTierMap
    ) -> OrchestrationMode {
        let backend = tierMap.backend(for: brain, catalog: catalog)
        return isACPBackend(backend) ? .supervisedAgent : .orchestratedFleet
    }

    public static func supportsFleetOrchestration(
        brain: BrainBinding,
        catalog: BrainCatalog,
        tierMap: HostTierMap
    ) -> Bool {
        mode(for: brain, catalog: catalog, tierMap: tierMap) == .orchestratedFleet
    }
}

extension ToolPolicy {
    /// Default for a fleet orchestrator: coordinate only via `delegate`.
    public static let fleetOrchestratorDefault = ToolPolicy(capability: .readOnly, allowed: ["delegate"])
}