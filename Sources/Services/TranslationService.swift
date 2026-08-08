import Foundation

/// The LLM provider used for translation, inferred from the model name so a
/// single "model" setting selects both the model and the API to call.
enum TranslationProvider {
    case openai
    case anthropic
    case google
    /// An OpenAI-compatible server on localhost or the LAN (LM Studio,
    /// Ollama, mlx-lm). Selected by the "local/" model-name prefix; needs
    /// no API key.
    case local
    /// OpenRouter's multi-provider gateway. Selected by the "openrouter/"
    /// model-name prefix; the rest of the name is the catalog id
    /// (e.g. openrouter/qwen/qwen3.7-max).
    case openRouter

    static func infer(from model: String) -> TranslationProvider {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("claude") {
            return .anthropic
        }
        if normalized.hasPrefix("gemini") || normalized.hasPrefix("models/gemini") {
            return .google
        }
        if normalized.hasPrefix("local/") {
            return .local
        }
        if normalized.hasPrefix("openrouter/") {
            return .openRouter
        }
        return .openai
    }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .local: return "Local server"
        case .openRouter: return "OpenRouter"
        }
    }
}

enum TranslationServiceError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse
    case apiError(String)
    /// An error retrying cannot fix (bad key, unknown model, malformed request).
    case fatalAPIError(String)
    case validationFailed(String)
    /// The chunk was too large for the model's input or output limits.
    /// Retrying at the same size cannot succeed, but splitting the chunk can.
    case responseTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add an \(provider) API key in Settings before translating."
        case .invalidResponse:
            return "The translation response could not be parsed."
        case .apiError(let message), .fatalAPIError(let message):
            return message
        case .validationFailed(let message), .responseTooLarge(let message):
            return message
        }
    }
}

/// A previously translated subtitle pair passed along with a chunk so the
/// model keeps terminology, names, tone, and pronouns consistent across
/// chunk boundaries.
private struct TranslationContextPair: Sendable {
    let source: String
    let translation: String
}

private struct TranslationChunkResult {
    let chunkNumber: Int
    let segments: [TranslatedSegment]
}

/// Secrets and prompt for a translation run, passed separately from the
/// persisted JobSettingsSnapshot so keys never reach a job file on disk.
struct TranslationCredentials {
    let apiKey: String
    let prompt: String
    let provider: TranslationProvider
    /// OpenAI-compatible server URL, used only when provider == .local.
    let localEndpoint: String
}

