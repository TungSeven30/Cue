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

private struct TranslationChunkResult {
    let chunkNumber: Int
    let segments: [TranslatedSegment]
}

struct OpenAITranslationService {
    @MainActor
    func translate(
        segments: [TranscriptionSegment],
        sourceLanguage: String,
        settings: AppSettingsStore,
        existingTranslations: [TranscriptionSegment],
        progress: @escaping @MainActor (JobProgress) -> Void,
        onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionSegment] {
        let apiKey = settings.openAIAPIKey
        let model = settings.openAIModel
        let chunkSize = settings.translationChunkMode.chunkSize
        let parallelism = max(1, min(4, settings.translationParallelism))
        let translationSourceLanguage = Self.translationSourceLanguage(
            translationSetting: settings.translationSourceLanguage,
            transcriptionSetting: sourceLanguage
        )
        let targetLanguage = settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = settings.translationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettingsStore.defaultTranslationPrompt
            : settings.translationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.isEmpty else {
            throw TranslationServiceError.missingAPIKey
        }

        let chunks = segments.chunked(into: chunkSize)
        var translatedByID = Dictionary(uniqueKeysWithValues: existingTranslations.map { ($0.id, $0.text) })
        let targetIDs = Set(segments.map(\.id))
        translatedByID = translatedByID.filter { targetIDs.contains($0.key) }

        if !translatedByID.isEmpty {
            onPartialResult(translatedByID: translatedByID, source: segments, progress: progress, onPartial: onPartial)
        }

        var nextIndex = 0
        while nextIndex < chunks.count {
            if Task.isCancelled {
                throw CancellationError()
            }

            let batchStart = nextIndex
            let batchEnd = min(nextIndex + parallelism, chunks.count)
            let indexedChunks = (batchStart..<batchEnd).compactMap { index -> (Int, [TranscriptionSegment])? in
                let chunk = chunks[index]
                let isComplete = chunk.allSatisfy { translatedByID[$0.id] != nil }
                return isComplete ? nil : (index, chunk)
            }
            nextIndex = batchEnd

            guard !indexedChunks.isEmpty else {
                continue
            }

            let chunkLabels = indexedChunks.map { "\($0.0 + 1)" }.joined(separator: ", ")
            progress(
                JobProgress(
                    stage: .translating,
                    detail: "Translating chunk \(chunkLabels) of \(chunks.count).",
                    fraction: Double(batchStart) / Double(max(chunks.count, 1))
                )
            )

            let results = try await withThrowingTaskGroup(of: TranslationChunkResult.self) { group in
                for (index, chunk) in indexedChunks {
                    let chunkNumber = index + 1
                    group.addTask {
                        let translatedChunk = try await translateChunkWithRetry(
                            chunk,
                            chunkNumber: chunkNumber,
                            totalChunks: chunks.count,
                            sourceLanguage: translationSourceLanguage,
                            targetLanguage: targetLanguage.isEmpty ? "English" : targetLanguage,
                            prompt: prompt,
                            apiKey: apiKey,
                            model: model
                        )
                        return TranslationChunkResult(chunkNumber: chunkNumber, segments: translatedChunk)
                    }
                }

                var collected: [TranslationChunkResult] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.chunkNumber < $1.chunkNumber }
            }

            for result in results {
                result.segments.forEach { translatedByID[$0.id] = $0.text }
                onPartialResult(translatedByID: translatedByID, source: segments, progress: progress, onPartial: onPartial)
            }
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

    @MainActor
    private func onPartialResult(
        translatedByID: [Int: String],
        source segments: [TranscriptionSegment],
        progress: @escaping @MainActor (JobProgress) -> Void,
        onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) {
        let partial = segments.compactMap { segment -> TranscriptionSegment? in
            guard let text = translatedByID[segment.id] else { return nil }
            return TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: text)
        }
        onPartial(partial)
        let completed = segments.filter { translatedByID[$0.id] != nil }.count
        progress(
            JobProgress(
                stage: .translating,
                detail: "Saved \(completed) of \(segments.count) translated segment(s).",
                fraction: Double(completed) / Double(max(segments.count, 1))
            )
        )
    }

    private func translateChunkWithRetry(
        _ segments: [TranscriptionSegment],
        chunkNumber: Int,
        totalChunks: Int,
        sourceLanguage: String,
        targetLanguage: String,
        prompt: String,
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
                    targetLanguage: targetLanguage,
                    prompt: prompt,
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
        targetLanguage: String,
        prompt: String,
        apiKey: String,
        model: String
    ) async throws -> [TranslatedSegment] {
        let systemPrompt = """
        \(prompt)

        Source language: \(sourceLanguage).
        Target language: \(targetLanguage).
        Preserve segment count, ordering, ids, and timing alignment.
        Keep lines concise for subtitles.
        This is chunk \(chunkNumber) of \(totalChunks); do not mention chunking.
        Return JSON only in the shape {"segments":[{"id":1,"text":"..."}]}.
        """

        let requestBody = TranslationRequest(
            model: model,
            input: [
                .init(
                    role: "system",
                    content: [
                        .init(
                            type: "input_text",
                            text: systemPrompt
                        )
                    ]
                ),
                .init(
                    role: "user",
                    content: [
                        .init(
                            type: "input_text",
                            text: """
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
        guard let jsonData = Self.extractJSONObject(from: rawText).data(using: .utf8) else {
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

    private static func extractJSONObject(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    private static func translationSourceLanguage(translationSetting: String, transcriptionSetting: String) -> String {
        let trimmedTranslation = translationSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranslation.isEmpty && trimmedTranslation.lowercased() != "auto" {
            return trimmedTranslation
        }

        switch transcriptionSetting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "en": return "English"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        case "ko": return "Korean"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "id": return "Indonesian"
        case "th": return "Thai"
        case "vi": return "Vietnamese"
        case "", "auto": return "the source language detected in the transcript"
        default: return transcriptionSetting
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
