import AppKit
import Foundation

/// Reaches the one thing the model cannot: Sparkle lives in `CueApp`, so the
/// app registers its updater here at launch. Nothing registered (tests, a
/// build without Sparkle) means the palette never offers "Check for Updates…".
@MainActor
enum PaletteHooks {
    static var checkForUpdates: (@MainActor () -> Void)?
}

/// Side effects a palette command needs from outside the model, injectable so
/// tests can run every command without touching Finder, the user's defaults,
/// or an updater.
struct PaletteEffects {
    var defaults: UserDefaults
    var reveal: (URL) -> Void
    var checkForUpdates: (@MainActor () -> Void)?

    @MainActor
    static var live: PaletteEffects {
        PaletteEffects(
            defaults: .standard,
            reveal: PaletteEffects.revealInFinder,
            checkForUpdates: PaletteHooks.checkForUpdates
        )
    }

    /// The sidebar's rule for "Open Destination Folder": select the file when
    /// it exists, else open its folder, else beep.
    static func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        } else {
            NSSound.beep()
        }
    }
}

/// What the view layer still owes after the model ran a row.
enum PaletteOutcome: Equatable {
    case done
    /// The pane is stored; the view must call `openSettings()` (an
    /// environment action the model cannot reach).
    case openSettings
    /// The row's enable condition failed at run time (the app changed between
    /// drawing the row and choosing it).
    case unavailable(String)
}

@MainActor
extension AppModel {
    // MARK: - Presentation

    /// ⌘K is inert while a sheet owns the window: the palette would open
    /// underneath it, unreachable.
    var canToggleCommandPalette: Bool {
        isShowingCommandPalette || !isPresentingSheetForPalette
    }

    private var isPresentingSheetForPalette: Bool {
        isPresentingSheet
    }

    /// Any sheet the main window can show. ContentView closes the palette
    /// when one appears, and ⌘K stays inert while one is up.
    var isPresentingSheet: Bool {
        isShowingExportSheet || isShowingSetupGuide || isShowingBurnInSheet
            || subtitleLoadRequest != nil || ytDlpInstallRequest != nil || overridesEditorJobID != nil
    }

    func toggleCommandPalette() {
        if isShowingCommandPalette {
            isShowingCommandPalette = false
        } else if canToggleCommandPalette {
            isShowingCommandPalette = true
        }
    }

    // MARK: - Snapshot

    /// The capability flags the menus read, copied verbatim, so a palette row
    /// and its menu item can never disagree.
    func makePaletteContext(canCheckForUpdates: Bool? = nil) -> PaletteContext {
        var context = PaletteContext()
        if let job = currentJob {
            context.selectedJobTitle = job.title
            context.selectedJobStatus = job.status
        }
        context.hasTranscript = !transcriptSegments.isEmpty
        context.hasTranslation = !translatedSegments.isEmpty
        context.isProcessing = isProcessing
        context.isGeneratingSummary = isGeneratingSummary
        context.isLoadingSubtitles = isReadingSubtitleFile || isApplyingSubtitleLoad
        context.isRunningDiagnostics = isRunningDiagnostics
        context.isTranslationReady = settings.isTranslationReady
        context.isSummaryReady = settings.isSummaryReady
        context.hasPendingWork = hasPendingWork
        context.queuePaused = queuePaused
        context.isPlayerVisible = isPlayerVisible
        context.canCheckForUpdates = canCheckForUpdates ?? (PaletteHooks.checkForUpdates != nil)
        context.canPerformPrimaryAction = canPerformPrimaryAction
        context.canLoadSubtitles = canLoadSubtitles
        context.canTranscribe = canTranscribe
        context.canTranslate = canTranslate
        context.canGenerateSummary = canGenerateSummary
        context.canCancel = canCancel
        context.canBurnIn = canBurnIn
        context.primaryActionTitle = primaryActionTitle
        context.primaryActionSymbol = primaryActionSystemImage
        context.translationExportTitle = translationExportTitle
        context.bilingualExportTitle = bilingualExportTitle
        return context
    }

    func makePaletteSnapshot(canCheckForUpdates: Bool? = nil) -> PaletteSnapshot {
        var snapshot = PaletteSnapshot()
        snapshot.context = makePaletteContext(canCheckForUpdates: canCheckForUpdates)
        snapshot.selectedJobID = selectedJobID
        snapshot.jobs = jobs.map { job in
            PaletteJobSummary(
                id: job.id,
                title: job.title,
                fileName: job.sourceURL.lastPathComponent,
                path: job.sourcePath,
                status: job.status,
                isArchived: job.archivedAt != nil,
                updatedAt: job.updatedAt,
                folderName: job.folderID.flatMap { folder(withID: $0)?.name }
            )
        }
        // Same visibility rule as the sidebar: folders with live jobs, plus
        // the ones the user made, which stay visible while empty.
        var liveCounts: [UUID: Int] = [:]
        for job in jobs where job.archivedAt == nil {
            if let folderID = job.folderID { liveCounts[folderID, default: 0] += 1 }
        }
        snapshot.folders = folders.compactMap { folder in
            let count = liveCounts[folder.id] ?? 0
            guard count > 0 || folder.isManual else { return nil }
            return PaletteFolderSummary(id: folder.id, name: folder.name, jobCount: count)
        }
        snapshot.watchFolders = settings.watchFolders.map { folder in
            PaletteWatchFolderSummary(id: folder.id, name: folder.name, path: folder.path, isEnabled: folder.enabled)
        }
        snapshot.failedDownloads = downloads.compactMap { download in
            download.failureMessage.map { PaletteDownloadSummary(id: download.id, title: download.title, message: $0) }
        }
        return snapshot
    }

