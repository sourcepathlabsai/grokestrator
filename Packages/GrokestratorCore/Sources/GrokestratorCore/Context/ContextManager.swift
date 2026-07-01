import Foundation

/// Budget for working-context gists sent to the model (`design/12` Phase B′).
public struct ContextBudget: Sendable, Equatable {
    public var maxChars: Int

    public init(maxChars: Int) {
        self.maxChars = maxChars
    }

    /// Default cap for role-transition carry-forward (matches tier-0 options).
    public static let roleTransition = ContextBudget(maxChars: 12_000)
}

/// Optional fast-tier summarizer for tier-1 compaction (`design/12` §Context management).
public protocol ContextSummarizer: Sendable {
    func summarize(_ text: String, budget: ContextBudget) async throws -> String
}

/// Host-provided compaction services (summarizer + retriever).
public struct ContextCompactionServices: Sendable {
    public var summarizer: ContextSummarizer?
    public var retriever: ContextRetriever?

    public init(summarizer: ContextSummarizer? = nil, retriever: ContextRetriever? = nil) {
        self.summarizer = summarizer
        self.retriever = retriever
    }
}

/// Budget-driven working-context ladder for role transitions and API brains.
/// Display transcript stays intact; only the injected preamble is compacted.
public enum ContextManager {
    /// Turn count above which retrieval augments tier-1 compaction.
    public static let retrievalThreshold = 25

    /// Whether tier-0 lossless extraction exceeds the budget and needs tier-1.
    public static func needsTier1(
        from turns: [AgentTurn],
        options: SessionGist.Options = .tier0,
        budget: ContextBudget = .roleTransition
    ) -> Bool {
        guard !turns.isEmpty else { return false }
        if turns.count > options.maxTurns { return true }
        let probe = SessionGist.Options(
            maxTurns: turns.count,
            maxUserPromptChars: options.maxUserPromptChars,
            maxOutcomeChars: options.maxOutcomeChars,
            maxTotalChars: 1_000_000
        )
        let raw = SessionGist.tier0(from: turns, options: probe)
        return (raw?.count ?? 0) > budget.maxChars
    }

    /// Build a compact gist body: tier-0 when it fits, tier-1 (+ retrieval + oracle) when not.
    public static func gistBody(
        from turns: [AgentTurn],
        options: SessionGist.Options = .tier0,
        budget: ContextBudget = .roleTransition,
        services: ContextCompactionServices = ContextCompactionServices()
    ) async -> String? {
        guard !turns.isEmpty else { return nil }

        if !needsTier1(from: turns, options: options, budget: budget) {
            let tier0 = SessionGist.tier0(from: turns, options: options) ?? ""
            return GistOracle.certify(summary: tier0, from: turns, budget: budget)
        }

        let body = await compactWithRetrieval(
            from: turns,
            options: options,
            budget: budget,
            services: services
        )
        guard let body else { return nil }
        return GistOracle.certify(summary: body, from: turns, budget: budget)
    }

    /// Wire-ready preamble for a role transition restart.
    public static func wirePreambleForTransition(
        from turns: [AgentTurn],
        options: SessionGist.Options = .tier0,
        budget: ContextBudget = .roleTransition,
        services: ContextCompactionServices = ContextCompactionServices()
    ) async -> String? {
        guard let body = await gistBody(from: turns, options: options, budget: budget, services: services) else {
            return nil
        }
        return SessionGist.wirePreamble(from: body)
    }

    // MARK: - Tier 1 + retrieval

    private static func compactWithRetrieval(
        from turns: [AgentTurn],
        options: SessionGist.Options,
        budget: ContextBudget,
        services: ContextCompactionServices
    ) async -> String? {
        let retrievalOptions = RetrievalOptions(
            maxChunks: 8,
            maxChars: min(budget.maxChars / 3, 4_000),
            recentTailTurns: 5
        )
        let tailCount = retrievalOptions.recentTailTurns
        let recent = Array(turns.suffix(tailCount))
        let query = recent.suffix(3).map(\.userPrompt).joined(separator: " ")

        var sections: [String] = []

        if turns.count >= retrievalThreshold {
            let retriever = services.retriever ?? KeywordRetriever()
            let chunks = await retriever.retrieve(query: query, from: turns, options: retrievalOptions)
            if let retrieved = ContextChunker.formatRetrieved(chunks) {
                sections.append(retrieved)
            }
        }

        let summaryBudget = ContextBudget(maxChars: max(2_000, budget.maxChars - sections.joined().count - 200))
        let tier0Seed = SessionGist.tier0(
            from: turns,
            options: SessionGist.Options(
                maxTurns: turns.count,
                maxUserPromptChars: options.maxUserPromptChars,
                maxOutcomeChars: options.maxOutcomeChars,
                maxTotalChars: min(summaryBudget.maxChars * 4, 48_000)
            )
        )

        var summary: String?
        if let summarizer = services.summarizer, let seed = tier0Seed {
            summary = try? await summarizer.summarize(seed, budget: summaryBudget)
        }
        if summary == nil {
            summary = SessionGist.tier1(from: turns, budget: summaryBudget)
        }
        if let summary { sections.append(summary) }

        if !recent.isEmpty, let tail = SessionGist.tier0(from: recent, options: options) {
            sections.append("[Recent tail]\n\(tail)")
        }

        let combined = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }
}