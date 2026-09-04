import Foundation
import os

struct TranscriptionResult {
    let backend: String
    let segments: [TranscriptionSegment]
}

struct TranscriptionMetrics: Codable, Equatable, Sendable {
    let backend: String
    let audioDurationSeconds: Double
    let audioLoadSeconds: Double
    let chunkPlanningSeconds: Double
    let modelLoadSeconds: Double
    let inferenceSeconds: Double
    let normalizationSeconds: Double
    let pipelineSeconds: Double
    let audioPreparationSeconds: Double
    let totalSeconds: Double
    let chunkCount: Int
    let inferenceRTF: Double
    let totalRTF: Double

    var logSummary: String {
        String(
            format:
                "Qwen metrics — audio %.1fs, prepare %.2fs, load WAV %.2fs, plan %.2fs, model %.2fs, inference+alignment %.2fs, normalize %.2fs, total %.2fs, chunks %d, inference RTF %.3fx, total RTF %.3fx.",
            audioDurationSeconds,
            audioPreparationSeconds,
            audioLoadSeconds,
            chunkPlanningSeconds,
            modelLoadSeconds,
            inferenceSeconds,
            normalizationSeconds,
            totalSeconds,
            chunkCount,
            inferenceRTF,
            totalRTF
        )
    }
}

enum TranscriptionServiceError: LocalizedError {
    case pythonFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .pythonFailed(let message):
            return message
        case .malformedResponse:
            return "The transcription helper returned malformed JSON."
        }
    }
}

struct TranscriptionService {
    private let workerPool: PythonWorkerPool

    init(workerPool: PythonWorkerPool = .shared) {
        self.workerPool = workerPool
    }

