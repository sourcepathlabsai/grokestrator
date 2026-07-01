import Foundation

/// A searchable slice of session history for retrieval (`design/12` step 4).
public struct RetrievedChunk: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let turnIndex: Int
    public let text: String
    public let score: Double

    public init(turnIndex: Int, text: String, score: Double) {
        self.id = UUID()
        self.turnIndex = turnIndex
        self.text = text
        self.score = score
    }
}

public struct RetrievalOptions: Sendable, Equatable {
    public var maxChunks: Int
    public var maxChars: Int
    /// Recent tail turns kept verbatim outside retrieval.
    public var recentTailTurns: Int

    public init(maxChunks: Int = 8, maxChars: Int = 4_000, recentTailTurns: Int = 5) {
        self.maxChunks = maxChunks
        self.maxChars = maxChars
        self.recentTailTurns = recentTailTurns
    }

    public static let `default` = RetrievalOptions()
}

/// Pulls relevant middle-history snippets for compaction. Mac supplies an embedding
/// implementation; Core always has a keyword fallback.
public protocol ContextRetriever: Sendable {
    func retrieve(
        query: String,
        from turns: [AgentTurn],
        options: RetrievalOptions
    ) async -> [RetrievedChunk]
}

/// Deterministic keyword-overlap retrieval (no network).
public struct KeywordRetriever: ContextRetriever {
    public init() {}

    public func retrieve(
        query: String,
        from turns: [AgentTurn],
        options: RetrievalOptions
    ) async -> [RetrievedChunk] {
        let chunks = ContextChunker.chunks(from: turns, excludingRecentTail: options.recentTailTurns)
        guard !chunks.isEmpty else { return [] }
        let queryTokens = tokenSet(query)
        guard !queryTokens.isEmpty else { return [] }

        let scored = chunks.map { chunk -> RetrievedChunk in
            let tokens = tokenSet(chunk.text)
            let overlap = queryTokens.intersection(tokens).count
            let score = Double(overlap) / sqrt(Double(max(tokens.count, 1)))
            return RetrievedChunk(turnIndex: chunk.turnIndex, text: chunk.text, score: score)
        }
        .filter { $0.score > 0 }
        .sorted { $0.score > $1.score }

        return select(scored, options: options)
    }

    private func select(_ ranked: [RetrievedChunk], options: RetrievalOptions) -> [RetrievedChunk] {
        var picked: [RetrievedChunk] = []
        var used = 0
        for chunk in ranked {
            if picked.count >= options.maxChunks { break }
            let addition = chunk.text.count + (picked.isEmpty ? 0 : 2)
            if used + addition > options.maxChars, !picked.isEmpty { break }
            picked.append(chunk)
            used += addition
        }
        return picked
    }

    private func tokenSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }
}

public enum ContextChunker {
    public struct Chunk: Sendable {
        public let turnIndex: Int
        public let text: String

        public init(turnIndex: Int, text: String) {
            self.turnIndex = turnIndex
            self.text = text
        }
    }

    public static func chunks(from turns: [AgentTurn], excludingRecentTail tail: Int) -> [Chunk] {
        guard turns.count > tail else { return [] }
        let middle = turns.dropLast(tail)
        return middle.enumerated().map { index, turn in
            Chunk(turnIndex: index + 1, text: turnText(turn))
        }
    }

    public static func turnText(_ turn: AgentTurn) -> String {
        var lines: [String] = []
        let prompt = turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { lines.append("User: \(prompt)") }
        if let outcome = assistantOutcome(in: turn) {
            lines.append("Outcome: \(outcome)")
        }
        return lines.joined(separator: "\n")
    }

    public static func formatRetrieved(_ chunks: [RetrievedChunk]) -> String? {
        guard !chunks.isEmpty else { return nil }
        var lines = ["[Retrieved context — relevant to recent work]"]
        for chunk in chunks.sorted(by: { $0.turnIndex < $1.turnIndex }) {
            lines.append("• Turn \(chunk.turnIndex): \(chunk.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func assistantOutcome(in turn: AgentTurn) -> String? {
        let assistants = turn.messages.filter { $0.role == .assistant }
        for msg in assistants.reversed() {
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if content.hasPrefix("["), content.contains("]"), content.count < 160 { continue }
            return content.count > 400 ? String(content.prefix(400)) + "…" : content
        }
        return assistants.last.map(\.content)
    }
}