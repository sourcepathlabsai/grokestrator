import Foundation
import GrokestratorCore

/// Local-embedding retrieval via an OpenAI-compatible `/embeddings` endpoint
/// (e.g. LM Studio + `nomic-embed-text`). Falls back to `KeywordRetriever`.
struct EmbeddingRetriever: ContextRetriever {
    private let keyword = KeywordRetriever()
    private let embedModel = "nomic-embed-text"

    func retrieve(
        query: String,
        from turns: [AgentTurn],
        options: RetrievalOptions
    ) async -> [RetrievedChunk] {
        let chunks = ContextChunker.chunks(from: turns, excludingRecentTail: options.recentTailTurns)
        guard !chunks.isEmpty else { return [] }

        if let embedded = await retrieveWithEmbeddings(query: query, chunks: chunks, options: options) {
            return embedded
        }
        return await keyword.retrieve(query: query, from: turns, options: options)
    }

    private func retrieveWithEmbeddings(
        query: String,
        chunks: [ContextChunker.Chunk],
        options: RetrievalOptions
    ) async -> [RetrievedChunk]? {
        let tierMap = ConnectionStore.loadTierMap()
        let catalog = ConnectionStore.loadBrainCatalog()
        let backend = tierMap.backend(for: tierMap.ref(for: .fast), catalog: catalog)

        guard case .openAICompatible(let baseURL, _, let apiKeyRef) = backend else { return nil }
        let key = apiKeyRef.flatMap { Secrets.value(for: $0) }
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + "/embeddings") else { return nil }

        let texts = [query] + chunks.map(\.text)
        let body: [String: Any] = ["model": embedModel, "input": texts]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 45
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else { return nil }

        let vectors: [[Double]] = rows
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            .compactMap { $0["embedding"] as? [Double] }
        guard vectors.count == texts.count, let queryVec = vectors.first else { return nil }

        let scored = zip(chunks, vectors.dropFirst()).map { chunk, vec -> RetrievedChunk in
            let score = cosine(queryVec, vec)
            return RetrievedChunk(turnIndex: chunk.turnIndex, text: chunk.text, score: score)
        }
        .sorted { $0.score > $1.score }

        return selectTop(scored, options: options)
    }

    private func selectTop(_ ranked: [RetrievedChunk], options: RetrievalOptions) -> [RetrievedChunk] {
        var picked: [RetrievedChunk] = []
        var used = 0
        for chunk in ranked {
            if picked.count >= options.maxChunks { break }
            let addition = chunk.text.count + (picked.isEmpty ? 0 : 2)
            if used + addition > options.maxChars, !picked.isEmpty { break }
            picked.append(chunk)
            used += addition
        }
        return picked
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}