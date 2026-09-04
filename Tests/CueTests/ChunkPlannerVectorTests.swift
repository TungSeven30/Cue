import Foundation
import Testing
@testable import Cue

/// Pins the vDSP planner and PCM conversion to the scalar implementations
/// they replaced: bit-exact for PCM, within float rounding for RMS, and
/// identical *decisions* (candidates and cut points) either way.
@Suite struct ChunkPlannerVectorTests {
    private let rate = 16_000

    private func tone(seconds: Double, amplitude: Float = 0.25) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            amplitude * Float(sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
        }
    }

    /// Deterministic pseudo-random noise (LCG), so the comparison is
    /// reproducible run to run.
    private func noise(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: Int64(bitPattern: state) >> 33)) / Float(Int32.max) * 0.5
        }
    }

    private var signals: [[Float]] {
        var interleaved: [Float] = []
        for _ in 0..<8 {
            interleaved += tone(seconds: 100)
            interleaved += [Float](repeating: 0, count: 2 * rate)
        }
        var quietGaps = noise(seconds: 700, seed: 11)
        // Near-silent (not exactly zero) gaps: exercises the threshold path.
        for gap in stride(from: 60, to: 700, by: 120) {
            for index in (gap * rate)..<((gap + 1) * rate) {
                quietGaps[index] *= 0.001
            }
        }
        return [
            interleaved,
            noise(seconds: 700, seed: 7),
            quietGaps,
            tone(seconds: 700, amplitude: 1.0),  // full scale, no silence at all
            [Float](repeating: 0, count: 700 * rate),  // all silence
            tone(seconds: 30),  // shorter than maxChunk: single chunk fast path
        ]
    }

    @Test func vectorisedRMSMatchesScalarReferenceWithinRounding() {
        for samples in signals {
            let frame = 800
            let fast = TranscriptionChunkPlanner.frameRMS(samples: samples, frame: frame)
            let reference = TranscriptionChunkPlanner.referenceFrameRMS(samples: samples, frame: frame)
            #expect(fast.count == reference.count)
            for (a, b) in zip(fast, reference) {
                #expect(abs(a - b) <= max(1e-6, abs(b) * 1e-5), "rms mismatch \(a) vs \(b)")
            }
        }
    }

    @Test func plannerDecisionsAreIdenticalToScalarReference() {
        for samples in signals {
            let fast = TranscriptionChunkPlanner.planSpeechChunks(
                samples: samples, sampleRate: rate, targetChunk: 150, maxChunk: 300)
            let reference = TranscriptionChunkPlanner.referencePlanSpeechChunks(
                samples: samples, sampleRate: rate, targetChunk: 150, maxChunk: 300)
            #expect(fast == reference)
        }
    }

    @Test func plannerDecisionsAreIdenticalWithProductionDefaults() {
        var long: [Float] = []
        for _ in 0..<14 {
            long += tone(seconds: 100)
            long += [Float](repeating: 0, count: rate)
        }
        let fast = TranscriptionChunkPlanner.planSpeechChunks(samples: long, sampleRate: rate)
        let reference = TranscriptionChunkPlanner.referencePlanSpeechChunks(samples: long, sampleRate: rate)
        #expect(fast == reference)
        #expect(fast.count >= 3)
    }

    @Test func bisectWindowSearchMatchesLinearSearch() {
        let cases: [[Double]] = [
            [3, 17, 44.5, 90, 91, 150, 299, 301, 480, 650],
            [0.2, 0.4, 0.6],  // everything inside minSilence: forces the "later" branch
            [700.5],  // past the end: single chunk
            [89, 91],  // exact tie distance to the first target: earliest wins
            [600, 600, 900],  // duplicates on the cap boundary
        ]
        for candidates in cases {
            let fast = TranscriptionChunkPlanner.chooseCuts(
                candidates: candidates, totalSeconds: 1_000, minSilence: 0.5,
                targetChunk: 150, maxChunk: 300, firstTarget: 90)
            let reference = TranscriptionChunkPlanner.referenceChooseCuts(
                candidates: candidates, totalSeconds: 1_000, minSilence: 0.5,
                targetChunk: 150, maxChunk: 300, firstTarget: 90)
            #expect(fast == reference, "candidates \(candidates)")
        }
    }

    @Test func pcmConversionIsBitExact() throws {
        var samples: [Int16] = (0..<50_000).map { Int16(truncatingIfNeeded: $0 &* 7919) }
        samples += [Int16.min, Int16.max, 0, -1, 1, 12_345, -32_767]
        var data = Data()
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        var wav = AudioExtractor.wavHeader(dataLength: UInt32(data.count))
        wav.append(data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WhisperCppEngine.loadPCM16AsFloat(url)

        #expect(floats.count == samples.count)
        for (float, sample) in zip(floats, samples) {
            #expect(float.bitPattern == (Float(sample) / 32_768).bitPattern)
        }
    }

    @Test func pcmConversionHandlesUnalignedDataChunk() {
        let samples: [Int16] = [1_000, -1_000, 12_345, Int16.min, Int16.max]
        var bytes: [UInt8] = [0xAA]  // one leading byte makes the PCM start odd-aligned
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let floats = bytes.withUnsafeBytes { raw in
            WhisperCppEngine.pcm16ToFloat(raw, byteOffset: 1, sampleCount: samples.count)
        }
        for (float, sample) in zip(floats, samples) {
            #expect(float.bitPattern == (Float(sample) / 32_768).bitPattern)
        }
    }
}
