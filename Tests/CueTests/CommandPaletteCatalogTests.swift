import Testing

@testable import Cue

struct CommandPaletteCatalogTests {
    private func spec(_ id: PaletteCommandID, in context: PaletteContext = PaletteContext()) -> PaletteCommandSpec {
        PaletteCatalog.spec(for: id, in: context)
    }

    private func enabledIDs(in context: PaletteContext) -> Set<PaletteCommandID> {
        Set(PaletteCommandID.allCases.filter { PaletteCatalog.availability(of: $0, in: context).isEnabled })
    }

    private func reason(_ id: PaletteCommandID, in context: PaletteContext) -> String? {
        PaletteCatalog.availability(of: id, in: context).reason
    }

    private func context(
        job status: JobStatus? = nil,
        _ configure: (inout PaletteContext) -> Void = { _ in }
    ) -> PaletteContext {
        var context = PaletteContext()
        if let status {
            context.selectedJobTitle = "Interview"
            context.selectedJobStatus = status
        }
        configure(&context)
        return context
    }

    // MARK: - Inventory

    @Test func everyCommandHasAUniqueTitleSymbolAndKnownMenuPath() {
        let knownPaths: Set<String> = ["File menu", "Toolbar", "Job context menu", "Setup", "Cue menu"]
        var titles: [String] = []
        for id in PaletteCommandID.allCases {
            let spec = spec(id)
            #expect(!spec.title.isEmpty, "\(id)")
            #expect(!spec.symbol.isEmpty, "\(id)")
            #expect(knownPaths.contains(spec.menuPath), "\(id): \(spec.menuPath)")
            #expect(!spec.keywords.isEmpty, "\(id)")
            titles.append(spec.title)
        }
        #expect(Set(titles).count == titles.count)
    }

    @Test func shortcutsMatchTheMenuBarExactly() {
        let expected: [PaletteCommandID: String] = [
            .primaryAction: "⌘⏎", .addFiles: "⌘O", .addFromURL: "⌘L", .loadSubtitles: "⇧⌘O",
            .startAll: "⇧⌘R", .transcribe: "⌘R", .translate: "⌘T", .stopAll: "⌘.",
            .exportSheet: "⌘E", .openSettings: "⌘,",
        ]
        for id in PaletteCommandID.allCases {
            #expect(spec(id).shortcut?.glyphs == expected[id], "\(id)")
        }
    }

    @Test func shortcutsNeverCollideAndLeaveCommandKFree() {
        let glyphs = PaletteCommandID.allCases.compactMap { spec($0).shortcut?.glyphs }
        #expect(Set(glyphs).count == glyphs.count)
        #expect(!glyphs.contains("⌘K"))
    }

    @Test func shortcutsAreSpokenInFull() {
        #expect(spec(.primaryAction).shortcut?.spoken == "Command Return")
        #expect(spec(.stopAll).shortcut?.spoken == "Command Period")
        #expect(spec(.loadSubtitles).shortcut?.spoken == "Shift Command O")
        #expect(spec(.openSettings).shortcut?.spoken == "Command Comma")
    }

    @Test func modifiersAreAlwaysWrittenInMacOrder() {
        let all = PaletteShortcut(key: "X", control: true, option: true, shift: true)
        #expect(all.glyphs == "⌃⌥⇧⌘X")
        #expect(all.spoken == "Control Option Shift Command X")
        let noCommand = PaletteShortcut(key: "X", control: true, command: false)
        #expect(noCommand.glyphs == "⌃X")
        #expect(noCommand.spoken == "Control X")
    }

