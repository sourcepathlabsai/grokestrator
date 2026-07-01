import Foundation

/// Lossless tier-0 compaction of a display transcript into a working-context seed.
/// Used when a Connection's role changes: the full `history.json` stays intact for the
/// UI, but only this gist is injected into a fresh agent session (see `design/12`).
public enum SessionGist {
    /// Budget and shaping knobs for tier-0 extraction.
    public struct Options: Sendable, Equatable {
        /// Maximum turns to include (most recent wins when trimming).
        public var maxTurns: Int
        /// Per-turn user prompt cap.
        public var maxUserPromptChars: Int
        /// Per-turn assistant outcome cap.
        public var maxOutcomeChars: Int
        /// Total output cap across all turns.
        public var maxTotalChars: Int

        public init(
            maxTurns: Int = 50,
            maxUserPromptChars: Int = 500,
            maxOutcomeChars: Int = 2_000,
            maxTotalChars: Int = 12_000
        ) {
            self.maxTurns = maxTurns
            self.maxUserPromptChars = maxUserPromptChars
            self.maxOutcomeChars = maxOutcomeChars
            self.maxTotalChars = maxTotalChars
        }

        public static let tier0 = Options()
    }

    /// Extract a compact gist from structured turns. Returns `nil` when there is
    /// nothing worth carrying forward (empty history).
    public static func tier0(from turns: [AgentTurn], options: Options = .tier0) -> String? {
        guard !turns.isEmpty else { return nil }

        let recent = turns.suffix(options.maxTurns)
        var sections: [String] = []
        var total = 0

        for (index, turn) in recent.enumerated() {
            var lines: [String] = []
            let prompt = truncate(turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                  to: options.maxUserPromptChars)
            if !prompt.isEmpty {
                lines.append("User: \(prompt)")
            }

            if let outcome = outcome(for: turn) {
                lines.append("Outcome: \(truncate(outcome, to: options.maxOutcomeChars))")
            }

            if let tools = toolSummary(for: turn) {
                lines.append(tools)
            }

            guard !lines.isEmpty else { continue }

            let header = "Turn \(index + 1):"
            let body = lines.joined(separator: "\n")
            let section = "\(header)\n\(body)"
            if total + section.count > options.maxTotalChars, !sections.isEmpty { break }
            sections.append(section)
            total += section.count + 2
        }

        let gist = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return gist.isEmpty ? nil : truncate(gist, to: options.maxTotalChars)
    }

    /// Build a wire-ready preamble from turns, or `nil` when history is empty.
    public static func wirePreambleForTransition(from turns: [AgentTurn], options: Options = .tier0) -> String? {
        guard let body = tier0(from: turns, options: options) else { return nil }
        return wirePreamble(from: body)
    }

    /// Deterministic tier-1 compaction when tier-0 exceeds budget. Collapses turns
    /// into a dense state summary (requests, outcomes, tool activity) without an LLM.
    public static func tier1(from turns: [AgentTurn], budget: ContextBudget) -> String? {
        guard !turns.isEmpty else { return nil }

        struct TurnFacts {
            var prompt: String
            var outcome: String?
            var toolCalls: Int
        }

        var facts: [TurnFacts] = []
        var totalToolCalls = 0

        for turn in turns {
            let prompt = truncate(
                turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                to: 220
            )
            let calls = turn.messages.filter { $0.role == .tool && $0.content.hasPrefix("Tool call:") }.count
            totalToolCalls += calls
            let outcome = outcome(for: turn).map { truncate($0, to: 320) }
            guard !prompt.isEmpty || outcome != nil else { continue }
            facts.append(TurnFacts(prompt: prompt, outcome: outcome, toolCalls: calls))
        }

        guard !facts.isEmpty else { return nil }

        func render(_ slice: ArraySlice<TurnFacts>) -> String {
            var lines: [String] = [
                "[Prior session — \(turns.count) turn(s) summarized]",
                "",
            ]
            let prompts = slice.map(\.prompt).filter { !$0.isEmpty }
            if !prompts.isEmpty {
                lines.append("Requests:")
                lines.append(contentsOf: prompts.map { "• \($0)" })
                lines.append("")
            }
            let outcomes = slice.compactMap(\.outcome)
            if !outcomes.isEmpty {
                lines.append("Outcomes:")
                lines.append(contentsOf: outcomes.map { "• \($0)" })
                lines.append("")
            }
            let toolTurns = slice.filter { $0.toolCalls > 0 }.count
            if toolTurns > 0 {
                let calls = slice.reduce(0) { $0 + $1.toolCalls }
                lines.append("Tool activity: \(toolTurns) turn(s), \(calls) call(s)")
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var slice = facts[...]
        var body = render(slice)
        while body.count > budget.maxChars, slice.count > 1 {
            slice = slice.dropFirst()
            body = render(slice)
        }
        return truncate(body, to: budget.maxChars)
    }

    /// Wrap a gist body for one-time injection into the agent preamble on role transition.
    public static func wirePreamble(from gistBody: String) -> String {
        """
        [Prior session context — role transition]
        The following summarizes work completed before this role change. The role \
        instructions above govern how you behave now; use this summary for continuity only.

        \(gistBody)
        """
    }

    // MARK: - Per-turn extraction

    private static func outcome(for turn: AgentTurn) -> String? {
        let assistants = turn.messages.filter { $0.role == .assistant }
        for msg in assistants.reversed() {
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            // Skip ephemeral one-line activity notes ([fs], [tool], mode updates).
            if content.hasPrefix("["), content.contains("]"), content.count < 160 { continue }
            return content
        }
        return assistants.last.map(\.content)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolSummary(for turn: AgentTurn) -> String? {
        let calls = turn.messages.filter { $0.role == .tool && $0.content.hasPrefix("Tool call:") }
        guard !calls.isEmpty else { return nil }
        return "Tools: \(calls.count) call(s)"
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }
}