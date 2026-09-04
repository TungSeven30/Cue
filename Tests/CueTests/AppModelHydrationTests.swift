import Foundation
import Testing
@testable import Cue

private actor EmptyHydrationDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// The job history loads off the main actor after the window is up; these
/// pin the merge rules and the gates that make that safe.
@MainActor
struct AppModelHydrationTests {
    @MainActor
    private struct Fixture {
        let baseURL: URL
        let defaults: UserDefaults
        let suiteName: String
        let settings: AppSettingsStore

        func makeModel() -> AppModel {
            AppModel(
                settings: settings,
                jobStore: JobStore(baseURL: baseURL),
                diagnosticsService: EmptyHydrationDiagnostics()
            )
        }

        func sourceURL(_ name: String) -> URL {
            baseURL.appendingPathComponent(name)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "app-model-hydration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-hydration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        settings.autoArchiveDays = 0
        return Fixture(baseURL: baseURL, defaults: defaults, suiteName: suiteName, settings: settings)
    }

    /// Writes `count` finished jobs straight into the store, optionally
    /// giving every one the same orderIndex to exercise the tie-break.
    private func seedHistory(_ fixture: Fixture, count: Int, sharedOrderIndex: Double? = nil, sourcePath: String? = nil) throws -> [UUID] {
        let store = JobStore(baseURL: fixture.baseURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var ids: [UUID] = []
        for index in 0..<count {
            let id = UUID()
            ids.append(id)
            let path = sourcePath ?? "\(fixture.baseURL.path)/history-\(index).mp4"
            let fingerprint = TranscriptionJob.fingerprint(for: URL(fileURLWithPath: path))
            let json = """
                {
                  "id": "\(id.uuidString)",
                  "sourcePath": "\(path)",
                  "sourceFingerprint": "\(fingerprint)",
                  "createdAt": "2026-01-01T00:00:00Z",
                  "updatedAt": "2026-01-02T00:00:\(String(format: "%02d", index % 60))Z",
                  "status": "transcriptionComplete",
                  "progress": {"stage": "complete", "detail": "done", "fraction": 1},
                  "settings": {"sourceLanguage": "auto", "whisperModel": "m", "whisperBackend": "whisper-cpp", "openAIModel": "gpt-5.2"},
                  "transcriptSegments": [{"id": 1, "start": 0, "end": 1, "text": "history \(index)"}],
                  "translatedSegments": [],
                  "orderIndex": \(sharedOrderIndex ?? Double(index)),
                  "log": "done\\n"
                }
                """
            store.saveJob(try decoder.decode(TranscriptionJob.self, from: Data(json.utf8)))
        }
        store.flush()
        return ids
    }

    @Test func jobsAddedDuringHydrationStayOnTopAndAreNotDuplicated() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let historyIDs = try seedHistory(fixture, count: 40)
        try Data("a".utf8).write(to: fixture.sourceURL("early-1.mp4"))
        try Data("b".utf8).write(to: fixture.sourceURL("early-2.mp4"))

        let model = fixture.makeModel()
        #expect(model.isHydratingJobs)
        #expect(model.jobs.isEmpty)
        model.addVideos(urls: [fixture.sourceURL("early-1.mp4"), fixture.sourceURL("early-2.mp4")])
        let earlyIDs = model.jobs.map(\.id)
        #expect(earlyIDs.count == 2)
        #expect(model.selectedJobID == earlyIDs.first)

        await model.hydration()

        #expect(!model.isHydratingJobs)
        #expect(model.jobs.count == 42)
        #expect(Array(model.jobs.prefix(2).map(\.id)) == earlyIDs, "interactive adds stay on top")
        #expect(Set(model.jobs.map(\.id)) == Set(earlyIDs).union(historyIDs))
        #expect(model.jobs[1].orderIndex < model.jobs[2].orderIndex, "early jobs are re-stamped above the history")
        #expect(model.jobs.map(\.orderIndex) == model.jobs.map(\.orderIndex).sorted())
        #expect(model.selectedJobID == earlyIDs.first, "an early selection is not overridden")
        model.flushPendingWork()
        // The re-stamped indices reached disk, so the next launch agrees.
        let reloaded = JobStore(baseURL: fixture.baseURL).loadJobs()
        let reloadedEarly = reloaded.filter { earlyIDs.contains($0.id) }.sorted { $0.orderIndex < $1.orderIndex }
        #expect(reloadedEarly.map(\.id) == earlyIDs)
        #expect(reloadedEarly.allSatisfy { early in reloaded.filter { historyIDs.contains($0.id) }.allSatisfy { early.orderIndex < $0.orderIndex } })
    }

