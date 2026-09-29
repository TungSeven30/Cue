import Foundation
import Testing

@testable import Cue

private actor PaletteStubDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// An isolated model over temp stores and a private defaults suite: nothing
/// here can reach the user's jobs, settings, ledger, or Keychain.
@MainActor
private struct PaletteModelFixture {
    let model: AppModel
    let settings: AppSettingsStore
    let defaults: UserDefaults
    let suiteName: String
    let baseURL: URL

    static func make() async throws -> PaletteModelFixture {
        let suiteName = "palette-model-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let settings = AppSettingsStore(
            defaults: defaults,
            readSecret: { _ in nil },
            writeSecret: { _, _ in true }
        )
        settings.autoStartAddedJobs = false
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            watchLedger: WatchFolderLedger(baseURL: baseURL),
            diagnosticsService: PaletteStubDiagnostics()
        )
        await model.hydration()
        // The launch-time environment check runs on a task of its own; wait it
        // out so a test never races it for `isRunningDiagnostics`.
        var waited = 0
        while model.isRunningDiagnostics && waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(!model.isRunningDiagnostics, "the stub diagnostics never finished")
        return PaletteModelFixture(
            model: model, settings: settings, defaults: defaults, suiteName: suiteName, baseURL: baseURL
        )
    }

    /// Adds a job and selects it (that is what adding does).
    @discardableResult
    func addJob(
        _ name: String,
        status: JobStatus = .idle,
        transcript: Bool = false,
        translation: Bool = false
    ) throws -> UUID {
        model.addVideos(urls: [baseURL.appendingPathComponent("\(name).mp4")])
        let id = try #require(model.selectedJobID)
        let index = try #require(model.index(of: id))
        model.jobs[index].status = status
        if transcript {
            model.jobs[index].transcriptSegments = [TranscriptionSegment(id: 1, start: 0, end: 4, text: "Hello there")]
        }
        if translation {
            model.jobs[index].translatedSegments = [TranscriptionSegment(id: 1, start: 0, end: 4, text: "こんにちは")]
        }
        return id
    }

    /// A local model needs a server URL and never an API key.
    func makeTranslationReady() {
        settings.openAIModel = "local/palette-test"
    }

    func cleanUp() {
        model.flushPendingWork()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseURL)
    }
}

/// What the app's own menus decide for the same command, read straight from
/// the model with the same expressions `CueApp` uses. `nil` means the menus
/// have no item to compare with.
@MainActor
private func menuEnablement(of id: PaletteCommandID, in model: AppModel) -> Bool? {
    switch id {
    case .primaryAction: model.canPerformPrimaryAction
    case .addFiles, .addFromURL, .openSetupGuide, .openSettings: true
    case .loadSubtitles: model.canLoadSubtitles
    case .startAll: model.hasPendingWork || model.queuePaused
    case .transcribe, .retryTranscribe: model.canTranscribe
    case .translate: model.canTranslate
    case .writeSummary: model.canGenerateSummary
    case .stopAll: model.canCancel
    case .exportSheet, .exportTranscriptSRT: !model.transcriptSegments.isEmpty
    case .exportTranslationSRT, .exportBilingualSRT: !model.translatedSegments.isEmpty
    case .exportLog, .toggleVideoPreview, .revealInFinder: model.currentJob != nil
    case .jobSettings: model.currentJob != nil && !model.isSelectedJobRunning
    case .burnIn: model.canBurnIn
    case .runDiagnostics: !model.isRunningDiagnostics
    case .checkForUpdates: nil
    }
}

@MainActor
private final class EffectLog {
    var revealed: [URL] = []
    var updateChecks = 0
}

@MainActor
struct CommandPaletteModelTests {
    private func effects(
        _ fixture: PaletteModelFixture,
        log: EffectLog,
        updater: Bool = true
    ) -> PaletteEffects {
        var checkForUpdates: (@MainActor () -> Void)?
        if updater { checkForUpdates = { log.updateChecks += 1 } }
        return PaletteEffects(
            defaults: fixture.defaults,
            reveal: { log.revealed.append($0) },
            checkForUpdates: checkForUpdates
        )
    }

    // MARK: - Snapshot of the model

    @Test func contextCopiesTheModelsOwnFlagsAndWording() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        try fixture.addJob("Keynote Rehearsal", status: .transcriptionComplete, transcript: true, translation: true)

