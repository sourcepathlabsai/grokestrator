import Foundation
import GrokestratorCore

/// Tier-1 compaction via the host's configured `fast` tier (`design/12` Phase B′).
/// Falls back to deterministic `SessionGist.tier1` when the fast tier is grok or
/// the API call fails.
struct FastTierSummarizer: ContextSummarizer {
    func summarize(_ text: String, budget: ContextBudget) async throws -> String {
        let tierMap = ConnectionStore.loadTierMap()
        let catalog = ConnectionStore.loadBrainCatalog()
        let backend = tierMap.backend(for: tierMap.ref(for: .fast), catalog: catalog)

        switch backend {
        case .openAICompatible(let baseURL, let model, let apiKeyRef):
            let key = apiKeyRef.flatMap { Secrets.value(for: $0) }
            return try await Self.summarizeWithOpenAI(
                text: text,
                budget: budget,
                baseURL: baseURL,
                model: model,
                apiKey: key
            )
        default:
            throw FastTierSummarizerError.noAPIFastTier
        }
    }

    private enum FastTierSummarizerError: Error {
        case noAPIFastTier
        case badURL
        case httpError(Int, String)
        case badResponse
    }

    private static func summarizeWithOpenAI(
        text: String,
        budget: ContextBudget,
        baseURL: String,
        model: String,
        apiKey: String?
    ) async throws -> String {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            throw FastTierSummarizerError.badURL
        }

        let system = """
        You compress prior session context for a coding agent restart. Preserve: \
        goals, decisions, facts, files touched, state changes, open questions, and \
        anything the user asked to remember. Drop tool noise and chain-of-thought. \
        Output plain text only — no markdown fences. Stay under \(budget.maxChars) characters.
        """

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "Summarize this prior session context:\n\n\(text)"],
            ],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw FastTierSummarizerError.httpError(code, String(detail))
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw FastTierSummarizerError.badResponse
        }

        let summary = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw FastTierSummarizerError.badResponse }
        if summary.count > budget.maxChars {
            let end = summary.index(summary.startIndex, offsetBy: budget.maxChars)
            return String(summary[..<end]) + "…"
        }
        return summary
    }
}