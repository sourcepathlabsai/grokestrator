import Foundation
import Testing
@testable import GrokestratorCore

@Suite("ContextManager — tier 1")
struct ContextManagerTests {
    @Test func shortHistoryUsesTier0() async {
        let turn = AgentTurn(
            userPrompt: "Fix login",
            messages: [AgentMessage(role: .assistant, content: "Fixed nil check.")]
        )
        let body = await ContextManager.gistBody(from: [turn])!
        #expect(body.contains("Turn 1:"))
        #expect(body.contains("User: Fix login"))
        #expect(!body.contains("[Prior session —"))
    }

    @Test func longHistoryEscalatesToTier1() async {
        var turns: [AgentTurn] = []
        for i in 0..<60 {
            turns.append(AgentTurn(
                userPrompt: "Task \(i): " + String(repeating: "a", count: 400),
                messages: [AgentMessage(role: .assistant, content: "Done \(i): " + String(repeating: "b", count: 800))]
            ))
        }
        #expect(ContextManager.needsTier1(from: turns))

        let budget = ContextBudget(maxChars: 4_000)
        let body = await ContextManager.gistBody(from: turns, budget: budget)!
        #expect(body.contains("[Prior session — 60 turn(s) summarized]"))
        #expect(body.count <= 4_010)
    }

    @Test func tier1PreservesRecentOutcomes() async {
        var turns: [AgentTurn] = []
        for i in 0..<40 {
            turns.append(AgentTurn(
                userPrompt: "step \(i)",
                messages: [AgentMessage(role: .assistant, content: "outcome \(i)")]
            ))
        }
        let body = await ContextManager.gistBody(
            from: turns,
            budget: ContextBudget(maxChars: 2_000)
        )!
        #expect(body.contains("outcome 39"))
    }

    @Test func wirePreambleUsesContextManager() async {
        let turn = AgentTurn(userPrompt: "hi", messages: [])
        let wire = await ContextManager.wirePreambleForTransition(from: [turn])!
        #expect(wire.contains("[Prior session context — role transition]"))
    }
}