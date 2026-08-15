import Foundation
import Testing

@testable import Cue

struct SubtitleImporterTests {
    private let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        World
        """

    private func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-importer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: dir.appendingPathComponent("movie.mp4"))
        for name in names {
            try Data(srt.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func importsBothSlotsFromRealFiles() throws {
        let dir = try makeFolder(["movie.ja.srt", "movie.vi.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "ja",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript?.source.fileName == "movie.ja.srt")
        #expect(result.transcript?.segments.count == 2)
        #expect(result.translation?.source.fileName == "movie.vi.srt")
        #expect(result.logLines.count == 2)
        #expect(result.logLines.allSatisfy { $0.contains("2 cues") })
    }

    @Test func noSidecarsYieldsEmptyResult() throws {
        let dir = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "auto",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript == nil)
        #expect(result.translation == nil)
        #expect(result.logLines.isEmpty)
    }

    // A batch add cannot raise dialogs, so an unreadable sidecar is reported
    // in the job log and otherwise ignored.
    @Test func unparseableSidecarIsLoggedNotThrown() throws {
        let dir = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a subtitle at all".utf8).write(to: dir.appendingPathComponent("movie.srt"))

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "auto",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript == nil)
        #expect(result.logLines.count == 1)
        #expect(result.logLines[0].contains("Could not read"))
    }

    @Test func importFileParsesAnyFolder() throws {
        let dir = try makeFolder(["elsewhere.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = try SubtitleImporter.importFile(at: dir.appendingPathComponent("elsewhere.srt"))
        #expect(document.segments.count == 2)
        #expect(document.source.format == .srt)
    }
}
