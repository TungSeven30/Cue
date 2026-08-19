import Foundation
import Testing
@testable import Cue

private func makeManifestTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cue-manifest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSettings() -> CLIManifest.Settings {
    CLIManifest.Settings(
        sourceLanguage: "ja",
        backend: "whisper-cpp",
        model: "ggml-large-v3-turbo-q5_0.bin",
        qualityPreset: "balanced",
        translationTargetLanguage: "Vietnamese",
        translationModel: "gpt-5.5",
        summaryModel: nil
    )
}

struct CLIManifestTests {
    @Test func roundTripsThroughDisk() throws {
        let directory = try makeManifestTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = CLIManifest(
            stage: "transcribe",
            source: CLIManifest.Source(path: "/movies/clip.mkv", pageURL: "https://example.com/watch"),
            settings: makeSettings(),
            transcript: [TranscriptionSegment(id: 1, start: 0, end: 2, text: "Hello")]
        )
        manifest.note("Transcribed 1 segment.")
        manifest.record(outputs: [CLIManifest.Output(role: "original", format: "srt", path: "/movies/clip.original.srt")])

        let url = directory.appendingPathComponent("clip.cue.json")
        try manifest.write(to: url)
        let decoded = try CLIManifest.read(contentsOf: url)
        #expect(decoded == manifest)
        #expect(decoded.sourceURL.path == "/movies/clip.mkv")
    }

    // A manifest written by an older Cue must still chain: only source and
    // settings are structurally required.
    @Test func decodesAMinimalManifest() throws {
        let json = """
            {
              "source": { "path": "/movies/clip.mkv" },
              "settings": {
                "sourceLanguage": "auto",
                "backend": "whisper-cpp",
                "model": "ggml",
                "qualityPreset": "balanced"
              }
            }
            """
        let manifest = try JSONDecoder().decode(CLIManifest.self, from: Data(json.utf8))
        #expect(manifest.version == CLIManifest.currentVersion)
        #expect(manifest.stage == "unknown")
        #expect(manifest.transcript.isEmpty)
        #expect(manifest.translation.isEmpty)
        #expect(manifest.outputs.isEmpty)
        #expect(manifest.log.isEmpty)
        #expect(manifest.summary == nil)
        #expect(manifest.settings.translationTargetLanguage == nil)
    }

    @Test func recordingTheSamePathReplacesRatherThanDuplicates() {
        var manifest = CLIManifest(
            stage: "transcribe",
            source: CLIManifest.Source(path: "/movies/clip.mkv", pageURL: nil),
            settings: makeSettings()
        )
        manifest.record(outputs: [CLIManifest.Output(role: "original", format: "srt", path: "/a.srt")])
        manifest.record(outputs: [CLIManifest.Output(role: "original", format: "srt", path: "/a.srt")])
        manifest.record(outputs: [CLIManifest.Output(role: "translated", format: "vtt", path: "/b.vtt")])
        #expect(manifest.outputs.count == 2)
        #expect(manifest.outputs.map(\.path) == ["/a.srt", "/b.vtt"])
    }

    @Test func manifestPathSitsBesideTheOutputs() {
        let directory = URL(fileURLWithPath: "/movies", isDirectory: true)
        #expect(CLIManifest.manifestURL(inDirectory: directory, baseName: "clip").path == "/movies/clip.cue.json")
        // Separators in a base name would redirect the write, so the same
        // sanitizer the export planner uses applies here too.
        #expect(CLIManifest.manifestURL(inDirectory: directory, baseName: "a/b").lastPathComponent == "a-b.cue.json")
    }

    @Test func manifestInputsAreDistinguishedFromMedia() {
        #expect(CLIManifest.looksLikeManifest("/movies/clip.cue.json"))
        #expect(CLIManifest.looksLikeManifest("/movies/CLIP.CUE.JSON"))
        #expect(!CLIManifest.looksLikeManifest("/movies/clip.mkv"))
        #expect(!CLIManifest.looksLikeManifest("/movies/clip.srt"))
    }

    @Test func jsonOutputIsStableAndUnescaped() throws {
        let manifest = CLIManifest(
            stage: "fetch",
            source: CLIManifest.Source(path: "/movies/clip.mkv", pageURL: "https://example.com/a/b"),
            settings: makeSettings()
        )
        let json = try manifest.jsonString()
        // Piping stdout into jq is the point, so slashes stay readable.
        #expect(json.contains("https://example.com/a/b"))
        #expect(!json.contains("https:\\/\\/"))
    }
}
