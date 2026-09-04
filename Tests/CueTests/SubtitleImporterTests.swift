import Foundation
import Testing

@testable import Cue

struct SubtitleImporterTests {
    @Test func skippedSourceContentPausesAutomaticWriteBack() throws {
        let dir = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("partial.srt")
        let bytes = Data((srt + "\n\nBroken cue without timestamps\n").utf8)
        try bytes.write(to: url)
        let document = try SubtitleImporter.importFile(at: url, backingUp: false)
        print("AUDIT04 lossy_source_writeback_enabled=\(!document.source.syncPaused)")
        #expect(document.segments.count == 2)
        #expect(document.source.syncPaused)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func ambiguousLegacyEncodingCannotAutomaticallyRewriteTheSource() throws {
        let dir = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("movie.vi.srt")
        var bytes = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        bytes.append(contentsOf: [86, 105, 234, 242, 116])
        try bytes.write(to: url)
        let document = try SubtitleImporter.importFile(at: url, backingUp: false)
        #expect(document.segments.first?.text == "Việt")
        #expect(document.source.syncPaused)
        #expect(document.source.lastSyncError != nil)
        #expect(try Data(contentsOf: url) == bytes)

        try Data("1\n00:00:01,000 --> 00:00:02,000\nTiếng Việt\n".utf8).write(to: url)
        #expect(try !SubtitleImporter.importFile(at: url, backingUp: false).source.syncPaused)
    }

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

    // The scanner guarantees a translation never arrives without its
    // transcript, but a transcript that fails to parse breaks that pair here.
    // Adopting the survivor alone marks the job translated with no transcript,
    // which then sends it to ASR and throws the adopted translation away.
    @Test func unparseableTranscriptDropsItsTranslation() throws {
        let dir = try makeFolder(["movie.vi.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a subtitle at all".utf8).write(to: dir.appendingPathComponent("movie.ja.srt"))

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "ja",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript == nil)
        #expect(result.translation == nil)
        #expect(result.logLines.contains { $0.contains("Could not read movie.ja.srt") })
        #expect(result.logLines.contains { $0.contains("Ignored movie.vi.srt") })
    }

    @Test func importFileParsesAnyFolder() throws {
        let dir = try makeFolder(["elsewhere.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = try SubtitleImporter.importFile(at: dir.appendingPathComponent("elsewhere.srt"))
        #expect(document.segments.count == 2)
        #expect(document.source.format == .srt)
    }

    // The user's file must be recoverable from the moment Cue adopts it: a
    // later re-translation unlinks the file and lets auto-export overwrite
    // it, and by then there may never have been an edit to trigger a backup.
    @Test func importBacksUpTheOriginalImmediately() throws {
        let dir = try makeFolder(["movie.ja.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("movie.ja.srt")

        let document = try SubtitleImporter.importFile(at: source)

        let backup = dir.appendingPathComponent("movie.ja.srt.bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == srt)
        #expect(document.source.didBackup)
    }

    @Test func importNeverOverwritesAnExistingBackup() throws {
        let dir = try makeFolder(["movie.ja.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("movie.ja.srt.bak")
        try Data("an older backup".utf8).write(to: backup)

        let document = try SubtitleImporter.importFile(at: dir.appendingPathComponent("movie.ja.srt"))

        #expect(try String(contentsOf: backup, encoding: .utf8) == "an older backup")
        #expect(document.source.didBackup)
    }

    // A failed backup must not fail the import; write-back's own backup step
    // stays as the fallback. The directory must already be read-only before
    // the one import attempt this test makes: importing once first would let
    // backUpOriginal's existing-file guard short-circuit past the copy on a
    // second call, proving nothing about the failure path.
    @Test func importSucceedsWhenTheBackupCannotBeWritten() throws {
        let dir = try makeFolder(["movie.ja.srt"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let document = try SubtitleImporter.importFile(at: dir.appendingPathComponent("movie.ja.srt"))

        #expect(document.segments.count == 2, "A read-only folder must not fail the import")
        #expect(document.source.didBackup == false)
        let backup = dir.appendingPathComponent("movie.ja.srt.bak")
        #expect(FileManager.default.fileExists(atPath: backup.path) == false)
    }
}
