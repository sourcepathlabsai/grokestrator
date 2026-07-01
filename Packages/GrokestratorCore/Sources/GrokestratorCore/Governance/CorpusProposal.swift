import Foundation

// MARK: - Agent-proposed corpus maintenance (design/13, #142)

/// A human-curated draft update to the project's design oracle or `design/` docs.
public struct CorpusProposal: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case approved
        case rejected
    }

    public let id: UUID
    public let createdAt: Date
    public var status: Status
    public let nodeID: UUID?
    public let nodeName: String?
    public let projectDirectory: String
    /// Repo-relative path, e.g. `design/oracle/invariants/INV-example.md`.
    public let targetPath: String
    public let markdown: String
    public let rationale: String
    public var reviewedAt: Date?
    public var reviewNote: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: Status = .pending,
        nodeID: UUID?,
        nodeName: String?,
        projectDirectory: String,
        targetPath: String,
        markdown: String,
        rationale: String,
        reviewedAt: Date? = nil,
        reviewNote: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.projectDirectory = projectDirectory
        self.targetPath = targetPath
        self.markdown = markdown
        self.rationale = rationale
        self.reviewedAt = reviewedAt
        self.reviewNote = reviewNote
    }

    /// Normalize and validate a repo-relative target path.
    public static func sanitizeTargetPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard path.hasPrefix("design/"), !path.contains("..") else { return nil }
        guard path.hasSuffix(".md") else { return nil }
        return path
    }

    /// Staged file path written on human approval (never overwrites canonical oracle directly).
    public var stagedFileURL: URL {
        let base = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent("design/oracle/proposed", isDirectory: true)
        let name = "\(id.uuidString.prefix(8))-\((targetPath as NSString).lastPathComponent)"
        return base.appendingPathComponent(name)
    }
}

/// Parse `[[CORPUS_PROPOSAL ...]]` blocks agents emit in assistant text.
public enum CorpusProposalParser {
    public struct Draft: Sendable, Hashable {
        public let targetPath: String
        public let rationale: String
        public let markdown: String

        public init(targetPath: String, rationale: String, markdown: String) {
            self.targetPath = targetPath
            self.rationale = rationale
            self.markdown = markdown
        }
    }

    /// Extract zero or more proposal drafts from assistant output.
    public static func parse(_ text: String) -> [Draft] {
        guard let re = try? NSRegularExpression(
            pattern: #"\[\[\s*CORPUS_PROPOSAL\s*(.*?)\]\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let ns = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: ns).compactMap { match in
            guard let bodyRange = Range(match.range(at: 1), in: text) else { return nil }
            return parseBlock(String(text[bodyRange]))
        }
    }

    private static func parseBlock(_ block: String) -> Draft? {
        let parts = block.components(separatedBy: "\n---\n")
        guard parts.count >= 2 else { return nil }
        let header = parts[0]
        let markdown = parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }

        var target: String?
        var rationale = ""
        for line in header.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("target:") {
                target = String(trimmed.dropFirst("target:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("rationale:") {
                rationale = String(trimmed.dropFirst("rationale:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let target, let path = CorpusProposal.sanitizeTargetPath(target) else { return nil }
        return Draft(targetPath: path, rationale: rationale, markdown: markdown)
    }
}