struct TranslationService {
    @MainActor
    func translate(
        segments: [TranscriptionSegment],
        sourceLanguage: String,
        settings: JobSettingsSnapshot,
        credentials: TranslationCredentials,
        existingTranslations: [TranscriptionSegment],
        progress: @escaping @MainActor (JobProgress) -> Void,
        onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionSegment] {
        let model = settings.openAIModel
        let provider = credentials.provider
        let apiKey = credentials.apiKey
        let localEndpoint = credentials.localEndpoint
        let chunkSize = settings.translationChunkMode.chunkSize
        let parallelism = max(1, min(4, settings.translationParallelism))
        let translationSourceLanguage = Self.translationSourceLanguage(
            translationSetting: settings.translationSourceLanguage,
            transcriptionSetting: sourceLanguage
        )
        let targetLanguage = settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = credentials.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettingsStore.defaultTranslationPrompt
            : credentials.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Local servers need no API key; an empty key is normal for them.
        guard provider == .local || !apiKey.isEmpty else {
            throw TranslationServiceError.missingAPIKey(provider.label)
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

            // Collect per-chunk outcomes instead of letting the first failure
            // abandon the group: successful sibling chunks are applied (and
            // persisted upstream as partial results) before the error is
            // rethrown, so a retry or resume does not re-translate them.
            let outcomes = await withTaskGroup(of: Result<TranslationChunkResult, Error>.self) { group in
                for (index, chunk) in indexedChunks {
                    let chunkNumber = index + 1
                    let context = Self.contextPairs(before: chunk, in: segments, translatedByID: translatedByID)
                    group.addTask {
                        do {
                            let translatedChunk = try await translateChunkWithRetry(
                                chunk,
                                chunkNumber: chunkNumber,
                                totalChunks: chunks.count,
                                sourceLanguage: translationSourceLanguage,
                                targetLanguage: targetLanguage.isEmpty ? "English" : targetLanguage,
                                prompt: prompt,
                                apiKey: apiKey,
                                model: model,
                                localEndpoint: localEndpoint,
                                context: context
                            )
                            return .success(TranslationChunkResult(chunkNumber: chunkNumber, segments: translatedChunk))
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                var collected: [Result<TranslationChunkResult, Error>] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            var firstError: Error?
            let results = outcomes
                .compactMap { try? $0.get() }
                .sorted { $0.chunkNumber < $1.chunkNumber }
            for outcome in outcomes {
                if case .failure(let error) = outcome, firstError == nil {
                    firstError = error
                }
            }

            for result in results {
                result.segments.forEach { translatedByID[$0.id] = $0.text }
                onPartialResult(translatedByID: translatedByID, source: segments, progress: progress, onPartial: onPartial)
            }

            if let firstError {
                throw firstError
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
        model: String,
        localEndpoint: String,
        context: [TranslationContextPair]
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
                    model: model,
                    localEndpoint: localEndpoint,
                    context: context
                )
            } catch {
                // Retrying cannot fix a rejected key or unknown model; surface
                // it immediately instead of burning the remaining attempts.
                if case TranslationServiceError.fatalAPIError = error {
                    throw error
                }
                lastError = error
                if Task.isCancelled {
                    throw CancellationError()
                }
                // An over-limit chunk fails identically at the same size;
                // skip straight to splitting instead of retrying.
                if case TranslationServiceError.responseTooLarge = error {
                    break
                }
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                }
            }
        }

        // A chunk that is too large for the model's limits, or one where the
        // model persistently drops or invents segment ids or returns broken
        // JSON, usually succeeds on smaller batches — split it in half rather
        // than failing the whole run over one bad response.
        if segments.count >= 2, let error = lastError, Self.isSplittable(error) {
            let midpoint = segments.count / 2
            let firstHalf = try await translateChunkWithRetry(
                Array(segments[..<midpoint]),
                chunkNumber: chunkNumber,
                totalChunks: totalChunks,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                prompt: prompt,
                apiKey: apiKey,
                model: model,
                localEndpoint: localEndpoint,
                context: context
            )
            let secondHalf = try await translateChunkWithRetry(
                Array(segments[midpoint...]),
                chunkNumber: chunkNumber,
                totalChunks: totalChunks,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                prompt: prompt,
                apiKey: apiKey,
                model: model,
                localEndpoint: localEndpoint,
                context: context
            )
            return firstHalf + secondHalf
        }

        throw lastError ?? TranslationServiceError.invalidResponse
    }

    /// Whether splitting the chunk in half is worth attempting: true for
    /// size-limit failures and for responses the model got structurally
    /// wrong (bad ids, truncated or malformed JSON).
    private static func isSplittable(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }
        switch error {
        case TranslationServiceError.validationFailed,
             TranslationServiceError.responseTooLarge,
             TranslationServiceError.invalidResponse:
            return true
        default:
            return false
        }
    }

    /// Generates a short spoiler-free introduction for the film from its
    /// subtitle text, in `language`, using the configured translation model.
    @MainActor
    func summarize(
        segments: [TranscriptionSegment],
        language: String,
        settings: JobSettingsSnapshot,
        credentials: TranslationCredentials,
        detail: SummaryDetail = .brief
    ) async throws -> String {
        let model = settings.openAIModel
        let provider = credentials.provider
        let apiKey = credentials.apiKey
        let localEndpoint = credentials.localEndpoint
        // Local servers need no API key; an empty key is normal for them.
        guard provider == .local || !apiKey.isEmpty else {
            throw TranslationServiceError.missingAPIKey(provider.label)
        }

        let systemPrompt = Self.summaryInstructions(detail: detail, language: language)
        // Even a 3-hour film's subtitles fit comfortably in a modern context
        // window; the cap is a guard against pathological inputs.
        let subtitleText = String(segments.map(\.text).joined(separator: "\n").prefix(200_000))

        let request = try Self.makeRequest(
            provider: provider,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userText: "Subtitles:\n\(subtitleText)",
            schemaName: "movie_intro_summary",
            schema: Self.summarySchema,
            localEndpoint: localEndpoint
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.classifyAPIError(provider: provider, data: data, statusCode: httpResponse.statusCode, model: model)
        }
        return try Self.parseSummary(from: Self.extractOutputText(provider: provider, data: data))
    }

    /// Internal (not private) so prompt selection can be unit-tested.
    static func summaryInstructions(detail: SummaryDetail, language: String) -> String {
        switch detail {
        case .brief:
            return """
            You write spoiler-free introductions for films based on their subtitles.
            Write 1-3 short sentences introducing the setting, main characters, and premise — like the blurb on the back of a DVD box.
            Do not reveal plot developments beyond the opening act, twists, or the ending.
            Write the introduction in \(language).
            Keep it under 280 characters so it fits on screen as a subtitle.
            Return JSON only in the shape {"summary":"..."}.
            """
        case .detailed:
            return """
            You write spoiler-free introductions for films based on their subtitles.
            Write a detailed introduction of 5-8 sentences: the setting and era, the main characters and how they relate to each other, the premise that sets the story in motion, and the film's tone or genre — like the opening of a thoughtful review that gives nothing away.
            Do not reveal plot developments beyond the opening act, twists, or the ending.
            Write the introduction in \(language). Plain sentences only — no markdown, no headings, no lists.
            Keep it under 900 characters; it will be shown as a sequence of subtitles.
            Return JSON only in the shape {"summary":"..."}.
            """
        }
    }

    /// Internal (not private) so the parsing can be unit-tested.
    static func parseSummary(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = extractJSONObject(from: trimmed).data(using: .utf8) else {
            throw TranslationServiceError.invalidResponse
        }
        let payload = try JSONDecoder().decode(SummaryPayload.self, from: data)
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw TranslationServiceError.invalidResponse
        }
        return summary
    }

