import Foundation
import Testing
@testable import Cue

private actor EmptyFolderDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// Folder behaviour through `AppModel`: placement on every creation path,
/// the launch migration, and the operations and their undo.
@MainActor
struct AppModelFolderTests {
    /// Serves a seeded history and records every save, with no disk involved.
    private final class SeededStore: JobPersisting {
        var startupError: String?
        /// Written before hydration starts and only read by the off-main
        /// snapshot load afterwards, so the unchecked access is race-free.
        nonisolated(unsafe) var seeded: [TranscriptionJob] = []
        var saved: [TranscriptionJob] = []

        func loadJobs() -> [TranscriptionJob] { seeded }
        nonisolated func loadJobsSnapshot() -> JobLoadSnapshot {
            JobLoadSnapshot(jobs: seeded, failures: [])
        }
        func recordStartupFailures(_ failures: [String]) { startupError = failures.last }
        func saveJob(_ job: TranscriptionJob) { saved.append(job) }
        func deleteJob(_ id: UUID) {}
        func flush() {}
    }

    @MainActor
    private struct Harness {
        let model: AppModel
        let store: SeededStore
        let repository: JobRepository
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        /// The last saved snapshot of each job, as the store received it.
        var lastSaved: [UUID: TranscriptionJob] {
            Dictionary(store.saved.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        }
    }

    private func makeHarness(
        seed: [TranscriptionJob] = [],
        folderStore: JobFolderStore? = nil,
        hydrate: Bool = true
    ) async throws -> Harness {
        let suiteName = "app-model-folders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        settings.autoArchiveDays = 0
        let store = SeededStore()
        store.seeded = seed
        let repository = JobRepository(store: store)
        let model = AppModel(
            settings: settings,
            jobRepository: repository,
            folderStore: folderStore,
            watchLedger: WatchFolderLedger(baseURL: directory.appendingPathComponent("ledger")),
            diagnosticsService: EmptyFolderDiagnostics()
        )
        if hydrate { await model.hydration() }
        return Harness(
            model: model, store: store, repository: repository, directory: directory,
            defaults: defaults, suiteName: suiteName)
    }

    private func job(_ path: String, at seconds: TimeInterval = 0, folderID: UUID? = nil, origin: JobOrigin = .manual)
        throws -> TranscriptionJob
    {
        try FolderTestJobs.make(
            sourcePath: path, origin: origin,
            createdAt: FolderTestJobs.epoch.addingTimeInterval(seconds), folderID: folderID)
    }

    private func file(_ harness: Harness, _ relative: String) throws -> URL {
        let url = harness.directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func folderName(_ harness: Harness, of jobID: UUID) -> String? {
        harness.model.folderName(forJob: jobID)
    }

    // MARK: Isolation

    @Test func aModelOverAnInjectedRepositoryKeepsItsFoldersInMemory() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        #expect(harness.model.folderStore.fileURL == nil)
    }

    @Test func aModelOverAJobStoreKeepsFoldersNextToItsJobs() async throws {
        let suiteName = "app-model-folders-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-folders-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        let jobStore = JobStore(baseURL: base)
        let model = AppModel(settings: settings, jobStore: jobStore, diagnosticsService: EmptyFolderDiagnostics())
        #expect(model.folderStore.fileURL == jobStore.directoryURL.appendingPathComponent("folders.json"))
        #expect(model.folderStore.fileURL?.path.hasPrefix(base.path) == true)
    }

    // MARK: Migration

    @Test func hydrationPlacesEveryUnfiledJobByItsDirectory() async throws {
        let a1 = try job("/v/Actress A/one.mp4", at: 1)
        let a2 = try job("/v/Actress A/two.mp4", at: 2)
        let b1 = try job("/v/Studio B/three.mp4", at: 3)
        let harness = try await makeHarness(seed: [a1, a2, b1])
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.jobs.allSatisfy { $0.folderID != nil })
        #expect(folderName(harness, of: a1.id) == "Actress A")
        #expect(folderName(harness, of: a2.id) == "Actress A")
        #expect(folderName(harness, of: b1.id) == "Studio B")
        #expect(model.folders.count == 2)
        #expect(model.folders.allSatisfy { !$0.isManual })
    }

    @Test func migrationSavesEveryChangedJobInOneBatch() async throws {
        let jobs = try (0..<6).map { try job("/v/Dir\($0 % 2)/clip\($0).mp4", at: TimeInterval($0)) }
        let harness = try await makeHarness(hydrate: false)
        defer { harness.cleanUp() }
        harness.store.seeded = jobs
        await harness.model.hydration()

        #expect(harness.repository.flushCount == 1)
        #expect(harness.store.saved.count == 6)
        #expect(harness.lastSaved.values.allSatisfy { $0.folderID != nil })
    }