    // MARK: - Running rows

    /// The single place a job row lands: select it, open its folder, and ask
    /// the sidebar to clear whatever filter or search hides it.
    func revealJobFromPalette(_ id: UUID) {
        guard job(withID: id) != nil else { return }
        revealJob(id)
    }

    /// A folder row opens the folder and reveals its newest live job (or its
    /// newest job, when every one is archived), so the sidebar scrolls there.
    func revealFolderFromPalette(_ id: UUID) {
        guard folder(withID: id) != nil else { return }
        setFolderExpanded(true, for: id)
        let members = jobs.filter { $0.folderID == id }
        let newest =
            members.filter { $0.archivedAt == nil }.max { $0.createdAt < $1.createdAt }
            ?? members.max { $0.createdAt < $1.createdAt }
        if let newest { revealJob(newest.id) }
    }

    /// Runs a row through the same model calls the menus, toolbar, and
    /// sidebar use, after re-checking its enable condition against the live
    /// app: a row drawn a moment ago may no longer be runnable.
    @discardableResult
    func performPaletteTarget(_ target: PaletteTarget, effects: PaletteEffects? = nil) -> PaletteOutcome {
        let effects = effects ?? .live
        if let reason = paletteUnavailabilityReason(for: target, canCheckForUpdates: effects.checkForUpdates != nil) {
            return .unavailable(reason)
        }
        switch target {
        case .job(let id):
            revealJobFromPalette(id)
            return .done
        case .folder(let id):
            revealFolderFromPalette(id)
            return .done
        case .command(let id):
            return performPaletteCommand(id, effects: effects)
        case .setting(let pane):
            effects.defaults.set(pane.rawValue, forKey: SettingsPane.storageKey)
            return .openSettings
        case .watchFolder(let id):
            if let folder = settings.watchFolders.first(where: { $0.id == id }) {
                effects.reveal(URL(fileURLWithPath: folder.path, isDirectory: true))
            }
            return .done
        case .download(let id):
            retryDownload(id)
            return .done
        }
    }

    /// Why `target` cannot run right now, or nil when it can. Side-effect
    /// free, so the view can refuse a row (and keep the palette open to say
    /// why) before it dismisses anything.
    func paletteUnavailabilityReason(for target: PaletteTarget, canCheckForUpdates: Bool? = nil) -> String? {
        switch target {
        case .job(let id):
            return job(withID: id) == nil ? "That job is no longer in the list" : nil
        case .folder(let id):
            return folder(withID: id) == nil ? "That folder was deleted" : nil
        case .command(let id):
            let context = makePaletteContext(canCheckForUpdates: canCheckForUpdates)
            switch PaletteCatalog.availability(of: id, in: context) {
            case .enabled: return nil
            case .disabled(let reason): return reason
            case .hidden: return "Not available in this build"
            }
        case .setting:
            return nil
        case .watchFolder(let id):
            return settings.watchFolders.contains(where: { $0.id == id }) ? nil : "That watch folder was removed"
        case .download(let id):
            return downloads.first(where: { $0.id == id })?.state.isFailed == true
                ? nil : "That download is no longer failed"
        }
    }

    private func performPaletteCommand(_ id: PaletteCommandID, effects: PaletteEffects) -> PaletteOutcome {
        switch id {
        case .primaryAction: performPrimaryAction()
        case .addFiles: selectVideo()
        case .addFromURL: promptForRemoteMedia()
        case .loadSubtitles: presentSubtitleLoadPanel()
        case .startAll: startAllPendingJobs()
        case .transcribe: startTranscription()
        case .translate: startTranslation()
        case .writeSummary: generateSummaryNow()
        case .stopAll: cancelActiveJob()
        case .exportSheet: isShowingExportSheet = true
        case .exportTranscriptSRT: exportTranscript(format: .srt)
        case .exportTranslationSRT: exportTranslation(format: .srt)
        case .exportBilingualSRT: exportBilingual(format: .srt)
        case .exportLog: exportLog()
        case .retryTranscribe: startTranscription(force: true)
        case .toggleVideoPreview: isPlayerVisible.toggle()
        case .jobSettings: overridesEditorJobID = selectedJobID
        case .burnIn: isShowingBurnInSheet = true
        case .revealInFinder:
            if let url = currentJob?.sourceURL { effects.reveal(url) }
        case .runDiagnostics:
            // The result is only visible in the setup guide, so show it.
            runDiagnostics()
            isShowingSetupGuide = true
        case .openSetupGuide: isShowingSetupGuide = true
        case .checkForUpdates: effects.checkForUpdates?()
        case .openSettings: return .openSettings
        }
        return .done
    }
}
