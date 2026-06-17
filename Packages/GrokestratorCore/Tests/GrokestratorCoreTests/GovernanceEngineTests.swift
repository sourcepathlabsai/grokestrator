import Testing
import Foundation
@testable import GrokestratorCore

/// Exercises the design-oracle pipeline (design/13) against representative Actions
/// from BOTH interception boundaries, pinning the behavior the shadow log should show.
@Suite("Design Oracle — governance engine")
struct GovernanceEngineTests {
    let engine = GovernanceEngine.shadow

    // MARK: API boundary (.structured) — precise detectors run

    @Test("read inside cwd → allow")
    func readAllowed() {
        let a = ProposedAction.fromAPITool(name: "read_file", arguments: ["path": "src/main.swift"],
                                           cwd: "/work", nodeName: nil, mcpServer: nil, mcpTool: nil)
        let v = engine.evaluate(a)
        #expect(v.outcome == .allow)
        #expect(v.sideEffect == .observe)
    }

    @Test("write escaping cwd → BLOCK (precise/definitive)")
    func pathEscapeBlocks() {
        let a = ProposedAction.fromAPITool(name: "write_file", arguments: ["path": "../../etc/passwd"],
                                           cwd: "/work", nodeName: nil, mcpServer: nil, mcpTool: nil)
        let v = engine.evaluate(a)
        #expect(v.outcome == .block)               // definitive + high severity ⇒ block
        #expect(v.findings.contains { $0.confidence == .definitive && $0.invariantID == "INV-cwd-confinement" })
    }

    @Test("destructive shell → escalate (recall/suspect)")
    func destructiveShellEscalates() {
        let a = ProposedAction.fromAPITool(name: "run_command", arguments: ["command": "rm -rf build/"],
                                           cwd: "/work", nodeName: nil, mcpServer: nil, mcpTool: nil)
        let v = engine.evaluate(a)
        #expect(v.outcome == .escalate)            // suspect trip ⇒ escalate, never silently blocked
        #expect(v.findings.contains { $0.confidence == .suspect && $0.invariantID == "INV-no-destructive-shell" })
    }

    @Test("benign shell → escalate via execute-class floor (not allow)")
    func benignShellStillEscalates() {
        // No detector trips, but `shell` is execute-class at high severity ⇒ surfaced.
        let a = ProposedAction.fromAPITool(name: "run_command", arguments: ["command": "ls -la"],
                                           cwd: "/work", nodeName: nil, mcpServer: nil, mcpTool: nil)
        let v = engine.evaluate(a)
        #expect(v.outcome == .escalate)
        #expect(v.sideEffect == .execute)
    }

    @Test("unknown MCP tool → escalate (fail-closed)")
    func unknownMCPFailsClosed() {
        let a = ProposedAction.fromAPITool(name: "mcp__Granted__search_grants", arguments: ["query": "arts"],
                                           cwd: "/work", nodeName: nil, mcpServer: "Granted", mcpTool: "search_grants")
        let v = engine.evaluate(a)
        #expect(v.outcome == .escalate)            // unknown classification ⇒ fail closed
        #expect(v.sideEffect == nil)
    }

    // MARK: ACP boundary (.semiStructured) — precise detectors abstain

    @Test("ACP destructive shell (command string only) → escalate")
    func acpDestructiveShellEscalates() {
        let a = ProposedAction.fromACPPermission(kind: "execute", variant: "Bash",
                                                 command: "rm -rf /tmp/x", title: "Bash: rm -rf /tmp/x",
                                                 agentName: "grok", cwd: nil, nodeName: nil)
        let v = engine.evaluate(a)
        #expect(a.fidelity == .semiStructured)
        #expect(v.outcome == .escalate)            // recall detector runs on payloadText
    }

    @Test("ACP path-escape goes UNDETECTED — the fidelity gap, pinned")
    func acpPathEscapeUndetected() {
        // grok's edit permission gives us a title, not a structured path. The precise
        // PathEscapeDetector ABSTAINS (needs .structured). This documents the real
        // limitation: the same invariant is enforceable on the API boundary but not
        // the ACP one. The action still surfaces (edit→fs.write is mutate, low) — but
        // NOT as a confinement block.
        let a = ProposedAction.fromACPPermission(kind: "edit", variant: nil,
                                                 command: nil, title: "Edit ../../etc/hosts",
                                                 agentName: "grok", cwd: "/work", nodeName: nil)
        let v = engine.evaluate(a)
        #expect(a.fidelity == .semiStructured)
        #expect(!v.findings.contains { $0.invariantID == "INV-cwd-confinement" })  // abstained
    }
}