    private static let summarySchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object(["type": .string("string")])
        ]),
        "required": .array([.string("summary")]),
        "additionalProperties": .bool(false)
    ])

    private func translateChunk(
        _ segments: [TranscriptionSegment],
        chunkNumber: Int,
        totalChunks: Int,
        sourceLanguage: String,
        targetLanguage: String,
        prompt: String,
        apiKey: String,
        model: String,
        localEndpoint: String,
        context: [TranslationContextPair]
    ) async throws -> [TranslatedSegment] {
        let systemPrompt = """
        \(prompt)

        Source language: \(sourceLanguage).
        Target language: \(targetLanguage).
        Preserve segment count, ordering, ids, and timing alignment.
        Keep lines concise for subtitles.
        When earlier translated context is provided, keep terminology, names, tone, speaker register, and pronouns consistent with it. Never re-output context lines.
        This is chunk \(chunkNumber) of \(totalChunks); do not mention chunking.
        Return JSON only in the shape {"segments":[{"id":1,"text":"..."}]}.
        """

        var userText = ""
        if !context.isEmpty {
            let contextLines = context
                .map { "\($0.source) => \($0.translation)" }
                .joined(separator: "\n")
            userText += """
            Already translated context from the preceding subtitles (for consistency only; do not include in the output):
            \(contextLines)


            """
        }
        userText += """
        Segments:
        \(String(decoding: try JSONEncoder().encode(segments), as: UTF8.self))
        """

        let provider = TranslationProvider.infer(from: model)
        let request = try Self.makeRequest(
            provider: provider,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userText: userText,
            localEndpoint: localEndpoint
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.classifyAPIError(provider: provider, data: data, statusCode: httpResponse.statusCode, model: model)
        }

        let rawText = try Self.extractOutputText(provider: provider, data: data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = Self.extractJSONObject(from: rawText).data(using: .utf8) else {
            throw TranslationServiceError.invalidResponse
        }

        let translated = try JSONDecoder().decode(TranslatedSegmentsPayload.self, from: jsonData)
        try Self.validate(translated.segments, expected: segments)
        // Drop empties so they fall back to the original text upstream rather
        // than failing the whole chunk on a single untranslatable segment.
        return translated.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Builds the provider-specific HTTP request. All providers receive
    /// the same system prompt, user text, and JSON schema for the reply.
    /// Internal (not private) so the request building can be unit-tested.
    static func makeRequest(
        provider: TranslationProvider,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userText: String,
        schemaName: String = "subtitle_translation",
        schema: JSONValue = TranslationSchema.segments,
        localEndpoint: String
    ) throws -> URLRequest {
        var request: URLRequest
        switch provider {
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                TranslationRequest(
                    model: model,
                    input: [
                        .init(role: "system", content: [.init(type: "input_text", text: systemPrompt)]),
                        .init(role: "user", content: [.init(type: "input_text", text: userText)])
                    ],
                    text: .init(
                        verbosity: "low",
                        format: .init(
                            type: "json_schema",
                            name: schemaName,
                            strict: true,
                            schema: schema
                        )
                    )
                )
            )
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(
                AnthropicRequest(
                    model: model,
                    max_tokens: 16000,
                    system: systemPrompt,
                    messages: [.init(role: "user", content: userText)],
                    output_config: .init(format: .init(type: "json_schema", schema: schema))
                )
            )
        case .google:
            let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
            guard let url = URL(string: endpoint) else {
                throw TranslationServiceError.fatalAPIError("The Gemini model name \"\(model)\" is not a valid model id.")
            }
            request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONEncoder().encode(
                GeminiRequest(
                    systemInstruction: .init(parts: [.init(text: systemPrompt)]),
                    contents: [.init(role: "user", parts: [.init(text: userText)])],
                    generationConfig: .init(
                        responseMimeType: "application/json",
                        responseJsonSchema: schema
                    )
                )
            )
        case .local:
            // The stored base URL may or may not end with a slash.
            var base = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.hasSuffix("/") { base = String(base.dropLast()) }
            // LM Studio's UI shows "Reachable at: http://host:1234" without the
            // /v1 the API actually lives under, so users paste exactly that.
            // A bare scheme://host[:port] gets /v1 appended; any explicit path
            // is respected as-is.
            if let parsed = URL(string: base), parsed.path.isEmpty {
                base += "/v1"
            }
            let joined = base + "/chat/completions"
            guard !base.isEmpty, let url = URL(string: joined), url.scheme != nil, url.host != nil else {
                throw TranslationServiceError.fatalAPIError("The local server URL \"\(localEndpoint)\" is not a valid URL. Set it in Settings (e.g. http://localhost:1234/v1).")
            }
            request = URLRequest(url: url)
            // No Authorization header: local servers need no API key. The
            // "local/" prefix is routing-only — strip it for the wire model
            // (an empty remainder is fine; LM Studio ignores the model field
            // when a single model is loaded).
            let wireModel = String(model.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("local/".count))
            request.httpBody = try JSONEncoder().encode(
                ChatCompletionsRequest(
                    model: wireModel,
                    messages: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: userText)
                    ],
                    response_format: .init(
                        type: "json_schema",
                        json_schema: .init(name: schemaName, strict: true, schema: schema)
                    ),
                    stream: false
                )
            )
        case .openRouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // Attribution headers OpenRouter asks apps to send; optional but
            // harmless and they identify traffic in the user's dashboard.
            request.setValue("https://github.com/TungSeven30/Cue", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Cue", forHTTPHeaderField: "X-Title")
            // The "openrouter/" prefix is routing-only; the remainder is the
            // catalog id the gateway expects on the wire.
            let wireModel = String(model.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("openrouter/".count))
            guard !wireModel.isEmpty else {
                throw TranslationServiceError.fatalAPIError("Set an OpenRouter model id after the openrouter/ prefix (e.g. openrouter/qwen/qwen3.7-max), or pick one via Browse OpenRouter Models in Settings.")
            }
            request.httpBody = try JSONEncoder().encode(
                ChatCompletionsRequest(
                    model: wireModel,
                    messages: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: userText)
                    ],
                    response_format: .init(
                        type: "json_schema",
                        json_schema: .init(name: schemaName, strict: true, schema: schema)
                    ),
                    stream: false
                )
            )
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Large chunks on slower models can exceed URLSession's default 60s;
        // big local models on big chunks can exceed even the cloud 300s.
        request.timeoutInterval = provider == .local ? 600 : 300
        return request
    }

    /// Pulls the model's text reply out of the provider-specific envelope.
    /// Internal (not private) so the parsing can be unit-tested.
    static func extractOutputText(provider: TranslationProvider, data: Data) throws -> String {
        switch provider {
        case .openai:
            let decoded = try JSONDecoder().decode(OpenAIResponseEnvelope.self, from: data)
            if decoded.status == "incomplete", decoded.incomplete_details?.reason == "max_output_tokens" {
                throw TranslationServiceError.responseTooLarge("The model's reply was cut off at its output-token limit.")
            }
            return decoded.outputText
        case .anthropic:
            let decoded = try JSONDecoder().decode(AnthropicResponseEnvelope.self, from: data)
            if decoded.stop_reason == "max_tokens" {
                throw TranslationServiceError.responseTooLarge("The model's reply was cut off at its output-token limit.")
            }
            if decoded.stop_reason == "refusal" {
                // An identical retry refuses again, so treat it as fatal.
                throw TranslationServiceError.fatalAPIError("Claude declined to translate this chunk (refusal). Try a different model or rephrase the prompt.")
            }
            return decoded.outputText
        case .google:
            let decoded = try JSONDecoder().decode(GeminiResponseEnvelope.self, from: data)
            if decoded.candidates?.first?.finishReason == "MAX_TOKENS" {
                throw TranslationServiceError.responseTooLarge("The model's reply was cut off at its output-token limit.")
            }
            return decoded.outputText
        case .local, .openRouter:
            let decoded = try JSONDecoder().decode(ChatCompletionsEnvelope.self, from: data)
            guard let choice = decoded.choices?.first else {
                // Some local servers (LM Studio among them) report errors as a
                // 200 with an "error" body — surface their message instead of
                // a generic parse failure.
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let message = body?["error"] as? String
                    ?? (body?["error"] as? [String: Any])?["message"] as? String {
                    throw TranslationServiceError.apiError("Local server error: \(message)")
                }
                throw TranslationServiceError.invalidResponse
            }
            if choice.finish_reason == "length" {
                throw TranslationServiceError.responseTooLarge("The model's reply was cut off at its output-token limit.")
            }
            // Reasoning models (e.g. Qwen3.6 in LM Studio) can land the whole
            // constrained answer in reasoning_content with content empty; the
            // strict downstream validation rejects anything that isn't the
            // requested subtitle JSON, so falling back is safe.
            let candidates = [choice.message?.content, choice.message?.reasoning_content]
            guard let content = candidates
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else {
                throw TranslationServiceError.invalidResponse
            }
            return content
        }
    }

    /// Turns a provider error response into a single actionable sentence
    /// instead of dumping raw JSON into the run log, and marks errors that
    /// retrying cannot fix as fatal so the retry loop stops immediately.
    static func classifyAPIError(
        provider: TranslationProvider,
        data: Data,
        statusCode: Int,
        model: String
    ) -> TranslationServiceError {
        // Every provider nests {"error": {"message": ...}}; codes vary in
        // shape, so dig leniently instead of decoding a strict envelope.
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errorBody = body?["error"] as? [String: Any]
        let message = errorBody?["message"] as? String
        let code = errorBody?["code"] as? String ?? errorBody?["status"] as? String
        let name = provider.label

        if statusCode == 401 || statusCode == 403 {
            return .fatalAPIError("\(name) rejected the API key (\(statusCode)). Check the key in Settings.")
        }
        if statusCode == 402 {
            // OpenRouter reports an empty balance as 402; retrying cannot
            // fix it until the account is topped up.
            return .fatalAPIError("\(name) reports insufficient credits (402). Top up the account and try again.")
        }
        if statusCode == 429 {
            return .apiError(message ?? "\(name) rate limit or quota exceeded (429). Try again later or check billing.")
        }
        if statusCode == 404 || code == "model_not_found" || code == "NOT_FOUND" {
            return .fatalAPIError("\(name) does not recognize the model \"\(model)\". Set a valid model in Settings.")
        }
        if statusCode == 400 {
            // A 400 caused by input-size limits is fixable by splitting the
            // chunk; every other 400 is a request-shape problem retrying
            // cannot fix.
            let lowered = (message ?? "").lowercased()
            let sizeHints = ["token", "too long", "length", "exceed", "context"]
            if sizeHints.contains(where: lowered.contains) {
                return .responseTooLarge("\(name) rejected the request as too large (400): \(message ?? "request too large").")
            }
            return .fatalAPIError("\(name) rejected the request (400): \(message ?? "invalid request"). Check the model in Settings supports structured JSON output.")
        }
        if let message {
            return .apiError("\(name) error (\(statusCode)): \(message)")
        }
        return .apiError("\(name) returned status \(statusCode).")
    }

    /// Collects the most recent already-translated pairs that precede a chunk,
    /// so the model can keep names, terminology, and tone consistent across
    /// chunk boundaries.
    private static func contextPairs(
        before chunk: [TranscriptionSegment],
        in segments: [TranscriptionSegment],
        translatedByID: [Int: String],
        limit: Int = 8
    ) -> [TranslationContextPair] {
        guard let firstID = chunk.first?.id,
              let chunkStart = segments.firstIndex(where: { $0.id == firstID })
        else {
            return []
        }
        return Array(
            segments[..<chunkStart]
                .compactMap { segment -> TranslationContextPair? in
                    guard let translation = translatedByID[segment.id] else { return nil }
                    return TranslationContextPair(source: segment.text, translation: translation)
                }
                .suffix(limit)
        )
    }

    static func validate(_ translated: [TranslatedSegment], expected segments: [TranscriptionSegment]) throws {
        let expectedIDs = Set(segments.map(\.id))
        let actualIDs = Set(translated.map(\.id))

        guard expectedIDs == actualIDs else {
            let missing = expectedIDs.subtracting(actualIDs).sorted()
            let extra = actualIDs.subtracting(expectedIDs).sorted()
            throw TranslationServiceError.validationFailed("Translation returned mismatched segment ids. Missing: \(missing). Extra: \(extra).")
        }
        // Set comparison alone would let a duplicated id mask a dropped one.
        guard translated.count == segments.count else {
            throw TranslationServiceError.validationFailed("Translation returned \(translated.count) segment(s) for \(segments.count) input segment(s) (duplicate ids).")
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
    let format: TranslationTextFormat
}

private struct TranslationTextFormat: Encodable {
    let type: String
    let name: String
    let strict: Bool
    let schema: JSONValue
}

/// Minimal JSON tree that can be encoded with JSONEncoder, used to embed the
/// structured-output schema in the request body.
/// Internal (not private) because it appears in makeRequest's signature,
/// which is internal for tests.
enum JSONValue: Encodable {
    case string(String)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }
}

