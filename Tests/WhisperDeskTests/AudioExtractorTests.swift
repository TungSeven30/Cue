import AVFoundation
import Foundation
import Testing
@testable import WhisperDesk

struct AudioExtractorTests {
    /// Writes a 2-second 440 Hz stereo 44.1 kHz WAV fixture with AVAudioFile.
    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / 44_100) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func extractsToSixteenKilohertzMonoWav() async throws {
        let source = try makeFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("extracted-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await AudioExtractor.extract(from: source, to: destination)

        let output = try AVAudioFile(forReading: destination)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        let seconds = Double(output.length) / output.fileFormat.sampleRate
        #expect(abs(seconds - 2.0) < 0.1)
    }

    @Test func throwsOnFileWithNoAudioTrack() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).txt")
        try Data("not audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).wav")

        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extract(from: source, to: destination)
        }
    }

    @Test func leavesNoFileBehindWhenExtractionFails() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).txt")
        try Data("not audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.wav")

        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extract(from: source, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.isEmpty)
    }
}
