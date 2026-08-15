import Foundation
import Testing

@testable import Cue

private actor EmptyImportDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

@MainActor
struct AppModelSubtitleImportTests {
    struct Fixture {
        let model: AppModel
        let baseURL: URL
        let suiteName: String

        var mediaURL: URL { baseURL.appendingPathComponent("movie.mp4") }

        func cleanUp() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    static let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        World
        """

    func makeFixture(sidecars: [String], autoStart: Bool = false) throws -> Fixture {
        let suiteName = "app-model-import-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: baseURL.appendingPathComponent("movie.mp4"))
        for name in sidecars {
            try Data(Self.srt.utf8).write(to: baseURL.appendingPathComponent(name))
        }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = autoStart
        settings.sourceLanguage = "ja"
        settings.translationTargetLanguage = "Vietnamese"
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            diagnosticsService: EmptyImportDiagnostics()
        )
        return Fixture(model: model, baseURL: baseURL, suiteName: suiteName)
    }

    /// Adoption runs in a detached Task; give it a moment to land.
    private func waitForAdoption(_ model: AppModel, jobID: UUID) async throws {
        for _ in 0..<100 {
            if !model.isScanningForSubtitles(jobID) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Sidecar scan never finished")
    }

    @Test func adoptsSidecarIntoTranscriptSlot() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        #expect(job.status == .transcriptionComplete)
        #expect(job.importedTranscriptSource?.fileName == "movie.ja.srt")
        // Nothing was transcribed, so no transcription clock was ever started.
        #expect(job.transcriptionFinishedAt == nil)
        #expect(job.log.contains("Loaded subtitles from movie.ja.srt (2 cues)."))
    }

    @Test func adoptsBothSlotsWhenSourceAndTargetSidecarsExist() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt", "movie.vi.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        #expect(job.translatedSegments.count == 2)
        #expect(job.importedTranslationSource?.fileName == "movie.vi.srt")
    }

    @Test func jobWithNoSidecarIsUntouched() async throws {
        let fixture = try makeFixture(sidecars: [])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.isEmpty)
        #expect(job.status == .idle)
        #expect(job.importedTranscriptSource == nil)
    }

    // PipelineScheduler only picks .queued jobs, for both slots. Clearing the
    // queued status on adoption would drop the job out of the queue and it
    // would never translate.
    @Test func adoptedJobStaysQueuedSoItCanTranslate() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"], autoStart: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.settings.openAIAPIKey = "test-key"
        #expect(model.settings.isTranslationReady, "Fixture must have a usable translation provider")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        // Adoption keeps the job .queued (not .transcriptionComplete) so the
        // scheduler can still pick it up; on a fast run processQueue() may
        // already have advanced it to .translating by the time we observe it
        // here, which is equally valid proof it reached the translation slot.
        #expect(
            job.status == .queued || job.status == .translating,
            "An adopted job must remain schedulable so it reaches the translation slot"
        )
    }

    // Both slots filled means no work is left, so the job leaves the queue
    // rather than waiting to be re-translated.
    @Test func adoptingBothSlotsLeavesTheQueue() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt", "movie.vi.srt"], autoStart: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        #expect(model.jobs.first?.status == .translationComplete)
    }

    // The race the pending set exists to close: pumpGPU schedules through
    // jobViews, not jobNeedsWork, so auto-start could otherwise begin ASR
    // before adoption lands.
    @Test func pendingScanKeepsTheJobOutOfScheduling() throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"], autoStart: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let job = try #require(model.jobs.first)
        #expect(model.isScanningForSubtitles(job.id))
        #expect(model.jobNeedsWork(job) == false)
        #expect(model.isRunningTranscription == false)
    }
}
