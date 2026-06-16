import Foundation
import GrokestratorCore

/// Host-local secret resolution for model-agnostic backends. A Node's
/// `AgentBackend` stores only an `apiKeyRef` (the *name* of a key, e.g.
/// `GROQ_API_KEY`) — never the secret itself. The value is resolved at launch from,
/// in order: the process environment, then a gitignored **`.env.local_llm`** file in
/// the app-support dir (`~/Library/Application Support/Grokestrator/.env.local_llm`).
///
/// Keys live only on the host machine and are never written to `connections.json`
/// or committed to git. See `design/12-model-agnostic-runtime.md`.
public enum Secrets {
    /// Resolve a key by name. Process env wins; falls back to the local file.
    public static func value(for name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        return store[name]
    }

    /// Parsed `.env.local_llm` (KEY=VALUE lines; `#` comments and blanks ignored;
    /// surrounding quotes stripped). Loaded once.
    private static let store: [String: String] = load()

    /// The host-local config file path (gitignored; lives outside any repo).
    public static var envFileURL: URL {
        ConnectionStore.supportDir.appendingPathComponent(".env.local_llm")
    }

    private static func load() -> [String: String] {
        guard let text = try? String(contentsOf: envFileURL, encoding: .utf8) else { return [:] }
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
