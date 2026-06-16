import Foundation
import GrokestratorCore

/// Host-local secret store for model-agnostic backends. A Node's `AgentBackend`
/// stores only an `apiKeyRef` (the *name* of a key, e.g. `GROQ_API_KEY`) — never the
/// secret itself. The value is resolved from, in order: the process environment,
/// then a gitignored **`.env.local_llm`** file in the app-support dir
/// (`~/Library/Application Support/Grokestrator/.env.local_llm`).
///
/// The app **owns** this file: it's created (with a commented template) on first
/// launch, and updated in-app when a user enters a key for an OpenAI-compatible
/// brain — so keys can be managed without hand-editing. Keys live only on this
/// machine, are written `0600`, and are never put in `connections.json` or git.
/// See `design/12-model-agnostic-runtime.md`.
public enum Secrets {
    /// The common key names offered in the first-run template (one per provider
    /// preset). Editable; users can add any name an `apiKeyRef` points at.
    public static let knownKeyNames = [
        "GROQ_API_KEY", "CEREBRAS_API_KEY", "GEMINI_API_KEY", "GROK_API_KEY", "OPENAI_API_KEY",
    ]

    /// Resolve a key by name. Process env wins; falls back to the local file.
    public static func value(for name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        lock.lock(); defer { lock.unlock() }
        return store[name]
    }

    /// Whether a non-empty value is resolvable for `name` (env or file).
    public static func hasValue(for name: String) -> Bool {
        (value(for: name)?.isEmpty == false)
    }

    /// Set (or replace) a host-local secret: upserts `name=value` into
    /// `.env.local_llm`, preserving every other line/comment, creating the file with
    /// a template + `0600` perms if absent, then refreshes the in-memory cache.
    /// Returns false only if the write fails. The value is trimmed; an empty value
    /// removes nothing (use the file directly to delete a key).
    @discardableResult
    public static func set(_ value: String, for name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespaces)
        let val = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !val.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }

        let existing = (try? String(contentsOf: envFileURL, encoding: .utf8)) ?? Self.template
        var lines = existing.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq].trimmingCharacters(in: .whitespaces) == key {
                lines[i] = "\(key)=\(val)"
                replaced = true
                break
            }
        }
        if !replaced {
            if let last = lines.last, !last.isEmpty { lines.append("") }  // keep a trailing newline tidy
            lines.append("\(key)=\(val)")
        }
        let text = lines.joined(separator: "\n")
        guard writeProtected(text) else { return false }
        store = parse(text)
        return true
    }

    /// Create `.env.local_llm` with a commented template if it doesn't exist yet.
    /// Idempotent — safe to call on every launch. Never overwrites an existing file.
    public static func ensureTemplateExists() {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: envFileURL.path) else { return }
        _ = writeProtected(Self.template)
    }

    /// The host-local config file path (gitignored; lives outside any repo).
    public static var envFileURL: URL {
        ConnectionStore.supportDir.appendingPathComponent(".env.local_llm")
    }

    // MARK: - Internals

    private static let lock = NSLock()
    private nonisolated(unsafe) static var store: [String: String] = load()

    /// Commented first-run scaffold listing the expected key names.
    private static var template: String {
        var t = """
        # Grokestrator host-local secrets (gitignored — never committed).
        # One KEY=VALUE per line. Keys back the OpenAI-compatible "brains" you add
        # in the app; Grokestrator updates this file when you enter a key there.
        # Fill in (or let the app fill in) the providers you use:

        """
        for name in knownKeyNames { t += "# \(name)=\n" }
        return t
    }

    /// Write `text` to the env file with `0600` perms (owner read/write only).
    /// Caller holds `lock`.
    private static func writeProtected(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            try data.write(to: envFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFileURL.path)
            return true
        } catch {
            return false
        }
    }

    private static func load() -> [String: String] {
        guard let text = try? String(contentsOf: envFileURL, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// Parse `.env.local_llm` (KEY=VALUE lines; `#` comments and blanks ignored;
    /// surrounding quotes stripped).
    private static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { out[String(key)] = String(val) }
        }
        return out
    }
}
