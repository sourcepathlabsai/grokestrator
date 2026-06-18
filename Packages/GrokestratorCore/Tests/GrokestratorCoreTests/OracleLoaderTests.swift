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

    // MARK: - Orient-on-read (Slice 2)

    @Test("orientationPreamble formats active invariants sorted critical-first")
    func orientationPreamble() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orient-\(UUID().uuidString)")
        let invDir = base.appendingPathComponent("design/oracle/invariants")
        try FileManager.default.createDirectory(at: invDir, withIntermediateDirectories: true)
        try "---\nid: INV-alpha\nseverity: high\nstate: active\n---\nAlpha must hold.".write(to: invDir.appendingPathComponent("INV-alpha.md"), atomically: true, encoding: .utf8)
        try "---\nid: INV-beta\nseverity: critical\nstate: active\n---\nBeta must hold.".write(to: invDir.appendingPathComponent("INV-beta.md"), atomically: true, encoding: .utf8)
        try "---\nid: INV-retired\nseverity: high\nstate: retired\n---\nRetired.".write(to: invDir.appendingPathComponent("INV-retired.md"), atomically: true, encoding: .utf8)

        let preamble = OracleLoader.orientationPreamble(projectDirectory: base.path)
        #expect(preamble != nil)
        #expect(preamble!.contains("[CRITICAL] INV-beta"))
        #expect(preamble!.contains("[HIGH] INV-alpha"))
        #expect(!preamble!.contains("INV-retired"))
        // Critical sorts before high
        let betaRange = preamble!.range(of: "INV-beta")!
        let alphaRange = preamble!.range(of: "INV-alpha")!
        #expect(betaRange.lowerBound < alphaRange.lowerBound)
        try? FileManager.default.removeItem(at: base)
    }

    @Test("orientationPreamble returns nil for nonexistent directory")
    func orientationNoDir() {
        let preamble = OracleLoader.orientationPreamble(projectDirectory: "/nonexistent-\(UUID().uuidString)")
        #expect(preamble == nil)
    }

    @Test("orientationPreamble returns nil when all invariants are retired")
    func orientationAllRetired() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orient-ret-\(UUID().uuidString)")
        let invDir = base.appendingPathComponent("design/oracle/invariants")
        try FileManager.default.createDirectory(at: invDir, withIntermediateDirectories: true)
        try "---\nid: INV-old\nseverity: high\nstate: retired\n---\nOld.".write(to: invDir.appendingPathComponent("INV-old.md"), atomically: true, encoding: .utf8)
        #expect(OracleLoader.orientationPreamble(projectDirectory: base.path) == nil)
        try? FileManager.default.removeItem(at: base)
    }

    @Test("orientationPreamble works against the SHIPPED design/oracle (dogfood)")
    func orientationShipped() {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let preamble = OracleLoader.orientationPreamble(projectDirectory: root.path)
        guard let preamble else { return }   // skip gracefully if layout differs
        #expect(preamble.contains("INV-no-destructive-shell"))
        #expect(preamble.contains("INV-cwd-confinement"))
        #expect(preamble.contains("INV-external-comms-reviewed"))
        #expect(preamble.hasPrefix("[Project Design Oracle"))
        #expect(preamble.hasSuffix("Honor these constraints in every action you take."))
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
