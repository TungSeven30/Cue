import Foundation
import Testing
@testable import WhisperDesk

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

    // A refusal will refuse again on an identical retry; it must be fatal so
    // the retry loop stops immediately.
    @Test func anthropicRefusalIsFatal() {
        let json = """
        {"content": [], "stop_reason": "refusal"}
        """
        do {
            _ = try TranslationService.extractOutputText(provider: .anthropic, data: Data(json.utf8))
            Issue.record("Expected fatalAPIError to be thrown")
        } catch TranslationServiceError.fatalAPIError {
        } catch {
            Issue.record("Expected fatalAPIError, got \(error)")
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
        let body = Data("""
        {"error": {"message": "prompt is too long: 250000 tokens > 200000 maximum"}}
        """.utf8)
        let error = TranslationService.classifyAPIError(provider: .anthropic, data: body, statusCode: 400, model: "claude-sonnet-5")
        guard case .responseTooLarge = error else {
            Issue.record("Expected responseTooLarge, got \(error)")
            return
        }
    }

    @Test func other400StaysFatal() {
        let body = Data("""
        {"error": {"message": "unknown parameter: output_config"}}
        """.utf8)
        let error = TranslationService.classifyAPIError(provider: .anthropic, data: body, statusCode: 400, model: "claude-sonnet-5")
        guard case .fatalAPIError = error else {
            Issue.record("Expected fatalAPIError, got \(error)")
            return
        }
    }
}
