import Foundation
import GrokestratorCore

/// Host-local queue of agent-proposed design-oracle updates awaiting human curation (#142).
public enum CorpusProposalStore {
    public static var storeURL: URL {
        ConnectionStore.supportDir.appendingPathComponent("corpus-proposals.json")
    }

    public static func load() -> [CorpusProposal] {
        guard let data = try? Data(contentsOf: storeURL),
              let proposals = try? JSONDecoder().decode([CorpusProposal].self, from: data) else {
            return []
        }
        return proposals.sorted { $0.createdAt > $1.createdAt }
    }

    public static func save(_ proposals: [CorpusProposal]) {
        guard let data = try? JSONEncoder().encode(proposals) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    @discardableResult
    public static func append(
        draft: CorpusProposalParser.Draft,
        nodeID: UUID?,
        nodeName: String?,
        projectDirectory: String
    ) -> CorpusProposal? {
        guard let target = CorpusProposal.sanitizeTargetPath(draft.targetPath) else { return nil }
        var all = load()
        let proposal = CorpusProposal(
            nodeID: nodeID,
            nodeName: nodeName,
            projectDirectory: projectDirectory,
            targetPath: target,
            markdown: draft.markdown,
            rationale: draft.rationale
        )
        all.insert(proposal, at: 0)
        save(all)
        return proposal
    }

    @discardableResult
    public static func append(
        target: String,
        markdown: String,
        rationale: String,
        nodeID: UUID?,
        nodeName: String?,
        projectDirectory: String
    ) -> CorpusProposal? {
        guard let path = CorpusProposal.sanitizeTargetPath(target) else { return nil }
        var all = load()
        let proposal = CorpusProposal(
            nodeID: nodeID,
            nodeName: nodeName,
            projectDirectory: projectDirectory,
            targetPath: path,
            markdown: markdown,
            rationale: rationale
        )
        all.insert(proposal, at: 0)
        save(all)
        return proposal
    }

    public static func pending() -> [CorpusProposal] {
        load().filter { $0.status == .pending }
    }

    @discardableResult
    public static func approve(id: UUID, note: String? = nil) -> String? {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return nil }
        var proposal = all[idx]
        guard proposal.status == .pending else { return nil }

        let url = proposal.stagedFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let header = """
            ---
            id: \(proposal.id.uuidString)
            status: proposed
            source: grokestrator-corpus-proposal
            target: \(proposal.targetPath)
            rationale: \(proposal.rationale)
            proposed_at: \(ISO8601DateFormatter().string(from: proposal.createdAt))
            ---

            """
            try (header + proposal.markdown).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        proposal.status = .approved
        proposal.reviewedAt = Date()
        proposal.reviewNote = note
        all[idx] = proposal
        save(all)
        return url.path
    }

    @discardableResult
    public static func reject(id: UUID, note: String? = nil) -> Bool {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return false }
        var proposal = all[idx]
        guard proposal.status == .pending else { return false }
        proposal.status = .rejected
        proposal.reviewedAt = Date()
        proposal.reviewNote = note
        all[idx] = proposal
        save(all)
        return true
    }
}