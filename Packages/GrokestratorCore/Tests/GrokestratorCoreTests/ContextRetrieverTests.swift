import Foundation
import Testing
@testable import GrokestratorCore

@Suite("Context retrieval")
struct ContextRetrieverTests {
    @Test func keywordRetrieverRanksRelevantTurn() async {
        var turns: [AgentTurn] = []
        for i in 0..<30 {
            let prompt = i == 12
                ? "implement ContextManager tier 1 retrieval"
                : "misc task \(i)"
            let outcome = i == 12
                ? "Added EmbeddingRetriever with nomic-embed."
                : "done \(i)"
            turns.append(AgentTurn(
                userPrompt: prompt,
                messages: [AgentMessage(role: .assistant, content: outcome)]
            ))
        }
        turns.append(AgentTurn(
            userPrompt: "unrelated wrap-up",
            messages: [AgentMessage(role: .assistant, content: "ok")]
        ))

        let retriever = KeywordRetriever()
        let chunks = await retriever.retrieve(
            query: "ContextManager tier 1 retrieval",
            from: turns,
            options: RetrievalOptions(maxChunks: 3, maxChars: 2_000, recentTailTurns: 1)
        )
        #expect(!chunks.isEmpty)
        #expect(chunks.contains { $0.text.localizedCaseInsensitiveContains("ContextManager") })
    }

    @Test func longHistoryIncludesRetrievedSection() async {
        var turns: [AgentTurn] = []
        for i in 0..<60 {
            let topic = i == 10 ? "orchestration SQLite schema" : "filler \(i)"
            turns.append(AgentTurn(
                userPrompt: topic,
                messages: [AgentMessage(role: .assistant, content: "outcome \(i)")]
            ))
        }
        let body = await ContextManager.gistBody(
            from: turns,
            budget: ContextBudget(maxChars: 6_000),
            services: ContextCompactionServices(retriever: KeywordRetriever())
        )!
        #expect(body.contains("[Retrieved context"))
    }
}