    @Test func suggestionRanksAreUniqueAndCoverTheCommonCommands() {
        let ranked = PaletteCommandID.allCases
            .compactMap { id in spec(id).suggestionRank.map { (id, $0) } }
            .sorted { $0.1 < $1.1 }
        #expect(
            ranked.map(\.0) == [.primaryAction, .addFiles, .addFromURL, .startAll, .stopAll, .exportSheet]
        )
        #expect(Set(ranked.map(\.1)).count == ranked.count)
    }

    // MARK: - Wording that follows the model

    @Test func titlesAndSymbolsFollowTheContext() {
        var context = PaletteContext()
        context.primaryActionTitle = "Translate"
        context.primaryActionSymbol = "character.bubble"
        context.translationExportTitle = "Japanese Translation"
        context.bilingualExportTitle = "English + Japanese"
        #expect(spec(.primaryAction, in: context).title == "Next Step: Translate")
        #expect(spec(.primaryAction, in: context).symbol == "character.bubble")
        #expect(spec(.exportTranslationSRT, in: context).title == "Export Japanese Translation SRT")
        #expect(spec(.exportBilingualSRT, in: context).title == "Export English + Japanese SRT")
    }

    @Test func videoPreviewRowNamesTheActionItWillTake() {
        var context = PaletteContext()
        #expect(spec(.toggleVideoPreview, in: context).title == "Show Video Preview")
        context.isPlayerVisible = true
        #expect(spec(.toggleVideoPreview, in: context).title == "Hide Video Preview")
        #expect(spec(.toggleVideoPreview, in: context).symbol == "play.rectangle.fill")
    }

    // MARK: - Availability mirrors the menus

    @Test func emptyContextEnablesOnlyContextFreeCommands() {
        #expect(
            enabledIDs(in: PaletteContext()) == [.addFiles, .addFromURL, .runDiagnostics, .openSetupGuide, .openSettings]
        )
    }

    @Test func eachCapabilityFlagUnlocksExactlyItsCommands() {
        let cases: [(String, (inout PaletteContext) -> Void, Set<PaletteCommandID>)] = [
            ("canPerformPrimaryAction", { $0.canPerformPrimaryAction = true }, [.primaryAction]),
            ("canLoadSubtitles", { $0.canLoadSubtitles = true }, [.loadSubtitles]),
            ("hasPendingWork", { $0.hasPendingWork = true }, [.startAll]),
            ("queuePaused", { $0.queuePaused = true }, [.startAll]),
            ("canTranscribe", { $0.canTranscribe = true }, [.transcribe, .retryTranscribe]),
            ("canTranslate", { $0.canTranslate = true }, [.translate]),
            ("canGenerateSummary", { $0.canGenerateSummary = true }, [.writeSummary]),
            ("canCancel", { $0.canCancel = true }, [.stopAll]),
            ("hasTranscript", { $0.hasTranscript = true }, [.exportSheet, .exportTranscriptSRT]),
            ("hasTranslation", { $0.hasTranslation = true }, [.exportTranslationSRT, .exportBilingualSRT]),
            ("canBurnIn", { $0.canBurnIn = true }, [.burnIn]),
            ("canCheckForUpdates", { $0.canCheckForUpdates = true }, [.checkForUpdates]),
            (
                "a selected job",
                {
                    $0.selectedJobTitle = "Interview"
                    $0.selectedJobStatus = .idle
                },
                [.exportLog, .toggleVideoPreview, .revealInFinder, .jobSettings]
            ),
        ]
        let baseline = enabledIDs(in: PaletteContext())
        for (name, configure, unlocked) in cases {
            var context = PaletteContext()
            configure(&context)
            #expect(enabledIDs(in: context) == baseline.union(unlocked), "\(name)")
        }
    }

    @Test func checkForUpdatesIsHiddenNotDisabledWithoutAnUpdater() {
        #expect(PaletteCatalog.availability(of: .checkForUpdates, in: PaletteContext()) == .hidden)
        #expect(PaletteCatalog.specs(in: PaletteContext()).count == PaletteCommandID.allCases.count - 1)
        var context = PaletteContext()
        context.canCheckForUpdates = true
        #expect(PaletteCatalog.specs(in: context).count == PaletteCommandID.allCases.count)
    }

    @Test func jobSettingsAreLockedWhileTheJobRuns() {
        for status in JobStatus.allCases {
            let context = context(job: status)
            let isEnabled = PaletteCatalog.availability(of: .jobSettings, in: context).isEnabled
            #expect(isEnabled == !status.isRunning, "\(status)")
        }
        #expect(
            reason(.jobSettings, in: context(job: .transcribing)) == "Settings can't change while the job runs"
        )
    }

    // MARK: - Reasons

    @Test func reasonsExplainTheNextStep() {
        #expect(reason(.stopAll, in: PaletteContext()) == "Nothing is running")
        #expect(reason(.startAll, in: PaletteContext()) == "Nothing is waiting to run")
        #expect(reason(.exportLog, in: PaletteContext()) == "Select a job first")
        #expect(reason(.translate, in: PaletteContext()) == "Select a job first")
        #expect(reason(.translate, in: context(job: .idle)) == "Transcribe the selected job first")
        #expect(reason(.exportSheet, in: context(job: .idle)) == "The selected job has no transcript yet")
        #expect(reason(.exportBilingualSRT, in: context(job: .idle)) == "The selected job has no translation yet")
        #expect(reason(.burnIn, in: context(job: .idle)) == "Transcribe the selected job first")
        #expect(reason(.runDiagnostics, in: context { $0.isRunningDiagnostics = true }) == "Already checking")

        let translationNotReady = context(job: .transcriptionComplete) { $0.hasTranscript = true }
        #expect(reason(.translate, in: translationNotReady) == "No translation model or API key is set up yet")
        let summaryNotReady = context(job: .transcriptionComplete) { $0.hasTranscript = true }
        #expect(reason(.writeSummary, in: summaryNotReady) == "No summary model or API key is set up yet")
    }

    @Test func busyJobsAreNamedAsTheReason() {
        #expect(reason(.transcribe, in: context(job: .transcribing)) == "The selected job is still running")
        #expect(reason(.retryTranscribe, in: context(job: .queued)) == "The selected job is waiting in the queue")
        #expect(reason(.transcribe, in: PaletteContext()) == "Select a job first")
        #expect(reason(.transcribe, in: context(job: .idle)) == "Not available right now")
        let busyTranslate = context(job: .translating) { $0.hasTranscript = true }
        #expect(reason(.translate, in: busyTranslate) == "The selected job is still running")
        let burning = context(job: .transcriptionComplete) {
            $0.hasTranscript = true
            $0.isProcessing = true
        }
        #expect(reason(.burnIn, in: burning) == "Wait for running jobs to finish")
    }

    @Test func reasonsAreShortSentencesThatNeverContradictTheSelection() {
        let statuses: [JobStatus?] = [nil] + JobStatus.allCases.map { Optional($0) }
        for status in statuses {
            for hasTranscript in [false, true] where status != nil || !hasTranscript {
                for ready in [false, true] {
                    var context = PaletteContext()
                    if let status {
                        context.selectedJobTitle = "Interview"
                        context.selectedJobStatus = status
                    }
                    context.hasTranscript = hasTranscript
                    context.isTranslationReady = ready
                    context.isSummaryReady = ready
                    for id in PaletteCommandID.allCases {
                        guard let reason = PaletteCatalog.availability(of: id, in: context).reason else { continue }
                        let label = "\(id) / \(String(describing: status)) / transcript \(hasTranscript)"
                        #expect(!reason.isEmpty, "\(label)")
                        #expect(!reason.hasSuffix("."), "\(label): \(reason)")
                        #expect(!reason.contains("!"), "\(label): \(reason)")
                        if status != nil {
                            #expect(reason != "Select a job first", "\(label)")
                        }
                    }
                }
            }
        }
    }
}
