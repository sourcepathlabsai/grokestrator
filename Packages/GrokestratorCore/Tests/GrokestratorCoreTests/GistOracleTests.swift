import Foundation
import Testing
@testable import GrokestratorCore

@Suite("Gist oracle")
struct GistOracleTests {
    @Test func extractsFileAnchors() {
        let turn = AgentTurn(
            userPrompt: "Fix AuthService.swift",
            messages: [AgentMessage(role: .assistant, content: "Updated AuthService.swift token check.")]
        )
        let anchors = GistOracle.extractAnchors(from: [turn])
        #expect(anchors.contains { $0.kind == .file && $0.label.contains("AuthService.swift") })
    }

    @Test func repairsMissingAnchors() {
        let turn = AgentTurn(
            userPrompt: "Remember: always run certify-pr.sh before PR",
            messages: [AgentMessage(role: .assistant, content: "We decided to use JWT sessions.")]
        )
        let anchors = GistOracle.extractAnchors(from: [turn])
        let summary = "Generic summary with no specifics."
        let check = GistOracle.verify(summary: summary, anchors: anchors)
        #expect(!check.passed)

        let repaired = GistOracle.repair(
            summary: summary,
            missing: check.missing,
            budget: ContextBudget(maxChars: 2_000)
        )
        #expect(repaired.contains("Pinned (gist oracle)"))
        #expect(repaired.contains("certify-pr.sh") || repaired.contains("JWT"))
    }

    @Test func certifyPassesWhenAnchorsPresent() {
        let turn = AgentTurn(
            userPrompt: "Edit ContextManager.swift",
            messages: [AgentMessage(role: .assistant, content: "ContextManager.swift updated.")]
        )
        let summary = "Worked on ContextManager.swift and finished the change."
        let certified = GistOracle.certify(summary: summary, from: [turn], budget: .roleTransition)
        #expect(certified.contains("ContextManager.swift"))
        #expect(!certified.contains("Pinned (gist oracle)"))
    }
}