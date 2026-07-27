import Foundation
import Testing
@testable import WhisperDesk

struct OpenRouterProviderTests {
    @Test func openRouterPrefixSelectsProvider() {
        #expect(TranslationProvider.infer(from: "openrouter/qwen/qwen3.7-max") == .openRouter)
        #expect(TranslationProvider.infer(from: "  OpenRouter/qwen/qwen3.7-plus ") == .openRouter)
        // The other prefixes keep their providers.
        #expect(TranslationProvider.infer(from: "claude-opus-5") == .anthropic)
        #expect(TranslationProvider.infer(from: "local/qwen3.6-35b") == .local)
        #expect(TranslationProvider.infer(from: "gpt-5.6-sol") == .openai)
    }

    @Test func requestTargetsOpenRouterWithStrippedModel() throws {
        let request = try TranslationService.makeRequest(
            provider: .openRouter,
            model: "openrouter/qwen/qwen3.7-max",
            apiKey: "sk-or-test",
            systemPrompt: "system",
            userText: "user",
            schemaName: "subtitles",
            schema: .object(["type": .string("object")]),
            localEndpoint: ""
        )
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "WhisperDesk")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The openrouter/ prefix is routing-only; the wire model is the
        // catalog id OpenRouter expects.
        #expect(json["model"] as? String == "qwen/qwen3.7-max")
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func requestRejectsBareOpenRouterPrefix() {
        #expect(throws: TranslationServiceError.self) {
            _ = try TranslationService.makeRequest(
                provider: .openRouter,
                model: "openrouter/",
                apiKey: "sk-or-test",
                systemPrompt: "s",
                userText: "u",
                schemaName: "n",
                schema: .object(["type": .string("object")]),
                localEndpoint: ""
            )
        }
    }

    @Test func insufficientCreditsIsFatal() {
        let body = Data(#"{"error":{"message":"Insufficient credits"}}"#.utf8)
        let error = TranslationService.classifyAPIError(
            provider: .openRouter, data: body, statusCode: 402, model: "openrouter/qwen/qwen3.7-max"
        )
        guard case .fatalAPIError(let message) = error else {
            Issue.record("402 must be fatal, got \(error)")
            return
        }
        #expect(message.contains("credits"))
    }
}

struct OpenRouterCatalogTests {
    private let sample = Data("""
    {
      "data": [
        {"id": "qwen/qwen3.7-max", "name": "Qwen: Qwen3.7 Max",
         "pricing": {"prompt": "0.0000012", "completion": "0.000006"}},
        {"id": "qwen/qwen3.7-plus", "name": "Qwen: Qwen3.7 Plus",
         "pricing": {"prompt": "0.0000004", "completion": "0.0000012"}},
        {"id": "meta-llama/llama-5-scout:free", "name": "Meta: Llama 5 Scout (free)",
         "pricing": {"prompt": "0", "completion": "0"}},
        {"id": "broken-entry-without-name"}
      ]
    }
    """.utf8)

    @Test func parsesModelsSortedByName() throws {
        let models = try OpenRouterModelCatalog.parse(sample)
        #expect(models.count == 3, "entries without a name are skipped, not fatal")
        #expect(models.map(\.name) == models.map(\.name).sorted())
        let max = try #require(models.first { $0.id == "qwen/qwen3.7-max" })
        #expect(max.promptPricePerToken == 0.0000012)
    }

    @Test func priceLabelsReadPerMillionTokens() throws {
        let models = try OpenRouterModelCatalog.parse(sample)
        let max = try #require(models.first { $0.id == "qwen/qwen3.7-max" })
        #expect(max.priceLabel == "$1.20 in / $6.00 out per 1M tokens")
        let free = try #require(models.first { $0.id == "meta-llama/llama-5-scout:free" })
        #expect(free.priceLabel == "Free")
    }

    @Test func malformedCatalogThrows() {
        #expect(throws: (any Error).self) {
            _ = try OpenRouterModelCatalog.parse(Data("not json".utf8))
        }
    }
}
