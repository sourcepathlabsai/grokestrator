import Foundation

/// In-memory store of recent delegation runs for the Run view sidebar.
/// MainActor-bound so SwiftUI can observe it via `GrokestratorModel`.
@MainActor
@Observable
public final class DelegationRunStore {
    public private(set) var runs: [DelegationRun] = []

    private let maxRuns: Int

    public init(maxRuns: Int = 100) {
        self.maxRuns = maxRuns
    }

    public func apply(_ update: DelegationRunUpdate) {
        switch update {
        case .started(let run):
            runs.insert(run, at: 0)
            if runs.count > maxRuns { runs.removeLast(runs.count - maxRuns) }
        case .finished(let id, let status, let preview):
            guard let idx = runs.firstIndex(where: { $0.id == id }) else { return }
            runs[idx].status = status
            runs[idx].finishedAt = Date()
            runs[idx].resultPreview = preview.map { String($0.prefix(200)) }
            refreshOracleCounts(for: runs[idx].id)
        }
    }

    /// Runs parented under one orchestrator, newest first.
    public func runs(for parentID: UUID, includeFinished: Bool = true) -> [DelegationRun] {
        runs.filter { run in
            run.parentID == parentID && (includeFinished || run.isActive)
        }
    }

    public func activeRuns(for parentID: UUID) -> [DelegationRun] {
        runs(for: parentID, includeFinished: false)
    }

    /// Any orchestrator with at least one active delegation.
    public var parentsWithActiveRuns: Set<UUID> {
        Set(runs.filter(\.isActive).map(\.parentID))
    }

    /// Recompute oracle verdict counts from the ledger for one run's child + time window.
    public func refreshOracleCounts(for runID: UUID) {
        guard let idx = runs.firstIndex(where: { $0.id == runID }) else { return }
        let run = runs[idx]
        let events = OracleLedger.shared.recent(nodeID: run.childID, limit: 500)
            .filter { $0.at >= run.startedAt }
        runs[idx].oracleAllow = events.filter { $0.outcome == "allow" }.count
        runs[idx].oracleEscalate = events.filter { $0.outcome == "escalate" }.count
        runs[idx].oracleBlock = events.filter { $0.outcome == "block" }.count
    }

    /// Refresh oracle counts on all active runs (called periodically from the sidebar).
    public func refreshActiveOracleCounts() {
        for run in runs where run.isActive {
            refreshOracleCounts(for: run.id)
        }
    }
}