import XCTest
@testable import GrokestratorCore

final class OrchestrationTreeTests: XCTestCase {

    private func node(_ name: String, parent: UUID? = nil, archived: Bool = false) -> ManagedInstance {
        ManagedInstance(
            name: name, command: "grok", arguments: ["agent", "stdio"],
            archived: archived, role: .orchestrator, parentID: parent
        )
    }

    func testDescendantsShallowestFirst() {
        let root = node("root")
        let mid = node("mid", parent: root.id)
        let leaf = node("leaf", parent: mid.id)
        let all = [root, mid, leaf]

        let desc = OrchestrationTree.descendants(of: root.id, in: all)
        XCTAssertEqual(desc.map(\.name), ["mid", "leaf"])
    }

    func testResolvePrefersDirectChild() {
        let root = node("root")
        let dup = node("worker", parent: root.id)
        let deep = node("worker", parent: dup.id)
        let hit = OrchestrationTree.resolveDescendant(named: "worker", under: root.id, in: [root, dup, deep])
        XCTAssertEqual(hit?.id, dup.id)
    }

    func testCycleDetection() {
        let a = node("a")
        let b = node("b", parent: a.id)
        let c = node("c", parent: b.id)
        let all = [a, b, c]
        XCTAssertTrue(OrchestrationTree.wouldCreateCycle(child: a.id, candidateParent: c.id, in: all))
        XCTAssertFalse(OrchestrationTree.wouldCreateCycle(child: c.id, candidateParent: a.id, in: all))
    }

    func testRootsOrphansMissingParent() {
        let root = node("root")
        let orphan = node("orphan", parent: UUID())
        let roots = OrchestrationTree.roots(in: [root, orphan])
        XCTAssertEqual(Set(roots.map(\.id)), Set([root.id, orphan.id]))
    }
}