import Foundation
import Testing
@testable import GrokestratorCore

@Suite("Session gist — tier 0")
struct SessionGistTests {
    @Test func emptyHistoryReturnsNil() {
        #expect(SessionGist.tier0(from: []) == nil)
    }

    @Test func extractsUserPromptAndFinalOutcome() {
        let turn = AgentTurn(
            userPrompt: "Fix the login bug",
            messages: [
                AgentMessage(role: .tool, content: "Tool call: read_file [path: Login.swift]"),
                AgentMessage(role: .assistant, content: "[fs] read Login.swift"),
                AgentMessage(role: .assistant, content: "Fixed the nil check in `LoginViewModel`."),
            ]
        )
        let gist = SessionGist.tier0(from: [turn])!
        #expect(gist.contains("User: Fix the login bug"))
        #expect(gist.contains("Outcome: Fixed the nil check"))
        #expect(gist.contains("Tools: 1 call(s)"))
    }

    @Test func respectsTotalCharBudget() {
        var turns: [AgentTurn] = []
        for i in 0..<20 {
            turns.append(AgentTurn(
                userPrompt: String(repeating: "x", count: 400),
                messages: [AgentMessage(role: .assistant, content: String(repeating: "y", count: 1_500))]
            ))
        }
        let gist = SessionGist.tier0(from: turns, options: .init(maxTurns: 20, maxTotalChars: 3_000))!
        #expect(gist.count <= 3_010)
    }

    @Test func wirePreambleWrapsBody() {
        let wrapped = SessionGist.wirePreamble(from: "Turn 1:\nUser: hi")
        #expect(wrapped.contains("[Prior session context — role transition]"))
        #expect(wrapped.contains("Turn 1:\nUser: hi"))
    }

    @Test func tier1CollapsesManyTurns() {
        var turns: [AgentTurn] = []
        for i in 0..<30 {
            turns.append(AgentTurn(
                userPrompt: "request \(i)",
                messages: [AgentMessage(role: .assistant, content: "result \(i)")]
            ))
        }
        let summary = SessionGist.tier1(from: turns, budget: ContextBudget(maxChars: 1_500))!
        #expect(summary.contains("[Prior session — 30 turn(s) summarized]"))
        #expect(summary.count <= 1_510)
    }
}