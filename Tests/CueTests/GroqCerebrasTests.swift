import Foundation
import Testing
@testable import Cue

struct GroqCerebrasProviderTests {
    @Test func groqPrefixSelectsProviderAndDoesNotFallThroughToOpenAI() {
        #expect(TranslationProvider.infer(from: "groq/openai/gpt-oss-120b") == .groq)
        #expect(TranslationProvider.infer(from: "  Groq/qwen/qwen3.8-27b ") == .groq)
        #expect(TranslationProvider.infer(from: "openai/gpt-oss-120b") == .openai)
        #expect(TranslationProvider.infer(from: "gpt-oss-120b") == .openai)
    }

    @Test func cerebrasPrefixSelectsProviderAndDoesNotFallThroughToOpenAI() {
        #expect(TranslationProvider.infer(from: "cerebras/gpt-oss-120b") == .cerebras)
        #expect(TranslationProvider.infer(from: "  Cerebras/gemma-4-31b ") == .cerebras)
        #expect(TranslationProvider.infer(from: "cerebras-gpt") == .openai)
    }

    @Test func requestTargetsGroqWithStrippedModel() throws {
        let request = try TranslationService.makeRequest(
            provider: .groq,
            model: "groq/openai/gpt-oss-120b",
            apiKey: "gsk-test",
            systemPrompt: "system",
            userText: "user",
            schemaName: "subtitles",
            schema: .object(["type": .string("object")]),
            localEndpoint: ""
        )
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "openai/gpt-oss-120b")
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func requestTargetsCerebrasWithStrippedModel() throws {
        let request = try TranslationService.makeRequest(
            provider: .cerebras,
            model: "cerebras/gpt-oss-120b",
            apiKey: "csk-test",
            systemPrompt: "system",
            userText: "user",
            schemaName: "subtitles",
            schema: .object(["type": .string("object")]),
            localEndpoint: ""
        )
        #expect(request.url?.absoluteString == "https://api.cerebras.ai/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer csk-test")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-oss-120b")
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func requestRejectsBareGroqAndCerebrasPrefixes() {
        #expect(throws: TranslationServiceError.self) {
            _ = try TranslationService.makeRequest(
                provider: .groq,
                model: "groq/",
                apiKey: "gsk-test",
                systemPrompt: "s",
                userText: "u",
                schemaName: "n",
                schema: .object(["type": .string("object")]),
                localEndpoint: ""
            )
        }
        #expect(throws: TranslationServiceError.self) {
            _ = try TranslationService.makeRequest(
                provider: .cerebras,
                model: "cerebras/",
                apiKey: "csk-test",
                systemPrompt: "s",
                userText: "u",
                schemaName: "n",
                schema: .object(["type": .string("object")]),
                localEndpoint: ""
            )
        }
    }

    @Test func groqEnvelopeExtractsMessageContent() throws {
        let json = """
            {
              "choices": [
                {"index": 0, "message": {"role": "assistant", "content": "{\\"segments\\":[]}"}, "finish_reason": "stop"}
              ]
            }
            """
        let text = try TranslationService.extractOutputText(provider: .groq, data: Data(json.utf8))
        #expect(text == "{\"segments\":[]}")
    }

    @Test func cerebrasLengthFinishReasonThrowsResponseTooLarge() {
        let json = """
            {"choices": [{"message": {"role": "assistant", "content": "{\\"segments\\":["}, "finish_reason": "length"}]}
            """
        do {
            _ = try TranslationService.extractOutputText(provider: .cerebras, data: Data(json.utf8))
            Issue.record("Expected responseTooLarge to be thrown")
        } catch TranslationServiceError.responseTooLarge {
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }
}
