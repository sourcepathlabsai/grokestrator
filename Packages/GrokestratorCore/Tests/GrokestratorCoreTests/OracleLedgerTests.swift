import Testing
import Foundation
@testable import GrokestratorCore

/// The ledger persists shadow verdicts as JSONL (human-readable + machine-parseable) so real
/// use accumulates the evidence the oracle is working.
@Suite("Design Oracle — ledger")
struct OracleLedgerTests {

    private func tempLedger() -> (OracleLedger, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-\(UUID().uuidString)/oracle-verdicts.jsonl")
        let ledger = OracleLedger()
        ledger.configure(fileURL: url)
        return (ledger, url)
    }

    private func event(_ command: String, nodeID: UUID) -> GovernanceEvent {
        let action = ProposedAction.fromAPITool(name: "run_command", arguments: ["command": command],
                                                cwd: "/w", nodeName: nil, mcpServer: nil, mcpTool: nil)
        return GovernanceEvent(action: action, verdict: GovernanceEngine.shadow.evaluate(action),
                               nodeID: nodeID, at: Date())
    }

    @Test("record → recent round-trips, newest first")
    func roundTrip() {
        let (ledger, url) = tempLedger()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let node = UUID()
        ledger.record(event("ls -la", nodeID: node))
        ledger.record(event("rm -rf build/", nodeID: node))
        // record() is async on a serial queue; recent() is sync on the same queue, so by the
        // time it runs both writes have flushed.
        let recent = ledger.recent(nodeID: node)
        #expect(recent.count == 2)
        #expect(recent.first?.payload?.contains("rm -rf") == true)   // newest first
        #expect(recent.first?.outcome == "escalate")                  // destructive shell
    }

    @Test("the on-disk form is human-readable JSONL")
    func humanReadable() throws {
        let (ledger, url) = tempLedger()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        ledger.record(event("rm -rf /tmp/x", nodeID: UUID()))
        _ = ledger.recent()   // flush
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(text.contains("\"outcome\":\"escalate\""))
        #expect(text.contains("rm -rf"))
        #expect(text.hasSuffix("\n"))   // newline-delimited
    }

    @Test("summary aggregates outcomes; nodeID filters")
    func summaryFilter() {
        let (ledger, url) = tempLedger()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = UUID(), b = UUID()
        ledger.record(event("ls", nodeID: a))            // escalate (execute floor)
        ledger.record(event("rm -rf x", nodeID: a))      // escalate
        ledger.record(event("cat f", nodeID: b))         // escalate (shell, unknown 'cat' → still shell-class)
        let sA = ledger.summary(nodeID: a)
        #expect(sA.escalate == 2)
        #expect(ledger.recent(nodeID: b).count == 1)
    }
}
