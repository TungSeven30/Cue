import Foundation

/// One entry from OpenRouter's public model catalog.
struct OpenRouterModel: Identifiable, Hashable {
    /// The wire id ("qwen/qwen3.7-max"); prefix with "openrouter/" to select
    /// it as the app's translation model.
    let id: String
    let name: String
    /// USD per token, as OpenRouter reports them; nil when unpriced.
    let promptPricePerToken: Double?
    let completionPricePerToken: Double?

    /// Human-readable pricing in the per-1M-tokens unit every provider
    /// advertises, since "$0.0000012 per token" is unreadable.
    var priceLabel: String {
        guard let promptPricePerToken, let completionPricePerToken else {
            return "Pricing unavailable"
        }
        if promptPricePerToken == 0 && completionPricePerToken == 0 {
            return "Free"
        }
        let input = String(format: "$%.2f", promptPricePerToken * 1_000_000)
        let output = String(format: "$%.2f", completionPricePerToken * 1_000_000)
        return "\(input) in / \(output) out per 1M tokens"
    }
}

/// Fetches and parses OpenRouter's model list. The endpoint is public — no
/// API key needed to browse, only to run translations.
enum OpenRouterModelCatalog {
    static let listURL = URL(string: "https://openrouter.ai/api/v1/models")!

    private struct Envelope: Decodable {
        struct Entry: Decodable {
            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }

            let id: String?
            let name: String?
            let pricing: Pricing?
        }

        let data: [Entry]
    }

    /// Tolerant parse: entries missing an id or name are skipped rather than
    /// failing the whole catalog, since OpenRouter adds fields freely.
    static func parse(_ data: Data) throws -> [OpenRouterModel] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.data
            .compactMap { entry -> OpenRouterModel? in
                guard let id = entry.id, !id.isEmpty,
                    let name = entry.name, !name.isEmpty
                else { return nil }
                return OpenRouterModel(
                    id: id,
                    name: name,
                    promptPricePerToken: entry.pricing?.prompt.flatMap(Double.init),
                    completionPricePerToken: entry.pricing?.completion.flatMap(Double.init)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func fetch(httpClient: any HTTPClient = URLSessionHTTPClient()) async throws -> [OpenRouterModel] {
        var request = URLRequest(url: listURL)
        request.timeoutInterval = 30
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationServiceError.apiError("OpenRouter's model list could not be loaded. Check your connection and try again.")
        }
        return try parse(data)
    }
}
