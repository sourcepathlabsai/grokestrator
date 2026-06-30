import Foundation

/// A scheduled wake-up for a standing child agent (`design/11` trigger.schedule).
public struct ScheduledTrigger: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let parentID: UUID
    public let childName: String
    public let cronSpec: String
    public let taskTemplate: String
    public let createdAt: Date
    public var lastFiredAt: Date?
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        parentID: UUID,
        childName: String,
        cronSpec: String,
        taskTemplate: String,
        createdAt: Date = Date(),
        enabled: Bool = true
    ) {
        self.id = id
        self.parentID = parentID
        self.childName = childName
        self.cronSpec = cronSpec
        self.taskTemplate = taskTemplate
        self.createdAt = createdAt
        self.lastFiredAt = nil
        self.enabled = enabled
    }
}

/// In-memory trigger + task.report store for orchestration MCP (`#135`).
@MainActor
@Observable
public final class OrchestrationTriggerStore {
    public private(set) var schedules: [ScheduledTrigger] = []
    public private(set) var reports: [UUID: [TaskReport]] = [:]

    public struct TaskReport: Identifiable, Sendable {
        public let id: UUID
        public let nodeID: UUID
        public let status: String
        public let result: String
        public let at: Date

        public init(nodeID: UUID, status: String, result: String, at: Date = Date()) {
            self.id = UUID()
            self.nodeID = nodeID
            self.status = status
            self.result = result
            self.at = at
        }
    }

    public init() {}

    public func recordReport(nodeID: UUID, status: String, result: String) {
        var list = reports[nodeID] ?? []
        list.insert(TaskReport(nodeID: nodeID, status: status, result: result), at: 0)
        if list.count > 50 { list.removeLast(list.count - 50) }
        reports[nodeID] = list
    }

    public func latestReport(for nodeID: UUID) -> TaskReport? {
        reports[nodeID]?.first
    }

    @discardableResult
    public func schedule(parentID: UUID, childName: String, cronSpec: String, taskTemplate: String) -> ScheduledTrigger {
        let trigger = ScheduledTrigger(parentID: parentID, childName: childName, cronSpec: cronSpec, taskTemplate: taskTemplate)
        schedules.insert(trigger, at: 0)
        return trigger
    }

    public func fire(event: String, payload: String, parentID: UUID?) -> [ScheduledTrigger] {
        schedules.filter { t in
            guard t.enabled else { return false }
            if let parentID { return t.parentID == parentID }
            return true
        }
    }

    public func markFired(_ id: UUID) {
        guard let idx = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[idx].lastFiredAt = Date()
    }
}