/// Structured-output schema so the Responses API is guaranteed to return
/// exactly {"segments":[{"id":Int,"text":String}]} — no code fences, no prose.
/// Internal (not private) because it is a default argument of makeRequest,
/// which is internal for tests.
enum TranslationSchema {
    static let segments: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "segments": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("integer")]),
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("id"), .string("text")]),
                    "additionalProperties": .bool(false)
                ])
            ])
        ]),
        "required": .array([.string("segments")]),
        "additionalProperties": .bool(false)
    ])
}

private struct OpenAIResponseEnvelope: Decodable {
    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    let output: [OpenAIOutputItem]
    let status: String?
    let incomplete_details: IncompleteDetails?

    var outputText: String {
        output
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined(separator: "")
    }
}

private struct OpenAIOutputItem: Decodable {
    // Reasoning models emit {"type":"reasoning"} items with no content key.
    let content: [OpenAIOutputContent]?
}

private struct OpenAIOutputContent: Decodable {
    let text: String?
}

// MARK: - Anthropic Messages API types

private struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct OutputConfig: Encodable {
        let format: OutputFormat
    }
    struct OutputFormat: Encodable {
        let type: String
        let schema: JSONValue
    }

    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]
    let output_config: OutputConfig
}

private struct AnthropicResponseEnvelope: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let content: [ContentBlock]
    let stop_reason: String?

    var outputText: String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}

