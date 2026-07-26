import Foundation
import Testing
@testable import WhisperDesk

struct WhisperCppEngineTests {
    // MARK: - Segment mapping

    @Test func mapsCentisecondTimestampsToSeconds() {
        let segment = WhisperCppEngine.mapSegment(index: 0, t0: 150, t1: 425, text: " Hello there ")
        #expect(segment.id == 1)
        #expect(segment.start == 1.5)
        #expect(segment.end == 4.25)
        #expect(segment.text == "Hello there")
    }

    // MARK: - WAV loading

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-wav-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func loadsCanonicalWavAsFloats() throws {
        let samples: [Int16] = [0, 16_384, -16_384, 32_767, -32_768]
        let pcm = pcmData(samples)
        var wav = AudioExtractor.wavHeader(dataLength: UInt32(pcm.count))
        wav.append(pcm)
        let url = try writeTemp(wav)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WhisperCppEngine.loadPCM16AsFloat(url)

        #expect(floats.count == samples.count)
        for (float, sample) in zip(floats, samples) {
            #expect(abs(float - Float(sample) / 32_768) < 1e-6)
        }
    }

    @Test func findsDataChunkBehindExtraChunks() throws {
        let samples: [Int16] = [1_000, -1_000, 12_345]
        let pcm = pcmData(samples)

        var wav = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let listBody = Data("INFOnote\u{00}".utf8)  // odd-size chunk exercises pad-byte alignment
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(4 + 24 + 8 + listBody.count + 1 + 8 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))          // PCM
        append(UInt16(1))          // mono
        append(UInt32(16_000))
        append(UInt32(16_000 * 2))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: Array("LIST".utf8))
        append(UInt32(listBody.count))
        wav.append(listBody)
        wav.append(0)              // pad byte for odd chunk size
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        wav.append(pcm)
        let url = try writeTemp(wav)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WhisperCppEngine.loadPCM16AsFloat(url)

        #expect(floats.count == samples.count)
        for (float, sample) in zip(floats, samples) {
            #expect(abs(float - Float(sample) / 32_768) < 1e-6)
        }
    }

    @Test func rejectsNonWavData() throws {
        let url = try writeTemp(Data("definitely not a RIFF file".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: WhisperCppError.self) {
            _ = try WhisperCppEngine.loadPCM16AsFloat(url)
        }
    }
}
