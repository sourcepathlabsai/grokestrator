import SwiftUI
import GrokestratorCore

/// Recursive sidebar tree node for fleet orchestration on iOS (#136).
/// Read-only mirror of the host Mac tree — designated on the host, arrives over the wire.
struct iOSTreeNodeView: View {
    let instance: InstanceItem
    let connections: [InstanceItem]
    let depth: Int
    @Binding var collapsedNodes: Set<UUID>

    private var children: [InstanceItem] {
        connections.filter { $0.parentID == instance.id }
    }

    var body: some View {
        if instance.role == .orchestrator, !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding(instance.id)) {
                ForEach(children) { child in
                    iOSTreeNodeView(
                        instance: child,
                        connections: connections,
                        depth: depth + 1,
                        collapsedNodes: $collapsedNodes
                    )
                }
            } label: {
                ConnectionRow(instance: instance)
                    .tag(instance.id)
                    .padding(.leading, CGFloat(depth) * 10)
            }
        } else if !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding(instance.id)) {
                ForEach(children) { child in
                    iOSTreeNodeView(
                        instance: child,
                        connections: connections,
                        depth: depth + 1,
                        collapsedNodes: $collapsedNodes
                    )
                }
            } label: {
                ConnectionRow(instance: instance)
                    .tag(instance.id)
                    .padding(.leading, CGFloat(depth) * 10)
            }
        } else {
            ConnectionRow(instance: instance)
                .tag(instance.id)
                .padding(.leading, CGFloat(depth) * 10)
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