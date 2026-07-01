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
        lastFiredAt: Date? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.parentID = parentID
        self.childName = childName
        self.cronSpec = cronSpec
        self.taskTemplate = taskTemplate
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
        self.enabled = enabled
    }

    public var schedule: TriggerSchedule? { TriggerSchedule.parse(cronSpec) }
}

/// Persisted trigger registry (`orchestration-triggers.json`).
public struct OrchestrationTriggerRegistry: Codable, Sendable, Equatable {
    public var schedules: [ScheduledTrigger]

    public init(schedules: [ScheduledTrigger] = []) {
        self.schedules = schedules
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

    public func load(_ registry: OrchestrationTriggerRegistry) {
        schedules = registry.schedules
    }

    public func snapshot() -> OrchestrationTriggerRegistry {
        OrchestrationTriggerRegistry(schedules: schedules)
    }

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
    public func schedule(parentID: UUID, childName: String, when: String, taskTemplate: String) throws -> ScheduledTrigger {
        guard let parsed = TriggerSchedule.parse(when) else {
            throw OrchestrationTriggerError.invalidSchedule(when)
        }
        let trigger = ScheduledTrigger(
            parentID: parentID,
            childName: childName,
            cronSpec: parsed.cronSpec,
            taskTemplate: taskTemplate
        )
        schedules.insert(trigger, at: 0)
        return trigger
    }

    /// Triggers subscribed to `event` via `event:<name>` cron specs.
    public func matchingEventTriggers(event: String, parentID: UUID?) -> [ScheduledTrigger] {
        let key = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        return schedules.filter { trigger in
            guard trigger.enabled else { return false }
            if let parentID, trigger.parentID != parentID { return false }
            guard case .event(let name)? = trigger.schedule else { return false }
            return name.lowercased() == key
        }
    }

    /// Interval triggers that are due for another wake (not event-based).
    public func dueIntervalTriggers(at now: Date = Date()) -> [ScheduledTrigger] {
        schedules.filter { trigger in
            guard trigger.enabled else { return false }
            guard case .interval(let seconds)? = trigger.schedule else { return false }
            let last = trigger.lastFiredAt ?? trigger.createdAt
            return now.timeIntervalSince(last) >= seconds
        }
    }

    public func markFired(_ id: UUID, at: Date = Date()) {
        guard let idx = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[idx].lastFiredAt = at
    }

    public func removeSchedule(_ id: UUID) {
        schedules.removeAll { $0.id == id }
    }
}

public enum OrchestrationTriggerError: Error, Sendable, LocalizedError {
    case invalidSchedule(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSchedule(let spec):
            return "Invalid trigger schedule \"\(spec)\". Use event:<name> or every Nm/Nh/Nd."
        }
    }
}