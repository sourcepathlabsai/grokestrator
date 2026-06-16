import Foundation
import GrokestratorCore

/// Fetches the available model IDs from an OpenAI-compatible provider's
/// `GET {baseURL}/models` endpoint, so the brain catalog can offer a live,
/// never-stale model list instead of hardcoded guesses. The key is resolved
/// host-locally by name (`Secrets`); it never leaves this machine.
enum BrainModelList {
    enum FetchError: LocalizedError {
        case badURL
        case http(Int, String)
        case decode

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid base URL."
            case .http(let code, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return "HTTP \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            case .decode: return "Couldn't read the model list from the response."
            }
        }
    }

    /// Resolve the key for `apiKeyRef` (if any) and list models at `baseURL`.
    static func fetch(baseURL: String, apiKeyRef: String?) async throws -> [String] {
        let key = apiKeyRef.flatMap { $0.isEmpty ? nil : Secrets.value(for: $0) }
        return try await fetch(baseURL: baseURL, apiKey: key)
    }

    static func fetch(baseURL: String, apiKey: String?) async throws -> [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed.hasSuffix("/") ? "\(trimmed)models" : "\(trimmed)/models")
        else { throw FetchError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // OpenAI shape: { "data": [ { "id": "..." }, ... ] }
        struct ModelsResponse: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw FetchError.decode
        }
        return decoded.data.map(\.id).sorted()
    }
}
