import Foundation

/// A half-open time range `[start, end)` in seconds covering part of a WAV.
struct SpeechChunk: Equatable, Sendable {
    let start: Double
    let end: Double
}

/// Silence-aware chunk planning and resume bookkeeping shared by the built-in
/// engine and the Python helper (which mirrors this logic in `plan_speech_chunks`).
enum TranscriptionChunkPlanner {
    static let defaultMinSilence = 0.5
    static let defaultTargetChunk = 300.0
    static let defaultMaxChunk = 600.0
    static let defaultFirstTarget = 90.0

    /// Chunks whose end is at or before `resumeThrough` are treated as finished.
    static func pendingChunks(_ chunks: [SpeechChunk], resumeThrough: Double) -> [SpeechChunk] {
        guard resumeThrough > 0 else { return chunks }
        return chunks.filter { $0.end > resumeThrough + 0.01 }
    }

    /// Merges a freshly transcribed batch into saved partials without duplicating
    /// cues from an interrupted re-run of the same chunk.
    static func mergePartialSegments(
        existing: [TranscriptionSegment],
        batch: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        guard !batch.isEmpty else { return existing }
        let replaceFrom = batch.map(\.start).min() ?? 0
        // Keep saved cues that end exactly at the resume frontier (a chunk
        // boundary is a cue boundary); drop only cues that reach into the
        // range the batch re-transcribed.
        var merged = existing.filter { $0.end <= replaceFrom + 0.01 }
        merged.append(contentsOf: batch)
        return merged
    }

    /// Combines saved partials with segments from a resumed run for the final
    /// post-processor pass.
    static func combinedSegments(
        partials: [TranscriptionSegment],
        newlyCollected: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        mergePartialSegments(existing: partials, batch: newlyCollected)
    }

    /// Plans cut points using RMS silence detection. Matches `plan_speech_chunks`
    /// in the Python helper so resume boundaries stay aligned across backends.
    static func planSpeechChunks(
        samples: [Float],
        sampleRate: Int,
        minSilence: Double = defaultMinSilence,
        targetChunk: Double = defaultTargetChunk,
        maxChunk: Double = defaultMaxChunk,
        firstTarget: Double = defaultFirstTarget
    ) -> [SpeechChunk] {
        let totalSeconds = Double(samples.count) / Double(sampleRate)
        if totalSeconds <= maxChunk {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }

        let frame = max(1, Int(Double(sampleRate) * 0.05))
        let usableCount = (samples.count / frame) * frame
        guard usableCount > 0 else {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }

        let frameCount = usableCount / frame
        var rms = [Float](repeating: 0, count: frameCount)
        let blockFrames = 4096
        var frameIndex = 0
        while frameIndex < frameCount {
            let blockEnd = min(frameIndex + blockFrames, frameCount)
            for index in frameIndex..<blockEnd {
                let offset = index * frame
                var sum: Float = 0
                for sample in samples[offset..<(offset + frame)] {
                    sum += sample * sample
                }
                rms[index] = sqrt(sum / Float(frame))
            }
            frameIndex = blockEnd
        }

        guard let peak = rms.max(), peak > 0 else {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }

        let sorted = rms.sorted()
        let percentileIndex = Int(Double(sorted.count - 1) * 0.95)
        let reference = sorted[max(0, min(percentileIndex, sorted.count - 1))]
        // Samples are normalized to [-1, 1] here, while the Python helper
        // works on raw int16 values: its floor of 1.0 becomes 1/32768 in
        // these units. A floor of 1.0 would call every frame silent and cut
        // in the middle of speech.
        let threshold = max(1.0 / 32_768.0, 0.1 * Double(reference))
        let frameSeconds = Double(frame) / Double(sampleRate)

        var candidates: [Double] = []
        var runStart: Int?
        for (index, value) in rms.enumerated() {
            if Double(value) < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let runLength = Double(index - start) * frameSeconds
                if runLength >= minSilence {
                    let center = Double(start) + Double(index - start) / 2.0
                    candidates.append(center * frameSeconds)
                }
                runStart = nil
            }
        }
        if let start = runStart {
            let runLength = Double(rms.count - start) * frameSeconds
            if runLength >= minSilence {
                let center = Double(start) + Double(rms.count - start) / 2.0
                candidates.append(center * frameSeconds)
            }
        }

        guard !candidates.isEmpty else {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }

        var chunks: [SpeechChunk] = []
        var start = 0.0
        for _ in 0..<10_000 {
            let remaining = totalSeconds - start
            if remaining <= maxChunk {
                chunks.append(SpeechChunk(start: start, end: totalSeconds))
                break
            }
            let inWindow = candidates.filter { $0 > start + minSilence && $0 <= start + maxChunk }
            let desired = chunks.isEmpty ? firstTarget : targetChunk
            let cut: Double
            if let best = inWindow.min(by: { abs($0 - (start + desired)) < abs($1 - (start + desired)) }) {
                cut = best
            } else if let later = candidates.first(where: { $0 > start + maxChunk }) {
                cut = later
            } else {
                chunks.append(SpeechChunk(start: start, end: totalSeconds))
                break
            }
            chunks.append(SpeechChunk(start: start, end: cut))
            start = cut
        }
        return chunks
    }
}
