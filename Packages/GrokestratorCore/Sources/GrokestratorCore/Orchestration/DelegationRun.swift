import Foundation

/// Lifecycle state of one parent→child delegation tracked by the run store.
public enum DelegationRunStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case failed
    case timedOut
}

/// One tracked delegation: orchestrator (parent) → child agent, with oracle summary.
/// Surfaced in the sidebar Run view (`design/11` Phase 1–2 observability).
public struct DelegationRun: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let parentID: UUID
    public let childID: UUID
    public let childName: String
    /// First ~120 chars of the delegated task for at-a-glance context.
    public let taskPreview: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: DelegationRunStatus
    /// Short preview of the result or error (nil while running).
    public var resultPreview: String?
    /// Oracle verdict counts for the child during this run window.
    public var oracleAllow: Int
    public var oracleEscalate: Int
    public var oracleBlock: Int

    public init(
        id: UUID = UUID(),
        parentID: UUID,
        childID: UUID,
        childName: String,
        task: String,
        startedAt: Date = Date(),
        status: DelegationRunStatus = .running
    ) {
        self.id = id
        self.parentID = parentID
        self.childID = childID
        self.childName = childName
        self.taskPreview = String(task.prefix(120))
        self.startedAt = startedAt
        self.finishedAt = nil
        self.status = status
        self.resultPreview = nil
        self.oracleAllow = 0
        self.oracleEscalate = 0
        self.oracleBlock = 0
    }

    public var isActive: Bool { status == .running }

    /// Human-readable edge label for the sidebar DAG row.
    public var edgeLabel: String { "→ \(childName)" }
}

/// Updates emitted by `GrokBuildManager.delegate` for UI recording.
public enum DelegationRunUpdate: Sendable {
    case started(DelegationRun)
    case finished(id: UUID, status: DelegationRunStatus, resultPreview: String?)
}