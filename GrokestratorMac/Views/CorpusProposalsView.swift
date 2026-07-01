import SwiftUI
import GrokestratorCore

/// Human curation queue for agent-proposed design-oracle updates (#142).
struct CorpusProposalsView: View {
    @Bindable var model: GrokestratorModel
    @State private var proposals: [CorpusProposal] = []
    @State private var lastAction: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Corpus Proposals")
                    .font(Theme.display(12, .semibold))
                Text(
                    "Agents draft updates to `design/` and the project oracle. Nothing lands in the canonical corpus until you approve here. Approved files are staged under `design/oracle/proposed/` for your git review."
                )
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

                if let lastAction {
                    Text(lastAction)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.accent)
                }

                let pending = proposals.filter { $0.status == .pending }
                if pending.isEmpty {
                    Text("No pending proposals.")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 8)
                } else {
                    ForEach(pending) { proposal in
                        proposalCard(proposal)
                    }
                }

                let reviewed = proposals.filter { $0.status != .pending }
                if !reviewed.isEmpty {
                    Text("REVIEWED")
                        .font(Theme.display(10, .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.top, 8)
                    ForEach(reviewed.prefix(10)) { proposal in
                        reviewedRow(proposal)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reload() }
    }

    private func proposalCard(_ proposal: CorpusProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(proposal.targetPath)
                    .font(Theme.body(12, .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
                Text(proposal.createdAt, style: .relative)
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.textFaint)
            }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textMuted)
            }
            if let name = proposal.nodeName {
                Text("From: \(name)")
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Text(proposal.markdown)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(8)
                .textSelection(.enabled)
            HStack {
                Button("Approve") { approve(proposal) }
                    .buttonStyle(.borderedProminent)
                Button("Reject", role: .destructive) { reject(proposal) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func reviewedRow(_ proposal: CorpusProposal) -> some View {
        HStack {
            Text(proposal.targetPath)
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(proposal.status.rawValue.capitalized)
                .font(Theme.body(10, .medium))
                .foregroundStyle(proposal.status == .approved ? .green : .orange)
        }
    }

    private func reload() {
        proposals = CorpusProposalStore.load()
    }

    private func approve(_ proposal: CorpusProposal) {
        if let path = CorpusProposalStore.approve(id: proposal.id) {
            lastAction = "Approved — staged at \(path)"
        } else {
            lastAction = "Approve failed."
        }
        reload()
    }

    private func reject(_ proposal: CorpusProposal) {
        _ = CorpusProposalStore.reject(id: proposal.id)
        lastAction = "Rejected \(proposal.targetPath)"
        reload()
    }
}