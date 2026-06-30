import SwiftUI
import GrokestratorCore

/// Dedicated Run/DAG view for fleet orchestrators (#134).
struct DelegationRunDAGView: View {
    let orchestrator: InstanceItem
    let runs: [DelegationRun]
    var childName: (UUID) -> String = { _ in "child" }
    var onSelectChild: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    private var active: [DelegationRun] { runs.filter(\.isActive) }
    private var finished: [DelegationRun] { runs.filter { !$0.isActive } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
                Text("Delegation runs — \(orchestrator.name)")
                    .font(Theme.display(14, .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dagSection
                    if !active.isEmpty { runList("Active", active) }
                    if !finished.isEmpty { runList("Recent", finished) }
                    if runs.isEmpty {
                        Text("No delegations yet. Fleet orchestrators delegate via the `delegate` MCP tool.")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.bgDeep)
    }

    private var dagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DAG").font(Theme.display(10, .semibold)).foregroundStyle(Theme.textFaint)
            HStack(spacing: 0) {
                nodeBox(orchestrator.name, tint: Theme.accent, isRoot: true)
                if !runs.isEmpty {
                    ForEach(runs.prefix(8)) { run in
                        edgeArrow
                        Button { onSelectChild(run.childID) } label: {
                            nodeBox(run.childName, tint: statusColor(run.status), isRoot: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func runList(_ title: String, _ items: [DelegationRun]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.display(9, .semibold))
                .foregroundStyle(Theme.textFaint)
            ForEach(items) { run in
                DelegationRunDAGRow(run: run, onSelect: onSelectChild)
            }
        }
    }

    private func nodeBox(_ label: String, tint: Color, isRoot: Bool) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(tint.opacity(0.15))
                .frame(width: isRoot ? 100 : 88, height: 36)
                .overlay(
                    Text(label)
                        .font(Theme.body(10, .medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                )
        }
    }

    private var edgeArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 4)
    }

    private func statusColor(_ status: DelegationRunStatus) -> Color {
        switch status {
        case .running: return .cyan
        case .completed: return .green
        case .failed: return .red
        case .timedOut: return .orange
        }
    }
}

private struct DelegationRunDAGRow: View {
    let run: DelegationRun
    var onSelect: (UUID) -> Void

    var body: some View {
        Button { onSelect(run.childID) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(statusTint).frame(width: 8, height: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(run.edgeLabel)")
                            .font(Theme.body(12, .medium))
                            .foregroundStyle(Theme.textBody)
                        Spacer()
                        Text(run.status.rawValue)
                            .font(Theme.mono(9))
                            .foregroundStyle(statusTint)
                    }
                    Text(run.isActive ? run.taskPreview : (run.resultPreview ?? run.taskPreview))
                        .font(Theme.body(10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(2)
                    oracleRow
                }
            }
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        }
        .buttonStyle(.plain)
    }

    private var statusTint: Color {
        switch run.status {
        case .running: return .cyan
        case .completed: return .green
        case .failed: return .red
        case .timedOut: return .orange
        }
    }

    @ViewBuilder
    private var oracleRow: some View {
        let total = run.oracleAllow + run.oracleEscalate + run.oracleBlock
        if total > 0 {
            HStack(spacing: 10) {
                if run.oracleAllow > 0 { oracleChip("allow", run.oracleAllow, .green) }
                if run.oracleEscalate > 0 { oracleChip("esc", run.oracleEscalate, .orange) }
                if run.oracleBlock > 0 { oracleChip("block", run.oracleBlock, .red) }
            }
        }
    }

    private func oracleChip(_ label: String, _ count: Int, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "lock.shield").font(.system(size: 7))
            Text("\(label) \(count)").font(Theme.mono(8))
        }
        .foregroundStyle(tint.opacity(0.85))
    }
}