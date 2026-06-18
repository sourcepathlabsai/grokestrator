import Foundation

// MARK: - Loading the project-owned design oracle (design/13, design/oracle/README.md)
//
// The oracle lives in the GOVERNED project's repo (`<project>/design/oracle/`), NOT in this
// app — so it survives swapping brains and is consumable outside Grokestrator. Per the
// "No Cognitive Gap" principle, the on-disk form is human-first markdown+frontmatter that a
// person and an agent read, edit, and act on identically; this loader is just the machine
// side reading the same shared artifact.

/// One named regex rule from an invariant's `## Detect` section. Named so the human reads the
/// intent and the machine reads the pattern from the same line.
public struct DetectRule: Sendable, Equatable {
    public let name: String
    public let pattern: String
}

/// A portable high-recall detector built from an invariant's `## Detect` rules — runnable by
/// ANY runtime straight from the repo (the ~80%). A match → suspect (escalate), never a block.
public struct RegexDetector: Detector {
    public let id: String
    public let invariantID: String
    public let minimumFidelity: ProposedAction.Fidelity = .semiStructured
    let severity: Severity
    let rules: [DetectRule]
    init(invariantID: String, severity: Severity, rules: [DetectRule]) {
        self.id = "DET-inline-\(invariantID)"
        self.invariantID = invariantID
        self.severity = severity
        self.rules = rules
    }
    public func examine(_ action: ProposedAction) -> [Finding] {
        let haystack = action.arguments?["command"] ?? action.payloadText ?? ""
        guard !haystack.isEmpty else { return [] }
        return rules.compactMap { rule in
            guard haystack.range(of: rule.pattern, options: .regularExpression) != nil else { return nil }
            return Finding(detector: id, invariantID: invariantID, confidence: .suspect,
                           severity: severity, trips: true,
                           note: "matched '\(rule.name)' in: \(haystack.prefix(120))")
        }
    }
}

public enum OracleLoader {
    /// Named precise detectors this runtime implements, keyed by the ID an invariant's
    /// frontmatter `detector:` references (the precise ~10–20%). Portable `## Detect`
    /// detectors are built from the files themselves.
    static let detectorRegistry: [String: any Detector] = [
        PathEscapeDetector.detectorID: PathEscapeDetector(),
        DestructiveShellDetector.detectorID: DestructiveShellDetector(),
    ]

    /// Build the runtime corpus for a project: its `design/oracle/` invariants merged over the
    /// built-in universal baseline classifications. Missing dir ⇒ baseline only (graceful).
    /// Pure file IO; safe on session start.
    public static func loadCorpus(projectDirectory: String) -> Corpus {
        let invDir = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent("design/oracle/invariants")
        let parsed = loadInvariants(fromDirectory: invDir)
        let invariants = parsed.map(\.invariant)
        let inlineDetectors = parsed.compactMap(\.detector)
        let namedIDs = Set(invariants.compactMap(\.detectorID))
        let named = namedIDs.compactMap { detectorRegistry[$0] }
        return Corpus(invariants: invariants,
                      classifications: Corpus.baselineClassifications,
                      detectors: inlineDetectors + named)
    }

    /// Parse every `*.md` invariant in a directory (sorted = stable order). Unreadable or
    /// malformed files are skipped, never crash the load.
    public static func loadInvariants(fromDirectory dir: URL) -> [(invariant: Invariant, detector: (any Detector)?)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return parseInvariant(markdown: text)
        }
    }

    /// Parse one invariant markdown file → (Invariant, optional portable detector). Pure
    /// string→struct, so it unit-tests without the filesystem. nil if there's no `id`.
    public static func parseInvariant(markdown: String) -> (invariant: Invariant, detector: (any Detector)?)? {
        let (fm, body) = splitFrontmatter(markdown)
        guard let id = fm["id"], !id.isEmpty else { return nil }
        let severity = Severity(name: fm["severity"]) ?? .medium
        let state = Invariant.State(rawValue: fm["state"] ?? "active") ?? .active
        let (statement, rationale) = splitStatement(body)
        let inv = Invariant(id: id, statement: statement, rationale: rationale,
                            detectorID: fm["detector"], severity: severity, state: state,
                            provenance: "design/oracle")
        let rules = parseDetectSection(body)
        let detector: (any Detector)? = rules.isEmpty ? nil
            : RegexDetector(invariantID: id, severity: severity, rules: rules)
        return (inv, detector)
    }

    // MARK: - Lightweight parsing (no external deps; tolerant of hand edits)

    /// Split `---`-delimited YAML-ish frontmatter (flat `key: value` scalars) from the body.
    static func splitFrontmatter(_ text: String) -> (frontmatter: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        var fm: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")), val.count >= 2 {
                    val = String(val.dropFirst().dropLast())
                }
                if !key.isEmpty { fm[key] = val }
            }
            i += 1
        }
        let body = i + 1 <= lines.count ? lines[(min(i + 1, lines.count))...].joined(separator: "\n") : ""
        return (fm, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// First paragraph (up to a blank line) = statement; following prose up to the first `##`
    /// heading = rationale.
    static func splitStatement(_ body: String) -> (statement: String, rationale: String) {
        let upToHeading = body.components(separatedBy: "\n## ").first ?? body
        let paras = upToHeading.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let statement = (paras.first ?? "").replacingOccurrences(of: "\n", with: " ")
        let rationale = paras.dropFirst().joined(separator: "\n\n")
        return (statement, rationale)
    }

    /// Parse a `## Detect` section's `- name: \`regex\`` bullets into named rules. Splitting on
    /// the backtick (not the colon) keeps regexes that contain `:` intact.
    static func parseDetectSection(_ body: String) -> [DetectRule] {
        guard let detectStart = rangeOfDetectHeading(body) else { return [] }
        // The section runs from the heading to the next `## ` (or EOF).
        let after = body[detectStart.upperBound...]
        let section = after.components(separatedBy: "\n## ").first ?? String(after)
        var rules: [DetectRule] = []
        for raw in section.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- "), let open = line.firstIndex(of: "`") else { continue }
            let afterOpen = line.index(after: open)
            guard let close = line[afterOpen...].firstIndex(of: "`") else { continue }
            let pattern = String(line[afterOpen..<close])
            var name = String(line[line.index(line.startIndex, offsetBy: 2)..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix(":") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
            if !pattern.isEmpty { rules.append(DetectRule(name: name.isEmpty ? "rule" : name, pattern: pattern)) }
        }
        return rules
    }

    /// Range of the line that opens a `## Detect…` section (nil if none).
    private static func rangeOfDetectHeading(_ body: String) -> Range<String.Index>? {
        for marker in ["## Detect", "##Detect"] {
            if let r = body.range(of: marker) { return r }
        }
        return nil
    }
}

extension Severity {
    /// Parse a frontmatter severity name (case-insensitive); nil if unrecognized.
    init?(name: String?) {
        switch name?.lowercased() {
        case "info": self = .info
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "critical": self = .critical
        default: return nil
        }
    }
}
