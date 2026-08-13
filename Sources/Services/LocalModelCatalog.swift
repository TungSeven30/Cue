import Foundation

enum LocalServerModelAvailability: Hashable, Sendable {
    /// Confirmed by LM Studio's native API as a loaded model instance.
    case running
    /// Returned by a generic OpenAI-compatible model catalog. The generic API
    /// does not expose enough state to prove that the model is loaded.
    case advertised
}

/// A text-generation model currently exposed by an OpenAI-compatible server
/// such as LM Studio or Ollama.
struct LocalServerModel: Identifiable, Hashable, Sendable {
    let id: String
    let ownedBy: String?
    let availability: LocalServerModelAvailability
}

enum LocalModelCatalogError: LocalizedError {
    case invalidEndpoint(String)
    case unavailable(String)
    case invalidResponse
    case noModels

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "\"\(endpoint)\" is not a valid local server URL."
        case .unavailable(let message):
            return message
        case .invalidResponse:
            return "The server responded, but its model list was not valid OpenAI-compatible JSON."
        case .noModels:
            return "Connected, but no text-generation models are loaded. Load a model in LM Studio and try again."
        }
    }
}

/// Discovers running LM Studio instances from its native `GET /api/v1/models`
/// endpoint, then falls back to the standard OpenAI-compatible `GET /v1/models`
/// catalog for other local servers. A path-less address gains `/v1`, matching
/// the request normalization used by TranslationService.
enum LocalModelCatalog {
    private struct OpenAIEnvelope: Decodable {
        struct Entry: Decodable {
            let id: String?
            let ownedBy: String?

            enum CodingKeys: String, CodingKey {
                case id
                case ownedBy = "owned_by"
            }
        }

        let data: [Entry]
    }

    private struct LMStudioEnvelope: Decodable {
        struct Entry: Decodable {
            struct LoadedInstance: Decodable {
                let id: String?
            }

            let type: String
            let publisher: String?
            let loadedInstances: [LoadedInstance]

            enum CodingKeys: String, CodingKey {
                case type
                case publisher
                case loadedInstances = "loaded_instances"
            }
        }

        let models: [Entry]
    }

    static func modelsURL(for endpoint: String) throws -> URL {
        let parsed = try validatedURL(for: endpoint)
        guard var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            throw LocalModelCatalogError.invalidEndpoint(endpoint)
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/v1" }
        components.percentEncodedPath = path + "/models"
        components.fragment = nil
        guard let url = components.url else {
            throw LocalModelCatalogError.invalidEndpoint(endpoint)
        }
        return url
    }

    /// LM Studio's native API always lives at the server origin, even when the
    /// saved translation endpoint includes the OpenAI-compatible `/v1` path.
    static func lmStudioModelsURL(for endpoint: String) throws -> URL {
        let parsed = try validatedURL(for: endpoint)
        guard var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            throw LocalModelCatalogError.invalidEndpoint(endpoint)
        }
        components.path = "/api/v1/models"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw LocalModelCatalogError.invalidEndpoint(endpoint)
        }
        return url
    }

    private static func validatedURL(for endpoint: String) throws -> URL {
        let base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
            let parsed = URL(string: base),
            let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            parsed.host != nil
        else {
            throw LocalModelCatalogError.invalidEndpoint(endpoint)
        }
        return parsed
    }

    /// Embedding-only models cannot translate subtitles. LM Studio's
    /// OpenAI-compatible response does not expose capabilities, so use the
    /// conventional id markers and keep the filter deliberately narrow.
    static func isLikelyEmbeddingModel(_ id: String) -> Bool {
        let normalized = id.lowercased()
        return normalized.contains("embedding") || normalized.contains("embed-text")
    }

    static func parseOpenAI(_ data: Data) throws -> [LocalServerModel] {
        let envelope: OpenAIEnvelope
        do {
            envelope = try JSONDecoder().decode(OpenAIEnvelope.self, from: data)
        } catch {
            throw LocalModelCatalogError.invalidResponse
        }

        let models = envelope.data
            .compactMap { entry -> LocalServerModel? in
                guard let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !id.isEmpty,
                    !isLikelyEmbeddingModel(id)
                else { return nil }
                return LocalServerModel(id: id, ownedBy: entry.ownedBy, availability: .advertised)
            }
            .uniqued(by: \.id)
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        guard !models.isEmpty else { throw LocalModelCatalogError.noModels }
        return models
    }

    /// LM Studio returns installed models and their loaded instances separately.
    /// Only loaded LLM instance ids are valid evidence that a model is running.
    static func parseLMStudio(_ data: Data) throws -> [LocalServerModel] {
        let envelope: LMStudioEnvelope
        do {
            envelope = try JSONDecoder().decode(LMStudioEnvelope.self, from: data)
        } catch {
            throw LocalModelCatalogError.invalidResponse
        }

        let models = envelope.models
            .filter { $0.type.lowercased() == "llm" }
            .flatMap { entry in
                entry.loadedInstances.compactMap { instance -> LocalServerModel? in
                    guard let id = instance.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !id.isEmpty
                    else { return nil }
                    return LocalServerModel(id: id, ownedBy: entry.publisher, availability: .running)
                }
            }
            .uniqued(by: \.id)
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        guard !models.isEmpty else { throw LocalModelCatalogError.noModels }
        return models
    }

    static func fetch(
        endpoint: String,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) async throws -> [LocalServerModel] {
        let lmStudioURL = try lmStudioModelsURL(for: endpoint)
        let lmStudioResponse = try await response(
            from: lmStudioURL,
            httpClient: httpClient
        )

        if (200..<300).contains(lmStudioResponse.statusCode) {
            do {
                return try parseLMStudio(lmStudioResponse.data)
            } catch LocalModelCatalogError.noModels {
                // A valid LM Studio response with zero loaded instances is
                // authoritative. Falling back to `/v1/models` would make
                // installed-but-stopped models look as if they were running.
                throw LocalModelCatalogError.noModels
            } catch LocalModelCatalogError.invalidResponse {
                // A different OpenAI-compatible server can coincidentally
                // answer this path. Fall back to its standard model catalog.
            }
        } else if ![404, 405, 501].contains(lmStudioResponse.statusCode) {
            throw LocalModelCatalogError.unavailable(
                "The local server returned HTTP \(lmStudioResponse.statusCode) while checking LM Studio."
            )
        }

        let openAIResponse = try await response(
            from: modelsURL(for: endpoint),
            httpClient: httpClient
        )
        guard (200..<300).contains(openAIResponse.statusCode) else {
            throw LocalModelCatalogError.unavailable(
                "The local server returned HTTP \(openAIResponse.statusCode) while loading models."
            )
        }
        return try parseOpenAI(openAIResponse.data)
    }

    private static func response(
        from url: URL,
        httpClient: any HTTPClient
    ) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw LocalModelCatalogError.unavailable(
                "Could not reach the local server. Check the address, start LM Studio's server, enable Serve on Local Network, and allow Cue in System Settings → Privacy & Security → Local Network."
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw LocalModelCatalogError.invalidResponse
        }
        return (data, http.statusCode)
    }
}

private extension Sequence {
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
