import Foundation
import Testing
@testable import Cue

struct ExportCoordinatorTests {
    private let segments = [TranscriptionSegment(id: 1, start: 1, end: 2, text: "Hello")]

    @Test func multiDocumentPlanUsesStableSafeNames() {
        let coordinator = ExportCoordinator()
        let folder = URL(filePath: "/tmp/export", directoryHint: .isDirectory)
        let plan = coordinator.plan(
            folder: folder,
            baseName: " show/episode: 1 ",
            documents: [
                .init(suffix: "original", segments: segments),
                .init(suffix: "translated.vi", segments: segments),
            ],
            formats: [.srt, .vtt],
            includeLog: true,
            summary: nil
        )

        #expect(plan.fileCount == 5)
        #expect(
            plan.urls.map(\.lastPathComponent) == [
                "show-episode- 1.original.srt",
                "show-episode- 1.original.vtt",
                "show-episode- 1.translated.vi.srt",
                "show-episode- 1.translated.vi.vtt",
                "show-episode- 1.log.txt",
            ])
    }

    @Test func normalizedURLDoesNotDoubleAppendExtensions() {
        #expect(ExportCoordinator.normalizedURL(URL(filePath: "/tmp/a.srt"), expectedExtension: "srt").path == "/tmp/a.srt")
        #expect(ExportCoordinator.normalizedURL(URL(filePath: "/tmp/a.srt.txt"), expectedExtension: "srt").path == "/tmp/a.srt")
        #expect(ExportCoordinator.normalizedURL(URL(filePath: "/tmp/a.txt"), expectedExtension: "srt").path == "/tmp/a.srt")
    }

    @Test func languageNamesAndCodesProducePlayerFriendlySuffixes() {
        #expect(ExportCoordinator.sidecarLanguageCode(for: "Vietnamese") == "vi")
        #expect(ExportCoordinator.sidecarLanguageCode(for: "ja") == "ja")
        #expect(ExportCoordinator.languageSuffix("Brazilian Portuguese") == "brazilian-portuguese")
    }

    // Auto-export would otherwise rewrite the very file we imported, and not
    // byte-identically: applyingIntro prepends the summary cue.
    //
    // @MainActor because TranscriptionJob's designated init is main-actor
    // isolated (it reads AppSettingsStore); the rest of this suite is not.
    @MainActor @Test func sidecarExportSkipsProtectedImportedPaths() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mediaURL = dir.appendingPathComponent("movie.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let protectedURL = dir.appendingPathComponent("movie.en.srt")
        let originalContents = "untouched"
        try Data(originalContents.utf8).write(to: protectedURL)

        let suiteName = "cue-protected-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })

        var job = TranscriptionJob(sourceURL: mediaURL, settings: settings)
        job.settings.sourceLanguage = "en"
        job.settings.translationTargetLanguage = "Vietnamese"
        job.transcriptSegments = segments
        job.translatedSegments = segments

        let written = try ExportCoordinator().writeSidecars(
            job: job,
            options: .init(
                includeOriginal: true,
                includeTranslation: true,
                includeBilingual: false,
                protectedPaths: [protectedURL.standardizedFileURL.path]
            )
        )

        #expect(written == ["movie.vi.srt"], "The protected path must not be rewritten")
        #expect(try String(contentsOf: protectedURL, encoding: .utf8) == originalContents)
    }
}
