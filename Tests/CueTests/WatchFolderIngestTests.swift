import Foundation
import Testing
@testable import Cue

private actor EmptyIngestDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// Watch-folder ingestion of a whole batch must cost one order-index base
/// and one repository flush, not one of each per file.
@MainActor
struct WatchFolderIngestTests {
    private final class RecordingStore: JobPersisting {
        var startupError: String?
        var saved: [TranscriptionJob] = []

        func loadJobs() -> [TranscriptionJob] { [] }
        nonisolated func loadJobsSnapshot() -> JobLoadSnapshot { JobLoadSnapshot(jobs: [], failures: []) }
        func recordStartupFailures(_ failures: [String]) { startupError = failures.last }
        func saveJob(_ job: TranscriptionJob) { saved.append(job) }
        func deleteJob(_ id: UUID) {}
        func flush() {}
    }

    @Test func aBatchOfFilesIsPersistedInOneFlushWithConsecutiveOrderIndices() async throws {
        let suiteName = "watch-ingest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        let store = RecordingStore()
        let repository = JobRepository(store: store)
        let model = AppModel(
            settings: settings,
            jobRepository: repository,
            diagnosticsService: EmptyIngestDiagnostics()
        )
        await model.hydration()
        // An existing manual job so the watch batch has something to land under.
        let manual = directory.appendingPathComponent("manual.mp4")
        try Data("m".utf8).write(to: manual)
        model.addVideos(urls: [manual])
        let flushesBefore = repository.flushCount
        let savesBefore = store.saved.count
        let maxExisting = try #require(model.jobs.map(\.orderIndex).max())

        let urls = (0..<25).map { directory.appendingPathComponent("episode-\($0).mkv") }
        for url in urls {
            try Data("x".utf8).write(to: url)
        }
        let folderID = UUID()
        model.ingestWatchFolderFiles(urls, folderID: folderID)

        #expect(repository.flushCount == flushesBefore + 1, "the batch must reach the store as one flush")
        #expect(store.saved.count == savesBefore + 25)
        #expect(Set(store.saved.suffix(25).map(\.id)).count == 25)
        let ingested = model.jobs.filter { $0.origin == .watchFolder }
        #expect(ingested.count == 25)
        #expect(ingested.map(\.orderIndex) == (1...25).map { maxExisting + Double($0) }, "one base, incremented per file")
        #expect(ingested.allSatisfy { $0.status == .queued })
        #expect(ingested.map { $0.sourceURL.lastPathComponent } == urls.map(\.lastPathComponent), "batch order is preserved")
        #expect(model.jobs.map(\.orderIndex) == model.jobs.map(\.orderIndex).sorted())
        model.flushPendingWork()
    }
}