    /// Decides which engine runs a job. `.auto` resolves to the built-in
    /// whisper.cpp engine (always available); explicitly chosen backends run
    /// as stored. A legacy `.auto` setting can be paired with a non-GGML
    /// model, which the native engine cannot load, so the run substitutes
    /// the built-in default model. A stored GGML model is kept as-is; the
    /// store's normalization makes an `.auto` + GGML pairing unreachable
    /// today, but it is handled here anyway so this function does not
    /// depend on that invariant (hand-edited plists exist). Resolution is
    /// per-dispatch and never rewrites the user's stored settings.
    static func resolveDispatch(
        backend: WhisperBackend,
        model: String
    ) -> (backend: WhisperBackend, model: String) {
        guard backend == .auto else {
            return (backend, model)
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return (.native, trimmed.hasPrefix("ggml-") ? trimmed : ModelDownloader.defaultModel)
    }

    @MainActor
    func transcribe(
        videoURL: URL,
        settings: JobSettingsSnapshot,
        resumeThrough: Double = 0,
        existingPartialSegments: [TranscriptionSegment] = [],
        progress: @escaping @MainActor (JobProgress) -> Void,
        onSegments: (@MainActor ([TranscriptionSegment]) -> Void)? = nil,
        onChunkComplete: (@MainActor (Double) -> Void)? = nil,
        onMetrics: (@MainActor (TranscriptionMetrics) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let resolved = Self.resolveDispatch(backend: settings.whisperBackend, model: settings.whisperModel)
        let snapshot = TranscriptionSettingsSnapshot(
            sourceLanguage: settings.sourceLanguage,
            qwenContext: settings.qwenContext,
            whisperModel: resolved.model,
            whisperBackendRawValue: resolved.backend.rawValue,
            preprocessAudio: settings.preprocessAudio,
            vadFilter: settings.vadFilter,
            removeEmptySegments: settings.removeEmptySegments,
            removeRepeatedText: settings.removeRepeatedText,
            mergeShortSegments: settings.mergeShortSegments,
            minSegmentDuration: settings.minSegmentDuration,
            maxMergeGap: settings.maxMergeGap,
            beamSize: settings.beamSize,
            bestOf: settings.bestOf,
            temperature: settings.temperature,
            noSpeechThreshold: settings.noSpeechThreshold
        )

        if resolved.backend == .native {
            return try await transcribeNatively(
                videoURL: videoURL,
                snapshot: snapshot,
                resumeThrough: resumeThrough,
                existingPartialSegments: existingPartialSegments,
                progress: progress,
                onSegments: onSegments,
                onChunkComplete: onChunkComplete
            )
        }

        // Extract audio natively (AVFoundation) so the helper skips its ffmpeg
        // step. "Clean audio" preprocessing is ffmpeg-only, so when it is on
        // and ffmpeg exists the helper keeps running its own filter chain.
        let wantsPreprocess = snapshot.preprocessAudio && ProcessEnvironment.hasFFmpeg
        let cachedWav = try AudioCache.cachedAudioURL(for: videoURL, preprocess: wantsPreprocess)
        var audioWavPath: String?
        let cachedWavSize = (try? FileManager.default.attributesOfItem(atPath: cachedWav.path)[.size] as? UInt64) ?? 0
        if cachedWavSize > 0 {
            // Safe: extraction is atomic (temp file + move), so existence == validity;
            // the size > 0 check mirrors the Python helper's cache-hit rule, since
            // the cache is shared with entries it writes.
            audioWavPath = cachedWav.path
        } else if !wantsPreprocess {
            progress(JobProgress(stage: .extractingAudio, detail: "Extracting audio.", fraction: 0.08))
            do {
                try await AudioExtractor.extract(from: videoURL, to: cachedWav)
                AudioCache.prune(directory: AudioCache.directory, keeping: cachedWav)
                audioWavPath = cachedWav.path
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Exotic container AVFoundation can't read: fall back to the
                // Python/ffmpeg path by passing nothing. Never worse than today.
                let fallback =
                    ProcessEnvironment.hasFFmpeg
                    ? "falling back to ffmpeg."
                    : "this file may need ffmpeg installed."
                progress(
                    JobProgress(
                        stage: .extractingAudio,
                        detail: "Native extraction failed (\(error.localizedDescription)); \(fallback)",
                        fraction: 0.08
                    ))
            }
        }
        // wantsPreprocess && no cache → pass nothing; the Python helper runs
        // its ffmpeg filter chain exactly as today.

        let request = PythonJobRequest(
            inputPath: videoURL.path,
            language: snapshot.sourceLanguage,
            qwenContext: snapshot.qwenContext,
            model: snapshot.whisperModel,
            backend: snapshot.whisperBackendRawValue,
            preprocessAudio: snapshot.preprocessAudio,
            vadFilter: snapshot.vadFilter,
            beamSize: snapshot.beamSize,
            bestOf: snapshot.bestOf,
            temperature: snapshot.temperature,
            noSpeechThreshold: snapshot.noSpeechThreshold,
            streamSegments: true,
            // The one-shot CLI passed this as "%.3f"; keep the same precision.
            resumeThroughSeconds: (resumeThrough * 1000).rounded() / 1000,
            startingSegmentID: existingPartialSegments.map(\.id).max().map { $0 + 1 } ?? 1,
            audioWav: audioWavPath
        )

        // The resident helper streams the same stderr events the one-shot
        // helper did; the pool delivers them in emission order and a serial
        // hop to the main queue keeps progress and segment updates ordered.
        let result = try await workerPool.run(request) { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch event {
                    case .progress(let update):
                        progress(update)
                    case .segments(let batch):
                        let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: snapshot)
                        if !cleaned.isEmpty { onSegments?(cleaned) }
                    case .chunkComplete(let through):
                        onChunkComplete?(through)
                    case .metrics(let metrics):
                        onMetrics?(metrics)
                    }
                }
            }
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        let segments = TranscriptionPostProcessor.cleanResumed(
            partials: existingPartialSegments,
            newlyCollected: result.segments,
            settings: snapshot
        )
        return TranscriptionResult(backend: result.backend, segments: segments)
    }

