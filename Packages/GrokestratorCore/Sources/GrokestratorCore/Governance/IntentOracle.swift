import Foundation

// MARK: - Verify-against-intent orientation oracle (design/13, #141)
//
// Shadow companion to the action oracle (`GovernanceEngine`): after a turn completes,
// check whether the agent's stated plan/answer plausibly honors active design invariants.
// Heuristic v0 — suspect findings escalate to the intent ledger; no enforcement yet.

public struct IntentFinding: Sendable, Hashable {
    public let invariantID: String
    public let severity: Severity
    public let confidence: Confidence
    public let note: String

    public init(invariantID: String, severity: Severity, confidence: Confidence = .suspect, note: String) {
        self.invariantID = invariantID
        self.severity = severity
        self.confidence = confidence
        self.note = note
    }
}

public struct IntentVerdict: Sendable {
    public let aligned: Bool
    public let findings: [IntentFinding]
    public let rationale: String

    public init(aligned: Bool, findings: [IntentFinding], rationale: String) {
        self.aligned = aligned
        self.findings = findings
        self.rationale = rationale
    }

    public var summary: String {
        aligned
            ? "ALIGNED — \(rationale)"
            : "CONTRADICTION — \(rationale)"
    }
}

public enum IntentOracle {
    /// Evaluate an agent turn's narrative output against the project's active invariants.
    public static func evaluate(
        changeText: String,
        userPrompt: String,
        corpus: Corpus,
        workingDirectory: String?
    ) -> IntentVerdict {
        let haystack = (userPrompt + "\n" + changeText).lowercased()
        guard !haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return IntentVerdict(aligned: true, findings: [], rationale: "empty change text")
        }

        var findings: [IntentFinding] = []
        let active = corpus.invariants.filter { $0.state == .active }

        for inv in active {
            if let finding = checkInvariant(inv, haystack: haystack, workingDirectory: workingDirectory) {
                findings.append(finding)
            }
        }

        if findings.isEmpty {
            return IntentVerdict(aligned: true, findings: [], rationale: "no invariant contradictions detected")
        }

        let ids = findings.map(\.invariantID).joined(separator: ", ")
        return IntentVerdict(
            aligned: false,
            findings: findings,
            rationale: "possible conflicts with \(ids)"
        )
    }

    // MARK: - Per-invariant heuristics

    private static func checkInvariant(
        _ inv: Invariant,
        haystack: String,
        workingDirectory: String?
    ) -> IntentFinding? {
        switch inv.id {
        case "INV-no-destructive-shell":
            return destructiveShellConflict(inv, haystack: haystack)
        case "INV-cwd-confinement":
            return cwdConflict(inv, haystack: haystack, workingDirectory: workingDirectory)
        case "INV-external-comms-reviewed":
            return externalCommsConflict(inv, haystack: haystack)
        default:
            return genericConflict(inv, haystack: haystack)
        }
    }

    private static func destructiveShellConflict(_ inv: Invariant, haystack: String) -> IntentFinding? {
        let destructive = [#"rm\s+-rf"#, #"mkfs\."#, #"\bdd\s+if="#, #"git\s+push\s+--force"#, #"drop\s+table"#, #"truncate\s+table"#]
        guard destructive.contains(where: { haystack.range(of: $0, options: .regularExpression) != nil }) else {
            return nil
        }
        let mitigated = ["confirm", "review", "ask", "human", "approval", "backup", "dry-run", "dry run"]
        if mitigated.contains(where: { haystack.contains($0) }) { return nil }
        return IntentFinding(
            invariantID: inv.id,
            severity: inv.severity,
            note: "plan mentions irreversible destruction without human confirmation cues"
        )
    }

    private static func cwdConflict(
        _ inv: Invariant,
        haystack: String,
        workingDirectory: String?
    ) -> IntentFinding? {
        guard let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return nil
        }
        let normalizedCWD = (cwd as NSString).standardizingPath
        // Absolute paths that clearly sit outside the node's working directory.
        let outside = #"(\/(?:etc|usr|var|tmp|opt|Applications|Library)(?:\/[^\s\"']+)?)"#
        if let re = try? NSRegularExpression(pattern: outside) {
            let range = NSRange(haystack.startIndex..., in: haystack)
            for m in re.matches(in: haystack, range: range) {
                guard let r = Range(m.range(at: 1), in: haystack) else { continue }
                let path = String(haystack[r])
                let normalized = (path as NSString).standardizingPath
                if !normalized.hasPrefix(normalizedCWD) {
                    return IntentFinding(
                        invariantID: inv.id,
                        severity: inv.severity,
                        note: "plan references path outside working directory: \(path.prefix(80))"
                    )
                }
            }
        }
        if haystack.contains("../") {
            return IntentFinding(
                invariantID: inv.id,
                severity: inv.severity,
                note: "plan references parent-directory escape (../)"
            )
        }
        return nil
    }

    private static func externalCommsConflict(_ inv: Invariant, haystack: String) -> IntentFinding? {
        let outbound = ["send email", "post to", "publish", "tweet", "slack message", "notify user", "mailgun", "smtp"]
        guard outbound.contains(where: { haystack.contains($0) }) else { return nil }
        let reviewed = ["review", "human", "approve", "draft only", "await", "confirm before send"]
        if reviewed.contains(where: { haystack.contains($0) }) { return nil }
        return IntentFinding(
            invariantID: inv.id,
            severity: inv.severity,
            note: "plan describes external communication without human-review cues"
        )
    }

    private static func genericConflict(_ inv: Invariant, haystack: String) -> IntentFinding? {
        let statement = inv.statement.lowercased()
        let negationMarkers = ["must not", "never", "without human", "without confirmation", "refusing"]
        guard negationMarkers.contains(where: { statement.contains($0) }) else { return nil }

        let verbs = ["will ", "going to ", "plan to ", "i'll ", "we'll ", "implement ", "execute "]
        guard verbs.contains(where: { haystack.contains($0) }) else { return nil }

        let tokens = tokenSet(statement).filter { $0.count >= 5 }
        let hits = tokens.filter { haystack.contains($0) }
        guard hits.count >= max(2, tokens.count / 3) else { return nil }

        return IntentFinding(
            invariantID: inv.id,
            severity: inv.severity,
            note: "plan language overlaps a negated invariant statement"
        )
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
    }
}