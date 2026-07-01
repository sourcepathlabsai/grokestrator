import Foundation

/// Structured return contract for orchestrated-fleet `delegate` children (`design/11`).
public struct ChildFindingEnvelope: Codable, Sendable, Hashable {
    public let envelopeVersion: String
    public let status: Status
    public let summary: String
    public let findings: [Finding]
    public let gaps: [String]
    public let recommendedNext: [String]

    enum CodingKeys: String, CodingKey {
        case envelopeVersion = "envelope_version"
        case status, summary, findings, gaps
        case recommendedNext = "recommended_next"
    }

    public enum Status: String, Codable, Sendable, Hashable {
        case success, partial, failed, needsHuman
    }

    public struct Finding: Codable, Sendable, Hashable {
        public let id: String
        public let kind: String
        public let statement: String
        public let confidence: Double?

        public init(id: String, kind: String, statement: String, confidence: Double? = nil) {
            self.id = id
            self.kind = kind
            self.statement = statement
            self.confidence = confidence
        }
    }

    public init(
        envelopeVersion: String = "1.0",
        status: Status,
        summary: String,
        findings: [Finding] = [],
        gaps: [String] = [],
        recommendedNext: [String] = []
    ) {
        self.envelopeVersion = envelopeVersion
        self.status = status
        self.summary = summary
        self.findings = findings
        self.gaps = gaps
        self.recommendedNext = recommendedNext
    }

    /// Parse JSON envelope from child text; nil if not valid envelope JSON.
    public static func parse(from text: String) -> ChildFindingEnvelope? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChildFindingEnvelope.self, from: data)
        else { return nil }
        guard decoded.envelopeVersion == "1.0", !decoded.summary.isEmpty else { return nil }
        return decoded
    }

    /// Wrap prose-only child output for the orchestrator with an explicit warning.
    public static func wrapProseOnly(_ text: String, childName: String) -> String {
        let preview = String(text.prefix(2000))
        return """
        [Child "\(childName)" returned prose, not a structured finding envelope. \
        Synthesize cautiously; re-delegate with explicit JSON envelope instructions if needed.]

        \(preview)
        """
    }

    /// Validate child output; returns formatted text for the orchestrator.
    public static func formatDelegateResult(_ text: String, childName: String) -> String {
        if let envelope = parse(from: text) {
            var lines = ["[Structured findings from \(childName) — status: \(envelope.status.rawValue)]"]
            lines.append(envelope.summary)
            if !envelope.findings.isEmpty {
                lines.append("Findings:")
                for f in envelope.findings {
                    lines.append("- [\(f.kind)] \(f.statement)")
                }
            }
            if !envelope.gaps.isEmpty {
                lines.append("Gaps: \(envelope.gaps.joined(separator: "; "))")
            }
            return lines.joined(separator: "\n")
        }
        return wrapProseOnly(text, childName: childName)
    }
}