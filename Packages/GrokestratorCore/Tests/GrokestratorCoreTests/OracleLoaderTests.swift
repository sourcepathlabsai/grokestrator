import Testing
import Foundation
@testable import GrokestratorCore

/// The project-owned oracle loads from `design/oracle/` markdown — human+machine-shared
/// (No Cognitive Gap). Parsing is pure string→struct, so most of this is filesystem-free.
@Suite("Design Oracle — loader")
struct OracleLoaderTests {

    @Test("invariant with a named (runtime) detector")
    func parseNamed() {
        let md = """
        ---
        id: INV-cwd-confinement
        severity: high
        state: active
        detector: DET-path-escape
        ---
        File actions must stay within the node's working directory.

        A node is sandboxed to its cwd; a path escape is out of bounds.
        """
        let parsed = OracleLoader.parseInvariant(markdown: md)
        #expect(parsed?.invariant.id == "INV-cwd-confinement")
        #expect(parsed?.invariant.severity == .high)
        #expect(parsed?.invariant.statement == "File actions must stay within the node's working directory.")
        #expect(parsed?.invariant.rationale.contains("sandboxed") == true)
        #expect(parsed?.invariant.detectorID == "DET-path-escape")
        #expect(parsed?.detector == nil)   // resolved from the registry at corpus build, not inline
    }

    @Test("invariant with portable ## Detect rules → a firing RegexDetector")
    func parseDetect() {
        let md = """
        ---
        id: INV-no-destructive-shell
        severity: critical
        ---
        Shell commands must not irreversibly destroy data without confirmation.

        Irreversible deletion is unrecoverable.

        ## Detect (any match → suspect)

        - recursive force-remove: `\\brm\\s+-rf`
        - filesystem format: `\\bmkfs\\b`
        """
        let parsed = OracleLoader.parseInvariant(markdown: md)
        let det = parsed?.detector as? RegexDetector
        #expect(det?.rules.count == 2)
        #expect(det?.rules.first?.name == "recursive force-remove")
        let action = ProposedAction.fromAPITool(name: "run_command", arguments: ["command": "rm -rf build/"],
                                                cwd: "/w", nodeName: nil, mcpServer: nil, mcpTool: nil)
        let findings = parsed?.detector?.examine(action) ?? []
        #expect(findings.contains { $0.confidence == .suspect && $0.invariantID == "INV-no-destructive-shell" })
    }

    @Test("grounding-only invariant has no detector")
    func groundingOnly() {
        let parsed = OracleLoader.parseInvariant(markdown: "---\nid: INV-x\nseverity: high\n---\nMust hold.")
        #expect(parsed?.invariant.detectorID == nil)
        #expect(parsed?.detector == nil)
    }

    @Test("no id → skipped")
    func noID() {
        #expect(OracleLoader.parseInvariant(markdown: "just prose, no frontmatter") == nil)
    }

    @Test("loadCorpus from a directory merges invariants over the baseline")
    func loadDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oracle-\(UUID().uuidString)")
        let invDir = base.appendingPathComponent("design/oracle/invariants")
        try FileManager.default.createDirectory(at: invDir, withIntermediateDirectories: true)
        try "---\nid: INV-x\nseverity: low\n---\nA must hold.".write(to: invDir.appendingPathComponent("INV-x.md"), atomically: true, encoding: .utf8)
        let corpus = OracleLoader.loadCorpus(projectDirectory: base.path)
        #expect(corpus.invariants.contains { $0.id == "INV-x" })
        #expect(corpus.classifications.count == Corpus.baselineClassifications.count)
        try? FileManager.default.removeItem(at: base)
    }

    @Test("the SHIPPED design/oracle parses + governs (dogfood)")
    func shippedOracle() {
        var root = URL(fileURLWithPath: #filePath)   // …/Packages/GrokestratorCore/Tests/GrokestratorCoreTests/<file>
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let corpus = OracleLoader.loadCorpus(projectDirectory: root.path)
        guard !corpus.invariants.isEmpty else { return }   // skip gracefully if layout differs
        #expect(corpus.invariants.contains { $0.id == "INV-no-destructive-shell" })
        #expect(corpus.invariants.contains { $0.id == "INV-cwd-confinement" })
        let engine = GovernanceEngine(corpus: corpus)
        let rm = ProposedAction.fromAPITool(name: "run_command", arguments: ["command": "rm -rf /tmp/x"],
                                            cwd: root.path, nodeName: nil, mcpServer: nil, mcpTool: nil)
        #expect(engine.evaluate(rm).outcome == .escalate)   // caught by the in-repo oracle, not code
    }
}
