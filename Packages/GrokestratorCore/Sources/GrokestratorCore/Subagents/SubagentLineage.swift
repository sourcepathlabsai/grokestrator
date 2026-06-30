import Foundation

/// One harness subagent spawned by grok's `task` tool, read from on-disk lineage
/// (`~/.grok/sessions/<cwd>/<session>/subagents/<id>/meta.json`). See `design/10` rung 1.
public struct SubagentLineageEntry: Sendable, Identifiable, Equatable {
    public let subagentID: String
    public let subagentType: String
    public let description: String
    public let status: String?

    public var id: String { subagentID }

    public init(subagentID: String, subagentType: String, description: String, status: String? = nil) {
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.description = description
        self.status = status
    }
}

/// Reads grok's on-disk subagent lineage for a parent session.
public enum SubagentLineageReader {
    private struct MetaJSON: Decodable {
        let subagent_id: String?
        let subagent_type: String?
        let description: String?
        let status: String?
    }

    /// URL-encodes a cwd the way grok stores session folders.
    public static func encodedCWD(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return expanded.addingPercentEncoding(withAllowedCharacters: allowed) ?? expanded
    }

    public static func subagentsDirectory(workingDirectory: String, sessionID: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwdKey = encodedCWD(workingDirectory)
        return home
            .appendingPathComponent(".grok/sessions/\(cwdKey)/\(sessionID)/subagents", isDirectory: true)
    }

    /// Lists subagent entries for a parent session, newest directories first.
    public static func readEntries(workingDirectory: String, sessionID: String) -> [SubagentLineageEntry] {
        let dir = subagentsDirectory(workingDirectory: workingDirectory, sessionID: sessionID)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        let sorted = children.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

        return sorted.compactMap { childDir in
            let metaURL = childDir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(MetaJSON.self, from: data) else { return nil }
            let id = meta.subagent_id ?? childDir.lastPathComponent
            let type = meta.subagent_type ?? "subagent"
            let desc = meta.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
            return SubagentLineageEntry(subagentID: id, subagentType: type, description: desc, status: meta.status)
        }
    }

    /// Formats a `task` tool call for the activity transcript.
    public static func formatTaskDelegation(arguments: [String: String]?) -> String {
        let args = arguments ?? [:]
        let type = args["subagent_type"] ?? args["subagentType"] ?? args["type"] ?? "subagent"
        let desc = args["description"] ?? args["prompt"] ?? args["task"] ?? args["message"] ?? ""
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.isEmpty ? type : String(trimmed.prefix(80))
        return "\(icon(for: type)) \(roleLabel(for: type)) — \(preview)"
    }

    /// Formats a lineage entry after the subagent completes.
    public static func formatLineageEntry(_ entry: SubagentLineageEntry) -> String {
        let status = entry.status.map { " (\($0))" } ?? ""
        return "  \(icon(for: entry.subagentType)) \(roleLabel(for: entry.subagentType)) — \(entry.description)\(status)"
    }

    public static func icon(for subagentType: String) -> String {
        switch subagentType.lowercased() {
        case "explore", "researcher": return "🔍"
        case "plan", "architect", "design-doc-writer": return "🏛"
        case "implementer", "coder", "general-purpose": return "⌨"
        case "reviewer", "code-reviewer": return "✓"
        default: return "▸"
        }
    }

    public static func roleLabel(for subagentType: String) -> String {
        switch subagentType.lowercased() {
        case "general-purpose": return "helper"
        case "design-doc-writer": return "architect"
        default: return subagentType
        }
    }
}