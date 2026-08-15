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

/// Never resolves within a test's lifetime, so a translation kicked off by
/// processQueue() can never reach markFailed/finishTranslation before an
/// assertion runs — deterministic, and never touches the network for real.
private struct HangingHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw URLError(.cancelled)
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

    func makeFixture(
        sidecars: [String],
        autoStart: Bool = false,
        translationService: TranslationService = TranslationService(httpClient: HangingHTTPClient())
    ) throws -> Fixture {
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
            diagnosticsService: EmptyImportDiagnostics(),
            translationService: translationService
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
    // would never translate. The fixture's HangingHTTPClient keeps this
    // hermetic: processQueue() really does dispatch to translationService
    // once translationReady is true, so this must never reach a live host.
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

    // Regression: jobNeedsWork is false for a job mid-scan, and
    // startAllPendingJobs/enqueueJobs used to gate on jobNeedsWork alone, so
    // a click during the scan window was silently dropped — the job stayed
    // .idle forever, since PipelineScheduler only ever picks up .queued jobs.
    @Test func queuingDuringScanStillTranscribesOnceScanSettles() async throws {
        let fixture = try makeFixture(sidecars: [])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let job = try #require(model.jobs.first)
        #expect(model.isScanningForSubtitles(job.id))

        // The click during the scan window must still take effect.
        model.startAllPendingJobs()
        #expect(model.jobs.first?.status == .queued)

        try await waitForAdoption(model, jobID: job.id)

        // No sidecar was found, so the transcript slot is still open; once
        // the scan settles the job must reach the GPU slot rather than being
        // stranded at .queued (or worse, .idle) forever. pumpGPU sets status
        // synchronously the instant the scan lands, so this transition itself
        // is not racy — but the fake media bytes make the ASR attempt that
        // follows fail almost immediately, so by the time waitForAdoption's
        // polling loop notices, the job may already be .transcribing or
        // .failed. Either is proof the scheduler engaged it; only .idle or
        // .queued would mean the click was lost.
        let finalStatus = model.jobs.first?.status
        #expect(finalStatus != .idle, "The queued click must not be stranded once the scan settles")
        #expect(finalStatus != .queued, "The scheduler must have picked the job up once the scan settled")

        model.cancelActiveJob()
    }

    // Regression: canStartSelectedJob/startTranscription bypass the
    // scheduler and don't consult subtitleScanPendingIDs, so a job could be
    // started by hand while its scan was still running. applyAdoptions must
    // not then overwrite the live ASR run's transcript, progress, and status
    // with the sidecar's — that would leave importedTranscriptSource
    // pointing at a file that no longer matches the job's actual transcript.
    @Test func runningJobDuringScanIsNotClobberedByLateAdoption() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let job = try #require(model.jobs.first)
        #expect(model.isScanningForSubtitles(job.id))

        // Started by hand while the scan for the very same folder is still
        // in flight.
        model.startTranscription(jobID: job.id)
        #expect(model.gpuJobID == job.id)
        #expect(model.jobs.first?.status == .transcribing)

        try await waitForAdoption(model, jobID: job.id)

        // The sidecar existed and would normally be adopted, but the job is
        // active, so applyAdoptions must have skipped it entirely. The fake
        // media bytes make the real ASR attempt fail quickly and racily
        // against this wait, so don't assert the exact in-flight status
        // (.transcribing vs. .failed) — assert the tell the bug would leave
        // behind instead. Without the isJobActive/isRunning guard,
        // applyAdoptions would see a non-.queued status and unconditionally
        // stamp .transcriptionComplete plus the sidecar's provenance, which a
        // real failed/still-running ASR attempt never produces on its own.
        #expect(model.jobs.first?.status != .transcriptionComplete)
        #expect(model.jobs.first?.transcriptSegments.isEmpty == true)
        #expect(model.jobs.first?.importedTranscriptSource == nil)

        model.cancelActiveJob()
    }

    // The skip-if-unchanged branch would otherwise treat imported subtitles as
    // "already transcribed with these settings", which they never were.
    @Test func transcribeOnImportedJobDoesNotTakeTheSkipPath() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)
        #expect(model.jobs.first?.importedTranscriptSource != nil)

        model.startTranscription(jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.status != .transcriptionComplete, "Skip path was taken for an imported transcript")
        #expect(job.log.contains("Skipped transcription") == false)
        // A real run clears provenance for both slots: the old files no longer
        // describe this job's contents.
        #expect(job.importedTranscriptSource == nil)
        #expect(job.importedTranslationSource == nil)

        model.cancelActiveJob()
    }

    @Test func realRunClearsImportedTranslationProvenance() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt", "movie.vi.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)
        #expect(model.jobs.first?.importedTranslationSource != nil)

        model.startTranscription(jobID: jobID)

        #expect(model.jobs.first?.translatedSegments.isEmpty == true)
        #expect(model.jobs.first?.importedTranslationSource == nil)

        model.cancelActiveJob()
    }

    @Test func editsAreWrittenBackToTheImportedFile() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        // A summary is reachable on a wholly imported job (generateSummary
        // runs on any job with segments), and it must stay export-only: the
        // file has to mirror exactly what the editor shows.
        model.jobs[0].summary = "A spoiler-free intro."

        let segment = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(segment, text: "Edited text")
        model.flushSubtitleSync()

        let contents = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(contents.contains("Edited text"))
        #expect(contents.contains("Hello") == false)
        #expect(contents.contains("A spoiler-free intro.") == false)
        let firstCue = try #require(contents.components(separatedBy: "\n\n").first)
        #expect(firstCue.contains("Edited text"), "The first cue must be the real segment, not an intro summary")
    }

    @Test func firstWriteBacksUpTheOriginalExactlyOnce() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let backupURL = fixture.baseURL.appendingPathComponent("movie.ja.srt.bak")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let first = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(first, text: "One")
        model.flushSubtitleSync()
        let afterFirst = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(afterFirst.contains("Hello"), "The backup must hold the untouched original")

        let second = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(second, text: "Two")
        model.flushSubtitleSync()
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == afterFirst, "Backup was taken twice")
        // Cue's own first write must have been re-baselined, or the changed-on-disk
        // guard mistakes it for an external edit and sync dies after one write.
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")
        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("Two"))
    }

    // The safeguard that makes automatic write-back defensible: an edit made
    // elsewhere must never be silently destroyed.
    @Test func externalChangePausesSyncInsteadOfOverwriting() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let external = "1\n00:00:01,000 --> 00:00:02,000\nChanged by another app\n"
        try Data(external.utf8).write(to: sidecarURL)

        let segment = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(segment, text: "Cue edit")
        model.flushSubtitleSync()

        #expect(try String(contentsOf: sidecarURL, encoding: .utf8) == external)
        #expect(model.jobs.first?.importedTranscriptSource?.syncPaused == true)
        #expect(model.jobs.first?.log.contains("changed outside Cue") == true)
    }

    @Test func manyEditsCoalesceIntoOneWrite() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        for text in ["a", "b", "c", "d"] {
            let segment = try #require(model.jobs.first?.transcriptSegments.first)
            model.updateTranscriptSegment(segment, text: text)
        }
        // Nothing on disk yet: the debounce has not fired.
        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("Hello"))

        model.flushSubtitleSync()
        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("d"))
    }

    @Test func unlinkStopsWriteBack() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        // Edit first, so unlink really has a queued write to cancel.
        let segment = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(segment, text: "Should not reach disk")

        model.unlinkImportedSubtitles(slot: .transcript, jobID: jobID)
        #expect(model.jobs.first?.importedTranscriptSource == nil)

        model.flushSubtitleSync()

        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("Hello"))
    }

    // A machine translation replaces translatedSegments wholesale. If the
    // imported file stayed linked, the next edit would write machine output
    // over the user's own translation — and the changed-on-disk guard cannot
    // catch it, because the file never changed on disk.
    @Test func retranslationStopsWritingToTheImportedTranslationFile() async throws {
        let response = Data(
            #"{"choices":[{"message":{"content":"{\"segments\":[{\"id\":3,\"text\":\"Machine three\"}]}"},"finish_reason":"stop"}]}"#
                .utf8
        )
        let client = RecordingHTTPClient(responses: [.init(data: response, statusCode: 200)])
        let fixture = try makeFixture(
            sidecars: ["movie.ja.srt", "movie.vi.srt"],
            translationService: TranslationService(httpClient: client)
        )
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.settings.openAIModel = "local/qwen"
        model.settings.localTranslationEndpoint = "http://127.0.0.1:1234/v1"
        // A downloaded translation rarely matches the transcript cue for cue.
        // The extra transcript cue is what gives the re-translation real work
        // to do, so machine output genuinely enters translatedSegments.
        let threeCues = Self.srt + "\n\n3\n00:00:05,000 --> 00:00:06,000\nThird\n"
        try Data(threeCues.utf8).write(to: fixture.baseURL.appendingPathComponent("movie.ja.srt"))
        let translationURL = fixture.baseURL.appendingPathComponent("movie.vi.srt")
        let original = try String(contentsOf: translationURL, encoding: .utf8)

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)
        #expect(model.jobs.first?.importedTranslationSource != nil)

        model.startTranslation(jobID: jobID)
        // Adoption already left the job .translationComplete, so wait on the
        // machine output landing rather than on the status.
        for _ in 0..<200 {
            if model.jobs.first?.translatedSegments.count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.jobs.first?.translatedSegments.last?.text == "Machine three")
        #expect(model.jobs.first?.importedTranslationSource == nil)

        let segment = try #require(model.jobs.first?.translatedSegments.first)
        model.updateTranslatedSegment(segment, text: "Edited")
        model.flushSubtitleSync()

        #expect(try String(contentsOf: translationURL, encoding: .utf8) == original)
    }
}