    /// Fully in-process path for the built-in whisper.cpp backend: native
    /// audio extraction → model download (short-circuits when installed) →
    /// WhisperCppEngine → the same TranscriptionPostProcessor cleanup the
    /// Python backends get. "Clean audio" preprocessing is ffmpeg-only by
    /// design, so this path always uses plain extraction under the
    /// preprocess=false cache key regardless of the toggle.
    @MainActor
    private func transcribeNatively(
        videoURL: URL,
        snapshot: TranscriptionSettingsSnapshot,
        resumeThrough: Double,
        existingPartialSegments: [TranscriptionSegment],
        progress: @escaping @MainActor (JobProgress) -> Void,
        onSegments: (@MainActor ([TranscriptionSegment]) -> Void)? = nil,
        onChunkComplete: (@MainActor (Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let cachedWav = try AudioCache.cachedAudioURL(for: videoURL, preprocess: false)
        let cachedWavSize = (try? FileManager.default.attributesOfItem(atPath: cachedWav.path)[.size] as? UInt64) ?? 0
        if cachedWavSize > 0 {
            progress(JobProgress(stage: .extractingAudio, detail: "Using cached extracted audio.", fraction: 0.12))
        } else {
            progress(JobProgress(stage: .extractingAudio, detail: "Extracting audio.", fraction: 0.08))
            // The extractor throttles to 5% steps; mapped into the same
            // 0.08–0.12 band the Python helper uses for extraction. A
            // container AVFoundation cannot demux (MKV) falls back to ffmpeg
            // when it is installed, instead of failing the job.
            let route = try await AudioSourceExtractor.extract(from: videoURL, to: cachedWav) { fraction in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        progress(
                            JobProgress(
                                stage: .extractingAudio,
                                detail: "Extracting audio.",
                                fraction: 0.08 + fraction * 0.04
                            ))
                    }
                }
            }
            if route == .ffmpeg {
                progress(
                    JobProgress(
                        stage: .extractingAudio,
                        detail: "Extracted audio with ffmpeg (macOS could not read this container).",
                        fraction: 0.12
                    ))
            }
            AudioCache.prune(directory: AudioCache.directory, keeping: cachedWav)
        }

        // whisper_full's abort callback fires on whisper's worker threads,
        // which have no current Task; cancellation travels through this
        // thread-independent flag instead of Task.isCancelled.
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            let modelURL = try await ModelDownloader().ensureInstalled(model: snapshot.whisperModel) { update in
                // ensureInstalled reports on a background queue; hop to the
                // main actor in emission order before touching UI state. Its
                // raw 0–1 download fraction is remapped into the 0.12–0.18
                // band (the Python path pins loadingModel at 0.18) so the
                // bar does not hit 100% mid-download; the detail text keeps
                // the downloader's "(N%)" wording.
                let remapped = JobProgress(
                    stage: update.stage,
                    detail: update.detail,
                    fraction: update.fraction.map { 0.12 + $0 * 0.06 }
                )
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        progress(remapped)
                    }
                }
            }
            try Task.checkCancellation()
            progress(JobProgress(stage: .transcribing, detail: "Transcribing with the built-in engine.", fraction: 0.2))
            let startingSegmentID = existingPartialSegments.map(\.id).max().map { $0 + 1 } ?? 1
            let result = try await WhisperCppEngine().transcribe(
                wavURL: cachedWav,
                modelURL: modelURL,
                language: snapshot.sourceLanguage,
                beamSize: snapshot.beamSize,
                noSpeechThreshold: snapshot.noSpeechThreshold,
                resumeThrough: resumeThrough,
                startingSegmentID: startingSegmentID,
                onProgress: { fraction in
                    // Inference 0→1 mapped into the 0.2–0.92 transcribing
                    // band, matching the Python helpers' fraction range.
                    let clamped = max(0, min(1, fraction))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            progress(
                                JobProgress(
                                    stage: .transcribing,
                                    detail: "Transcribing with the built-in engine.",
                                    fraction: 0.2 + clamped * 0.72
                                ))
                        }
                    }
                },
                onSegments: { batch in
                    let cleaned = TranscriptionPostProcessor.cleanWindow(batch, settings: snapshot)
                    guard !cleaned.isEmpty else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { onSegments?(cleaned) }
                    }
                },
                onChunkComplete: { chunkEnd in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { onChunkComplete?(chunkEnd) }
                    }
                },
                isCancelled: { cancelFlag.withLock { $0 } }
            )
            // A cancel landing after whisper_full's last abort poll would
            // otherwise report success; re-check like the Python path does
            // after its subprocess exits.
            try Task.checkCancellation()
            let segments = TranscriptionPostProcessor.cleanResumed(
                partials: existingPartialSegments,
                newlyCollected: result.segments,
                settings: snapshot
            )
            return TranscriptionResult(backend: WhisperBackend.native.rawValue, segments: segments)
        } onCancel: {
            cancelFlag.withLock { $0 = true }
        }
    }

}

