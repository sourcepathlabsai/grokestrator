import Foundation

/// One recorded verify-against-intent evaluation (#141).
public struct IntentVerificationEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let nodeID: UUID?
    public let userPrompt: String?
    public let changePreview: String?
    public let aligned: Bool
    public let rationale: String
    public let findings: [IntentFindingRecord]

    public struct IntentFindingRecord: Codable, Sendable, Hashable {
        public let invariantID: String
        public let severity: Int
        public let note: String

        public init(_ finding: IntentFinding) {
            self.invariantID = finding.invariantID
            self.severity = finding.severity.rawValue
            self.note = finding.note
        }
    }

    public init(
        verdict: IntentVerdict,
        nodeID: UUID?,
        userPrompt: String?,
        changeText: String?,
        at: Date = Date()
    ) {
        self.id = UUID()
        self.at = at
        self.nodeID = nodeID
        self.userPrompt = userPrompt.map { String($0.prefix(240)) }
        self.changePreview = changeText.map { String($0.prefix(480)) }
        self.aligned = verdict.aligned
        self.rationale = verdict.rationale
        self.findings = verdict.findings.map(IntentFindingRecord.init)
    }
}

/// Append-only JSONL ledger for intent-orientation checks (shadow mode).
public final class IntentLedger: @unchecked Sendable {
    public static let shared = IntentLedger()
    private let queue = DispatchQueue(label: "ai.sourcepathlabs.grokestrator.intent-ledger")
    private var url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    public func configure(fileURL: URL) {
        queue.sync {
            self.url = fileURL
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    public func record(_ event: IntentVerificationEvent) {
        queue.async { [weak self] in
            guard let self, let url = self.url,
                  var line = try? self.encoder.encode(event) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    public func recent(nodeID: UUID? = nil, limit: Int = 200) -> [IntentVerificationEvent] {
        queue.sync {
            guard let url, let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            var events: [IntentVerificationEvent] = []
            for raw in text.split(separator: "\n").reversed() {
                guard let e = try? decoder.decode(IntentVerificationEvent.self, from: Data(raw.utf8)) else {
                    continue
                }
                if let nodeID, e.nodeID != nodeID { continue }
                events.append(e)
                if events.count >= limit { break }
            }
            return events
        }
    }
}