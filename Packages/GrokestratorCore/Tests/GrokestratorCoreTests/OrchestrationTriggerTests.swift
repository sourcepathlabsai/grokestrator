import Foundation
import Testing
@testable import GrokestratorCore

@Suite("Orchestration triggers (#135)")
struct OrchestrationTriggerTests {
    @Test func parsesIntervalSpecs() {
        #expect(TriggerSchedule.parse("every 30m") == .interval(1_800))
        #expect(TriggerSchedule.parse("every 1h") == .interval(3_600))
        #expect(TriggerSchedule.parse("every 2d") == .interval(172_800))
    }

    @Test func parsesEventSpecs() {
        #expect(TriggerSchedule.parse("event:pr-merged") == .event(name: "pr-merged"))
    }

    @Test @MainActor func eventFireMatchesSubscribers() throws {
        let store = OrchestrationTriggerStore()
        _ = try store.schedule(parentID: UUID(), childName: "worker", when: "event:deploy", taskTemplate: "check")
        _ = try store.schedule(parentID: UUID(), childName: "other", when: "every 1h", taskTemplate: "tick")
        let matches = store.matchingEventTriggers(event: "deploy", parentID: nil)
        #expect(matches.count == 1)
        #expect(matches[0].childName == "worker")
    }

    @Test @MainActor func intervalDueAfterElapsed() throws {
        let store = OrchestrationTriggerStore()
        let parent = UUID()
        let trigger = try store.schedule(parentID: parent, childName: "cron", when: "every 1h", taskTemplate: "run")
        store.markFired(trigger.id, at: Date(timeIntervalSince1970: 0))
        let due = store.dueIntervalTriggers(at: Date(timeIntervalSince1970: 3_700))
        #expect(due.map(\.id) == [trigger.id])
    }

    @Test @MainActor func registryRoundTrips() throws {
        let store = OrchestrationTriggerStore()
        _ = try store.schedule(parentID: UUID(), childName: "a", when: "event:foo", taskTemplate: "t")
        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(OrchestrationTriggerRegistry.self, from: data)
        let reloaded = OrchestrationTriggerStore()
        reloaded.load(decoded)
        #expect(reloaded.schedules.count == 1)
    }
}