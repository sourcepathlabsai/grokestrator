import SwiftUI
import GrokestratorCore

/// Recursive sidebar tree node for fleet orchestration (#136).
struct OrchestratorTreeNodeView: View {
    let instance: InstanceItem
    let group: SidebarServerGroup
    let depth: Int
    let hasParentInGroup: Bool
    @Bindable var model: GrokestratorModel
    @Binding var collapsedNodes: Set<UUID>
    var instanceRow: (InstanceItem, SidebarServerGroup) -> AnyView
    var orchestratorLabel: (InstanceItem, SidebarServerGroup) -> AnyView
    var rowMenu: (InstanceItem) -> AnyView

    private var children: [InstanceItem] {
        group.instances.filter { $0.parentID == instance.id }
    }

    var body: some View {
        nodeContent
    }

    @ViewBuilder
    private var nodeContent: some View {
        let isFleetOrch = model.showsFleetTree(for: instance)

        if isFleetOrch {
            DisclosureGroup(isExpanded: expansionBinding(instance.id)) {
                DelegationRunsSidebarSection(
                    runs: model.delegationRuns.runs(for: instance.id),
                    onSelectChild: { model.selectedInstanceID = $0 }
                )
                ForEach(children) { child in
                    OrchestratorTreeNodeView(
                        instance: child, group: group, depth: depth + 1,
                        hasParentInGroup: true, model: model,
                        collapsedNodes: $collapsedNodes,
                        instanceRow: instanceRow,
                        orchestratorLabel: orchestratorLabel,
                        rowMenu: rowMenu
                    )
                }
            } label: {
                orchestratorLabel(instance, group)
            }
        } else if !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding(instance.id)) {
                ForEach(children) { child in
                    OrchestratorTreeNodeView(
                        instance: child, group: group, depth: depth + 1,
                        hasParentInGroup: true, model: model,
                        collapsedNodes: $collapsedNodes,
                        instanceRow: instanceRow,
                        orchestratorLabel: orchestratorLabel,
                        rowMenu: rowMenu
                    )
                }
            } label: {
                orchestratorLabel(instance, group)
                    .padding(.leading, CGFloat(depth) * 12)
            }
        } else {
            instanceRow(instance, group)
                .padding(.leading, CGFloat(hasParentInGroup ? depth : 0) * 12)
        }
    }

    private func expansionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedNodes.contains(id) },
            set: { open in
                if open { collapsedNodes.remove(id) } else { collapsedNodes.insert(id) }
            }
        )
    }
}