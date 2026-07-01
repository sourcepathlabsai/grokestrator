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
/// Implemented by the Mac host when a non-grok `fast` tier is configured.
public protocol ContextSummarizer: Sendable {
    func summarize(_ text: String, budget: ContextBudget) async throws -> String
}

/// Budget-driven working-context ladder for role transitions and API brains.
/// Display transcript stays intact; only the injected preamble is compacted.
public enum ContextManager {
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

    /// Build a compact gist body: tier-0 when it fits, tier-1 when it does not.
    public static func gistBody(
        from turns: [AgentTurn],
        options: SessionGist.Options = .tier0,
        budget: ContextBudget = .roleTransition,
        summarizer: ContextSummarizer? = nil
    ) async -> String? {
        guard !turns.isEmpty else { return nil }

        if !needsTier1(from: turns, options: options, budget: budget) {
            return SessionGist.tier0(from: turns, options: options)
        }

        let tier0Seed = SessionGist.tier0(
            from: turns,
            options: SessionGist.Options(
                maxTurns: turns.count,
                maxUserPromptChars: options.maxUserPromptChars,
                maxOutcomeChars: options.maxOutcomeChars,
                maxTotalChars: min(budget.maxChars * 4, 48_000)
            )
        )

        if let summarizer, let seed = tier0Seed {
            if let summarized = try? await summarizer.summarize(seed, budget: budget) {
                let trimmed = summarized.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= budget.maxChars + 50 {
                    return trimmed
                }
            }
        }

        return SessionGist.tier1(from: turns, budget: budget)
    }

    /// Wire-ready preamble for a role transition restart.
    public static func wirePreambleForTransition(
        from turns: [AgentTurn],
        options: SessionGist.Options = .tier0,
        budget: ContextBudget = .roleTransition,
        summarizer: ContextSummarizer? = nil
    ) async -> String? {
        guard let body = await gistBody(from: turns, options: options, budget: budget, summarizer: summarizer) else {
            return nil
        }
        return SessionGist.wirePreamble(from: body)
    }
}