        let context = model.makePaletteContext(canCheckForUpdates: false)
        #expect(context.selectedJobTitle == "Keynote Rehearsal")
        #expect(context.selectedJobStatus == .transcriptionComplete)
        #expect(context.hasTranscript)
        #expect(context.hasTranslation)
        #expect(context.primaryActionTitle == model.primaryActionTitle)
        #expect(context.primaryActionSymbol == model.primaryActionSystemImage)
        #expect(context.translationExportTitle == model.translationExportTitle)
        #expect(context.bilingualExportTitle == model.bilingualExportTitle)
        #expect(context.canPerformPrimaryAction == model.canPerformPrimaryAction)
        #expect(context.isPlayerVisible == model.isPlayerVisible)
        #expect(!context.canCheckForUpdates)
        #expect(model.makePaletteContext(canCheckForUpdates: true).canCheckForUpdates)
    }

    @Test func snapshotListsJobsFoldersAndTheSelection() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        try fixture.addJob("Interview")
        let keynote = try fixture.addJob("Keynote", status: .failed)
        fixture.settings.watchFolders = [WatchFolder(path: "/Users/me/Inbox")]

        let snapshot = model.makePaletteSnapshot()
        #expect(snapshot.selectedJobID == keynote)
        #expect(Set(snapshot.jobs.map(\.title)) == ["Interview", "Keynote"])
        let summary = try #require(snapshot.jobs.first { $0.id == keynote })
        #expect(summary.status == .failed)
        #expect(summary.fileName == "Keynote.mp4")
        #expect(summary.path == fixture.baseURL.appendingPathComponent("Keynote.mp4").path)
        #expect(!summary.isArchived)
        #expect(snapshot.watchFolders.map(\.name) == ["Inbox"])
        #expect(snapshot.watchFolders.first?.isEnabled == true)
        #expect(snapshot.failedDownloads.isEmpty)
    }

    // MARK: - Menu parity

    @Test func everyRowAgreesWithItsMenuItemAcrossModelStates() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model

        func check(_ state: String) {
            let context = model.makePaletteContext(canCheckForUpdates: true)
            for id in PaletteCommandID.allCases {
                guard let expected = menuEnablement(of: id, in: model) else { continue }
                let actual = PaletteCatalog.availability(of: id, in: context).isEnabled
                #expect(actual == expected, "\(state): \(id) is \(actual ? "enabled" : "disabled") in the palette")
            }
        }

        check("no jobs")
        model.queuePaused = true
        check("paused queue, no jobs")
        model.queuePaused = false
        model.isRunningDiagnostics = true
        check("diagnostics running")
        model.isRunningDiagnostics = false

        try fixture.addJob("Idle")
        check("idle job")
        try fixture.addJob("Queued", status: .queued)
        check("queued job")
        try fixture.addJob("Transcribed", status: .transcriptionComplete, transcript: true)
        check("transcript, translation not set up")
        fixture.makeTranslationReady()
        check("transcript, translation ready")
        try fixture.addJob("Translated", status: .translationComplete, transcript: true, translation: true)
        check("transcript and translation")
        try fixture.addJob("Translating", status: .translating, transcript: true)
        check("job translating")
        try fixture.addJob("Transcribing", status: .transcribing)
        check("job transcribing")
    }

    // MARK: - Presentation

    @Test func toggleOpensClosesAndStaysInertBehindSheets() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let jobID = try fixture.addJob("Interview")

        model.toggleCommandPalette()
        #expect(model.isShowingCommandPalette)
        model.toggleCommandPalette()
        #expect(!model.isShowingCommandPalette)

        let sheets: [(String, () -> Void, () -> Void)] = [
            ("export", { model.isShowingExportSheet = true }, { model.isShowingExportSheet = false }),
            ("setup guide", { model.isShowingSetupGuide = true }, { model.isShowingSetupGuide = false }),
            ("burn in", { model.isShowingBurnInSheet = true }, { model.isShowingBurnInSheet = false }),
            (
                "yt-dlp install", { model.ytDlpInstallRequest = YtDlpInstallRequest(pageURL: nil) },
                { model.ytDlpInstallRequest = nil }
            ),
            ("job settings", { model.overridesEditorJobID = jobID }, { model.overridesEditorJobID = nil }),
        ]
        for (name, present, dismiss) in sheets {
            present()
            #expect(model.isPresentingSheet, "\(name)")
            #expect(!model.canToggleCommandPalette, "\(name)")
            model.toggleCommandPalette()
            #expect(!model.isShowingCommandPalette, "\(name) let the palette open underneath it")
            dismiss()
            #expect(!model.isPresentingSheet, "\(name)")
            #expect(model.canToggleCommandPalette, "\(name)")
        }

        // An open palette can always be closed, even if a sheet appears over it.
        model.toggleCommandPalette()
        model.isShowingExportSheet = true
        #expect(model.canToggleCommandPalette)
        model.toggleCommandPalette()
        #expect(!model.isShowingCommandPalette)
    }

    // MARK: - Running rows

    @Test func jobRowsLandInOneCallSite() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let first = try fixture.addJob("Interview")
        let second = try fixture.addJob("Keynote")
        model.selectJob(first)

        let index = PaletteIndex.build(from: model.makePaletteSnapshot())
        let row = try #require(index.results(for: "keynote").entryRows.first)
        #expect(row.entry.target == .job(second))
        let outcome = model.performPaletteTarget(row.entry.target, effects: effects(fixture, log: EffectLog()))
        #expect(outcome == .done)
        #expect(model.selectedJobID == second)

        // A job removed since the row was drawn changes nothing and says so.
        model.revealJobFromPalette(UUID())
        #expect(model.selectedJobID == second)
        let gone = model.performPaletteTarget(.job(UUID()), effects: effects(fixture, log: EffectLog()))
        #expect(gone == .unavailable("That job is no longer in the list"))
        #expect(model.selectedJobID == second)
    }

    @Test func settingRowsStoreThePaneThenAskTheViewToOpenSettings() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let outcome = fixture.model.performPaletteTarget(
            .setting(.models), effects: effects(fixture, log: EffectLog())
        )
        #expect(outcome == .openSettings)
        #expect(fixture.defaults.string(forKey: SettingsPane.storageKey) == "models")
        #expect(fixture.model.performPaletteTarget(.command(.openSettings), effects: effects(fixture, log: EffectLog())) == .openSettings)
    }

    @Test func watchFolderRowsRevealTheFolderAndRefuseARemovedOne() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let log = EffectLog()
        let watched = WatchFolder(path: "/Users/me/Inbox")
        fixture.settings.watchFolders = [watched]

        let outcome = fixture.model.performPaletteTarget(.watchFolder(watched.id), effects: effects(fixture, log: log))
        #expect(outcome == .done)
        #expect(log.revealed == [URL(fileURLWithPath: "/Users/me/Inbox", isDirectory: true)])

        let removed = fixture.model.performPaletteTarget(.watchFolder(UUID()), effects: effects(fixture, log: log))
        #expect(removed == .unavailable("That watch folder was removed"))
        #expect(log.revealed.count == 1)
    }

    @Test func downloadRowsRefuseADownloadThatIsNoLongerFailed() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let outcome = fixture.model.performPaletteTarget(.download(UUID()), effects: effects(fixture, log: EffectLog()))
        #expect(outcome == .unavailable("That download is no longer failed"))
    }

    @Test func commandsRecheckTheirEnableConditionWhenRun() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let live = effects(fixture, log: EffectLog())

        // Nothing selected: refused with the reason the row showed, and nothing ran.
        #expect(model.performPaletteTarget(.command(.exportSheet), effects: live) == .unavailable("Select a job first"))
        #expect(model.performPaletteTarget(.command(.transcribe), effects: live) == .unavailable("Select a job first"))
        #expect(model.performPaletteTarget(.command(.stopAll), effects: live) == .unavailable("Nothing is running"))
        #expect(model.performPaletteTarget(.command(.startAll), effects: live) == .unavailable("Nothing is waiting to run"))
        #expect(!model.isShowingExportSheet)

        try fixture.addJob("Interview")
        #expect(
            model.performPaletteTarget(.command(.exportSheet), effects: live)
                == .unavailable("The selected job has no transcript yet")
        )
        #expect(
            model.performPaletteTarget(.command(.translate), effects: live)
                == .unavailable("Transcribe the selected job first")
        )
        #expect(!model.isShowingExportSheet)
        #expect(!model.isShowingBurnInSheet)

        let hidden = effects(fixture, log: EffectLog(), updater: false)
        #expect(
            model.performPaletteTarget(.command(.checkForUpdates), effects: hidden)
                == .unavailable("Not available in this build")
        )
    }

    @Test func commandsRunTheSameModelStateChangesAsTheirMenus() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let log = EffectLog()
        let live = effects(fixture, log: log)
        let id = try fixture.addJob("Keynote", status: .transcriptionComplete, transcript: true)
        let job = try #require(model.job(withID: id))

        #expect(model.performPaletteTarget(.command(.exportSheet), effects: live) == .done)
        #expect(model.isShowingExportSheet)
        model.isShowingExportSheet = false

        #expect(model.performPaletteTarget(.command(.burnIn), effects: live) == .done)
        #expect(model.isShowingBurnInSheet)
        model.isShowingBurnInSheet = false

        #expect(model.performPaletteTarget(.command(.jobSettings), effects: live) == .done)
        #expect(model.overridesEditorJobID == id)
        model.overridesEditorJobID = nil

        #expect(model.performPaletteTarget(.command(.openSetupGuide), effects: live) == .done)
        #expect(model.isShowingSetupGuide)
        model.isShowingSetupGuide = false

        // The result of a check is only visible in the setup guide, so it opens.
        #expect(model.performPaletteTarget(.command(.runDiagnostics), effects: live) == .done)
        #expect(model.isShowingSetupGuide)
        model.isShowingSetupGuide = false

        #expect(model.performPaletteTarget(.command(.revealInFinder), effects: live) == .done)
        #expect(log.revealed == [job.sourceURL])

        #expect(model.performPaletteTarget(.command(.checkForUpdates), effects: live) == .done)
        #expect(log.updateChecks == 1)
    }

    @Test func theVideoPreviewCommandFlipsTheSameFlagAsTheToolbarButton() async throws {
        let fixture = try await PaletteModelFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.model
        try fixture.addJob("Interview")

        // The flag persists itself; put the process's defaults back as found.
        let key = "isPlayerVisible"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let before = model.isPlayerVisible
        let live = effects(fixture, log: EffectLog())
        #expect(model.performPaletteTarget(.command(.toggleVideoPreview), effects: live) == .done)
        #expect(model.isPlayerVisible == !before)
        #expect(model.makePaletteContext().isPlayerVisible == !before)
        #expect(model.performPaletteTarget(.command(.toggleVideoPreview), effects: live) == .done)
        #expect(model.isPlayerVisible == before)
    }
}
