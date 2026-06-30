import Foundation
import GrokestratorCore

extension GrokestratorModel {
    // MARK: - Dual-path orchestration (`design/10` §0)

    func orchestrationMode(for item: InstanceItem) -> OrchestrationMode {
        orchestrationMode(for: binding(for: item))
    }

    func orchestrationMode(for brain: BrainBinding) -> OrchestrationMode {
        OrchestrationSupport.mode(for: brain, catalog: brainCatalog, tierMap: hostTierMap)
    }

    func supportsFleetOrchestration(for item: InstanceItem) -> Bool {
        orchestrationMode(for: item) == .orchestratedFleet
    }

    func supportsFleetOrchestration(brain: BrainBinding) -> Bool {
        orchestrationMode(for: brain) == .orchestratedFleet
    }

    /// Fleet tree UI + `delegate` apply only to orchestrated-fleet orchestrators.
    func showsFleetTree(for item: InstanceItem) -> Bool {
        item.role == .orchestrator && supportsFleetOrchestration(for: item)
    }

    func isFleetOrchestrator(_ item: InstanceItem) -> Bool {
        showsFleetTree(for: item)
    }

    var localFleetOrchestrators: [InstanceItem] {
        instances.filter { $0.serverID == nil && showsFleetTree(for: $0) }
    }

    // MARK: - Legacy ACP fleet anti-pattern (#166)

    private static let dismissedLegacyKey = "grokestrator.dismissedLegacyACPOrch"

    var dismissedLegacyOrchestrationWarnings: Set<UUID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.dismissedLegacyKey) ?? []
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.dismissedLegacyKey)
        }
    }

    func legacyACPFleetOrchestratorIDs() -> [UUID] {
        connections.filter { conn in
            guard conn.role == .orchestrator, !conn.archived else { return false }
            let mode = OrchestrationSupport.mode(for: conn.brain, catalog: brainCatalog, tierMap: hostTierMap)
            guard mode == .supervisedAgent else { return false }
            return connections.contains { $0.parentID == conn.id && !$0.archived }
        }.map(\.id)
    }

    func shouldShowLegacyOrchestrationWarning(for item: InstanceItem) -> Bool {
        legacyACPFleetOrchestratorIDs().contains(item.id)
            && !dismissedLegacyOrchestrationWarnings.contains(item.id)
    }

    func dismissLegacyOrchestrationWarning(for item: InstanceItem) {
        dismissLegacyOrchestrationWarning(for: item.id)
    }

    func dismissLegacyOrchestrationWarning(for id: UUID) {
        var s = dismissedLegacyOrchestrationWarnings
        s.insert(id)
        dismissedLegacyOrchestrationWarnings = s
    }

    /// Flatten a legacy ACP orchestrator tree: parent → agent, children → roots.
    func flattenLegacyFleetTree(orchestratorID: UUID) {
        guard let orchIdx = connections.firstIndex(where: { $0.id == orchestratorID }) else { return }
        for idx in connections.indices where connections[idx].parentID == orchestratorID {
            connections[idx].parentID = nil
            if let item = instances.first(where: { $0.id == connections[idx].id }) {
                item.parentID = nil
                syncTreeMetadataToRemotes(id: item.id, role: item.role, parentID: nil)
            }
        }
        connections[orchIdx].role = .agent
        if let item = instances.first(where: { $0.id == orchestratorID }) {
            item.role = .agent
            syncTreeMetadataToRemotes(id: item.id, role: .agent, parentID: item.parentID)
        }
        ConnectionStore.save(connections)
        dismissLegacyOrchestrationWarning(for: orchestratorID)
    }

    func orchestrationModeLabel(for item: InstanceItem) -> String {
        switch orchestrationMode(for: item) {
        case .supervisedAgent: return "Supervised Agent"
        case .orchestratedFleet: return "Orchestrated Fleet"
        }
    }
}