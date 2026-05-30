import Foundation

enum TranslationServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key in Settings before translating."
        case .invalidResponse:
            return "The translation response could not be parsed."
        case .apiError(let message):
            return message
        case .validationFailed(let message):
            return message
        }
    }
}

struct OpenAITranslationService {
    @MainActor
    func translate(
        segments: [TranscriptionSegment],
        sourceLanguage: String,
        settings: AppSettingsStore,
        progress: @escaping @MainActor (JobProgress) -> Void
    ) async throws -> [TranscriptionSegment] {
        let apiKey = settings.openAIAPIKey
        let model = settings.openAIModel

        guard !apiKey.isEmpty else {
            throw TranslationServiceError.missingAPIKey
        }

        let chunks = segments.chunked(into: 80)
        var translatedByID: [Int: String] = [:]

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled {
                throw CancellationError()
            }

            let chunkNumber = index + 1
            progress(
                JobProgress(
                    stage: .translating,
                    detail: "Translating chunk \(chunkNumber) of \(chunks.count).",
                    fraction: Double(index) / Double(max(chunks.count, 1))
                )
            )

            let translatedChunk = try await translateChunkWithRetry(
                chunk,
                chunkNumber: chunkNumber,
                totalChunks: chunks.count,
                sourceLanguage: sourceLanguage,
                apiKey: apiKey,
                model: model
            )
            translatedChunk.forEach { translatedByID[$0.id] = $0.text }
        }

        let untranslated = segments.filter { translatedByID[$0.id] == nil }.count
        let completionDetail = untranslated > 0
            ? "Translation complete. \(untranslated) segment(s) kept their original text."
            : "Translation complete."
        progress(JobProgress(stage: .complete, detail: completionDetail, fraction: 1.0))

        return segments.map { segment in
            TranscriptionSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: translatedByID[segment.id] ?? segment.text
            )
        }
    }

    private func translateChunkWithRetry(
        _ segments: [TranscriptionSegment],
        chunkNumber: Int,
        totalChunks: Int,
        sourceLanguage: String,
        apiKey: String,
        model: String
    ) async throws -> [TranslatedSegment] {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await translateChunk(
                    segments,
                    chunkNumber: chunkNumber,
                    totalChunks: totalChunks,
                    sourceLanguage: sourceLanguage,
                    apiKey: apiKey,
                    model: model
                )
            } catch {
                lastError = error
                if Task.isCancelled {
                    throw CancellationError()
                }
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                }
            }
        }
        throw lastError ?? TranslationServiceError.invalidResponse
    }

    private func translateChunk(
        _ segments: [TranscriptionSegment],
        chunkNumber: Int,
        totalChunks: Int,
        sourceLanguage: String,
        apiKey: String,
        model: String
    ) async throws -> [TranslatedSegment] {
        let requestBody = TranslationRequest(
            model: model,
            input: [
                .init(
                    role: "system",
                    content: [
                        .init(
                            type: "input_text",
                            text: """
                            You translate subtitle segments into natural English.
                            Preserve segment count, ordering, ids, and timing alignment.
                            Keep lines concise for subtitles.
                            This is chunk \(chunkNumber) of \(totalChunks); do not mention chunking.
                            Return JSON only in the shape {"segments":[{"id":1,"text":"..."}]}.
                            """
                        )
                    ]
                ),
                .init(
                    role: "user",
                    content: [
                        .init(
                            type: "input_text",
                            text: """
                            Source language: \(sourceLanguage).
                            Segments:
                            \(String(decoding: try JSONEncoder().encode(segments), as: UTF8.self))
                            """
                        )
                    ]
                )
            ],
            text: .init(verbosity: "low")
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationServiceError.apiError(
                Self.describeAPIError(data: data, statusCode: httpResponse.statusCode, model: model)
            )
        }

        let decoded = try JSONDecoder().decode(OpenAIResponseEnvelope.self, from: data)
        let rawText = decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = rawText.data(using: .utf8) else {
            throw TranslationServiceError.invalidResponse
        }

        let translated = try JSONDecoder().decode(TranslatedSegmentsPayload.self, from: jsonData)
        try validate(translated.segments, expected: segments)
        // Drop empties so they fall back to the original text upstream rather
        // than failing the whole chunk on a single untranslatable segment.
        return translated.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Turns an OpenAI error response into a single actionable sentence
    /// instead of dumping raw JSON into the run log.
    private static func describeAPIError(data: Data, statusCode: Int, model: String) -> String {
        let parsed = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data)
        let message = parsed?.error.message

        if statusCode == 401 {
            return "OpenAI rejected the API key (401). Check the key in Settings."
        }
        if statusCode == 429 {
            return message ?? "OpenAI rate limit or quota exceeded (429). Try again later or check billing."
        }
        if let code = parsed?.error.code, code == "model_not_found" || statusCode == 404 {
            return "OpenAI does not recognize the model \"\(model)\". Set a valid model in Settings."
        }
        if let message {
            return "OpenAI error (\(statusCode)): \(message)"
        }
        return "OpenAI returned status \(statusCode)."
    }

    private func validate(_ translated: [TranslatedSegment], expected segments: [TranscriptionSegment]) throws {
        let expectedIDs = Set(segments.map(\.id))
        let actualIDs = Set(translated.map(\.id))

        guard expectedIDs == actualIDs else {
            let missing = expectedIDs.subtracting(actualIDs).sorted()
            let extra = actualIDs.subtracting(expectedIDs).sorted()
            throw TranslationServiceError.validationFailed("Translation returned mismatched segment ids. Missing: \(missing). Extra: \(extra).")
        }
    }
}

private struct TranslationRequest: Encodable {
    let model: String
    let input: [TranslationMessage]
    let text: TranslationTextConfig
}

private struct TranslationMessage: Encodable {
    let role: String
    let content: [TranslationContent]
}

private struct TranslationContent: Encodable {
    let type: String
    let text: String
}

private struct TranslationTextConfig: Encodable {
    let verbosity: String
}

private struct OpenAIResponseEnvelope: Decodable {
    let output: [OpenAIOutputItem]

    var outputText: String {
        output
            .flatMap(\.content)
            .compactMap(\.text)
            .joined(separator: "")
    }
}

private struct OpenAIOutputItem: Decodable {
    let content: [OpenAIOutputContent]
}

private struct OpenAIOutputContent: Decodable {
    let text: String?
}

private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
        let code: String?
    }
    let error: APIError
}

private struct TranslatedSegmentsPayload: Decodable {
    let segments: [TranslatedSegment]
}

private struct TranslatedSegment: Decodable {
    let id: Int
    let text: String
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
