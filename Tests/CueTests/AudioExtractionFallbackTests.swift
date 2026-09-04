import AVFoundation
import Foundation
import Testing
@testable import Cue

/// The built-in engine must not fail on containers AVFoundation cannot open
/// when ffmpeg is installed, and must say what to install when it is not.
@Suite struct AudioExtractionFallbackTests {
    private var hasFFmpeg: Bool { ProcessEnvironment.toolExists("ffmpeg") }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Two seconds of a 440 Hz tone muxed into Matroska by ffmpeg itself.
    private func makeMKV(in dir: URL) throws -> URL {
        let mkv = dir.appendingPathComponent("tone.mkv")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        make.environment = ProcessEnvironment.withToolPaths()
        make.arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:a", "aac", mkv.path,
        ]
        make.standardError = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        try #require(make.terminationStatus == 0, "ffmpeg could not build the MKV fixture")
        return mkv
    }

    /// A 44.1 kHz stereo WAV AVFoundation reads natively.
    private func makeNativeFixture(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("native.wav")
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

    @Test func nativeExtractorStillCannotOpenMatroska() async throws {
        guard hasFFmpeg else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try makeMKV(in: dir)
        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extract(from: mkv, to: dir.appendingPathComponent("native-out.wav"))
        }
    }

    @Test func mkvFallsBackToFFmpegAndProducesThePCMTheEngineExpects() async throws {
        guard hasFFmpeg else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try makeMKV(in: dir)
        let out = dir.appendingPathComponent("out.wav")

        let route = try await AudioSourceExtractor.extract(from: mkv, to: out, hasFFmpeg: true, progress: nil)

        #expect(route == .ffmpeg)
        let floats = try WhisperCppEngine.loadPCM16AsFloat(out)
        #expect(abs(Double(floats.count) / 16_000 - 2.0) < 0.1)
        #expect(floats.contains { abs($0) > 0.1 }, "the tone must survive the round trip")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
    }

    @Test func supportedContainerStaysOnTheNativePath() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeNativeFixture(in: dir)
        let out = dir.appendingPathComponent("out.wav")

        let route = try await AudioSourceExtractor.extract(from: source, to: out, hasFFmpeg: true, progress: nil)

        #expect(route == .native)
        let output = try AVAudioFile(forReading: out)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
    }

    @Test func missingFFmpegProducesAnErrorThatNamesIt() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("not-media.mkv")
        try Data("definitely not a media file".utf8).write(to: bogus)

        do {
            _ = try await AudioSourceExtractor.extract(
                from: bogus, to: dir.appendingPathComponent("out.wav"), hasFFmpeg: false, progress: nil)
            Issue.record("expected extraction to fail")
        } catch {
            #expect(error is FFmpegUnavailableError)
            #expect(error.localizedDescription.contains("brew install ffmpeg"))
        }
    }

    @Test func ffmpegFailureReportsItsLastLineAndLeavesNoPartialFile() async throws {
        guard hasFFmpeg else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("not-media.mkv")
        try Data("definitely not a media file".utf8).write(to: bogus)
        let out = dir.appendingPathComponent("out.wav")

        await #expect(throws: AudioExtractorError.self) {
            try await FFmpegAudioExtractor.extract(from: bogus, to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
    }

    @Test func cancellationStopsFFmpegAndLeavesNoPartialFile() async throws {
        guard hasFFmpeg else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A long synthetic source so ffmpeg is still running when cancelled.
        let long = dir.appendingPathComponent("long.mkv")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        make.environment = ProcessEnvironment.withToolPaths()
        make.arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1200", "-c:a", "aac", long.path,
        ]
        make.standardError = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        try #require(make.terminationStatus == 0)
        let out = dir.appendingPathComponent("out.wav")

        let task = Task {
            try await FFmpegAudioExtractor.extract(from: long, to: out)
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
    }
}
