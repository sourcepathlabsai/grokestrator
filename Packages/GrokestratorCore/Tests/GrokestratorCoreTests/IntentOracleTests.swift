import Foundation
import Testing
@testable import GrokestratorCore

@Suite struct IntentOracleTests {
    private let corpus = GovernanceEngine.shadow.corpus

    @Test func alignedWhenNoContradiction() {
        let verdict = IntentOracle.evaluate(
            changeText: "I'll add a unit test under Packages/GrokestratorCore.",
            userPrompt: "Add coverage",
            corpus: corpus,
            workingDirectory: "/Users/dev/grokestrator"
        )
        #expect(verdict.aligned)
        #expect(verdict.findings.isEmpty)
    }

    @Test func flagsDestructiveShellWithoutReview() {
        let verdict = IntentOracle.evaluate(
            changeText: "Running `rm -rf /tmp/build` to clean artifacts.",
            userPrompt: "clean up",
            corpus: corpus,
            workingDirectory: "/Users/dev/grokestrator"
        )
        #expect(!verdict.aligned)
        #expect(verdict.findings.contains { $0.invariantID == "INV-no-destructive-shell" })
    }

    @Test func allowsDestructiveShellWithHumanReviewCue() {
        let verdict = IntentOracle.evaluate(
            changeText: "I will run rm -rf only after you confirm.",
            userPrompt: "clean",
            corpus: corpus,
            workingDirectory: "/Users/dev/grokestrator"
        )
        #expect(verdict.aligned)
    }

    @Test func flagsParentDirectoryEscape() {
        let verdict = IntentOracle.evaluate(
            changeText: "Copy ../secrets into the repo.",
            userPrompt: "fix",
            corpus: corpus,
            workingDirectory: "/Users/dev/grokestrator"
        )
        #expect(!verdict.aligned)
        #expect(verdict.findings.contains { $0.invariantID == "INV-cwd-confinement" })
    }
}