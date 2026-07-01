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

    /// Fleet orchestrators that may parent `item` without creating a cycle (#136).
    func validParentCandidates(for item: InstanceItem) -> [InstanceItem] {
        guard item.serverID == nil, supportsFleetOrchestration(for: item) else { return [] }
        return localFleetOrchestrators.filter { cand in
            cand.id != item.id
                && !OrchestrationTree.wouldCreateCycle(child: item.id, candidateParent: cand.id, in: connections)
        }
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

    // MARK: - Orchestration MCP handlers (#135)

    func loadOrchestrationTriggersFromDisk() {
        orchestrationTriggers.load(ConnectionStore.loadOrchestrationTriggers())
    }

    func persistOrchestrationTriggers() {
        ConnectionStore.saveOrchestrationTriggers(orchestrationTriggers.snapshot())
    }

    func handleTaskReport(callerID: UUID?, status: String, result: String) -> String {
        guard let callerID else { return "task.report requires a fleet node identity." }
        orchestrationTriggers.recordReport(nodeID: callerID, status: status, result: result)
        delegationRuns.applyTaskReport(childID: callerID, status: status, result: result)
        let preview = result.count > 80 ? String(result.prefix(80)) + "…" : result
        return "Recorded \(status) report: \(preview)"
    }

    func handleNodeConfigure(callerID: UUID?, childName: String, policyJSON: String) async -> String {
        guard let callerID else { return "node.configure requires a fleet orchestrator identity." }
        guard let child = resolveDescendant(named: childName, under: callerID) else {
            return "No descendant named \"\(childName)\" under this orchestrator."
        }
        guard let data = policyJSON.data(using: .utf8),
              let policy = try? JSONDecoder().decode(ToolPolicy.self, from: data),
              let item = instances.first(where: { $0.id == child.id }) else {
            return "Invalid policy JSON for node.configure. Expected ToolPolicy: { capability, allowed? }."
        }
        setToolPolicy(policy, for: item)
        return "Updated tool policy for \"\(child.name)\" (capability=\(policy.capability.rawValue))."
    }

    func handleTriggerSchedule(callerID: UUID?, childName: String, when: String, task: String) -> String {
        guard let callerID else { return "trigger.schedule requires a fleet orchestrator identity." }
        guard resolveDescendant(named: childName, under: callerID) != nil else {
            return "No descendant named \"\(childName)\" under this orchestrator."
        }
        do {
            let trigger = try orchestrationTriggers.schedule(
                parentID: callerID, childName: childName, when: when, taskTemplate: task
            )
            persistOrchestrationTriggers()
            return "Scheduled \"\(childName)\" (\(trigger.id.uuidString.prefix(8))) when=\(trigger.cronSpec)."
        } catch {
            return error.localizedDescription
        }
    }

    func handleTriggerFire(callerID: UUID?, event: String, payload: String) async -> String {
        let matches = orchestrationTriggers.matchingEventTriggers(event: event, parentID: callerID)
        guard !matches.isEmpty else { return "No triggers matched event \"\(event)\"." }
        var fired = 0
        for trigger in matches {
            guard !childHasActiveDelegation(named: trigger.childName, under: trigger.parentID) else { continue }
            orchestrationTriggers.markFired(trigger.id)
            let prompt = assembleTriggerPrompt(template: trigger.taskTemplate, payload: payload)
            _ = await manager.delegate(
                callerID: trigger.parentID, toChildNamed: trigger.childName, task: prompt
            )
            fired += 1
        }
        persistOrchestrationTriggers()
        return fired == 0
            ? "Triggers matched but children are already running — skipped."
            : "Fired \(fired) trigger(s) for event \"\(event)\"."
    }

    /// Host-local interval scheduler tick (`trigger.schedule` with `every Nm/h/d`).
    func tickOrchestrationTriggers() async {
        let due = orchestrationTriggers.dueIntervalTriggers()
        guard !due.isEmpty else { return }
        for trigger in due {
            guard !childHasActiveDelegation(named: trigger.childName, under: trigger.parentID) else { continue }
            orchestrationTriggers.markFired(trigger.id)
            _ = await manager.delegate(
                callerID: trigger.parentID, toChildNamed: trigger.childName, task: trigger.taskTemplate
            )
        }
        persistOrchestrationTriggers()
    }

    func startOrchestrationTriggerScheduler() {
        guard triggerSchedulerTask == nil else { return }
        triggerSchedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.tickOrchestrationTriggers()
            }
        }
    }

    func assembleTriggerPrompt(template: String, payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return template }
        return "\(template)\n\n[Event payload]\n\(trimmed)"
    }

    func childHasActiveDelegation(named childName: String, under parentID: UUID) -> Bool {
        guard let child = resolveDescendant(named: childName, under: parentID) else { return false }
        return delegationRuns.runs.contains { $0.parentID == parentID && $0.childID == child.id && $0.isActive }
    }

    private func resolveDescendant(named name: String, under parentID: UUID) -> ManagedConnection? {
        OrchestrationTree.resolveDescendant(named: name, under: parentID, in: connections)
    }
}