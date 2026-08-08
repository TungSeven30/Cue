import Foundation
import Testing
@testable import Cue

struct TranslationServiceParsingTests {
    // Reasoning models return {"type":"reasoning","summary":[...]} items with
    // no "content" key in the Responses API output array; decoding must not
    // fail on them.
    @Test func openAIEnvelopeToleratesReasoningItems() throws {
        let json = """
            {
              "status": "completed",
              "output": [
                {"type": "reasoning", "summary": []},
                {"type": "message", "content": [{"type": "output_text", "text": "{\\"segments\\":[]}"}]}
              ]
            }
            """
        let text = try TranslationService.extractOutputText(provider: .openai, data: Data(json.utf8))
        #expect(text == "{\"segments\":[]}")
    }

    @Test func openAIIncompleteResponseThrowsResponseTooLarge() {
        let json = """
            {
              "status": "incomplete",
              "incomplete_details": {"reason": "max_output_tokens"},
              "output": [{"type": "message", "content": [{"type": "output_text", "text": "{\\"segments\\":["}]}]
            }
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .openai, data: Data(json.utf8))
            Issue.record("Expected responseTooLarge to be thrown")
        } catch TranslationServiceError.responseTooLarge {
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }

    @Test func anthropicMaxTokensThrowsResponseTooLarge() {
        let json = """
            {"content": [{"type": "text", "text": "{\\"segments\\":["}], "stop_reason": "max_tokens"}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .anthropic, data: Data(json.utf8))
            Issue.record("Expected responseTooLarge to be thrown")
        } catch TranslationServiceError.responseTooLarge {
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }

    // Refusals have their own type: translation stops immediately, while
    // summary generation may route this one failure to an explicit fallback.
    @Test func anthropicRefusalIsTypedForFallback() {
        let json = """
            {"content": [], "stop_reason": "refusal"}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .anthropic, data: Data(json.utf8))
            Issue.record("Expected contentRefused to be thrown")
        } catch TranslationServiceError.contentRefused {
        } catch {
            Issue.record("Expected contentRefused, got \(error)")
        }
    }

    @Test func geminiSafetyBlockIsTypedForFallback() {
        let json = """
            {"promptFeedback": {"blockReason": "SAFETY"}}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .google, data: Data(json.utf8))
            Issue.record("Expected contentRefused to be thrown")
        } catch TranslationServiceError.contentRefused {
        } catch {
            Issue.record("Expected contentRefused, got \(error)")
        }
    }

    @Test func geminiMaxTokensThrowsResponseTooLarge() {
        let json = """
            {"candidates": [{"finishReason": "MAX_TOKENS", "content": {"parts": [{"text": "partial"}]}}]}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .google, data: Data(json.utf8))
            Issue.record("Expected responseTooLarge to be thrown")
        } catch TranslationServiceError.responseTooLarge {
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }

    @Test func validationRejectsDuplicateSegmentIDs() {
        let expected = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "a"),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "b"),
        ]
        let translated = [
            TranslatedSegment(id: 1, text: "x"),
            TranslatedSegment(id: 1, text: "y"),
        ]
        #expect(throws: (any Error).self) {
            try TranslationService.validate(translated, expected: expected)
        }
    }

    @Test func validationAcceptsExactMatch() throws {
        let expected = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "a"),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "b"),
        ]
        let translated = [
            TranslatedSegment(id: 2, text: "y"),
            TranslatedSegment(id: 1, text: "x"),
        ]
        try TranslationService.validate(translated, expected: expected)
    }

    // A 400 caused by an over-long request should be splittable, not fatal.
    @Test func lengthy400ClassifiedAsResponseTooLarge() {
        let body = Data(
            """
            {"error": {"message": "prompt is too long: 250000 tokens > 200000 maximum"}}
            """.utf8)
        let error = TranslationService.classifyAPIError(provider: .anthropic, data: body, statusCode: 400, model: "claude-sonnet-5")
        guard case .responseTooLarge = error else {
            Issue.record("Expected responseTooLarge, got \(error)")
            return
        }
    }

    @Test func other400StaysFatal() {
        let body = Data(
            """
            {"error": {"message": "unknown parameter: output_config"}}
            """.utf8)
        let error = TranslationService.classifyAPIError(provider: .anthropic, data: body, statusCode: 400, model: "claude-sonnet-5")
        guard case .fatalAPIError = error else {
            Issue.record("Expected fatalAPIError, got \(error)")
            return
        }
    }

    @Test func policy400IsTypedForFallback() {
        let body = Data(
            """
            {"error": {"message": "Request blocked by content policy", "code": "content_policy_violation"}}
            """.utf8)
        let error = TranslationService.classifyAPIError(provider: .openai, data: body, statusCode: 400, model: "gpt-5.5")
        guard case .contentRefused = error else {
            Issue.record("Expected contentRefused, got \(error)")
            return
        }
    }

    @Test func explicitPolicy403IsNotMisreportedAsBadKey() {
        let body = Data(
            """
            {"error": {"message": "Blocked content", "code": "content_policy_violation"}}
            """.utf8)
        let error = TranslationService.classifyAPIError(provider: .openRouter, data: body, statusCode: 403, model: "openrouter/example")
        guard case .contentRefused = error else {
            Issue.record("Expected contentRefused, got \(error)")
            return
        }
    }

    // The local/ prefix (with the slash) selects the local provider,
    // case-insensitively; a bare "local/" is valid because LM Studio ignores
    // the model field when a single model is loaded.
    @Test func inferSelectsLocalProviderForLocalPrefix() {
        #expect(TranslationProvider.infer(from: "local/qwen3.6-35b") == .local)
        #expect(TranslationProvider.infer(from: "LOCAL/x") == .local)
        #expect(TranslationProvider.infer(from: "local/") == .local)
        #expect(TranslationProvider.infer(from: "localmodel") == .openai)
    }

    @Test func localEnvelopeExtractsMessageContent() throws {
        let json = """
            {
              "choices": [
                {"index": 0, "message": {"role": "assistant", "content": "{\\"segments\\":[]}"}, "finish_reason": "stop"}
              ]
            }
            """
        let text = try TranslationService.extractOutputText(provider: .local, data: Data(json.utf8))
        #expect(text == "{\"segments\":[]}")
    }

    @Test func localLengthFinishReasonThrowsResponseTooLarge() {
        let json = """
            {"choices": [{"message": {"role": "assistant", "content": "{\\"segments\\":["}, "finish_reason": "length"}]}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .local, data: Data(json.utf8))
            Issue.record("Expected responseTooLarge to be thrown")
        } catch TranslationServiceError.responseTooLarge {
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }

    @Test func localEmptyChoicesThrowsInvalidResponse() {
        let json = """
            {"choices": []}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .local, data: Data(json.utf8))
            Issue.record("Expected invalidResponse to be thrown")
        } catch TranslationServiceError.invalidResponse {
        } catch {
            Issue.record("Expected invalidResponse, got \(error)")
        }
    }

    // The local/ prefix is routing-only: the wire model is the remainder, and
    // the endpoint join must tolerate a trailing slash on the stored base URL.
    @Test func localRequestStripsPrefixAndJoinsEndpoint() throws {
        let request = try TranslationService.makeRequest(
            provider: .local,
            model: "local/qwen3.6-35b",
            apiKey: "",
            systemPrompt: "system",
            userText: "user",
            localEndpoint: "http://localhost:1234/v1"
        )
        #expect(request.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 600)

        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["model"] as? String == "qwen3.6-35b")

        let trailingSlash = try TranslationService.makeRequest(
            provider: .local,
            model: "local/",
            apiKey: "",
            systemPrompt: "system",
            userText: "user",
            localEndpoint: "http://192.168.1.10:1234/v1/"
        )
        #expect(trailingSlash.url?.absoluteString == "http://192.168.1.10:1234/v1/chat/completions")
        // Bare "local/" sends an empty wire model — LM Studio serves whatever
        // model is loaded, so this must not be rejected client-side.
        let slashBody = try #require(trailingSlash.httpBody)
        let slashDecoded = try #require(try JSONSerialization.jsonObject(with: slashBody) as? [String: Any])
        #expect(slashDecoded["model"] as? String == "")
    }

    // LM Studio's UI displays "Reachable at: http://host:1234" without the /v1
    // the API lives under; a pasted path-less base must get /v1 appended, while
    // an explicit path — /v1 or otherwise — is respected verbatim.
    @Test func localEndpointWithoutPathGainsV1() throws {
        let bare = try TranslationService.makeRequest(
            provider: .local,
            model: "local/x",
            apiKey: "",
            systemPrompt: "s",
            userText: "u",
            localEndpoint: "http://127.0.0.1:1234"
        )
        #expect(bare.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")

        let customPath = try TranslationService.makeRequest(
            provider: .local,
            model: "local/x",
            apiKey: "",
            systemPrompt: "s",
            userText: "u",
            localEndpoint: "http://127.0.0.1:8080/api/v1"
        )
        #expect(customPath.url?.absoluteString == "http://127.0.0.1:8080/api/v1/chat/completions")
    }

    // Captured live from LM Studio serving Qwen3.6: the schema-constrained
    // answer landed entirely in reasoning_content with content empty. The
    // fallback must recover it; downstream validation guards against actual
    // chain-of-thought text slipping through.
    @Test func localReasoningContentRecoveredWhenContentEmpty() throws {
        let json = """
            {"id": "chatcmpl-1", "object": "chat.completion", "model": "qwen/qwen3.6-27b",
             "choices": [{"index": 0,
                          "message": {"role": "assistant", "content": "",
                                      "reasoning_content": "{\\"segments\\": [{\\"id\\": 1, \\"text\\": \\"Xin ch\\u00e0o\\"}]}",
                                      "tool_calls": []},
                          "logprobs": null, "finish_reason": "stop"}]}
            """
        let text = try TranslationService.extractOutputText(provider: .local, data: Data(json.utf8))
        #expect(text.contains("Xin chào"))
        #expect(text.contains("\"segments\""))
    }

    // A 200 response carrying {"error": ...} (LM Studio's unexpected-endpoint
    // shape) must surface the server's message, not a generic parse failure.
    @Test func localErrorBodySurfacesServerMessage() {
        let json = """
            {"error": "Unexpected endpoint or method. (POST /chat/completions)"}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .local, data: Data(json.utf8))
            Issue.record("Expected apiError to be thrown")
        } catch TranslationServiceError.apiError(let message) {
            #expect(message.contains("Unexpected endpoint"))
        } catch {
            Issue.record("Expected apiError, got \(error)")
        }
    }

    @Test @MainActor func translationUsesCredentialsProviderWhenModelNameDisagrees() async throws {
        let suiteName = "translation-provider-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(
            defaults: defaults,
            readSecret: { _ in nil },
            writeSecret: { _, _ in true }
        )
        settings.openAIModel = "gpt-5.5"
        settings.translationParallelism = 1

        let response = Data(
            """
            {"choices":[{"message":{"content":"{\\"segments\\":[{\\"id\\":1,\\"text\\":\\"Hola\\"}]}"},"finish_reason":"stop"}]}
            """.utf8)
        let client = RecordingHTTPClient(responses: [.init(data: response, statusCode: 200)])
        let service = TranslationService(httpClient: client)
        let result = try await service.translate(
            segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Hello")],
            sourceLanguage: "English",
            settings: JobSettingsSnapshot(settings: settings),
            credentials: TranslationCredentials(
                apiKey: "",
                prompt: AppSettingsStore.defaultTranslationPrompt,
                provider: .local,
                localEndpoint: "http://127.0.0.1:1234/v1"
            ),
            existingTranslations: [],
            progress: { _ in },
            onPartial: { _ in }
        )

        #expect(result.map(\.text) == ["Hola"])
        let requests = await client.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
        let body = try #require(requests.first?.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["model"] as? String == "gpt-5.5")
    }

    @Test @MainActor func progressivePassSubmitsOnlyMissingSegments() async throws {
        let suiteName = "translation-pending-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.openAIModel = "local/qwen"
        settings.translationParallelism = 1

        let response = Data(
            #"{"choices":[{"message":{"content":"{\"segments\":[{\"id\":2,\"text\":\"Dos\"}]}"},"finish_reason":"stop"}]}"#.utf8
        )
        let client = RecordingHTTPClient(responses: [.init(data: response, statusCode: 200)])
        let source = [
            TranscriptionSegment(id: 1, start: 0, end: 1, text: "One"),
            TranscriptionSegment(id: 2, start: 1, end: 2, text: "Two"),
        ]
        let result = try await TranslationService(httpClient: client).translate(
            segments: source,
            sourceLanguage: "English",
            settings: JobSettingsSnapshot(settings: settings),
            credentials: TranslationCredentials(
                apiKey: "", prompt: AppSettingsStore.defaultTranslationPrompt,
                provider: .local, localEndpoint: "http://127.0.0.1:1234/v1"),
            existingTranslations: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Uno")],
            progress: { _ in },
            onPartial: { _ in }
        )

        #expect(result.map(\.text) == ["Uno", "Dos"])
        let request = try #require((await client.capturedRequests()).first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userText = try #require(messages.last?["content"] as? String)
        let encodedSegments = try #require(userText.components(separatedBy: "Segments:\n").last)
        let submitted = try #require(try JSONSerialization.jsonObject(with: Data(encodedSegments.utf8)) as? [[String: Any]])
        #expect(submitted.compactMap { $0["id"] as? Int } == [2])
    }

    @Test @MainActor func summaryRetriesExplicitFallbackAfterPolicyRefusal() async throws {
        let refusal = Data("{\"content\":[],\"stop_reason\":\"refusal\"}".utf8)
        let success = Data(
            """
            {"choices":[{"message":{"content":"{\\"summary\\":\\"A quiet mystery begins.\\"}"},"finish_reason":"stop"}]}
            """.utf8)
        let client = RecordingHTTPClient(
            responses: [
                .init(data: refusal, statusCode: 200),
                .init(data: success, statusCode: 200),
            ]
        )
        let service = TranslationService(httpClient: client)
        let result = try await service.summarize(
            segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Opening dialogue")],
            language: "English",
            primary: SummaryModelConfiguration(
                model: "claude-sonnet-5",
                credentials: TranslationCredentials(
                    apiKey: "anthropic-key",
                    prompt: "unused",
                    provider: .anthropic,
                    localEndpoint: "http://127.0.0.1:1234/v1"
                )
            ),
            fallback: SummaryModelConfiguration(
                model: "local/qwen",
                credentials: TranslationCredentials(
                    apiKey: "",
                    prompt: "unused",
                    provider: .local,
                    localEndpoint: "http://127.0.0.1:1234/v1"
                )
            )
        )

        #expect(result.summary == "A quiet mystery begins.")
        #expect(result.model == "local/qwen")
        #expect(result.usedFallback)
        let requests = await client.capturedRequests()
        #expect(requests.map { $0.url?.host } == ["api.anthropic.com", "127.0.0.1"])
    }

    @Test @MainActor func summaryDoesNotFallbackForRateLimit() async {
        let rateLimit = Data("{\"error\":{\"message\":\"slow down\"}}".utf8)
        let unusedSuccess = Data(
            """
            {"choices":[{"message":{"content":"{\\"summary\\":\\"Should not run.\\"}"},"finish_reason":"stop"}]}
            """.utf8)
        let client = RecordingHTTPClient(
            responses: [
                .init(data: rateLimit, statusCode: 429),
                .init(data: unusedSuccess, statusCode: 200),
            ]
        )
        let service = TranslationService(httpClient: client)

        do {
            _ = try await service.summarize(
                segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Opening dialogue")],
                language: "English",
                primary: SummaryModelConfiguration(
                    model: "gpt-5.5",
                    credentials: TranslationCredentials(
                        apiKey: "openai-key",
                        prompt: "unused",
                        provider: .openai,
                        localEndpoint: "http://127.0.0.1:1234/v1"
                    )
                ),
                fallback: SummaryModelConfiguration(
                    model: "local/qwen",
                    credentials: TranslationCredentials(
                        apiKey: "",
                        prompt: "unused",
                        provider: .local,
                        localEndpoint: "http://127.0.0.1:1234/v1"
                    )
                )
            )
            Issue.record("Expected apiError to be thrown")
        } catch TranslationServiceError.apiError {
        } catch {
            Issue.record("Expected apiError, got \(error)")
        }

        let requests = await client.capturedRequests()
        #expect(requests.count == 1)
    }
}
