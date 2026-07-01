import XCTest
@testable import GrokestratorCore

@MainActor
final class DelegationRunStoreTests: XCTestCase {

    func testApplyStartedAndFinished() {
        let store = DelegationRunStore(maxRuns: 10)
        let parent = UUID()
        let child = UUID()
        let run = DelegationRun(id: UUID(), parentID: parent, childID: child, childName: "Implementer", task: "Fix bug")

        store.apply(.started(run))
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.activeRuns(for: parent).count, 1)

        store.apply(.finished(id: run.id, status: .completed, resultPreview: "Done"))
        XCTAssertEqual(store.activeRuns(for: parent).count, 0)
        XCTAssertEqual(store.runs(for: parent).first?.status, .completed)
        XCTAssertEqual(store.runs(for: parent).first?.resultPreview, "Done")
    }

    func testMultipleParallelActiveRuns() {
        let store = DelegationRunStore(maxRuns: 10)
        let parent = UUID()
        let childA = UUID()
        let childB = UUID()
        store.apply(.started(DelegationRun(parentID: parent, childID: childA, childName: "Researcher", task: "A")))
        store.apply(.started(DelegationRun(parentID: parent, childID: childB, childName: "Implementer", task: "B")))
        XCTAssertEqual(store.activeRuns(for: parent).count, 2)
    }
}