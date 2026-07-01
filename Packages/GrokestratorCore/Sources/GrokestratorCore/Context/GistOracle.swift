import Foundation

/// Verifies compacted gists still name key entities and decisions (`design/12` gist safeguards).
public enum GistOracle {
    public enum AnchorKind: String, Sendable, Codable {
        case file
        case decision
        case remember
    }

    public struct Anchor: Sendable, Hashable {
        public let kind: AnchorKind
        public let label: String

        public init(kind: AnchorKind, label: String) {
            self.kind = kind
            self.label = label
        }
    }

    public struct Verification: Sendable {
        public let passed: Bool
        public let missing: [Anchor]

        public init(passed: Bool, missing: [Anchor]) {
            self.passed = passed
            self.missing = missing
        }
    }

    /// Extract anchors that a compaction must preserve.
    public static func extractAnchors(from turns: [AgentTurn], limit: Int = 24) -> [Anchor] {
        var seen = Set<String>()
        var anchors: [Anchor] = []

        func add(_ kind: AnchorKind, _ raw: String) {
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count >= 3 else { return }
            let key = "\(kind.rawValue):\(label.lowercased())"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            anchors.append(Anchor(kind: kind, label: label))
        }

        for turn in turns {
            let corpus = ([turn.userPrompt] + turn.messages.map(\.content)).joined(separator: "\n")
            for path in filePaths(in: corpus) { add(.file, path) }
            if rememberCue(in: turn.userPrompt) { add(.remember, turn.userPrompt) }
            for msg in turn.messages where msg.role == .assistant {
                if let decision = decisionPhrase(in: msg.content) { add(.decision, decision) }
            }
        }

        if anchors.count > limit {
            anchors = Array(anchors.prefix(limit))
        }
        return anchors
    }

    /// Check whether `summary` still reflects extracted anchors.
    public static func verify(summary: String, anchors: [Anchor]) -> Verification {
        let haystack = summary.lowercased()
        var missing: [Anchor] = []
        for anchor in anchors {
            if !matches(anchor, in: haystack) { missing.append(anchor) }
        }
        return Verification(passed: missing.isEmpty, missing: missing)
    }

    /// Append missing anchors under a pinned section, trimming to budget.
    public static func repair(summary: String, missing: [Anchor], budget: ContextBudget) -> String {
        guard !missing.isEmpty else { return summary }
        var lines = ["Pinned (gist oracle):"]
        for anchor in missing {
            let prefix: String
            switch anchor.kind {
            case .file:     prefix = "File"
            case .decision: prefix = "Decision"
            case .remember: prefix = "Remember"
            }
            lines.append("• \(prefix): \(anchor.label)")
        }
        let pinned = lines.joined(separator: "\n")
        let combined = summary + "\n\n" + pinned
        if combined.count <= budget.maxChars { return combined }
        let room = max(0, budget.maxChars - summary.count - 2)
        guard room > 40 else { return truncate(summary, to: budget.maxChars) }
        let trimmedPinned = truncate(pinned, to: room)
        return summary + "\n\n" + trimmedPinned
    }

    /// Verify and repair in one pass.
    public static func certify(
        summary: String,
        from turns: [AgentTurn],
        budget: ContextBudget
    ) -> String {
        let anchors = extractAnchors(from: turns)
        guard !anchors.isEmpty else { return truncate(summary, to: budget.maxChars) }
        let check = verify(summary: summary, anchors: anchors)
        let body = check.passed ? summary : repair(summary: summary, missing: check.missing, budget: budget)
        return truncate(body, to: budget.maxChars)
    }

    // MARK: - Matching heuristics

    private static func matches(_ anchor: Anchor, in haystack: String) -> Bool {
        let needle = anchor.label.lowercased()
        if haystack.contains(needle) { return true }
        if anchor.kind == .file {
            let base = (anchor.label as NSString).lastPathComponent.lowercased()
            if !base.isEmpty, haystack.contains(base) { return true }
        }
        let tokens = tokenSet(needle).filter { $0.count >= 5 }
        guard !tokens.isEmpty else { return false }
        let hits = tokens.filter { haystack.contains($0) }.count
        return hits >= max(1, tokens.count / 2)
    }

    private static func filePaths(in text: String) -> [String] {
        let pattern = #"[A-Za-z0-9_./-]+\.(?:swift|md|json|py|ts|tsx|js|yml|yaml|plist|sh)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func rememberCue(in prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return lower.contains("remember") || lower.contains("don't forget") || lower.contains("do not forget")
    }

    private static func decisionPhrase(in text: String) -> String? {
        let markers = ["decided", "we will", "chosen", "constraint", "must not", "will use", "going with"]
        let lower = text.lowercased()
        guard markers.contains(where: { lower.contains($0) }) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }
}