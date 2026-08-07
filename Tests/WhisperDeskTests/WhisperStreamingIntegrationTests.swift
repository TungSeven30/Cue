import Foundation
import os
import Testing
@testable import WhisperDesk

@Suite struct WhisperStreamingIntegrationTests {
    @Test func streamedSegmentsMatchFinalResult() async throws {
        // Only run against an already-installed model; never download in tests.
        // `ModelDownloader.models` is ordered largest to smallest, so reverse
        // it to prefer the smallest (fastest) installed model — ggml-tiny.bin
        // when present.
        let downloader = ModelDownloader()
        guard let modelURL = ModelDownloader.models.reversed().lazy
            .map({ downloader.destinationURL(for: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("fixture.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "This is a streaming test. The quick brown fox jumps over the lazy dog. Segments should arrive incrementally."]
        do {
            try say.run()
        } catch {
            return
        }
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { return }

        let wav = dir.appendingPathComponent("fixture.wav")
        try await AudioExtractor.extract(from: aiff, to: wav)

        let streamedBatches = OSAllocatedUnfairLock(initialState: [[TranscriptionSegment]]())
        let result = try await WhisperCppEngine().transcribe(
            wavURL: wav, modelURL: modelURL, language: "en",
            beamSize: 3, noSpeechThreshold: 0.6,
            onProgress: { _ in },
            onSegments: { batch in streamedBatches.withLock { $0.append(batch) } },
            isCancelled: { false }
        )
        let batches = streamedBatches.withLock { $0 }
        print("WhisperStreamingIntegrationTests: model=\(modelURL.lastPathComponent) batches=\(batches.count) segments=\(batches.flatMap { $0 }.count)")
        let streamed = batches.flatMap { $0 }
        #expect(!streamed.isEmpty)
        #expect(streamed.map(\.id) == result.segments.map(\.id))
        #expect(streamed.map(\.text) == result.segments.map(\.text))
    }
}