struct TranscriptionSettingsSnapshot: Sendable {
    let sourceLanguage: String
    let qwenContext: String
    let whisperModel: String
    let whisperBackendRawValue: String
    let preprocessAudio: Bool
    let vadFilter: Bool
    let removeEmptySegments: Bool
    let removeRepeatedText: Bool
    let mergeShortSegments: Bool
    let minSegmentDuration: Double
    let maxMergeGap: Double
    let beamSize: Int
    let bestOf: Int
    let temperature: Double
    let noSpeechThreshold: Double
}

enum TranscriptionPostProcessor {
    static func clean(_ segments: [TranscriptionSegment], settings: TranscriptionSettingsSnapshot) -> [TranscriptionSegment] {
        var cleaned = segments.map { segment in
            TranscriptionSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: normalizeWhitespace(segment.text)
            )
        }

        if settings.removeRepeatedText {
            cleaned = cleaned.map { segment in
                TranscriptionSegment(
                    id: segment.id,
                    start: segment.start,
                    end: segment.end,
                    text: collapseRepeatedText(segment.text)
                )
            }
            cleaned = removeAdjacentDuplicates(cleaned)
            cleaned = removeEchoesAfterSilence(cleaned)
        }

        if settings.removeEmptySegments {
            cleaned = cleaned.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        if settings.mergeShortSegments {
            cleaned = mergeShortSegments(cleaned, minDuration: settings.minSegmentDuration, maxGap: settings.maxMergeGap)
        }

        cleaned = repairInvalidTimings(cleaned)
        cleaned = repairLongDurations(cleaned)

        return renumber(cleaned)
    }

    /// Final pass for a run that may have resumed from saved partials. The
    /// partials (streamed, window-cleaned, carrying their streamed ids) and
    /// the newly transcribed raw segments are merged on the time axis first,
    /// then cleaned as one transcript: the cross-segment passes (dedupe,
    /// merge) see the whole file, and ids are renumbered once from 1 —
    /// cleaning the new half alone would restart its ids at 1 and collide
    /// with the saved half, breaking translation lookups and SRT numbering.
    static func cleanResumed(
        partials: [TranscriptionSegment],
        newlyCollected: [TranscriptionSegment],
        settings: TranscriptionSettingsSnapshot
    ) -> [TranscriptionSegment] {
        clean(
            TranscriptionChunkPlanner.combinedSegments(partials: partials, newlyCollected: newlyCollected),
            settings: settings
        )
    }

