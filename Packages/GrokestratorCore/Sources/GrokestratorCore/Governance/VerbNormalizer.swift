import Foundation

// MARK: - Harness verb normalization (design/12, design/13, #154)
//
// Grokestrator is the harness for API brains (Cerebras, Groq, Gemini, …) and the
// mediation layer for ACP agents (grok, Claude Code, custom). Every intercepted
// action is normalized into one **canonical verb vocabulary** before it becomes a
// `ProposedAction` and hits the governance corpus key index.
//
// Two boundaries, one vocabulary:
//  • **API tool loop** — we own tool names (`read_file`, `run_command`, …).
//  • **ACP permission** — vendor adapters differ; per-`ACPAdapter` inference.

/// Normalizes raw boundary-specific identifiers into the shared governance verb set.
public enum VerbNormalizer: Sendable {

    /// Canonical verbs referenced by `Corpus.baselineClassifications` and extended in
    /// `design/oracle/`. Unclassified verbs (e.g. `fetch`, `think`, unknown tool names)
    /// fail closed through the corpus key index.
    public enum Verb: String, Sendable {
        case fsRead = "fs.read"
        case fsList = "fs.list"
        case fsWrite = "fs.write"
        case shell = "shell"
        case delegate = "delegate"
        case mcpCall = "mcp.call"
        case fetch = "fetch"
        case think = "think"
        case unknown = "unknown"
    }

    /// Which ACP adapter produced a permission payload — selects inference strategy.
    public enum ACPAdapter: String, Sendable {
        /// grok-native: standard ACP `ToolKind` on `toolCall.kind`.
        case grok
        /// `@zed-industries/claude-code-acp`: omits `kind`; title + tool `rawInput`.
        case claudeCodeACP
        /// Unknown/custom agent: try standard kind, then shared title heuristics.
        case generic
    }

    // MARK: API tool loop (Grokestrator-owned harness)

    /// Map a tool name from `OpenAICompatSession.executeTool` / our tool registry.
    public static func fromAPIToolName(_ name: String) -> String {
        APIToolVerbMap.normalize(name)
    }

    // MARK: ACP permission boundary

    /// Map an ACP `session/request_permission` payload using the adapter strategy.
    public static func fromACPPermission(kind: String?, variant: String?, command: String?,
                                           title: String?, adapter: ACPAdapter) -> String {
        switch adapter {
        case .grok:
            return ACPStandardVerbMap.normalize(kind: kind, variant: variant,
                                                command: command, title: title,
                                                titleInference: false)
        case .claudeCodeACP:
            return ClaudeACPVerbMap.normalize(kind: kind, variant: variant,
                                              command: command, title: title)
        case .generic:
            return ACPStandardVerbMap.normalize(kind: kind, variant: variant,
                                                command: command, title: title,
                                                titleInference: true)
        }
    }

    /// Pick an ACP adapter from the agent's stable display name (`initialize` agentInfo).
    public static func inferACPAdapter(agentName: String?) -> ACPAdapter {
        guard let raw = agentName?.lowercased() else { return .generic }
        if raw.contains("claude") { return .claudeCodeACP }
        if raw.contains("grok") { return .grok }
        return .generic
    }
}

// MARK: - API tool name table (source of truth for API brains)

private enum APIToolVerbMap {
    static func normalize(_ name: String) -> String {
        switch name {
        case "read_file":    return VerbNormalizer.Verb.fsRead.rawValue
        case "list_dir":     return VerbNormalizer.Verb.fsList.rawValue
        case "write_file":   return VerbNormalizer.Verb.fsWrite.rawValue
        case "run_command":  return VerbNormalizer.Verb.shell.rawValue
        case "delegate":     return VerbNormalizer.Verb.delegate.rawValue
        case let n where n.hasPrefix("mcp__"): return VerbNormalizer.Verb.mcpCall.rawValue
        default:             return name
        }
    }
}

// MARK: - ACP standard ToolKind (ACP spec + grok)

private enum ACPStandardVerbMap {
    static func normalize(kind: String?, variant: String?, command: String?, title: String?,
                          titleInference: Bool) -> String {
        if let v = variant?.lowercased() {
            if v.contains("bash") || v.contains("shell") || v.contains("command") {
                return VerbNormalizer.Verb.shell.rawValue
            }
        }
        if let k = kind?.lowercased(), let mapped = mapToolKind(k) {
            return mapped
        }
        if titleInference, let verb = ACPTitleHeuristics.infer(title) { return verb }
        if let k = kind?.lowercased(), k != "other" { return k }
        return VerbNormalizer.Verb.unknown.rawValue
    }

    static func mapToolKind(_ kind: String) -> String? {
        switch kind {
        case "read":                          return VerbNormalizer.Verb.fsRead.rawValue
        case "search":                          return VerbNormalizer.Verb.fsList.rawValue
        case "fetch":                           return VerbNormalizer.Verb.fetch.rawValue
        case "edit", "move":                    return VerbNormalizer.Verb.fsWrite.rawValue
        case "execute", "delete":               return VerbNormalizer.Verb.shell.rawValue
        case "think", "other", "switch_mode":   return nil
        default:                                return nil
        }
    }
}

// MARK: - Claude Code adapter (`claude-code-acp` title patterns)

private enum ClaudeACPVerbMap {
    static func normalize(kind: String?, variant: String?, command: String?, title: String?) -> String {
        if let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
            return VerbNormalizer.Verb.shell.rawValue
        }
        if let verb = ACPTitleHeuristics.infer(title) { return verb }
        if let k = kind?.lowercased(), let mapped = ACPStandardVerbMap.mapToolKind(k) {
            return mapped
        }
        return VerbNormalizer.Verb.unknown.rawValue
    }
}

// MARK: - Shared title heuristics (Claude `toolInfoFromToolUse` + generic fallback)

private enum ACPTitleHeuristics {
    static func infer(_ title: String?) -> String? {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if raw.hasPrefix("`"), raw.hasSuffix("`"), raw.count > 2 {
            return VerbNormalizer.Verb.shell.rawValue
        }
        if lower.hasPrefix("read ") || lower == "read file" || lower.hasPrefix("read notebook") {
            return VerbNormalizer.Verb.fsRead.rawValue
        }
        if lower.hasPrefix("edit ") || lower.hasPrefix("edit `") { return VerbNormalizer.Verb.fsWrite.rawValue }
        if lower.hasPrefix("write ") { return VerbNormalizer.Verb.fsWrite.rawValue }
        if lower.hasPrefix("list the ") { return VerbNormalizer.Verb.fsList.rawValue }
        if lower.hasPrefix("find ") || lower.hasPrefix("grep") { return VerbNormalizer.Verb.fsList.rawValue }
        if lower.hasPrefix("fetch ") { return VerbNormalizer.Verb.fetch.rawValue }
        if lower == "terminal" || lower == "tail logs" || lower.hasPrefix("kill process") {
            return VerbNormalizer.Verb.shell.rawValue
        }
        if lower.hasPrefix("update todos") || lower == "ready to code?" {
            return VerbNormalizer.Verb.think.rawValue
        }
        return nil
    }
}