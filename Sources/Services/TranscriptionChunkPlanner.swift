import Accelerate
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
    ///
    /// The frame energies come from vDSP; the scalar version below is kept as
    /// the oracle the vector tests compare against (`referencePlanSpeechChunks`).
    static func planSpeechChunks(
        samples: [Float],
        sampleRate: Int,
        minSilence: Double = defaultMinSilence,
        targetChunk: Double = defaultTargetChunk,
        maxChunk: Double = defaultMaxChunk,
        firstTarget: Double = defaultFirstTarget
    ) -> [SpeechChunk] {
        plan(
            samples: samples, sampleRate: sampleRate, minSilence: minSilence, targetChunk: targetChunk,
            maxChunk: maxChunk, firstTarget: firstTarget, rms: frameRMS, cuts: chooseCuts
        )
    }

    /// Scalar implementation, retained only as the test oracle for the
    /// vectorised planner. Not used by production code paths.
    static func referencePlanSpeechChunks(
        samples: [Float],
        sampleRate: Int,
        minSilence: Double = defaultMinSilence,
        targetChunk: Double = defaultTargetChunk,
        maxChunk: Double = defaultMaxChunk,
        firstTarget: Double = defaultFirstTarget
    ) -> [SpeechChunk] {
        plan(
            samples: samples, sampleRate: sampleRate, minSilence: minSilence, targetChunk: targetChunk,
            maxChunk: maxChunk, firstTarget: firstTarget, rms: referenceFrameRMS, cuts: referenceChooseCuts
        )
    }

    private static func plan(
        samples: [Float],
        sampleRate: Int,
        minSilence: Double,
        targetChunk: Double,
        maxChunk: Double,
        firstTarget: Double,
        rms: ([Float], Int) -> [Float],
        cuts: ([Double], Double, Double, Double, Double, Double) -> [SpeechChunk]
    ) -> [SpeechChunk] {
        let totalSeconds = Double(samples.count) / Double(sampleRate)
        if totalSeconds <= maxChunk {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }

        let frame = max(1, Int(Double(sampleRate) * 0.05))
        let values = rms(samples, frame)
        // An empty frame list (fewer samples than one frame) and an all-zero
        // signal both fall back to a single chunk, exactly as before.
        guard let peak = values.max(), peak > 0 else {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }

        let sorted = values.sorted()
        let percentileIndex = Int(Double(sorted.count - 1) * 0.95)
        let reference = sorted[max(0, min(percentileIndex, sorted.count - 1))]
        // Samples are normalized to [-1, 1] here, while the Python helper
        // works on raw int16 values: its floor of 1.0 becomes 1/32768 in
        // these units. A floor of 1.0 would call every frame silent and cut
        // in the middle of speech.
        let threshold = max(1.0 / 32_768.0, 0.1 * Double(reference))
        let frameSeconds = Double(frame) / Double(sampleRate)

        let candidates = silenceCandidates(
            rms: values, frameSeconds: frameSeconds, threshold: threshold, minSilence: minSilence)
        guard !candidates.isEmpty else {
            return [SpeechChunk(start: 0, end: totalSeconds)]
        }
        return cuts(candidates, totalSeconds, minSilence, targetChunk, maxChunk, firstTarget)
    }

    /// Root-mean-square of each whole `frame`-sample window, via vDSP. The
    /// trailing partial frame is dropped, matching the scalar version.
    static func frameRMS(samples: [Float], frame: Int) -> [Float] {
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }
        var rms = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<frameCount {
                var value: Float = 0
                vDSP_rmsqv(base + index * frame, 1, &value, vDSP_Length(frame))
                rms[index] = value
            }
        }
        return rms
    }

    /// The original scalar loop, kept as the oracle for `frameRMS`.
    static func referenceFrameRMS(samples: [Float], frame: Int) -> [Float] {
        let frameCount = samples.count / frame
        var rms = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let offset = index * frame
            var sum: Float = 0
            for sample in samples[offset..<(offset + frame)] {
                sum += sample * sample
            }
            rms[index] = sqrt(sum / Float(frame))
        }
        return rms
    }

    /// Centres (in seconds) of every silent run at least `minSilence` long.
    /// Ascending by construction, which the binary search in `chooseCuts`
    /// relies on.
    static func silenceCandidates(
        rms: [Float],
        frameSeconds: Double,
        threshold: Double,
        minSilence: Double
    ) -> [Double] {
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
        return candidates
    }

    /// Greedy cut selection: the candidate nearest the target length inside
    /// the window, else the first candidate past the hard cap. The window is
    /// located with binary search over the ascending candidate list; ties
    /// resolve to the earliest candidate, as the linear scan did.
    static func chooseCuts(
        candidates: [Double],
        totalSeconds: Double,
        minSilence: Double,
        targetChunk: Double,
        maxChunk: Double,
        firstTarget: Double
    ) -> [SpeechChunk] {
        var chunks: [SpeechChunk] = []
        var start = 0.0
        for _ in 0..<10_000 {
            let remaining = totalSeconds - start
            if remaining <= maxChunk {
                chunks.append(SpeechChunk(start: start, end: totalSeconds))
                break
            }
            // In-window candidates satisfy start + minSilence < c <= start + maxChunk.
            let lower = upperBound(candidates, start + minSilence)
            let upper = upperBound(candidates, start + maxChunk)
            let desired = chunks.isEmpty ? firstTarget : targetChunk
            let cut: Double
            if lower < upper {
                let goal = start + desired
                var best = candidates[lower]
                for candidate in candidates[(lower + 1)..<upper] where abs(candidate - goal) < abs(best - goal) {
                    best = candidate
                }
                cut = best
            } else if upper < candidates.count {
                cut = candidates[upper]
            } else {
                chunks.append(SpeechChunk(start: start, end: totalSeconds))
                break
            }
            chunks.append(SpeechChunk(start: start, end: cut))
            start = cut
        }
        return chunks
    }

    /// The original linear-scan selection, kept as the oracle for `chooseCuts`.
    static func referenceChooseCuts(
        candidates: [Double],
        totalSeconds: Double,
        minSilence: Double,
        targetChunk: Double,
        maxChunk: Double,
        firstTarget: Double
    ) -> [SpeechChunk] {
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

    /// Index of the first element strictly greater than `value` in an
    /// ascending array (`values.count` when none is).
    private static func upperBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
