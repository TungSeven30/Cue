import Foundation
import Testing
@testable import Cue

@MainActor
struct JobRepositoryTests {
    private final class RecordingStore: JobPersisting {
        var startupError: String?
        var loaded: [TranscriptionJob] = []
        var saved: [TranscriptionJob] = []
        var deleted: [UUID] = []
        var flushCount = 0

        func loadJobs() -> [TranscriptionJob] { loaded }
        nonisolated func loadJobsSnapshot() -> JobLoadSnapshot { JobLoadSnapshot(jobs: [], failures: []) }
        func recordStartupFailures(_ failures: [String]) { startupError = failures.last }
        func saveJob(_ job: TranscriptionJob) { saved.append(job) }
        func deleteJob(_ id: UUID) { deleted.append(id) }
        func flush() { flushCount += 1 }
    }

    /// Immutable snapshot payload so the store's nonisolated loader can run
    /// off the main actor without touching mutable test state.
    private final class SnapshotStore: JobPersisting {
        var startupError: String?
        private let snapshot: JobLoadSnapshot

        init(snapshot: JobLoadSnapshot) {
            self.snapshot = snapshot
        }

        func loadJobs() -> [TranscriptionJob] { snapshot.jobs }
        nonisolated func loadJobsSnapshot() -> JobLoadSnapshot { snapshot }
        func recordStartupFailures(_ failures: [String]) { startupError = failures.last }
        func saveJob(_: TranscriptionJob) {}
        func deleteJob(_: UUID) {}
        func flush() {}
    }

    private func makeJob() throws -> TranscriptionJob {
        let data = Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "sourcePath": "/tmp/example.mp4",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-02T00:00:00Z",
              "status": "idle",
              "progress": {"stage": "queued", "detail": "x"},
              "settings": {
                "sourceLanguage": "auto", "whisperModel": "m",
                "whisperBackend": "auto", "openAIModel": "gpt-5.2"
              },
              "transcriptSegments": [], "translatedSegments": [], "log": ""
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: data)
    }

    @Test func debouncedSnapshotsCoalesceToTheNewestJob() throws {
        let store = RecordingStore()
        let repository = JobRepository(store: store, debounceNanoseconds: 60_000_000_000)
        var job = try makeJob()
        repository.save(job, debounced: true)
        job.log = "newest"
        repository.save(job, debounced: true)

        repository.flush()

        #expect(store.saved.count == 1)
        #expect(store.saved.first?.log == "newest")
    }

    @Test func flushPersistsPendingSnapshotsBeforeFlushingStore() throws {
        let store = RecordingStore()
        let repository = JobRepository(store: store, debounceNanoseconds: 60_000_000_000)
        let job = try makeJob()
        repository.save(job, debounced: true)

        repository.flush()

        #expect(store.saved.map(\.id) == [job.id])
        #expect(store.flushCount == 1)
    }

    @Test func batchSavePersistsEverySnapshotOnce() throws {
        let store = RecordingStore()
        let repository = JobRepository(store: store)
        let jobs = try (0..<20).map { _ in try makeJob() }

        repository.save(jobs)

        #expect(Set(store.saved.map(\.id)) == Set(jobs.map(\.id)))
        #expect(store.saved.count == jobs.count)
    }

    @Test func loadJobsSnapshotRunsOffMainActor() async throws {
        let job = try makeJob()
        let expected = JobLoadSnapshot(jobs: [job], failures: ["startup warning"])
        let repository = JobRepository(store: SnapshotStore(snapshot: expected))

        let loaded = await Task.detached(priority: .userInitiated) {
            repository.loadJobsSnapshot()
        }.value

        #expect(loaded.jobs.map(\.id) == [job.id])
        #expect(loaded.failures == ["startup warning"])
    }

    @Test func deleteDropsAQueuedSnapshot() throws {
        let store = RecordingStore()
        let repository = JobRepository(store: store, debounceNanoseconds: 60_000_000_000)
        let job = try makeJob()
        repository.save(job, debounced: true)

        repository.delete(job.id)
        repository.flush()

        #expect(store.saved.isEmpty)
        #expect(store.deleted == [job.id])
    }
}
