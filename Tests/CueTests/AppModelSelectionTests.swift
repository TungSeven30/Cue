import Foundation
import Testing
@testable import Cue

private actor EmptySelectionDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

@MainActor
struct AppModelSelectionTests {
    @Test func multiSelectionKeepsOnePrimaryJobForTheDetailPane() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2), fixture.sourceURL(3)])
        let ids = model.jobs.map(\.id)
        let initialPrimary = try #require(model.selectedJobID)
        let additionalID = try #require(ids.first(where: { $0 != initialPrimary }))

        model.selectJobs([initialPrimary, additionalID])

        #expect(model.selectedJobIDs == [initialPrimary, additionalID])
        #expect(model.selectedJobID == additionalID)
        #expect(model.currentJob?.id == additionalID)

        model.selectJobs([initialPrimary])

        #expect(model.selectedJobIDs == [initialPrimary])
        #expect(model.selectedJobID == initialPrimary)
    }

    @Test func bulkDeleteRemovesAllSelectedRecordsButNotSourceMedia() async throws {
        let fixture = try await makeFixture(createSources: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sourceURLs = [fixture.sourceURL(1), fixture.sourceURL(2), fixture.sourceURL(3)]
        model.addVideos(urls: sourceURLs)
        let deletingIDs = Set(model.jobs.prefix(2).map(\.id))
        model.selectJobs(deletingIDs)

        #expect(model.canDeleteJobs(deletingIDs))
        model.deleteJobs(deletingIDs)
        model.flushPendingWork()

        #expect(model.jobs.count == 1)
        #expect(model.jobs.allSatisfy { !deletingIDs.contains($0.id) })
        #expect(model.selectedJobIDs == Set(model.jobs.map(\.id)))
        #expect(model.selectedJobID == model.jobs.first?.id)
        #expect(sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(JobStore(baseURL: fixture.baseURL).loadJobs().count == 1)
    }

    @Test func bulkArchiveAndUnarchiveUpdatesTheSelectionAndPersists() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2), fixture.sourceURL(3)])
        let archivingIDs = Set(model.jobs.prefix(2).map(\.id))
        model.selectJobs(archivingIDs)

        model.setArchived(archivingIDs, true)
        model.flushPendingWork()

        #expect(model.jobs.filter { archivingIDs.contains($0.id) }.allSatisfy { $0.archivedAt != nil })
        #expect(model.selectedJobIDs.isDisjoint(with: archivingIDs))
        #expect(model.currentJob?.archivedAt == nil)

        model.setArchived(archivingIDs, false)
        model.flushPendingWork()

        #expect(model.jobs.filter { archivingIDs.contains($0.id) }.allSatisfy { $0.archivedAt == nil })
        let reloaded = JobStore(baseURL: fixture.baseURL).loadJobs()
        #expect(reloaded.filter { archivingIDs.contains($0.id) }.allSatisfy { $0.archivedAt == nil })
    }

    @Test func bulkRemoveFromQueueChangesOnlyQueuedJobs() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2), fixture.sourceURL(3)])
        let queuedIDs = Set(model.jobs.prefix(2).map(\.id))
        for index in model.jobs.indices where queuedIDs.contains(model.jobs[index].id) {
            model.jobs[index].status = .queued
            model.jobs[index].progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }
        let untouchedID = try #require(model.jobs.first(where: { !queuedIDs.contains($0.id) })?.id)
        let untouchedIndex = try #require(model.jobs.firstIndex(where: { $0.id == untouchedID }))
        model.jobs[untouchedIndex].status = .canceled

        model.removeJobsFromQueue(Set(model.jobs.map(\.id)))

        #expect(model.jobs.filter { queuedIDs.contains($0.id) }.allSatisfy { $0.status == .idle })
        #expect(model.jobs.first(where: { $0.id == untouchedID })?.status == .canceled)
    }

    @Test func restoreQueueUndoRestoresEligibleJobsAndPausedState() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2)])
        let ids = Set(model.jobs.map(\.id))
        for index in model.jobs.indices {
            model.jobs[index].status = .queued
            model.jobs[index].progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }

        model.removeJobsFromQueue(ids)
        model.restoreJobsToQueue(ids, queueWasPaused: true)

        #expect(model.queuePaused)
        #expect(model.jobs.allSatisfy { $0.status == .queued })
    }

    @Test func startSelectedJobPausesEveryOtherQueuedJob() async throws {
        let fixture = try await makeFixture(createSources: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2), fixture.sourceURL(3)])
        let selectedID = try #require(model.jobs.dropFirst().first?.id)
        let otherIDs = Set(model.jobs.lazy.filter { $0.id != selectedID }.map(\.id))

        for index in model.jobs.indices {
            model.jobs[index].status = .queued
            model.jobs[index].progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }
        model.selectJob(selectedID)

        #expect(model.canStartSelectedJob)
        model.startSelectedJob()

        #expect(model.queuePaused)
        #expect(model.gpuJobID == selectedID)
        #expect(model.jobs.first(where: { $0.id == selectedID })?.status == .transcribing)
        #expect(model.jobs.filter { otherIDs.contains($0.id) }.allSatisfy { $0.status == .queued })

        model.cancelActiveJob()
    }

    @Test func startSelectedJobRequiresExactlyOneIdleSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2)])
        let ids = Set(model.jobs.map(\.id))

        model.selectJobs(ids)
        #expect(!model.canStartSelectedJob)

        model.selectJobs([])
        #expect(!model.canStartSelectedJob)
    }

    @Test func retryFailedJobsQueuesOnlyRetryableFailures() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.addVideos(urls: [fixture.sourceURL(1), fixture.sourceURL(2), fixture.sourceURL(3)])
        // addVideos kicks off an async sidecar scan per job; jobNeedsWork (which
        // gates retryFailedJobs) treats a job mid-scan as having no work, so the
        // scan must land before this test forces jobs into .failed and retries.
        for job in model.jobs {
            var settled = false
            for _ in 0..<100 {
                if !model.isScanningForSubtitles(job.id) {
                    settled = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            if !settled { Issue.record("Sidecar scan never finished") }
        }
        let failedIDs = Set(model.jobs.prefix(2).map(\.id))
        for index in model.jobs.indices where failedIDs.contains(model.jobs[index].id) {
            model.jobs[index].status = .failed
        }
        let untouchedID = try #require(model.jobs.first(where: { !failedIDs.contains($0.id) })?.id)

        model.retryFailedJobs(Set(model.jobs.map(\.id)))

        #expect(model.jobs.filter { failedIDs.contains($0.id) }.allSatisfy { $0.status == .queued || $0.status.isRunning })
        #expect(model.jobs.first(where: { $0.id == untouchedID })?.status == .idle)
    }

    private func makeFixture(createSources: Bool = false) async throws -> SelectionFixture {
        let suiteName = "app-model-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        if createSources {
            for index in 1...3 {
                try Data("media \(index)".utf8).write(to: baseURL.appendingPathComponent("source-\(index).mp4"))
            }
        }
        let settings = AppSettingsStore(
            defaults: defaults,
            readSecret: { _ in nil },
            writeSecret: { _, _ in true }
        )
        settings.autoStartAddedJobs = false
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            diagnosticsService: EmptySelectionDiagnostics()
        )
        await model.hydration()
        return SelectionFixture(
            model: model,
            baseURL: baseURL,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private struct SelectionFixture {
    let model: AppModel
    let baseURL: URL
    let defaults: UserDefaults
    let suiteName: String

    func sourceURL(_ index: Int) -> URL {
        baseURL.appendingPathComponent("source-\(index).mp4")
    }

    func cleanUp() {
        model.flushPendingWork()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseURL)
    }
}
