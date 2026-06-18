import Foundation

// MARK: - The oracle ledger — the evidence the shadow oracle is working (design/13, Slice 1)
//
// Shadow verdicts were ephemeral (NSLog). You can't *prove* the oracle works without a record,
// so every evaluation is appended here as one JSONL line — human-readable AND machine-parseable
// (No Cognitive Gap: Bob can `cat`/`grep` it directly; the app reads the same file). It's an
// observational ledger, not authored intent, so it lives in host-local app storage (not the
// project repo / `design/oracle/`, which is curated intent).

/// One recorded governance evaluation: the proposed action + the verdict the oracle reached.
public struct GovernanceEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let nodeID: UUID?
    public let boundary: String        // "apiToolLoop" | "acpPermission"
    public let verb: String
    public let rawVerb: String
    public let payload: String?        // short preview of the command/args
    public let fidelity: String
    public let outcome: String         // "allow" | "escalate" | "block"
    public let sideEffect: String?     // nil ⇒ unknown (fail-closed)
    public let severity: Int
    public let rationale: String

    public init(action: ProposedAction, verdict: Verdict, nodeID: UUID?, at: Date) {
        self.id = UUID()
        self.at = at
        self.nodeID = nodeID
        self.boundary = action.provenance.boundary.rawValue
        self.verb = action.verb
        self.rawVerb = action.rawVerb
        self.payload = (action.payloadText ?? action.arguments?.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
            .map { String($0.prefix(240)) }
        self.fidelity = "\(action.fidelity)"
        self.outcome = verdict.outcome.rawValue
        self.sideEffect = verdict.sideEffect?.rawValue
        self.severity = verdict.severity.rawValue
        self.rationale = verdict.rationale
    }
}

/// Append-only JSONL ledger of governance verdicts. Thread-safe (a serial queue), so the
/// session actors can fire-and-forget `record(_:)`. Configured once at launch with a
/// host-local file URL; until then it no-ops (never crashes a session over logging).
public final class OracleLedger: @unchecked Sendable {
    public static let shared = OracleLedger()
    private let queue = DispatchQueue(label: "ai.sourcepathlabs.grokestrator.oracle-ledger")
    private var url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    /// Point the ledger at a host-local file (creates the parent directory). Call once at launch.
    public func configure(fileURL: URL) {
        queue.sync {
            self.url = fileURL
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
    }

    /// Append one event as a JSONL line. Non-blocking on the caller.
    public func record(_ event: GovernanceEvent) {
        queue.async { [weak self] in
            guard let self, let url = self.url,
                  var line = try? self.encoder.encode(event) else { return }
            line.append(0x0A)   // newline-delimited
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                h.seekToEndOfFile(); h.write(line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// The most recent events (optionally for one node), newest first. Reads the file fresh.
    public func recent(nodeID: UUID? = nil, limit: Int = 200) -> [GovernanceEvent] {
        queue.sync {
            guard let url, let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            var events: [GovernanceEvent] = []
            for raw in text.split(separator: "\n").reversed() {
                guard let e = try? decoder.decode(GovernanceEvent.self, from: Data(raw.utf8)) else { continue }
                if let nodeID, e.nodeID != nodeID { continue }
                events.append(e)
                if events.count >= limit { break }
            }
            return events
        }
    }

    /// Aggregate outcome counts over `recent(nodeID:)` — the at-a-glance "what is it doing".
    public func summary(nodeID: UUID? = nil, limit: Int = 1000) -> (allow: Int, escalate: Int, block: Int) {
        let events = recent(nodeID: nodeID, limit: limit)
        return (events.filter { $0.outcome == "allow" }.count,
                events.filter { $0.outcome == "escalate" }.count,
                events.filter { $0.outcome == "block" }.count)
    }
}