// MARK: - Local OpenAI-compatible chat-completions types

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct ResponseFormat: Encodable {
        let type: String
        let json_schema: JSONSchemaFormat
    }
    struct JSONSchemaFormat: Encodable {
        let name: String
        let strict: Bool
        let schema: JSONValue
    }

    let model: String
    let messages: [Message]
    let response_format: ResponseFormat
    let stream: Bool
}

private struct ChatCompletionsEnvelope: Decodable {
    struct Choice: Decodable {
        let message: ChoiceMessage?
        let finish_reason: String?
    }
    struct ChoiceMessage: Decodable {
        let content: String?
        // Reasoning models served by LM Studio can emit the entire
        // schema-constrained answer into this channel, leaving content empty.
        let reasoning_content: String?
    }

    let choices: [Choice]?
}

// MARK: - Google Gemini API types

private struct GeminiRequest: Encodable {
    struct Part: Encodable {
        let text: String
    }
    struct SystemInstruction: Encodable {
        let parts: [Part]
    }
    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }
    struct GenerationConfig: Encodable {
        let responseMimeType: String
        let responseJsonSchema: JSONValue
    }

    let systemInstruction: SystemInstruction
    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiResponseEnvelope: Decodable {
    struct Candidate: Decodable {
        let content: CandidateContent?
        let finishReason: String?
    }
    struct CandidateContent: Decodable {
        let parts: [CandidatePart]?
    }
    struct CandidatePart: Decodable {
        let text: String?
    }

    let candidates: [Candidate]?

    var outputText: String {
        (candidates ?? [])
            .compactMap(\.content?.parts)
            .flatMap { $0 }
            .compactMap(\.text)
            .joined()
    }
}

struct TranslatedSegmentsPayload: Decodable {
    let segments: [TranslatedSegment]
}

private struct SummaryPayload: Decodable {
    let summary: String
}

struct TranslatedSegment: Decodable {
    let id: Int
    let text: String

    init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
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
