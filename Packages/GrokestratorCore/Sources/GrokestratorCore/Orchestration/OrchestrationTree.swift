import Foundation

/// Soft `parentID` tree helpers for fleet orchestration (#136).
public enum OrchestrationTree {

    public protocol Node: Identifiable where ID == UUID {
        var parentID: UUID? { get }
        var archived: Bool { get }
        var name: String { get }
    }

    /// Active (non-archived) nodes only.
    public static func active<N: Node>(_ nodes: [N]) -> [N] {
        nodes.filter { !$0.archived }
    }

    /// Direct children of `parentID`.
    public static func children<N: Node>(of parentID: UUID, in nodes: [N]) -> [N] {
        active(nodes).filter { $0.parentID == parentID }
    }

    /// All descendants (BFS), shallowest first.
    public static func descendants<N: Node>(of parentID: UUID, in nodes: [N]) -> [N] {
        var result: [N] = []
        var frontier: Set<UUID> = [parentID]
        let live = active(nodes)
        while !frontier.isEmpty {
            let layer = live.filter { node in
                guard let p = node.parentID else { return false }
                return frontier.contains(p)
            }
            result.append(contentsOf: layer)
            frontier = Set(layer.map(\.id))
        }
        return result
    }

    /// First name match among descendants (direct children win over deeper nodes).
    public static func resolveDescendant<N: Node>(
        named name: String, under parentID: UUID, in nodes: [N]
    ) -> N? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        var frontier: Set<UUID> = [parentID]
        let live = active(nodes)
        while !frontier.isEmpty {
            let layer = live.filter { node in
                guard let p = node.parentID else { return false }
                return frontier.contains(p)
            }
            if let hit = layer.first(where: { $0.name.lowercased() == key }) { return hit }
            frontier = Set(layer.map(\.id))
        }
        return nil
    }

    /// True when `candidateParent` is `child` or lies in `child`'s subtree.
    public static func wouldCreateCycle<N: Node>(
        child: UUID, candidateParent: UUID, in nodes: [N]
    ) -> Bool {
        if child == candidateParent { return true }
        return isDescendant(candidateParent, of: child, in: nodes)
    }

    public static func isDescendant<N: Node>(_ nodeID: UUID, of ancestorID: UUID, in nodes: [N]) -> Bool {
        descendants(of: ancestorID, in: nodes).contains { $0.id == nodeID }
    }

    /// Root nodes for sidebar rendering: no parent, or parent absent from the group.
    public static func roots<N: Node>(in nodes: [N]) -> [N] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { item in
            guard let p = item.parentID else { return true }
            return !ids.contains(p)
        }
    }
}

extension ManagedInstance: OrchestrationTree.Node {}