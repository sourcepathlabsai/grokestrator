import SwiftUI
import GrokestratorCore

/// Run-view rows nested under an orchestrator in the sidebar (#134).
/// Shows parent→child delegation edges, status, and oracle verdict counts.
struct DelegationRunsSidebarSection: View {
    let runs: [DelegationRun]
    var onSelectChild: (UUID) -> Void = { _ in }

    var body: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("RUNS")
                    .font(Theme.display(9, .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.leading, 28)
                    .padding(.top, 4)

                ForEach(runs) { run in
                    DelegationRunRow(run: run, onSelectChild: onSelectChild)
                }
            }
        }
    }
}

private struct DelegationRunRow: View {
    let run: DelegationRun
    var onSelectChild: (UUID) -> Void

    var body: some View {
        Button {
            onSelectChild(run.childID)
        } label: {
            HStack(spacing: 6) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(run.edgeLabel)
                            .font(Theme.body(11, .medium))
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(run.status.rawValue)
                            .font(Theme.mono(8))
                            .foregroundStyle(statusTint.opacity(0.9))
                    }
                    if run.isActive {
                        ThinkingIndicator(status: "delegating…", compact: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let preview = run.resultPreview {
                        Text(preview)
                            .font(Theme.body(9))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    } else {
                        Text(run.taskPreview)
                            .font(Theme.body(9))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    }
                    oracleSummary
                }
            }
            .padding(.leading, 28)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.taskPreview)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 6, height: 6)
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
    private var oracleSummary: some View {
        let total = run.oracleAllow + run.oracleEscalate + run.oracleBlock
        if total > 0 {
            HStack(spacing: 8) {
                if run.oracleAllow > 0 {
                    oracleChip("allow", run.oracleAllow, .green)
                }
                if run.oracleEscalate > 0 {
                    oracleChip("esc", run.oracleEscalate, .orange)
                }
                if run.oracleBlock > 0 {
                    oracleChip("block", run.oracleBlock, .red)
                }
            }
        }
    }

    private func oracleChip(_ label: String, _ count: Int, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "lock.shield")
                .font(.system(size: 7))
            Text("\(label) \(count)")
                .font(Theme.mono(8))
        }
        .foregroundStyle(tint.opacity(0.85))
    }
}