    /// Window-local subset of `clean` for streamed batches: deterministic,
    /// idempotent, per-segment only. No renumbering (ids are globally
    /// monotonic across windows), no merges, no cross-window dedupe — the
    /// full `clean` pass at completion remains authoritative.
    static func cleanWindow(_ segments: [TranscriptionSegment], settings: TranscriptionSettingsSnapshot) -> [TranscriptionSegment] {
        var cleaned = segments.map { segment in
            TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: normalizeWhitespace(segment.text))
        }
        if settings.removeRepeatedText {
            cleaned = cleaned.map { segment in
                TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: collapseRepeatedText(segment.text))
            }
        }
        if settings.removeEmptySegments {
            cleaned = cleaned.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return repairInvalidTimings(cleaned)
    }

    /// Whisper-style transcribers sometimes stretch a short utterance across
    /// a long run of silence or music. Cap the display time to roughly what
    /// the text needs to be read, so a one-word subtitle does not linger on
    /// screen for half a minute.
    private static func repairLongDurations(
        _ segments: [TranscriptionSegment],
        maximumDuration: Double = 8.0
    ) -> [TranscriptionSegment] {
        segments.map { segment in
            guard segment.end - segment.start > maximumDuration else { return segment }
            let readingTime = 0.8 + Double(segment.text.count) * 0.35
            let allowed = min(maximumDuration, max(1.5, readingTime))
            return TranscriptionSegment(
                id: segment.id,
                start: segment.start,
                end: segment.start + allowed,
                text: segment.text
            )
        }
    }

    /// Transcribers occasionally emit segments with zero or near-zero
    /// duration (word-level alignment of an isolated word). A subtitle that
    /// displays for 0s is useless in a player, so extend it to a readable
    /// minimum without overlapping the next segment.
    static func repairInvalidTimings(
        _ segments: [TranscriptionSegment],
        minimumDuration: Double = 0.8,
        gapToNext: Double = 0.05
    ) -> [TranscriptionSegment] {
        var result = segments
        for index in result.indices {
            let segment = result[index]
            guard segment.end - segment.start < 0.2 else { continue }
            var end = segment.start + minimumDuration
            if index + 1 < result.count {
                let capped = min(end, result[index + 1].start - gapToNext)
                // When the next segment starts at or before this one, a
                // brief overlap beats leaving a zero-length cue in place.
                if capped > segment.start {
                    end = capped
                }
            }
            result[index] = TranscriptionSegment(
                id: segment.id,
                start: segment.start,
                end: end,
                text: segment.text
            )
        }
        return result
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseRepeatedText(_ text: String) -> String {
        var current = normalizeWhitespace(text)
        guard !current.isEmpty else { return "" }

        // Iterate until stable (with a cap to protect against pathological input)
        for _ in 0..<10 {
            let previous = current
            current = collapseRepeatedTextPass(current)
            if current == previous {
                break  // Reached fixed point
            }
        }
        return current
    }

    private static func collapseRepeatedTextPass(_ text: String) -> String {
        let trimmed = normalizeWhitespace(text)
        guard !trimmed.isEmpty else { return "" }

        let words = trimmed.split(separator: " ").map(String.init)
        if words.count >= 4 {
            for phraseLength in stride(from: min(8, words.count / 2), through: 1, by: -1) {
                var output: [String] = []
                var index = 0
                while index < words.count {
                    let phrase = Array(words[index..<min(index + phraseLength, words.count)])
                    var next = index + phraseLength
                    var repeated = false
                    while next + phraseLength <= words.count && Array(words[next..<next + phraseLength]) == phrase {
                        repeated = true
                        next += phraseLength
                    }
                    output.append(contentsOf: phrase)
                    index = repeated ? next : index + phraseLength
                }
                let candidate = output.joined(separator: " ")
                if candidate.count < trimmed.count {
                    return candidate
                }
            }
        }

        let scalars = Array(trimmed)
        guard scalars.count >= 8 else { return trimmed }
        for length in stride(from: min(20, scalars.count / 2), through: 2, by: -1) {
            let first = String(scalars.prefix(length))
            var cursor = length
            var repeats = 1
            while cursor + length <= scalars.count && String(scalars[cursor..<cursor + length]) == first {
                repeats += 1
                cursor += length
            }
            if repeats >= 2 && cursor == scalars.count {
                return first
            }
        }
        return trimmed
    }

    private static func removeAdjacentDuplicates(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        for segment in segments {
            let normalized = comparableText(segment.text)
            if let last = result.last {
                let previous = comparableText(last.text)
                let closeInTime = segment.start - last.end <= 0.35
                if closeInTime && !normalized.isEmpty && normalized == previous {
                    result[result.count - 1] = TranscriptionSegment(
                        id: last.id,
                        start: last.start,
                        end: max(last.end, segment.end),
                        text: last.text
                    )
                    continue
                }
            }
            result.append(segment)
        }
        return result
    }

    private static func removeEchoesAfterSilence(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        for segment in segments {
            if let last = result.last, isLikelySilenceEcho(segment, after: last) {
                continue
            }
            result.append(segment)
        }
        return result
    }

    private static func isLikelySilenceEcho(_ segment: TranscriptionSegment, after previous: TranscriptionSegment) -> Bool {
        let gap = segment.start - previous.end
        guard gap >= 1.5 else { return false }

        let current = comparableText(segment.text)
        let prior = comparableText(previous.text)
        let minimumLength = gap >= 4 ? 6 : 8
        guard current.count >= minimumLength, prior.count >= minimumLength else {
            return false
        }

        let duration = segment.end - segment.start
        let similarity = textSimilarity(current, prior)
        if current == prior {
            return duration >= 0.8
        }
        return duration >= 1.2 && similarity >= 0.9
    }

    private static func comparableText(_ text: String) -> String {
        text
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    private static func textSimilarity(_ first: String, _ second: String) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        if first == second { return 1 }

        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        let distance = editDistance(firstCharacters, secondCharacters)
        let longest = max(firstCharacters.count, secondCharacters.count)
        return 1 - (Double(distance) / Double(max(longest, 1)))
    }

    private static func editDistance(_ first: [Character], _ second: [Character]) -> Int {
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        var previous = Array(0...second.count)
        var current = Array(repeating: 0, count: second.count + 1)

        for firstIndex in 1...first.count {
            current[0] = firstIndex
            for secondIndex in 1...second.count {
                let substitutionCost = first[firstIndex - 1] == second[secondIndex - 1] ? 0 : 1
                current[secondIndex] = min(
                    previous[secondIndex] + 1,
                    current[secondIndex - 1] + 1,
                    previous[secondIndex - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[second.count]
    }

    private static func mergeShortSegments(_ segments: [TranscriptionSegment], minDuration: Double, maxGap: Double) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        for segment in segments {
            let duration = segment.end - segment.start
            if duration < minDuration,
                let last = result.last,
                segment.start - last.end <= maxGap
            {
                result[result.count - 1] = TranscriptionSegment(
                    id: last.id,
                    start: last.start,
                    end: max(last.end, segment.end),
                    text: normalizeWhitespace("\(last.text) \(segment.text)")
                )
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func renumber(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.enumerated().map { index, segment in
            TranscriptionSegment(id: index + 1, start: segment.start, end: segment.end, text: segment.text)
        }
    }
}

enum TranscriptionStreamEvent: Equatable, Sendable {
    case progress(JobProgress)
    case segments([TranscriptionSegment])
    case chunkComplete(Double)
    case metrics(TranscriptionMetrics)

    private struct SegmentsEnvelope: Decodable {
        let event: String
        let segments: [TranscriptionSegment]
    }

    private struct ChunkCompleteEnvelope: Decodable {
        let event: String
        let through: Double
    }

    private struct ProgressEnvelope: Decodable {
        let stage: JobStage
        let detail: String
        let fraction: Double?
    }

    private struct MetricsEnvelope: Decodable {
        let event: String
        let metrics: TranscriptionMetrics
    }

    static func decode(_ line: String) -> TranscriptionStreamEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        // Progress lines are by far the most frequent and always start with
        // their "stage" key; decode them first when the prefix says so rather
        // than after three failed envelope decodes. The full chain below
        // still handles any key order.
        if line.hasPrefix("{\"stage\""), let envelope = try? JSONDecoder().decode(ProgressEnvelope.self, from: data) {
            return .progress(JobProgress(stage: envelope.stage, detail: envelope.detail, fraction: envelope.fraction))
        }
        if let envelope = try? JSONDecoder().decode(SegmentsEnvelope.self, from: data), envelope.event == "segments" {
            return .segments(envelope.segments)
        }
        if let envelope = try? JSONDecoder().decode(ChunkCompleteEnvelope.self, from: data), envelope.event == "chunk_complete" {
            return .chunkComplete(envelope.through)
        }
        if let envelope = try? JSONDecoder().decode(MetricsEnvelope.self, from: data), envelope.event == "metrics" {
            return .metrics(envelope.metrics)
        }
        if let envelope = try? JSONDecoder().decode(ProgressEnvelope.self, from: data) {
            return .progress(JobProgress(stage: envelope.stage, detail: envelope.detail, fraction: envelope.fraction))
        }
        return nil
    }
}

// ProcessBox and PipeCollector live in Sources/Support so the ffmpeg
// fallback, the Python worker pool, and diagnostics share them.
