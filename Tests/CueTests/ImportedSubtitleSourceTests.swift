import Foundation
import Testing

@testable import Cue

struct ImportedSubtitleSourceTests {
    private func makeFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("movie.en.srt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func capturesFileStateAtImport() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        #expect(source.fileName == "movie.en.srt")
        #expect(source.fileSize > 0)
        #expect(source.didBackup == false)
        #expect(source.syncPaused == false)
        #expect(source.matchesFileOnDisk())
    }

    // The guard that makes automatic write-back safe: if the file changed
    // under us, we must not overwrite it.
    @Test func detectsExternalModification() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        try Data("1\n00:00:01,000 --> 00:00:02,000\nEdited elsewhere\n".utf8).write(to: url)
        #expect(source.matchesFileOnDisk() == false)

        source.refreshFileState()
        #expect(source.matchesFileOnDisk(), "refreshFileState must re-baseline after our own write")
    }

    @Test func missingFileDoesNotMatch() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        let source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        #expect(source.matchesFileOnDisk() == false)
    }

    // Job JSON on disk predates these fields.
    //
    // This uses a bare JSONDecoder (`.deferredToDate`, so the numeric `0`
    // dates are valid) rather than JobStore's `.iso8601` one, which is
    // private. The decoder strategy is irrelevant to what's under test: that
    // the two new keys are optional.
    @Test func legacyJobJSONDecodesWithoutProvenance() throws {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "sourcePath": "/videos/movie.mp4",
              "createdAt": 0, "updatedAt": 0,
              "status": "idle",
              "progress": {"stage": "idle", "detail": "", "fraction": null},
              "settings": {
                "sourceLanguage": "auto", "whisperModel": "large-v3",
                "whisperBackend": "auto", "openAIModel": "gpt-4o-mini"
              },
              "transcriptSegments": [], "translatedSegments": [],
              "log": ""
            }
            """
        let decoder = JSONDecoder()
        let job = try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
        #expect(job.importedTranscriptSource == nil)
        #expect(job.importedTranslationSource == nil)
    }

    @Test func provenanceSurvivesEncodeDecode() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        source.didBackup = true
        source.lastSyncError = "boom"

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(ImportedSubtitleSource.self, from: data)
        #expect(decoded == source)
    }
}
