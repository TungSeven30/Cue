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
}
