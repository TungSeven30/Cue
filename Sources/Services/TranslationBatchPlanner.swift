import Foundation

/// Builds stable, provider-sized translation requests. Planning only missing
/// contiguous subtitles prevents a later progressive pass from retranslating
/// lines that were part of a smaller early batch.
enum TranslationBatchPlanner {
    static func estimatedTokens(in text: String) -> Int {
        var ascii = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                ascii += 1
            } else {
                nonASCII += 1
            }
        }
        // Latin subtitle text averages roughly four characters/token; CJK is
        // conservatively treated as one scalar/token. Include JSON/id overhead.
        return max(1, (ascii + 3) / 4 + nonASCII)
    }

    static func estimatedTokens(in segments: ArraySlice<TranscriptionSegment>) -> Int {
        segments.reduce(0) { $0 + estimatedTokens(in: $1.text) + 12 }
    }

    static func pendingChunks(
        _ segments: [TranscriptionSegment],
        translatedIDs: Set<Int>,
        mode: TranslationChunkMode
    ) -> [[TranscriptionSegment]] {
        var result: [[TranscriptionSegment]] = []
        var current: [TranscriptionSegment] = []
        var currentTokens = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(current)
            current = []
            currentTokens = 0
        }

        for segment in segments {
            guard !translatedIDs.contains(segment.id) else {
                // Never bridge across an already translated range: doing so
                // would make progressive chunk boundaries unstable.
                flush()
                continue
            }
            let segmentTokens = estimatedTokens(in: segment.text) + 12
            if !current.isEmpty,
                current.count >= mode.chunkSize
                    || currentTokens + segmentTokens > mode.targetInputTokens
            {
                flush()
            }
            current.append(segment)
            currentTokens += segmentTokens
        }
        flush()
        return result
    }
}
