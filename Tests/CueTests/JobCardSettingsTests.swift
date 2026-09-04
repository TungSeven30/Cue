import Foundation
import Testing
@testable import Cue

private actor EmptyJobCardDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

@MainActor
struct JobCardSettingsTests {
    @Test func jobCardOverrideDoesNotMutateGlobalDefaults() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.settings.translationTargetLanguage = "English"
        model.settings.transcriptionPreset = .builtIn
        model.settings.autoTranslateAfterTranscription = false
        model.settings.generateSummary = false
        model.addVideos(urls: [fixture.sourceURL(1)])

        let globalTarget = model.settings.translationTargetLanguage
        let globalPreset = model.settings.transcriptionPreset
        let globalAutoTranslate = model.settings.autoTranslateAfterTranscription
        let globalSummary = model.settings.generateSummary

        model.updateSelectedJobOverrides {
            $0.translationTargetLanguage = "Vietnamese"
            $0.transcriptionPreset = .bestAccuracy
            $0.autoTranslate = true
            $0.generateSummary = true
        }

        #expect(model.settings.translationTargetLanguage == globalTarget)
        #expect(model.settings.transcriptionPreset == globalPreset)
        #expect(model.settings.autoTranslateAfterTranscription == globalAutoTranslate)
        #expect(model.settings.generateSummary == globalSummary)
        #expect(model.currentJob?.overrides.translationTargetLanguage == "Vietnamese")
        #expect(model.currentJob?.overrides.transcriptionPreset == .bestAccuracy)
        #expect(model.currentJob?.overrides.autoTranslate == true)
        #expect(model.currentJob?.overrides.generateSummary == true)
    }

    @Test func newlyAddedJobStillUsesGlobalDefaults() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.settings.translationTargetLanguage = "English"
        model.addVideos(urls: [fixture.sourceURL(1)])
        let firstJobID = try #require(model.currentJob?.id)

        model.updateSelectedJobOverrides {
            $0.translationTargetLanguage = "Vietnamese"
            $0.openAIModel = "gpt-5.5"
        }

        model.addVideos(urls: [fixture.sourceURL(2)])
        let newJob = try #require(model.jobs.first { $0.id != firstJobID })

        #expect(newJob.overrides.isEmpty)
        #expect(model.resolvedSettings(for: newJob).translationTargetLanguage == "English")
        #expect(model.resolvedSettings(for: newJob).openAIModel == model.settings.openAIModel)
    }

    @Test func jobCardEditDoesNotRewriteWatchFolderProfile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        var folder = WatchFolder(path: "/tmp/japanese-inbox")
        folder.profile.translationTargetLanguage = "Japanese"
        folder.profile.autoTranslate = true
        model.settings.watchFolders = [folder]
        let folderID = folder.id

        model.addVideos(urls: [fixture.sourceURL(1)])
        model.updateSelectedJobOverrides {
            $0.translationTargetLanguage = "Vietnamese"
            $0.autoTranslate = false
        }

        let stored = try #require(model.settings.watchFolders.first { $0.id == folderID })
        #expect(stored.profile.translationTargetLanguage == "Japanese")
        #expect(stored.profile.autoTranslate == true)
    }

    private func makeFixture() async throws -> JobCardFixture {
        let suiteName = "job-card-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("job-card-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        for index in 1...2 {
            try Data("media \(index)".utf8).write(to: baseURL.appendingPathComponent("source-\(index).mp4"))
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
            diagnosticsService: EmptyJobCardDiagnostics()
        )
        await model.hydration()
        return JobCardFixture(
            model: model,
            baseURL: baseURL,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private struct JobCardFixture {
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
