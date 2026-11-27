import Foundation
import Testing
@testable import Cue

struct NousProviderTests {
    @Test func nousPrefixSelectsPortalNotOpenRouter() {
        #expect(TranslationProvider.infer(from: "  NoUs/Hermes-4.3-36B  ").label == "Nous Portal")
        #expect(TranslationProvider.infer(from: "openrouter/nousresearch/hermes-4-70b") == .openRouter)
    }

    @Test(arguments: [
        "  NoUs/Hermes-4.3-36B  ",
        "nous/Vendor/Model/Preview:free",
    ])
    func requestUsesNativeChatCompletionsWithCasePreserved(model: String) throws {
        let request = try TranslationService.makeRequest(
            provider: TranslationProvider.infer(from: model),
            model: model,
            apiKey: "fixture-nous",
            systemPrompt: "Return JSON only.",
            userText: "Input subtitles",
            maxOutputTokens: 2_048,
            localEndpoint: ""
        )
        #expect(request.url?.absoluteString == "https://inference-api.nousresearch.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-nous")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
        let json = try Self.body(of: request)
        let wireModel = model.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("nous/".count)
        #expect(json["model"] as? String == String(wireModel))
        #expect(json["max_tokens"] as? Int == 2_048)
        #expect(json["stream"] as? Bool == false)
        #expect(json["response_format"] == nil)
        #expect(
            json["messages"] as? [[String: String]] == [
                ["role": "system", "content": "Return JSON only."],
                ["role": "user", "content": "Input subtitles"],
            ])
    }

    @Test(arguments: ["nous/", "  NOUS/  \n"])
    func emptyModelIDIsFatal(model: String) throws {
        do {
            _ = try TranslationService.makeRequest(
                provider: TranslationProvider.infer(from: model),
                model: model,
                apiKey: "fixture-nous",
                systemPrompt: "system",
                userText: "user",
                localEndpoint: ""
            )
            Issue.record("An empty Nous model id must not be sent")
        } catch TranslationServiceError.fatalAPIError(let message) {
            #expect(message.contains("Nous Portal"))
            #expect(message.contains("nous/Hermes-4.3-36B"))
        }
    }

    @Test func rejectedNousKeyIsFatal() {
        let model = "nous/Hermes-4-70B"
        let error = TranslationService.classifyAPIError(
            provider: TranslationProvider.infer(from: model),
            data: Data(#"{"error":{"message":"Invalid credentials"}}"#.utf8),
            statusCode: 401,
            model: model
        )
        guard case .fatalAPIError(let message) = error else {
            Issue.record("A 401 must be fatal, got \(error)")
            return
        }
        #expect(message.contains("Nous Portal rejected the API key"))
    }

    @Test func badNousRequestDoesNotSuggestStructuredOutputConfiguration() {
        let model = "nous/Hermes-4-70B"
        let error = TranslationService.classifyAPIError(
            provider: TranslationProvider.infer(from: model),
            data: Data(#"{"error":{"message":"Invalid parameters"}}"#.utf8),
            statusCode: 400,
            model: model
        )
        guard case .fatalAPIError(let message) = error else {
            Issue.record("A non-size-related 400 must be fatal, got \(error)")
            return
        }
        #expect(message.contains("Nous Portal rejected the request"))
        #expect(!message.contains("structured JSON"))
    }

    @Test func chatErrorEnvelopeNamesNousPortal() {
        let provider = TranslationProvider.infer(from: "nous/Hermes-4-405B")
        do {
            _ = try TranslationService.extractOutputText(
                provider: provider,
                data: Data(#"{"error":{"message":"Provider unavailable"}}"#.utf8)
            )
            Issue.record("An error envelope must not produce output text")
        } catch TranslationServiceError.apiError(let message) {
            #expect(message == "Nous Portal error: Provider unavailable")
        } catch {
            Issue.record("Expected a provider error, got \(error)")
        }
    }

    @Test func chatLengthFinishIsClassifiedAsTruncation() {
        let provider = TranslationProvider.infer(from: "nous/Hermes-4-70B")
        do {
            _ = try TranslationService.extractOutputText(
                provider: provider,
                data: Data(#"{"choices":[{"message":{"content":"{"},"finish_reason":"length"}]}"#.utf8)
            )
            Issue.record("A truncated reply must not produce output text")
        } catch TranslationServiceError.responseTooLarge {
        } catch {
            Issue.record("Expected a truncation error, got \(error)")
        }
    }

    @Test @MainActor func translationRequestsJSONAndParsesSegmentIDs() async throws {
        let setup = makeSettings()
        defer { setup.defaults.removePersistentDomain(forName: setup.domain) }
        let model = "nous/Hermes-4.3-36B"
        setup.settings.openAIModel = model
        setup.settings.translationTargetLanguage = "French"
        let client = RecordingHTTPClient(responses: [
            .init(
                data: Data(#"{"choices":[{"message":{"content":"{\"segments\":[{\"id\":3,\"text\":\"Bonjour\"}]}"},"finish_reason":"stop"}]}"#.utf8),
                statusCode: 200)
        ])
        let service = TranslationService(httpClient: client)
        let segments = [TranscriptionSegment(id: 3, start: 0, end: 1, text: "Hello")]
        let translated = try await service.translate(
            segments: segments,
            sourceLanguage: "en",
            settings: JobSettingsSnapshot(settings: setup.settings),
            credentials: credentials(for: model),
            existingTranslations: [],
            progress: { _ in },
            onPartial: { _ in }
        )
        #expect(translated == [TranscriptionSegment(id: 3, start: 0, end: 1, text: "Bonjour")])
        let requests = await client.capturedRequests()
        let request = try #require(requests.first)
        let json = try Self.body(of: request)
        #expect(json["response_format"] == nil)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["content"]?.contains(#"Return JSON only in the shape {"segments":[{"id":1,"text":"..."}]}"#) == true)
    }

    @Test(arguments: [SummaryDetail.brief, .detailed])
    @MainActor func summaryRequestsJSONAndParsesSummary(detail: SummaryDetail) async throws {
        let model = "nous/Hermes-4-405B"
        let client = RecordingHTTPClient(responses: [
            .init(data: Data(#"{"choices":[{"message":{"content":"{\"summary\":\"An old friend returns.\"}"},"finish_reason":"stop"}]}"#.utf8), statusCode: 200)
        ])
        let result = try await TranslationService(httpClient: client).summarize(
            segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Hello")],
            language: "English",
            primary: SummaryModelConfiguration(model: model, credentials: credentials(for: model)),
            detail: detail
        )
        #expect(result.summary == "An old friend returns.")
        #expect(result.model == model)
        let requests = await client.capturedRequests()
        let request = try #require(requests.first)
        let json = try Self.body(of: request)
        #expect(json["response_format"] == nil)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["content"]?.contains(#"Return JSON only in the shape {"summary":"..."}"#) == true)
    }

    @Test @MainActor func summaryStillRejectsWrongJSONShape() async throws {
        let model = "nous/Hermes-4-405B"
        let client = StubHTTPClient(
            data: Data(#"{"choices":[{"message":{"content":"{\"description\":\"Missing summary field\"}"},"finish_reason":"stop"}]}"#.utf8),
            statusCode: 200
        )
        do {
            _ = try await TranslationService(httpClient: client).summarize(
                segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Hello")],
                language: "English",
                primary: SummaryModelConfiguration(model: model, credentials: credentials(for: model))
            )
            Issue.record("A response without a summary field must be rejected")
        } catch DecodingError.keyNotFound(let key, _) {
            #expect(key.stringValue == "summary")
        }
    }

    private func credentials(for model: String) -> TranslationCredentials {
        TranslationCredentials(
            apiKey: "fixture-nous",
            prompt: "Translate the dialogue.",
            provider: TranslationProvider.infer(from: model),
            localEndpoint: ""
        )
    }

    @MainActor private func makeSettings() -> (settings: AppSettingsStore, defaults: UserDefaults, domain: String) {
        let domain = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        return (settings, defaults, domain)
    }

    private static func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