    @Test func migrationKeepsKnownFolderIDsAndReplacesUnknownOnes() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-folders-known-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let known = JobFolder(name: "My Picks", sourceKeys: [], isExpanded: true, isManual: true)
        let saver = JobFolderStore(baseURL: base)
        saver.save([known])
        saver.flush()

        let kept = try job("/v/Show/a.mp4", at: 1, folderID: known.id)
        let orphan = try job("/v/Show/b.mp4", at: 2, folderID: UUID())
        let harness = try await makeHarness(seed: [kept, orphan], folderStore: JobFolderStore(baseURL: base))
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.job(withID: kept.id)?.folderID == known.id)
        #expect(folderName(harness, of: kept.id) == "My Picks")
        #expect(folderName(harness, of: orphan.id) == "Show")
        #expect(harness.lastSaved[orphan.id]?.folderID != nil)
        #expect(harness.lastSaved[kept.id] == nil, "a job with a known folder is not rewritten")
    }

    @Test func aSecondLaunchChangesNothing() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-folders-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folderStore = JobFolderStore(baseURL: base)
        let jobs = try (0..<4).map { try job("/v/Dir\($0 % 2)/clip\($0).mp4", at: TimeInterval($0)) }

        let first = try await makeHarness(seed: jobs, folderStore: folderStore)
        defer { first.cleanUp() }
        first.model.flushPendingWork()
        let placed = first.lastSaved.values.sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(placed.allSatisfy { $0.folderID != nil })

        let second = try await makeHarness(seed: placed, folderStore: JobFolderStore(baseURL: base))
        defer { second.cleanUp() }
        #expect(second.store.saved.isEmpty, "already-placed jobs must not be saved again")
        #expect(second.model.folders == first.model.folders, "the folder list survives the round trip exactly")
        let secondFolders = Dictionary(uniqueKeysWithValues: second.model.jobs.map { ($0.id, $0.folderID) })
        #expect(placed.allSatisfy { secondFolders[$0.id] == $0.folderID })
    }

    // MARK: Creation paths

    @Test func addedVideosLandInTheirDirectoryFolder() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        let one = try file(harness, "Season 1/e1.mp4")
        let two = try file(harness, "Season 1/e2.mp4")
        let other = try file(harness, "Extras/x.mp4")
        harness.model.addVideos(urls: [one, two, other])

        let byName = Dictionary(grouping: harness.model.jobs, by: { folderName(harness, of: $0.id) ?? "?" })
        #expect(byName["Season 1"]?.count == 2)
        #expect(byName["Extras"]?.count == 1)
        #expect(harness.lastSaved.values.allSatisfy { $0.folderID != nil }, "the folder id is saved with the job")
    }

    @Test func aDownloadLandsInItsSiteFolder() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        let url = try file(harness, "Downloads/clip.mp4")
        harness.model.addVideos(
            urls: [url], origin: .url, sourceNote: "Downloaded from https://www.example.com/watch?v=1.")
        let added = try #require(harness.model.jobs.first)
        #expect(folderName(harness, of: added.id) == "example.com")
    }

    @Test func watchFolderBatchesSplitBySubfolderAndSaveOnce() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        let urls = [
            try file(harness, "Watch/Actress A/1.mp4"),
            try file(harness, "Watch/Actress A/2.mp4"),
            try file(harness, "Watch/Studio B/3.mp4"),
        ]
        let flushesBefore = harness.repository.flushCount
        harness.model.ingestWatchFolderFiles(urls, folderID: UUID())

        #expect(harness.repository.flushCount == flushesBefore + 1)
        #expect(Set(harness.model.jobs.compactMap { folderName(harness, of: $0.id) }) == ["Actress A", "Studio B"])
    }

    @Test func aRenamedFolderStillReceivesNewVideosFromTheSameDirectory() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        harness.model.addVideos(urls: [try file(harness, "Show/a.mp4")])
        let firstFolder = try #require(harness.model.jobs.first?.folderID)

        #expect(harness.model.renameFolder(firstFolder, to: "Favourite Show") == .accepted("Favourite Show"))
        harness.model.addVideos(urls: [try file(harness, "Show/b.mp4")])

        #expect(harness.model.folders.count == 1)
        #expect(harness.model.jobs.allSatisfy { $0.folderID == firstFolder })
        #expect(harness.model.folderName(forJob: harness.model.jobs[0].id) == "Favourite Show")
    }

    @Test func jobsAddedBeforeHydrationFinishesAreFiledByHydration() async throws {
        let seeded = try job("/v/Show/old.mp4", at: 1)
        let harness = try await makeHarness(seed: [seeded], hydrate: false)
        defer { harness.cleanUp() }
        harness.model.addVideos(urls: [try file(harness, "Show/early.mp4")])
        #expect(harness.model.jobs.first?.folderID == nil, "no folder list yet, so the early add waits")
        await harness.model.hydration()

        #expect(harness.model.jobs.allSatisfy { $0.folderID != nil })
        #expect(harness.model.folders.count == 2, "one for /v/Show and one for the temp directory's Show")
        #expect(Set(harness.lastSaved.keys) == Set(harness.model.jobs.map(\.id)))
    }

    // MARK: Move, create, merge

    @Test func movingJobsChangesOnlyTheirFolderAndSavesOneBatch() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let targetFolder = try #require(model.job(withID: b.id)?.folderID)
        let updatedAtBefore = try #require(model.job(withID: a.id)?.updatedAt)
        harness.store.saved.removeAll()
        let flushesBefore = harness.repository.flushCount

        let change = try #require(model.moveJobs([a.id], toFolder: targetFolder))
        #expect(change.kind == .moved)
        #expect(change.movedCount == 1)
        #expect(model.job(withID: a.id)?.folderID == targetFolder)
        #expect(model.job(withID: a.id)?.updatedAt == updatedAtBefore, "moving is not job activity")
        #expect(harness.store.saved.map(\.id) == [a.id])
        #expect(harness.repository.flushCount == flushesBefore + 1)
        #expect(model.moveJobs([a.id], toFolder: targetFolder) == nil, "already there")
    }

    @Test func movingIntoAnUnknownFolderDoesNothing() async throws {
        let a = try job("/v/A/a.mp4")
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let before = harness.model.job(withID: a.id)?.folderID
        #expect(harness.model.moveJobs([a.id], toFolder: UUID()) == nil)
        #expect(harness.model.job(withID: a.id)?.folderID == before)
    }

    @Test func aMoveIsUndone() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let original = try #require(model.job(withID: a.id)?.folderID)
        let target = try #require(model.job(withID: b.id)?.folderID)

        let change = try #require(model.moveJobs([a.id], toFolder: target))
        model.undoFolderChange(change)
        #expect(model.job(withID: a.id)?.folderID == original)
        #expect(harness.lastSaved[a.id]?.folderID == original)
    }

    @Test func undoDoesNotDragBackAJobTheUserMovedAgain() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let target = try #require(model.job(withID: b.id)?.folderID)
        let change = try #require(model.moveJobs([a.id], toFolder: target))
        let elsewhere = try #require(model.createFolder(named: "Elsewhere")?.folderID)
        model.moveJobs([a.id], toFolder: elsewhere)

        model.undoFolderChange(change)
        #expect(model.job(withID: a.id)?.folderID == elsewhere)
    }

    @Test func newFolderWithSelectedJobsMovesThemAndUndoRemovesTheFolder() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/A/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let original = try #require(model.job(withID: a.id)?.folderID)

        let change = try #require(model.createFolder(named: "Best of", movingJobs: [a.id, b.id]))
        #expect(change.kind == .created)
        #expect(change.movedCount == 2)
        #expect(model.folder(withID: change.folderID)?.isManual == true)
        #expect(model.job(withID: a.id)?.folderID == change.folderID)

        model.undoFolderChange(change)
        #expect(model.folder(withID: change.folderID) == nil)
        #expect(model.jobs.allSatisfy { $0.folderID == original })
    }

    @Test func aFolderNameMustBeNewAndNonEmpty() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        #expect(harness.model.createFolder(named: "   ") == nil)
        #expect(harness.model.createFolder(named: "Picks") != nil)
        #expect(harness.model.createFolder(named: "picks") == nil)
        #expect(harness.model.validatedFolderName("PICKS") == .duplicate)
        #expect(harness.model.suggestedFolderName == "New Folder")
        #expect(harness.model.folders.count == 1)
    }

    @Test func mergingMovesJobsAndKeysAndRemovesTheSource() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let source = try #require(model.job(withID: a.id)?.folderID)
        let target = try #require(model.job(withID: b.id)?.folderID)

        let change = try #require(model.mergeFolder(source, into: target))
        #expect(change.kind == .merged(sourceName: "A"))
        #expect(change.movedCount == 1)
        #expect(model.folder(withID: source) == nil)
        #expect(model.job(withID: a.id)?.folderID == target)
        #expect(Set(model.folder(withID: target)?.sourceKeys ?? []) == ["dir:/v/A", "dir:/v/B"])
    }

    @Test func aVideoFromAMergedFoldersOldPlaceFollowsItsKeys() async throws {
        let harness = try await makeHarness(hydrate: false)
        defer { harness.cleanUp() }
        let a = try job(harness.directory.appendingPathComponent("A/a.mp4").path, at: 1)
        let b = try job(harness.directory.appendingPathComponent("B/b.mp4").path, at: 2)
        harness.store.seeded = [a, b]
        await harness.model.hydration()
        let model = harness.model
        let source = try #require(model.job(withID: a.id)?.folderID)
        let target = try #require(model.job(withID: b.id)?.folderID)
        model.mergeFolder(source, into: target)

        model.addVideos(urls: [try file(harness, "A/again.mp4")])
        let arrival = try #require(model.jobs.first)
        #expect(arrival.folderID == target, "the merged folder took over A's source key")
        #expect(model.folders.count == 1)
    }

    @Test func mergingIntoItselfOrAMissingFolderDoesNothing() async throws {
        let a = try job("/v/A/a.mp4")
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let only = try #require(harness.model.job(withID: a.id)?.folderID)
        #expect(harness.model.mergeFolder(only, into: only) == nil)
        #expect(harness.model.mergeFolder(only, into: UUID()) == nil)
        #expect(harness.model.mergeFolder(UUID(), into: only) == nil)
        #expect(harness.model.folders.count == 1)
    }

    @Test func aMergeIsUndoneWithItsKeys() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let source = try #require(model.job(withID: a.id)?.folderID)
        let target = try #require(model.job(withID: b.id)?.folderID)
        let foldersBefore = model.folders

        let change = try #require(model.mergeFolder(source, into: target))
        model.undoFolderChange(change)

        #expect(model.job(withID: a.id)?.folderID == source)
        #expect(model.job(withID: b.id)?.folderID == target)
        #expect(Set(model.folders.map(\.id)) == Set(foldersBefore.map(\.id)))
        #expect(model.folder(withID: source)?.sourceKeys == ["dir:/v/A"])
        #expect(model.folder(withID: target)?.sourceKeys == ["dir:/v/B"])
    }

    // MARK: Delete

    @Test func deletingAFolderNeverDeletesJobs() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/A/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.job(withID: a.id)?.folderID)

        let change = try #require(model.deleteFolder(folder))
        #expect(change.kind == .deleted)
        #expect(model.jobs.count == 2)
        // Automatic placement puts them straight back in a fresh folder of the same name.
        let refiled = try #require(model.job(withID: a.id)?.folderID)
        #expect(refiled != folder)
        #expect(model.job(withID: b.id)?.folderID == refiled)
        #expect(model.folderName(forJob: a.id) == "A")
        #expect(model.folder(withID: folder) == nil)
    }

    @Test func deletingAManualFolderReturnsItsJobsToTheirDirectoryFolder() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let model = harness.model
        let picks = try #require(model.createFolder(named: "Picks", movingJobs: [a.id])?.folderID)
        #expect(model.job(withID: a.id)?.folderID == picks)

        let change = try #require(model.deleteFolder(picks))
        #expect(model.folder(withID: picks) == nil)
        #expect(model.folderName(forJob: a.id) == "A")
        #expect(change.movedCount == 1)
    }

    @Test func deleteFolderIsUndoneIncludingKeysAndMembership() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/A/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let original = try #require(model.job(withID: a.id)?.folderID)
        let folderBefore = try #require(model.folder(withID: original))
        harness.model.renameFolder(original, to: "Renamed")

        let change = try #require(model.deleteFolder(original))
        model.undoFolderChange(change)

        #expect(model.job(withID: a.id)?.folderID == original)
        #expect(model.job(withID: b.id)?.folderID == original)
        #expect(model.folders.count == 1, "the replacement folder made by re-placement is dropped")
        #expect(model.folder(withID: original)?.name == "Renamed")
        #expect(model.folder(withID: original)?.sourceKeys == folderBefore.sourceKeys)
        #expect(harness.lastSaved[a.id]?.folderID == original)
    }

    @Test func undoingADeleteFoldsLaterArrivalsIntoTheRestoredFolder() async throws {
        let harness = try await makeHarness(hydrate: false)
        defer { harness.cleanUp() }
        let a = try job(harness.directory.appendingPathComponent("A/a.mp4").path, at: 1)
        harness.store.seeded = [a]
        await harness.model.hydration()
        let model = harness.model
        let original = try #require(model.job(withID: a.id)?.folderID)
        let change = try #require(model.deleteFolder(original))
        let replacement = try #require(model.job(withID: a.id)?.folderID)
        #expect(replacement != original)

        // A new video from the same directory joins the replacement folder.
        model.addVideos(urls: [try file(harness, "A/new.mp4")])
        let arrival = try #require(model.jobs.first)
        #expect(arrival.folderID == replacement)

        model.undoFolderChange(change)
        #expect(model.job(withID: a.id)?.folderID == original)
        #expect(model.job(withID: arrival.id)?.folderID == original, "later arrivals follow the restored keys")
        #expect(model.folder(withID: replacement) == nil)
        #expect(model.folders.count == 1)
        #expect(harness.lastSaved[arrival.id]?.folderID == original)
    }

    // MARK: Expansion and reveal

    @Test func expansionPersistsThroughTheBook() async throws {
        let a = try job("/v/A/a.mp4")
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let folder = try #require(harness.model.job(withID: a.id)?.folderID)
        harness.model.setFolderExpanded(false, for: folder)
        #expect(harness.model.folder(withID: folder)?.isExpanded == false)
        harness.model.setAllFoldersExpanded(true)
        #expect(harness.model.folder(withID: folder)?.isExpanded == true)
    }

    @Test func selectingAJobInACollapsedFolderOpensIt() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.job(withID: a.id)?.folderID)
        model.setFolderExpanded(false, for: folder)

        model.selectJob(a.id)
        #expect(model.folder(withID: folder)?.isExpanded == true)

        model.setFolderExpanded(false, for: folder)
        model.selectJobs([b.id])
        #expect(model.folder(withID: folder)?.isExpanded == false, "selecting elsewhere leaves it closed")
        model.selectJobs([a.id, b.id])
        #expect(model.folder(withID: folder)?.isExpanded == true)
    }

    @Test func collapsingAFolderKeepsTheSelectionOfItsJobs() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let a2 = try job("/v/A/a2.mp4", at: 2)
        let b = try job("/v/B/b.mp4", at: 3)
        let harness = try await makeHarness(seed: [a, a2, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.job(withID: a.id)?.folderID)

        model.selectJobs([a.id, a2.id])
        model.setFolderExpanded(false, for: folder)
        #expect(model.selectedJobIDs == [a.id, a2.id])
        #expect(model.selectedJobID != nil)

        model.setAllFoldersExpanded(false)
        #expect(model.selectedJobIDs == [a.id, a2.id], "collapsing every folder does not clear the selection either")
        model.setAllFoldersExpanded(true)
        #expect(model.selectedJobIDs == [a.id, a2.id])
    }

    @Test func theLaunchTimePickDoesNotReopenACollapsedFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-folders-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try job("/v/A/a.mp4", at: 1)
        let first = try await makeHarness(seed: [a], folderStore: JobFolderStore(baseURL: base))
        defer { first.cleanUp() }
        let folder = try #require(first.model.job(withID: a.id)?.folderID)
        first.model.setFolderExpanded(false, for: folder)
        first.model.flushPendingWork()

        let placed = try #require(first.lastSaved[a.id])
        let second = try await makeHarness(seed: [placed], folderStore: JobFolderStore(baseURL: base))
        defer { second.cleanUp() }
        #expect(second.model.selectedJobID == a.id)
        #expect(second.model.folder(withID: folder)?.isExpanded == false)
    }

    @Test func revealJobSelectsOpensAndPublishesARequest() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.job(withID: a.id)?.folderID)
        model.setFolderExpanded(false, for: folder)

        model.revealJob(a.id)
        #expect(model.selectedJobID == a.id)
        #expect(model.folder(withID: folder)?.isExpanded == true)
        let request = try #require(model.revealRequest)
        #expect(request.jobID == a.id)
        #expect(!request.showsArchived)

        model.consumeRevealRequest(request)
        #expect(model.revealRequest == nil)
    }

    @Test func revealingAnArchivedJobAsksForTheArchivedView() async throws {
        var archived = try job("/v/A/a.mp4", at: 1)
        archived.archivedAt = FolderTestJobs.epoch
        let harness = try await makeHarness(seed: [archived])
        defer { harness.cleanUp() }
        harness.model.revealJob(archived.id)
        #expect(harness.model.revealRequest?.showsArchived == true)
    }

    @Test func revealingTheSameJobTwiceIsANewRequest() async throws {
        let a = try job("/v/A/a.mp4")
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        harness.model.revealJob(a.id)
        let first = try #require(harness.model.revealRequest)
        harness.model.revealJob(a.id)
        let second = try #require(harness.model.revealRequest)
        #expect(first != second)
        harness.model.consumeRevealRequest(first)
        #expect(harness.model.revealRequest == second, "consuming a stale request leaves the newer one")
    }

    @Test func paletteJobRowsRevealThroughTheFolderTree() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.job(withID: a.id)?.folderID)
        model.setFolderExpanded(false, for: folder)

        #expect(model.performPaletteTarget(.job(a.id)) == .done)
        #expect(model.selectedJobID == a.id)
        #expect(model.folder(withID: folder)?.isExpanded == true)
        #expect(model.revealRequest?.jobID == a.id)
    }

    @Test func paletteFolderRowsOpenTheFolderAtItsNewestLiveJob() async throws {
        let older = try job("/v/A/older.mp4", at: 1)
        let newer = try job("/v/A/newer.mp4", at: 2)
        var archived = try job("/v/A/archived.mp4", at: 3)
        archived.archivedAt = FolderTestJobs.epoch
        let other = try job("/v/B/other.mp4", at: 4)
        let harness = try await makeHarness(seed: [older, newer, archived, other])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.job(withID: older.id)?.folderID)
        model.setFolderExpanded(false, for: folder)

        // The snapshot names each job's folder and counts only live jobs.
        let snapshot = model.makePaletteSnapshot()
        let summary = try #require(snapshot.folders.first { $0.id == folder })
        #expect(summary.jobCount == 2)
        #expect(snapshot.jobs.first { $0.id == newer.id }?.folderName == summary.name)

        #expect(model.performPaletteTarget(.folder(folder)) == .done)
        #expect(model.folder(withID: folder)?.isExpanded == true)
        #expect(model.selectedJobID == newer.id)
        #expect(model.revealRequest?.jobID == newer.id)

        let gone = UUID()
        #expect(model.paletteUnavailabilityReason(for: .folder(gone)) == "That folder was deleted")
    }

    @Test func paletteOffersManualEmptyFoldersButNotEmptyAutomaticOnes() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let model = harness.model
        let automatic = try #require(model.job(withID: a.id)?.folderID)
        let change = try #require(model.createFolder(named: "Later", movingJobs: [a.id]))

        let folders = model.makePaletteSnapshot().folders
        #expect(folders.map(\.id) == [change.folderID])
        #expect(folders.first?.jobCount == 1)
        #expect(!folders.contains { $0.id == automatic }, "the emptied automatic folder is hidden, as in the sidebar")
    }

    @Test func revealingAnUnknownJobDoesNothing() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        harness.model.revealJob(UUID())
        #expect(harness.model.revealRequest == nil)
    }

    // MARK: Read API

    @Test func readAPIsAnswerForKnownAndUnknownJobs() async throws {
        let a = try job("/v/A/a.mp4")
        let harness = try await makeHarness(seed: [a])
        defer { harness.cleanUp() }
        let model = harness.model
        let folder = try #require(model.folderID(forJob: a.id))
        #expect(model.folder(withID: folder)?.name == "A")
        #expect(model.folderName(forJob: a.id) == "A")
        #expect(model.folderName(forJob: UUID()) == nil)
        #expect(model.folder(withID: UUID()) == nil)
        #expect(model.folders.map(\.id) == [folder])
    }

    // MARK: Concurrency with other job writes

    @Test func aFolderMoveSurvivesLaterJobUpdatesAndViceVersa() async throws {
        let a = try job("/v/A/a.mp4", at: 1)
        let b = try job("/v/B/b.mp4", at: 2)
        let harness = try await makeHarness(seed: [a, b])
        defer { harness.cleanUp() }
        let model = harness.model
        let target = try #require(model.job(withID: b.id)?.folderID)
        model.moveJobs([a.id], toFolder: target)

        // An ordinary job write (archive) goes through the same index-based
        // path and must not put the old folder back.
        model.setArchived(a.id, true)
        #expect(model.job(withID: a.id)?.folderID == target)
        #expect(harness.lastSaved[a.id]?.folderID == target)
        #expect(harness.lastSaved[a.id]?.archivedAt != nil)
    }
}
