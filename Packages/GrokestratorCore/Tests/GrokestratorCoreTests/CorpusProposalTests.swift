import Foundation
import Testing
@testable import GrokestratorCore

@Suite struct CorpusProposalTests {
    @Test func sanitizeTargetPath() {
        #expect(CorpusProposal.sanitizeTargetPath("design/oracle/invariants/INV-x.md") != nil)
        #expect(CorpusProposal.sanitizeTargetPath("../etc/passwd") == nil)
        #expect(CorpusProposal.sanitizeTargetPath("src/foo.md") == nil)
    }

    @Test func parseCorpusProposalBlock() {
        let text = """
        Done.

        [[CORPUS_PROPOSAL
        target: design/oracle/invariants/INV-test.md
        rationale: capture new rule
        ---
        ---
        id: INV-test
        severity: high
        state: proposed
        ---

        Shell must not run outside cwd.
        ]]
        """
        let drafts = CorpusProposalParser.parse(text)
        #expect(drafts.count == 1)
        #expect(drafts[0].targetPath == "design/oracle/invariants/INV-test.md")
        #expect(drafts[0].markdown.contains("INV-test"))
    }
}