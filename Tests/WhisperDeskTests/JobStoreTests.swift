import Foundation
import Testing
@testable import WhisperDesk

@MainActor
struct JobStoreTests {
    private let baseURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperdesk-jobstore-\(UUID().uuidString)")
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
        store.saveJob(try makeJob(status: .transcriptionComplete))
        store.flush()

        let reloaded = JobStore(baseURL: baseURL).loadJobs()
        #expect(reloaded.count == 3)
        #expect(!reloaded.contains { $0.status.isRunning }, "Running statuses must be sanitized on load")
        #expect(reloaded.filter { $0.status == .canceled }.count == 2)
        #expect(reloaded.filter { $0.status == .transcriptionComplete }.count == 1)
    }

    @Test func flushCompletesPendingWrites() throws {
        defer { cleanUp() }
        let store = JobStore(baseURL: baseURL)
        let job = try makeJob(status: .idle)
        store.saveJob(job)
        store.flush()

        let jobsFolder = baseURL.appendingPathComponent("WhisperDesk/jobs", isDirectory: true)
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
        let legacyURL = baseURL.appendingPathComponent("WhisperDesk/jobs.json")
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
        let folder = baseURL.appendingPathComponent("WhisperDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode([job]).write(to: folder.appendingPathComponent("jobs.json"))

        let reloaded = JobStore(baseURL: baseURL).loadJobs()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.log == "legacy only\n")
    }
}