    @Test func hydratedOrderIsIdenticalAcrossLaunchesWithEqualOrderIndices() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try seedHistory(fixture, count: 60, sharedOrderIndex: 3)

        let first = fixture.makeModel()
        await first.hydration()
        let second = fixture.makeModel()
        await second.hydration()

        #expect(first.jobs.count == 60)
        #expect(first.jobs.map(\.id) == second.jobs.map(\.id))
        #expect(first.selectedJobID == first.jobs.first?.id)
    }

    @Test func watchFoldersAndQueueWaitForHydration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let inbox = fixture.baseURL.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let media = inbox.appendingPathComponent("episode.mp4")
        try Data(repeating: 1, count: 2048).write(to: media)
        // The history already contains this exact file (same fingerprint),
        // so a scan must treat it as done, never as a new file. The scanner
        // reports the fully resolved path (the temp folder is a symlink into
        // /private, which URL.resolvingSymlinksInPath deliberately strips),
        // so the seeded job uses realpath, as a real ingest would have.
        let resolvedPath = try #require(realpath(media.path, nil).map { String(cString: $0) })
        _ = try seedHistory(fixture, count: 1, sourcePath: resolvedPath)
        fixture.settings.watchFolders = [WatchFolder(path: inbox.path)]

        let model = fixture.makeModel()
        #expect(model.watchServices.isEmpty, "no watch service may run before the history is merged")

        await model.hydration()

        #expect(model.watchServices.count == 1)
        #expect(model.jobs.count == 1)
        // Two scans more than the stability interval apart would ingest an
        // unknown file; this one is blocked by the loaded job's fingerprint.
        let service = try #require(model.watchServices.values.first)
        service.scan()
        try await Task.sleep(for: .seconds(WatchFolderScanEngine.stabilityInterval + 0.5))
        service.scan()
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.jobs.count == 1, "a file whose job loaded from history must not be re-ingested")
        model.settings.watchFolders = []
        model.syncWatchFolders()
    }

    @Test func storeFailuresSurfaceAfterHydration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try seedHistory(fixture, count: 2)
        let corrupt = fixture.baseURL.appendingPathComponent("Cue/jobs/\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: corrupt)

        let model = fixture.makeModel()
        await model.hydration()

        #expect(model.jobs.count == 2)
        #expect(model.jobStoreStartupError?.contains("It was preserved") == true)
        // The notification bus is process-wide, so under parallel tests the
        // displayed message may already belong to another fixture; only its
        // presence is asserted here.
        #expect(model.persistenceError != nil)
    }

    @Test func indexLookupSurvivesReorderInsertAndDelete() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        await model.hydration()
        let urls = (1...5).map { fixture.sourceURL("clip-\($0).mp4") }
        for url in urls {
            try Data("x".utf8).write(to: url)
        }
        model.addVideos(urls: urls)
        let ids = model.jobs.map(\.id)

        func expectConsistent() {
            for (offset, job) in model.jobs.enumerated() {
                #expect(model.index(of: job.id) == offset)
                #expect(model.job(withID: job.id)?.id == job.id)
            }
        }
        expectConsistent()
        model.moveJobToBottom(ids[0])
        #expect(model.jobs.last?.id == ids[0])
        expectConsistent()
        model.moveJobToTop(ids[3])
        expectConsistent()
        model.deleteJobs([ids[1]])
        expectConsistent()
        #expect(model.index(of: ids[1]) == nil)
        model.addVideos(urls: [fixture.sourceURL("clip-1.mp4")])
        expectConsistent()
        #expect(model.index(of: UUID()) == nil)
    }
}
