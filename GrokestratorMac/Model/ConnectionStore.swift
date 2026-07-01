import Foundation
import GrokestratorCore

/// On-disk registry of every Connection this Mac has ever created
/// (active + archived). GKSS loads it on boot and writes on every mutation —
/// add, edit, archive, restore, delete-permanently.
///
/// **Layout** (per `connection-semantics` memory):
/// ```
/// ~/Library/Application Support/Grokestrator/
///   connections.json                                    ← this file (the registry)
///   connections/<connectionID>/history.json             ← per-Connection transcript
/// ```
/// Existing `conversations/<id>.json` files (the legacy history location) are
/// migrated lazily on first read so users don't lose prior transcripts.
public enum ConnectionStore {
    // MARK: - Paths (nonisolated — pure path math + filesystem ops, thread-safe)

    public static var supportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grokestrator", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static var registryURL: URL { supportDir.appendingPathComponent("connections.json") }

    /// Per-Connection directory: `~/Library/Application Support/Grokestrator/connections/<id>/`.
    public static func connectionDir(for id: UUID) -> URL {
        let dir = supportDir.appendingPathComponent("connections", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func historyURL(for id: UUID) -> URL {
        let url = connectionDir(for: id).appendingPathComponent("history.json")
        migrateLegacyHistoryIfNeeded(id: id, into: url)
        return url
    }

    /// Load persisted transcript turns for a Connection (empty when absent).
    public static func loadHistoryTurns(for id: UUID) -> [AgentTurn] {
        let url = historyURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let turns = try? JSONDecoder().decode([AgentTurn].self, from: data) else {
            return []
        }
        return turns
    }

    /// Append a marker turn to on-disk history (e.g. role transition on a stopped Node).
    public static func appendMarkerToHistory(for id: UUID, prompt: String) {
        var turns = loadHistoryTurns(for: id)
        turns.append(AgentTurn(userPrompt: prompt, messages: []))
        let url = historyURL(for: id)
        guard let data = try? JSONEncoder().encode(turns) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func pendingSessionGistURL(for id: UUID) -> URL {
        connectionDir(for: id).appendingPathComponent("pending-session-gist.txt")
    }

    /// Persist a gist preamble to inject on the next conversation handshake.
    public static func savePendingSessionGist(_ gist: String, for id: UUID) {
        let trimmed = gist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearPendingSessionGist(for: id)
            return
        }
        try? trimmed.write(to: pendingSessionGistURL(for: id), atomically: true, encoding: .utf8)
    }

    public static func clearPendingSessionGist(for id: UUID) {
        try? FileManager.default.removeItem(at: pendingSessionGistURL(for: id))
    }

    /// Load and delete the pending gist (one-time consumption).
    public static func consumePendingSessionGist(for id: UUID) -> String? {
        let url = pendingSessionGistURL(for: id)
        guard let gist = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let trimmed = gist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One-shot migration of any file at the legacy `conversations/<id>.json`
    /// path to the new `connections/<id>/history.json` location. Skips if the
    /// new location already has a file.
    private static func migrateLegacyHistoryIfNeeded(id: UUID, into newURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newURL.path) else { return }
        let legacy = supportDir
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: newURL)
    }

    // MARK: - Registry I/O

    public static func load() -> [ManagedConnection] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ManagedConnection].self, from: data)) ?? []
    }

    public static func save(_ connections: [ManagedConnection]) {
        // Strip runtime fields before persisting — only the config survives a boot.
        let sanitized = connections.map { conn -> ManagedConnection in
            var c = conn
            c.status = .stopped
            c.lastExitCode = nil
            c.pid = nil
            return c
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sanitized) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    // MARK: - Brain catalog I/O

    /// Host-local library of named brains (gitignored; machine config). Holds model
    /// + key *names* only — no secrets. Referenced by id from Nodes and the tier map.
    public static var brainCatalogURL: URL { supportDir.appendingPathComponent("brains.json") }

    /// The brain catalog, or an empty one if absent/unreadable.
    public static func loadBrainCatalog() -> BrainCatalog {
        guard let data = try? Data(contentsOf: brainCatalogURL),
              let catalog = try? JSONDecoder().decode(BrainCatalog.self, from: data) else {
            return BrainCatalog()
        }
        return catalog
    }

    public static func saveBrainCatalog(_ catalog: BrainCatalog) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(catalog) else { return }
        try? data.write(to: brainCatalogURL, options: .atomic)
    }

    // MARK: - MCP server registry I/O

    /// Host-local MCP server registry (machine config; lives in the support dir, so
    /// outside any repo). The harness owns it — one source of truth for grok and API
    /// brains alike. May hold env values for stdio servers, so it stays host-local.
    public static var mcpRegistryURL: URL { supportDir.appendingPathComponent("mcp.json") }

    public static func loadMCPRegistry() -> MCPRegistry {
        guard let data = try? Data(contentsOf: mcpRegistryURL),
              let registry = try? JSONDecoder().decode(MCPRegistry.self, from: data) else {
            return MCPRegistry()
        }
        return registry
    }

    public static func saveMCPRegistry(_ registry: MCPRegistry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(registry) else { return }
        try? data.write(to: mcpRegistryURL, options: .atomic)
    }

    // MARK: - Host tier map I/O

    /// Host-local `Tier → BrainRef` map (gitignored; machine config, not synced).
    public static var tierMapURL: URL { supportDir.appendingPathComponent("tiermap.json") }

    /// The host tier map, or `.default` (every tier → grok) if absent/unreadable.
    public static func loadTierMap() -> HostTierMap {
        guard let data = try? Data(contentsOf: tierMapURL),
              let map = try? JSONDecoder().decode(HostTierMap.self, from: data) else {
            return .default
        }
        return map
    }

    public static func saveTierMap(_ map: HostTierMap) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: tierMapURL, options: .atomic)
    }

    // MARK: - Team template registry I/O

    /// Host-local custom fleet team templates (machine config; gitignored).
    public static var teamTemplatesURL: URL { supportDir.appendingPathComponent("team-templates.json") }

    public static func loadTeamTemplates() -> TeamTemplateRegistry {
        guard let data = try? Data(contentsOf: teamTemplatesURL),
              let registry = try? JSONDecoder().decode(TeamTemplateRegistry.self, from: data) else {
            return TeamTemplateRegistry()
        }
        return registry
    }

    public static func saveTeamTemplates(_ registry: TeamTemplateRegistry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(registry) else { return }
        try? data.write(to: teamTemplatesURL, options: .atomic)
    }

    // MARK: - Harness template registry I/O

    /// Host-local custom ACP harness team templates (machine config; gitignored).
    public static var harnessTemplatesURL: URL { supportDir.appendingPathComponent("harness-templates.json") }

    public static func loadHarnessTemplates() -> HarnessTemplateRegistry {
        guard let data = try? Data(contentsOf: harnessTemplatesURL),
              let registry = try? JSONDecoder().decode(HarnessTemplateRegistry.self, from: data) else {
            return HarnessTemplateRegistry()
        }
        return registry
    }

    public static func saveHarnessTemplates(_ registry: HarnessTemplateRegistry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(registry) else { return }
        try? data.write(to: harnessTemplatesURL, options: .atomic)
    }

    /// Permanently deletes a Connection's history directory. Caller is
    /// responsible for removing the registry entry separately.
    public static func deleteHistoryDirectory(for id: UUID) {
        let dir = supportDir.appendingPathComponent("connections", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}
