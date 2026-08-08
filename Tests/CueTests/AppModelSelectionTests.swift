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
    @Test func multiSelectionKeepsOnePrimaryJobForTheDetailPane() throws {
        let fixture = try makeFixture()
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

    @Test func bulkDeleteRemovesAllSelectedRecordsButNotSourceMedia() throws {
        let fixture = try makeFixture(createSources: true)
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

    private func makeFixture(createSources: Bool = false) throws -> SelectionFixture {
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
