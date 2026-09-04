import Foundation
import os
import Testing
@testable import Cue

/// Real inference against whatever model is installed (never downloads;
/// skips when none is). These pin the property the resident-weights design
/// depends on: a fresh `whisper_state` per run reproduces a cold load exactly.
@Suite(.serialized) struct WhisperEngineDeterminismTests {
    private func transcribe(
        _ wav: URL,
        modelURL: URL,
        cache: WhisperModelCache,
        planning: ChunkPlanning = .default,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onChunkComplete: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [TranscriptionSegment] {
        try await WhisperCppEngine(cache: cache, chunkPlanning: planning).transcribe(
            wavURL: wav, modelURL: modelURL, language: "en", beamSize: 5, noSpeechThreshold: 0.6,
            onProgress: { _ in }, onChunkComplete: onChunkComplete, isCancelled: isCancelled
        ).segments
    }

    @Test func residentWeightsWithFreshStateMatchAColdLoadByteForByte() async throws {
        guard let modelURL = BenchmarkFixtures.installedModelURL() else { return }
        let wav = try await BenchmarkFixtures.spokenFixtureWAV()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let cache = WhisperModelCache()

        let first = try await transcribe(wav, modelURL: modelURL, cache: cache)
        let second = try await transcribe(wav, modelURL: modelURL, cache: cache)  // resident weights
        await cache.evictAll()
        let cold = try await transcribe(wav, modelURL: modelURL, cache: cache)  // reloaded from disk

        #expect(!first.isEmpty)
        #expect(first == second)
        #expect(first == cold)
    }

    @Test func multiChunkRunsAreDeterministicAndBoundariesAreStable() async throws {
        guard let modelURL = BenchmarkFixtures.installedModelURL() else { return }
        // Speech, a full second of digital silence, speech again: the planner
        // is guaranteed a cut candidate, and the tightened windows force it.
        let wav = try await BenchmarkFixtures.spokenFixtureWAV(repeats: 2, gapSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let planning = ChunkPlanning(minSilence: 0.3, targetChunk: 12, maxChunk: 20, firstTarget: 10)
        let cache = WhisperModelCache()
        let ends = OSAllocatedUnfairLock(initialState: [[Double]]())

        func run() async throws -> [TranscriptionSegment] {
            let index = ends.withLock {
                $0.append([]); return $0.count - 1
            }
            return try await transcribe(
                wav, modelURL: modelURL, cache: cache, planning: planning,
                onChunkComplete: { end in ends.withLock { $0[index].append(end) } }
            )
        }

        let a = try await run()
        let b = try await run()
        await cache.evictAll()
        let c = try await run()

        let chunkEnds = ends.withLock { $0 }
        #expect(chunkEnds[0].count >= 2, "fixture must split into several chunks, got \(chunkEnds[0])")
        #expect(chunkEnds[0] == chunkEnds[1])
        #expect(chunkEnds[0] == chunkEnds[2])
        #expect(!a.isEmpty)
        #expect(a == b)
        #expect(a == c)
        #expect(a.map(\.id) == Array(1...a.count), "chunked ids must stay contiguous")
    }

    @Test func cancellationAbortsInferenceAndLeavesTheCacheUsable() async throws {
        guard let modelURL = BenchmarkFixtures.installedModelURL() else { return }
        let wav = try await BenchmarkFixtures.spokenFixtureWAV()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let cache = WhisperModelCache()

        await #expect(throws: CancellationError.self) {
            _ = try await transcribe(wav, modelURL: modelURL, cache: cache, isCancelled: { true })
        }
        // The lease was released on the error path: the model is idle, still
        // resident, and the next run reuses it.
        #expect(await cache.residentKeys().count == 1)
        let after = try await transcribe(wav, modelURL: modelURL, cache: cache)
        #expect(!after.isEmpty)
    }
}
