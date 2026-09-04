import Foundation
import Testing
@testable import Cue

@MainActor
struct JobStoreTests {
    private struct InjectedFailure: LocalizedError {
        let errorDescription: String? = "injected disk failure"
    }

    private let baseURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-jobstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Builds a job by decoding JSON so tests never touch AppSettingsStore
    /// (which reads UserDefaults and the real Keychain).
    private func makeJob(status: JobStatus, log: String = "log\n") throws -> TranscriptionJob {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "sourcePath": "/tmp/example.mp4",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-02T00:00:00Z",
              "status": "\(status.rawValue)",
              "progress": {"stage": "transcribing", "detail": "x"},
              "settings": {
                "sourceLanguage": "auto",
                "whisperModel": "m",
                "whisperBackend": "auto",
                "openAIModel": "gpt-5.2"
              },
              "transcriptSegments": [],
              "translatedSegments": [],
              "log": \(String(decoding: try JSONEncoder().encode(log), as: UTF8.self))
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: baseURL)
    }

    // A crash or force-quit mid-run must not leave a job stuck in a running
    // state forever: running states are unstartable, uncancelable, and
    // undeletable-without-data-loss.
    @Test func runningJobsAreMarkedInterruptedOnLoad() throws {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL)
        store.saveJob(try makeJob(status: .transcribing))
        store.saveJob(try makeJob(status: .translating))
        store.saveJob(try makeJob(status: .burningIn))
        store.saveJob(try makeJob(status: .transcriptionComplete))
        store.flush()

        let reloaded = JobStore(baseURL: baseURL).loadJobs()
        #expect(reloaded.count == 4)
        #expect(!reloaded.contains { $0.status.isRunning }, "Running statuses must be sanitized on load")
        #expect(reloaded.filter { $0.status == .canceled }.count == 3)
        #expect(reloaded.filter { $0.status == .transcriptionComplete }.count == 1)
    }

    /// Files decode in parallel; the result must not depend on which thread
    /// finished first, including for jobs that share an updatedAt.
    @Test func concurrentLoadReturnsEverySavedJobInDeterministicOrder() throws {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL)
        var expectedIDs = Set<UUID>()
        for index in 0..<300 {
            // Fifty jobs share the same updatedAt so the id tie-break matters.
            let job = try makeJob(status: .transcriptionComplete, log: "job \(index)\n")
            expectedIDs.insert(job.id)
            store.saveJob(job)
        }
        store.flush()

        let first = JobStore(baseURL: baseURL).loadJobs()
        let second = JobStore(baseURL: baseURL).loadJobs()
        let snapshot = JobStore(baseURL: baseURL).loadJobsSnapshot()

        #expect(first.count == 300)
        #expect(Set(first.map(\.id)) == expectedIDs)
        #expect(first.map(\.id) == second.map(\.id), "load order must be identical across launches")
        #expect(first.map(\.id) == snapshot.jobs.map(\.id))
        #expect(snapshot.failures.isEmpty)
        let sortedAgain = first.sorted(by: JobLoadOrdering.storeOrder)
        #expect(sortedAgain.map(\.id) == first.map(\.id))
    }

    @Test func simultaneousSnapshotsPreserveEveryJobPayload() async throws {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL)
        var expected: [UUID: String] = [:]
        for index in 0..<200 {
            let job = try makeJob(status: .idle, log: "Distinct payload \(index)")
            expected[job.id] = job.log
            store.saveJob(job)
        }
        store.flush()
        let snapshots = await withTaskGroup(of: JobLoadSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { store.loadJobsSnapshot() } }
            var snapshots: [JobLoadSnapshot] = []
            for await snapshot in group { snapshots.append(snapshot) }
            return snapshots
        }
        #expect(snapshots.count == 8)
        for snapshot in snapshots {
            #expect(snapshot.failures.isEmpty)
            #expect(snapshot.jobs.count == expected.count)
            #expect(snapshot.jobs.allSatisfy { expected[$0.id] == $0.log })
            #expect(snapshot.jobs.map(\.id) == snapshots.first?.jobs.map(\.id))
        }
        print("AUDIT06 validated_job_payloads=\(snapshots.reduce(0) { $0 + $1.jobs.count })/1600")
    }

    @Test func backgroundSnapshotCollectsFailuresForTheMainActorToSurface() throws {
        defer { cleanUp() }
        let job = try makeJob(status: .idle)
        let writer = JobStore(baseURL: baseURL)
        writer.saveJob(job)
        writer.flush()
        let expectedName = "\(job.id.uuidString).json"
        let reader = JobStore(baseURL: baseURL) { operation, url in
            if case .read = operation, url.lastPathComponent == expectedName { throw InjectedFailure() }
        }

        let snapshot = reader.loadJobsSnapshot()
        #expect(snapshot.jobs.isEmpty)
        #expect(snapshot.failures.count == 1)
        #expect(reader.startupError == nil, "a snapshot must not touch actor state")

        reader.recordStartupFailures(snapshot.failures)
        #expect(reader.startupError?.contains("It was preserved") == true)
    }

    @Test func flushCompletesPendingWrites() throws {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL)
        let job = try makeJob(status: .idle)
        store.saveJob(job)
        store.flush()

        let jobsFolder = baseURL.appendingPathComponent("Cue/jobs", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: jobsFolder.path)
        #expect(files.contains("\(job.id.uuidString).json"), "flush() must guarantee the write hit disk")
    }

    // A stale legacy jobs.json must never overwrite newer per-job files.
    @Test func legacyMigrationDoesNotClobberNewerPerJobFile() throws {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL)
        let job = try makeJob(status: .transcriptionComplete, log: "new data\n")
        store.saveJob(job)
        store.flush()

        var staleJob = job
        staleJob.log = "stale legacy data\n"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = baseURL.appendingPathComponent("Cue/jobs.json")
        try encoder.encode([staleJob]).write(to: legacyURL)

        let reloaded = JobStore(baseURL: baseURL).loadJobs()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.log == "new data\n", "Legacy migration overwrote a newer per-job file")
    }

    @Test func legacyMigrationStillImportsUnknownJobs() throws {
        defer { cleanUp() }
        let job = try makeJob(status: .transcriptionComplete, log: "legacy only\n")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let folder = baseURL.appendingPathComponent("Cue", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode([job]).write(to: folder.appendingPathComponent("jobs.json"))

        let reloaded = JobStore(baseURL: baseURL).loadJobs()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.log == "legacy only\n")
    }

    @Test func directoryCreationFailureIsVisibleAtStartup() {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL) { operation, _ in
            if case .createDirectory = operation { throw InjectedFailure() }
        }

        #expect(store.startupError?.contains("Could not create the job-history folder") == true)
    }

    @Test func directoryListingFailureDoesNotPretendHistoryIsEmpty() {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL) { operation, _ in
            if case .listDirectory = operation { throw InjectedFailure() }
        }

        #expect(store.loadJobs().isEmpty)
        #expect(store.startupError?.contains("Existing jobs may be hidden") == true)
    }

    @Test func failedSaveLeavesNoPartialJobFile() throws {
        defer { cleanUp() }
        let job = try makeJob(status: .idle)
        let store = JobStore(baseURL: baseURL) { operation, _ in
            if case .write = operation { throw InjectedFailure() }
        }

        store.saveJob(job)
        store.flush()

        let jobURL = baseURL.appendingPathComponent("Cue/jobs/\(job.id.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: jobURL.path))
    }

    @Test func failedJobReadPreservesTheOriginalForRecovery() throws {
        defer { cleanUp() }
        let job = try makeJob(status: .idle)
        let writer = JobStore(baseURL: baseURL)
        writer.saveJob(job)
        writer.flush()
        let expectedName = "\(job.id.uuidString).json"
        let reader = JobStore(baseURL: baseURL) { operation, url in
            if case .read = operation, url.lastPathComponent == expectedName { throw InjectedFailure() }
        }

        #expect(reader.loadJobs().isEmpty)
        let preserved = baseURL.appendingPathComponent("Cue/jobs/\(job.id.uuidString).corrupt.json")
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        #expect(reader.startupError?.contains("It was preserved") == true)
    }

    @Test func failedLegacyMoveKeepsSourceAndJobsVisibleForThisLaunch() throws {
        defer { cleanUp() }
        let job = try makeJob(status: .transcriptionComplete, log: "recover me\n")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let folder = baseURL.appendingPathComponent("Cue", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacyURL = folder.appendingPathComponent("jobs.json")
        try encoder.encode([job]).write(to: legacyURL)
        let store = JobStore(baseURL: baseURL) { operation, _ in
            if case .move = operation { throw InjectedFailure() }
        }

        let loaded = store.loadJobs()

        #expect(loaded.map(\.id) == [job.id])
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(store.startupError?.contains("original remains") == true)
    }
}
