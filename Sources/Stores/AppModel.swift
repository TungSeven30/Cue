import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettingsStore
    @Published var jobs: [TranscriptionJob] = []
    /// True until the persisted job history has been loaded and merged.
    /// The window shows immediately; views render a neutral state instead
    /// of "no jobs yet" while this is set, and the queue and watch folders
    /// wait, so a scan can never re-ingest a file whose job has not loaded.
    @Published private(set) var isHydratingJobs = true
    private var hydrationTask: Task<Void, Never>?
    /// Verified-on-use cache behind `index(of:)`. Never trusted blindly:
    /// a hit is checked against the job at that position, so any reorder,
    /// insert, or delete is caught and the map is rebuilt once.
    private var jobIndexCache: [UUID: Int] = [:]
    /// Every highlighted sidebar job. The detail pane continues to use
    /// `selectedJobID` as the primary member of this selection.
    @Published private(set) var selectedJobIDs: Set<UUID> = []
    @Published private(set) var selectedJobID: UUID? {
        didSet {
            guard selectedJobID != oldValue else { return }
            playerController.pause()
            if selectedJobID == nil { playerController.clear() }
        }
    }
    @Published var diagnostics: [EnvironmentDiagnostic] = []
    @Published var isRunningDiagnostics = false
    @Published var persistenceError: String?
    @Published var isShowingExportSheet = false
    @Published var isShowingSetupGuide = false
    @Published var overridesEditorJobID: UUID?
    @Published var isGeneratingSummary = false
    @Published var isShowingBurnInSheet = false
    /// In-flight and just-failed yt-dlp fetches. Kept out of `jobs` because a
    /// job is identified by a file that does not exist until a fetch lands.
    @Published private(set) var downloads: [MediaDownload] = []
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    /// Non-nil while the offer-to-install-yt-dlp sheet is up.
    @Published var ytDlpInstallRequest: YtDlpInstallRequest?
    private var ytDlpInstallTask: Task<Void, Never>?
    /// Set when a subtitle file has been parsed and needs a slot chosen.
    @Published var subtitleLoadRequest: SubtitleLoadRequest?
    @Published private(set) var isReadingSubtitleFile = false
    @Published private(set) var isApplyingSubtitleLoad = false
    private let subtitleFileWriter = SubtitleFileWriter()
    private var subtitleWriteRequests: [SubtitleFileWriter.Key: SubtitleFileWriter.Request] = [:]
    /// nil = not yet checked; cached until Recheck (spec §3.1).
    @Published var burnInPreflight: BurnInService.PreflightResult?
    /// The setup guide auto-opens once per launch (when something required is
    /// missing); after that it is only reachable from the diagnostics popover.
    private var didOfferSetupGuide = false
    @Published var isPlayerVisible: Bool {
        didSet {
            UserDefaults.standard.set(isPlayerVisible, forKey: "isPlayerVisible")
            if !isPlayerVisible {
                playerController.pause()
            }
        }
    }
    /// Set when the user cancels while jobs are still queued; Start All resumes.
    @Published var queuePaused = false
    /// Guards the 30s volume-reconnect retry so timers never stack.
    private var volumeRetryScheduled = false
    /// Jobs whose folder is still being scanned for subtitle sidecars. They
    /// must not be scheduled: an adopted transcript would arrive after ASR had
    /// already started. In-memory only — a scan interrupted by a quit simply
    /// never adopts, which is safe.
    private var subtitleScanPendingIDs: Set<UUID> = []
    private var subtitleSyncWorkItems: [SubtitleSyncKey: DispatchWorkItem] = [:]
    let playerController = PlayerController()
    private var didProcessQueuedJob = false
    /// Keeps very chatty jobs from growing without bound in memory and on disk.
    private static let maxLogLength = 200_000

    private let transcriptionService = TranscriptionService()
    private let translationService: TranslationService
    private let diagnosticsService: any EnvironmentDiagnosing
    private let jobRepository: JobRepository
    private let burnInService = BurnInService()
    private let exportCoordinator = ExportCoordinator()
    /// Memoised quality warnings for the displayed transcript/translation;
    /// see SubtitleWarningCache for why per-render recomputation was O(n²).
    private let warningCache = SubtitleWarningCache()
    private let watchLedger: WatchFolderLedger
    private lazy var watchCoordinator = WatchFolderCoordinator(
        makeService: { [weak self] id in
            self?.makeWatchService(folderID: id) ?? WatchFolderService()
        },
        onServiceChange: { [weak self] in self?.objectWillChange.send() }
    )
    var watchServices: [UUID: WatchFolderService] { watchCoordinator.services }
    /// The pipeline runs as two independently serial slots: the GPU slot
    /// (transcription and burn-in — the heavyweight local consumers) and the
    /// translation slot (network-bound). They may run at the same time on
    /// different jobs, which is what lets job B transcribe while job A is
    /// still translating.
    private let pipeline = PipelineCoordinator()
    private var gpuTask: Task<Void, Never>? {
        get { pipeline.gpuTask }
        set { pipeline.gpuTask = newValue }
    }
    private(set) var gpuJobID: UUID? {
        get { pipeline.gpuJobID }
        set { pipeline.gpuJobID = newValue }
    }
    private var translationTask: Task<Void, Never>? {
        get { pipeline.translationTask }
        set { pipeline.translationTask = newValue }
    }
    private(set) var translationJobID: UUID? {
        get { pipeline.translationJobID }
        set { pipeline.translationJobID = newValue }
    }
    /// Live progressive-translation sessions, keyed by job. A driver exists
    /// from the moment a translating job starts transcribing until its
    /// translation finishes; all of its work runs in the translation slot.
    private var drivers: [UUID: ProgressiveTranslationDriver] = [:]
    /// The last translation fraction seen while the job was still
    /// transcribing, so the transcription progress line can report both.
    private var streamingTranslationFraction: [UUID: Double] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Only the newest diagnostics snapshot may update the UI. Probe processes
    /// can finish out of order when settings change quickly.
    private var diagnosticsTask: Task<Void, Never>?
    /// Held while any job is running so overnight batches survive idle sleep
    /// and App Nap (spec §2.7). Display sleep stays allowed.
    private var processingActivity: NSObjectProtocol?

    private func updateProcessingActivity() {
        // Downloads keep the assertion alive too: a long fetch is exactly
        // the kind of unattended work idle sleep would otherwise stall,
        // even though it occupies no pipeline slot. A brew install of
        // yt-dlp counts for the same reason.
        let isInstallingYtDlp = ytDlpInstallTask != nil && ytDlpInstallRequest?.phase.isFailed == false
        if isProcessing || isInstallingYtDlp || downloads.contains(where: { !$0.state.isFailed }) {
            guard processingActivity == nil else { return }
            processingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Processing transcription queue"
            )
        } else if let activity = processingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            processingActivity = nil
        }
    }

    init(
        settings: AppSettingsStore? = nil,
        jobStore: JobStore? = nil,
        jobRepository: JobRepository? = nil,
        watchLedger: WatchFolderLedger? = nil,
        diagnosticsService: any EnvironmentDiagnosing = EnvironmentDiagnosticsService(),
        translationService: TranslationService = TranslationService()
    ) {
        self.settings = settings ?? AppSettingsStore()
        self.watchLedger = watchLedger ?? WatchFolderLedger()
        // Tests inject a repository over a recording store; the app builds
        // one over the on-disk JobStore.
        self.jobRepository = jobRepository ?? JobRepository(store: jobStore ?? JobStore())
        self.diagnosticsService = diagnosticsService
        self.translationService = translationService
        isPlayerVisible = UserDefaults.standard.object(forKey: "isPlayerVisible") as? Bool ?? true
        persistenceError = self.watchLedger.startupError
        // `settings` is a nested ObservableObject; changes to its fields do not
        // fire AppModel's objectWillChange on their own, so forward them.
        self.settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Debounced edits and queued background writes must reach the disk
        // before the process exits, or the last ~400ms of changes are lost.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.prepareForTermination() }
            .store(in: &cancellables)
        Publishers.Merge(
            NotificationCenter.default.publisher(for: JobStore.persistenceDidFail),
            NotificationCenter.default.publisher(for: WatchFolderLedger.persistenceDidFail)
        )
        .receive(on: DispatchQueue.main)
        .compactMap { $0.object as? String }
        .sink { [weak self] message in self?.persistenceError = message }
        .store(in: &cancellables)
        // Diagnostics classify probes as required/optional based on the
        // selected backend, so a backend switch must re-run them or the
        // pill keeps a stale verdict. dropFirst skips the value replayed
        // on subscription (the runDiagnostics() below covers launch); the
        // sink fires during willSet, but runDiagnostics reads the setting
        // inside a Task, which runs after the assignment lands.
        self.settings.$whisperBackend
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.runDiagnostics() }
            .store(in: &cancellables)
        // The translation-key row depends on the selected model (provider),
        // the local server URL, and the API keys, so edits to any of them
        // must also re-run diagnostics. Unlike the backend picker, these
        // fields change on every keystroke and runDiagnostics shells out to
        // probe processes, so the debounce is load-bearing: it collapses a
        // typing burst into one re-run after the user pauses.
        Publishers.MergeMany(
            self.settings.$openAIModel.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$localTranslationEndpoint.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$openAIAPIKey.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$anthropicAPIKey.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$googleAPIKey.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$openRouterAPIKey.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$groqAPIKey.dropFirst().removeDuplicates().map { _ in () },
            self.settings.$cerebrasAPIKey.dropFirst().removeDuplicates().map { _ in () }
        )
        .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.runDiagnostics() }
        .store(in: &cancellables)
        runDiagnostics()
        Self.current = self
        // Decoding a large history takes long enough to notice; do it off
        // the main actor and merge once it lands (see finishHydration).
        let repository = self.jobRepository
        hydrationTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                repository.loadJobsSnapshot()
            }.value
            self?.finishHydration(with: snapshot)
        }
        // Files opened through the Dock icon or Finder's Open With can arrive
        // before this model exists; the delegate parks them until now.
        OpenFileRequests.register { [weak self] urls in
            self?.addMedia(urls: urls)
        }
    }

    /// The live model, for the app delegate's quit confirmation. Weak so a
    /// test fixture's model never outlives its test.
    private(set) weak static var current: AppModel?

    /// Anything a quit would interrupt: pipeline work, a fetch, or an install.
    var hasActiveWork: Bool {
        isProcessing
            || downloads.contains { !$0.state.isFailed }
            || (ytDlpInstallTask != nil && ytDlpInstallRequest?.phase.isFailed == false)
    }

    /// Writes every pending job mutation to disk synchronously. Called on
    /// app termination.
    func flushPendingWork() {
        flushSubtitleSync()
        jobRepository.flush()
        watchLedger.flush()
    }

    /// Stops every child process this instance owns, then flushes. Without
    /// this, yt-dlp, ffmpeg, and the Python helper outlive the app as
    /// orphans; the interrupted jobs are stamped canceled on the next launch.
    private func prepareForTermination() {
        _ = pipeline.cancelAll()
        for task in downloadTasks.values {
            task.cancel()
        }
        ytDlpInstallTask?.cancel()
        // The resident Python helper is a child process; SIGTERM it now so it
        // does not outlive the app. Its serve loop also exits on stdin EOF,
        // and the orphan reaper covers anything that still survives.
        PythonWorkerPool.shared.terminateImmediately()
        flushPendingWork()
    }

    /// Asks for notification permission while the user is looking at the app
    /// (starting a job), not the first time a job finishes in the background
    /// — by then the prompt appears behind another app and is usually missed.
    private func requestNotificationAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Resolves when the persisted history has been merged into `jobs`.
    func hydration() async {
        await hydrationTask?.value
    }

    /// The job store's own startup failure, if any. `persistenceError` can
    /// be overwritten by later failure notifications; this stays put.
    var jobStoreStartupError: String? {
        jobRepository.startupError
    }

    /// Merges the loaded history under whatever was added interactively
    /// while it loaded: early adds keep their order and stay on top (their
    /// indices are re-stamped against the loaded ones), duplicates by id are
    /// impossible because early jobs have fresh ids, and only then do the
    /// queue and watch folders start.
    private func finishHydration(with snapshot: JobLoadSnapshot) {
        jobRepository.recordStartupFailures(snapshot.failures)
        let loaded = JobLoadOrdering.stableSortedByOrderIndex(snapshot.jobs)
        let earlyIDs = Set(jobs.map(\.id))
        let persisted = loaded.filter { !earlyIDs.contains($0.id) }
        var early = jobs
        if !early.isEmpty {
            let indices = QueueOrdering.indicesForBatchAdd(count: early.count, existing: persisted.map(\.orderIndex))
            for (offset, orderIndex) in indices.enumerated() {
                early[offset].orderIndex = orderIndex
            }
        }
        jobs = early + persisted
        jobIndexCache.removeAll()
        if !early.isEmpty {
            jobRepository.save(early)
        }
        // Same precedence as the synchronous load had: a job-history startup
        // failure outranks anything that arrived earlier.
        if let startupError = jobRepository.startupError {
            persistenceError = startupError
        }
        autoArchiveOldJobs()
        if selectedJobID == nil {
            selectJob(jobs.first(where: { $0.archivedAt == nil })?.id ?? jobs.first?.id)
        }
        isHydratingJobs = false
        syncWatchFolders()
        processQueue()
    }

    /// Position of the job with `id`, O(1) on the hot path. The cached index
    /// is validated against the array before use and the map is rebuilt when
    /// it is stale, so structural edits to `jobs` need no bookkeeping.
    func index(of id: UUID) -> Int? {
        if let cached = jobIndexCache[id], cached < jobs.count, jobs[cached].id == id {
            return cached
        }
        jobIndexCache = Dictionary(jobs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return jobIndexCache[id]
    }

    func job(withID id: UUID) -> TranscriptionJob? {
        index(of: id).map { jobs[$0] }
    }

    var currentJob: TranscriptionJob? {
        guard let index = currentJobIndex else {
            return nil
        }
        return jobs[index]
    }

    var selectedVideoURL: URL? {
        currentJob?.sourceURL
    }

    var transcriptSegments: [TranscriptionSegment] {
        currentJob?.transcriptSegments ?? []
    }

    var translatedSegments: [TranscriptionSegment] {
        currentJob?.translatedSegments ?? []
    }

    /// What the transcript tab and player should render: the final transcript
    /// when it exists, else the live streamed partials. Gating logic
    /// (canTranslate, skip checks, export) must keep using the real fields.
    var displayTranscriptSegments: [TranscriptionSegment] {
        guard let job = currentJob else { return [] }
        return job.transcriptSegments.isEmpty ? job.partialTranscriptSegments : job.transcriptSegments
    }

    var displayTranslatedSegments: [TranscriptionSegment] {
        guard let job = currentJob else { return [] }
        return job.translatedSegments.isEmpty ? job.partialTranslatedSegments : job.translatedSegments
    }

    var partialTranslatedSegments: [TranscriptionSegment] {
        currentJob?.partialTranslatedSegments ?? []
    }

    var log: String {
        currentJob?.log ?? "Choose a video to begin.\n"
    }

    var status: String {
        currentJob?.status.label ?? "Idle"
    }

    var progress: JobProgress {
        currentJob?.progress ?? .idle
    }

    var isRunningTranscription: Bool {
        currentJob?.status == .transcribing
    }

    var isRunningTranslation: Bool {
        currentJob?.status == .translating
    }

    /// Any pipeline work is in flight (either slot).
    var isProcessing: Bool {
        gpuJobID != nil || translationJobID != nil
    }

    /// True while the job occupies a pipeline slot; such a job cannot be
    /// deleted, only canceled.
    func isJobActive(_ id: UUID) -> Bool {
        id == gpuJobID || id == translationJobID
    }

    func isScanningForSubtitles(_ id: UUID) -> Bool {
        subtitleScanPendingIDs.contains(id)
    }

    /// The job the user is looking at is the one running.
    var isSelectedJobRunning: Bool {
        currentJob?.status.isRunning == true
    }

    var canTranscribe: Bool {
        currentJob != nil && !isSelectedJobRunning && currentJob?.status != .queued
    }

    var canTranslate: Bool {
        !transcriptSegments.isEmpty && !isSelectedJobRunning && currentJob?.status != .queued
            && settings.isTranslationReady
    }

    var canCancel: Bool {
        isProcessing
    }

    /// The manual summary action works on any finished job with a transcript,
    /// independent of the auto-summary toggle.
    var canGenerateSummary: Bool {
        guard let job = currentJob else { return false }
        return !job.transcriptSegments.isEmpty
            && !job.status.isRunning
            && !isGeneratingSummary
            && settings.isSummaryReady
    }

    func checkBurnInAvailability() {
        Task {
            burnInPreflight = await BurnInService.preflight()
        }
    }

    var canBurnIn: Bool {
        guard let job = currentJob else { return false }
        return !job.transcriptSegments.isEmpty && !isProcessing && !job.status.isRunning
    }

    var hasPendingWork: Bool {
        jobs.contains { jobNeedsWork($0) } || !subtitleScanPendingIDs.isEmpty
    }

    /// The sidebar's single-job Start action is intentionally stricter than
    /// queueing: it needs one exact, runnable selection and an idle pipeline.
    /// This prevents a multi-selection or an already-running batch from
    /// turning a precise action into more work than the user requested.
    var canStartSelectedJob: Bool {
        guard selectedJobIDs.count == 1,
            let id = selectedJobIDs.first,
            let job = self.job(withID: id),
            !isProcessing,
            job.archivedAt == nil,
            !job.status.isRunning
        else { return false }

        if job.transcriptSegments.isEmpty { return true }
        return job.translatedSegments.isEmpty && settings.isTranslationReady
    }

    var queuedJobCount: Int {
        jobs.filter { $0.status == .queued }.count
    }

    var translationTargetLabel: String {
        // For a not-yet-translated job, honor its override so the action
        // button names the language the run will actually produce.
        let target =
            translatedSegments.isEmpty
            ? (currentJob?.overrides.translationTargetLanguage ?? settings.translationTargetLanguage)
            : currentJob?.settings.translationTargetLanguage ?? settings.translationTargetLanguage
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Translation" : trimmed
    }

    var translationExportTitle: String {
        "\(translationTargetLabel) Translation"
    }

    var bilingualExportTitle: String {
        "Bilingual Captions (\(translationTargetLabel))"
    }

    var primaryActionTitle: String {
        if currentJob == nil { return "Open Video" }
        if transcriptSegments.isEmpty { return "Transcribe" }
        if translatedSegments.isEmpty { return "Translate to \(translationTargetLabel)" }
        return "Export…"
    }

    /// Tooltip for the primary action: explains what pressing it does,
    /// since the title alone ("Export…") doesn't say what gets exported.
    var primaryActionHelp: String {
        if currentJob == nil { return "Choose video or audio files to add as jobs" }
        if transcriptSegments.isEmpty { return "Transcribe the selected video's audio into subtitles" }
        if translatedSegments.isEmpty { return "Translate the transcript to \(translationTargetLabel)" }
        return "Export subtitles, captions, or a burned-in video for this job"
    }

    var primaryActionSystemImage: String {
        if currentJob == nil { return "folder" }
        if transcriptSegments.isEmpty { return "waveform" }
        if translatedSegments.isEmpty { return "character.bubble" }
        return "square.and.arrow.up"
    }

    var canPerformPrimaryAction: Bool {
        if currentJob == nil { return true }
        if transcriptSegments.isEmpty { return canTranscribe }
        if translatedSegments.isEmpty { return canTranslate }
        return !isSelectedJobRunning
    }

    var diagnosticsSummary: String {
        guard !diagnostics.isEmpty else {
            return "Not checked"
        }
        // Only hard failures count against the summary: missing optional
        // tools are warnings in the popover list, not toolbar alarms.
        let failures = diagnostics.filter { $0.state == .failed }.count
        if failures > 0 {
            return "\(failures) missing"
        }
        return "Ready"
    }

    private var currentJobIndex: Int? {
        guard let selectedJobID else {
            return nil
        }
        return index(of: selectedJobID)
    }

    func selectJob(_ id: UUID?) {
        enqueuePendingSubtitleSync()
        selectedJobID = id
        selectedJobIDs = id.map { [$0] } ?? []
    }

    /// Updates the native macOS multi-selection while keeping a deterministic
    /// primary job in the detail pane. Newly selected rows take precedence;
    /// removing a primary row falls back to the first selected job in queue
    /// order rather than leaving stale detail visible.
    func selectJobs(_ ids: Set<UUID>) {
        // Walk the jobs once rather than materializing every job id and then
        // intersecting. This stays linear when Command-A selects a large
        // history and also discards ids that no longer exist.
        var validIDs = Set<UUID>()
        validIDs.reserveCapacity(min(ids.count, jobs.count))
        for job in jobs where ids.contains(job.id) {
            validIDs.insert(job.id)
        }
        let newlySelected = validIDs.subtracting(selectedJobIDs)
        selectedJobIDs = validIDs

        if let newPrimary = jobs.first(where: { newlySelected.contains($0.id) })?.id {
            selectedJobID = newPrimary
        } else if let selectedJobID, validIDs.contains(selectedJobID) {
            // Preserve the current detail when Command-click changes another
            // row in the selection.
        } else {
            selectedJobID = jobs.first(where: { validIDs.contains($0.id) })?.id
        }
    }

    func selectVideo() {
        let panel = NSOpenPanel()
        // Drag-and-drop accepts any file, so the picker should too for
        // containers macOS has no built-in type for (notably MKV).
        var types: [UTType] = [.movie, .mpeg4Movie, .audio, .audiovisualContent]
        if let mkv = UTType(filenameExtension: "mkv") {
            types.append(mkv)
        }
        panel.allowedContentTypes = types
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose video or audio files, or folders to add everything inside them (including subfolders)."
        if panel.runModal() == .OK {
            let added = addMedia(urls: panel.urls)
            if added == 0,
                panel.urls.contains(where: { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                })
            {
                let alert = NSAlert()
                alert.messageText = "No Video or Audio Files Found"
                alert.informativeText = "The chosen folder does not contain any video or audio files."
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }

    func performPrimaryAction() {
        if currentJob == nil {
            selectVideo()
        } else if transcriptSegments.isEmpty {
            startTranscription()
        } else if translatedSegments.isEmpty {
            startTranslation()
        } else {
            isShowingExportSheet = true
        }
    }

    /// Adds a video as a new job. Used by the file picker and drag-and-drop.
    func addVideo(url: URL) {
        addVideos(urls: [url])
    }

    /// Adds a mixed list of files and folders: folders contribute every
    /// media file inside them, at any depth, in one batch. Returns how many
    /// jobs were added so interactive callers can tell an empty folder from
    /// a successful add.
    @discardableResult
    func addMedia(urls: [URL]) -> Int {
        let expanded = MediaFileTypes.expandForAdd(urls: urls)
        addVideos(urls: expanded)
        return expanded.count
    }

    /// Adds videos as separate jobs. Used by the file picker, drag-and-drop,
    /// and — with `origin: .url` — by a finished yt-dlp download, which is a
    /// manual add in every respect except where the file came from.
    func addVideos(urls: [URL], origin: JobOrigin = .manual, sourceNote: String? = nil) {
        let batchIndices = QueueOrdering.indicesForBatchAdd(count: urls.count, existing: jobs.map(\.orderIndex))
        let shouldStart = settings.autoStartAddedJobs
        let newJobs = zip(urls, batchIndices).map { url, orderIndex in
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.origin = origin
            job.log =
                sourceNote.map { "\($0)\nSaved to \(url.path(percentEncoded: false)).\n" }
                ?? "Selected \(url.path(percentEncoded: false)).\n"
            job.orderIndex = orderIndex
            if shouldStart {
                job.status = .queued
                job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            }
            return job
        }
        guard !newJobs.isEmpty else { return }
        if shouldStart {
            // Interactive additions intentionally resume a paused queue.
            queuePaused = false
        }
        jobs.insert(contentsOf: newJobs, at: 0)
        selectJob(newJobs.first?.id)
        jobRepository.save(newJobs)
        // Adoption gates scheduling via subtitleScanPendingIDs, so processQueue
        // is safe to call now: pending jobs are filtered out of jobViews and
        // picked up when the scan lands.
        adoptSidecars(for: newJobs.map(\.id))
        if shouldStart {
            processQueue()
        }
    }

    func setOverrides(_ overrides: JobSettingsOverrides, for id: UUID) {
        guard let job = self.job(withID: id), !job.status.isRunning else { return }
        updateJob(id) { job in
            job.overrides = overrides
            job.log +=
                overrides.isEmpty
                ? "Cleared job-specific settings.\n"
                : "Set job-specific settings.\n"
        }
    }

    // MARK: - Selected job card settings

    /// Global defaults layered with the job's override bag — what the header
    /// card displays and what the next run will resolve to.
    func resolvedSettings(for job: TranscriptionJob) -> JobSettingsSnapshot {
        JobSettingsSnapshot(settings: settings).applying(job.overrides)
    }

    var selectedJobResolvedSettings: JobSettingsSnapshot? {
        currentJob.map { resolvedSettings(for: $0) }
    }

    /// Writes an explicit override on the selected job so later default
    /// changes do not rewrite this film.
    func updateSelectedJobOverrides(_ mutate: (inout JobSettingsOverrides) -> Void) {
        guard let id = selectedJobID,
            let job = currentJob,
            !job.status.isRunning
        else { return }
        var overrides = job.overrides
        mutate(&overrides)
        setOverrides(overrides, for: id)
    }

    func jobCardBinding<T>(
        get: @escaping (JobSettingsSnapshot) -> T,
        setOverride: @escaping (inout JobSettingsOverrides, T, JobSettingsSnapshot) -> Void
    ) -> Binding<T> {
        Binding(
            get: { [unowned self] in
                guard let resolved = self.selectedJobResolvedSettings else {
                    return get(JobSettingsSnapshot(settings: self.settings))
                }
                return get(resolved)
            },
            set: { [unowned self] newValue in
                let baseline =
                    self.selectedJobResolvedSettings
                    ?? JobSettingsSnapshot(settings: self.settings)
                self.updateSelectedJobOverrides { setOverride(&$0, newValue, baseline) }
            }
        )
    }

    var selectedJobTranscriptionValidationMessage: String? {
        guard let resolved = selectedJobResolvedSettings else { return nil }
        return AppSettingsStore.transcriptionValidationMessage(
            backend: resolved.whisperBackend,
            model: resolved.whisperModel
        )
    }

    func repairSelectedJobTranscriptionModel() {
        guard let resolved = selectedJobResolvedSettings else { return }
        let repaired = AppSettingsStore.normalizedWhisperModel(
            for: resolved.whisperBackend,
            current: resolved.whisperModel,
            force: true
        )
        updateSelectedJobOverrides {
            $0.transcriptionPreset = .custom
            $0.whisperBackend = resolved.whisperBackend
            $0.whisperModel = repaired
        }
    }

    var jobCardAutoTranslate: Binding<Bool> {
        Binding(
            get: { [unowned self] in
                self.currentJob?.overrides.autoTranslate ?? self.settings.autoTranslateAfterTranscription
            },
            set: { [unowned self] newValue in
                self.updateSelectedJobOverrides { $0.autoTranslate = newValue }
            }
        )
    }

    var jobCardGenerateSummary: Binding<Bool> {
        Binding(
            get: { [unowned self] in
                self.currentJob?.overrides.generateSummary ?? self.settings.generateSummary
            },
            set: { [unowned self] newValue in
                self.updateSelectedJobOverrides { $0.generateSummary = newValue }
            }
        )
    }

    var jobCardShowsIntroSummaryDetail: Bool {
        currentJob?.overrides.generateSummary ?? settings.generateSummary
    }

    var jobCardSummaryDetail: Binding<SummaryDetail> {
        Binding(
            get: { [unowned self] in
                self.currentJob?.overrides.summaryDetail ?? self.settings.summaryDetail
            },
            set: { [unowned self] newValue in
                self.updateSelectedJobOverrides { $0.summaryDetail = newValue }
            }
        )
    }

    func deleteJob(_ id: UUID) {
        deleteJobs([id])
    }

    func canDeleteJobs(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return false }
        let queuedTranslationIDs = pipeline.queuedTranslationJobIDs
        var remaining = ids
        for job in jobs where remaining.remove(job.id) != nil {
            if isJobActive(job.id) || queuedTranslationIDs.contains(job.id) {
                return false
            }
            if remaining.isEmpty {
                return true
            }
        }
        // At least one requested id was stale or never belonged to this model.
        return false
    }

    /// Deletes a sidebar selection as one UI operation. Source media and
    /// exported files are deliberately untouched; only Cue's job records are
    /// removed. If any selected job is active, nothing is partially deleted.
    func deleteJobs(_ ids: Set<UUID>) {
        // The running job cannot be deleted; cancel it first. A streaming job
        // between the GPU handoff and its finish pass owns neither slot but
        // still has work queued, so check the translation queue too.
        guard canDeleteJobs(ids) else { return }

        jobs.removeAll { ids.contains($0.id) }
        selectedJobIDs.subtract(ids)
        if let selectedJobID, index(of: selectedJobID) != nil {
            selectedJobIDs.insert(selectedJobID)
        } else if let nextSelectedID = jobs.first(where: { selectedJobIDs.contains($0.id) })?.id {
            selectedJobID = nextSelectedID
        } else {
            selectJob(jobs.first?.id)
        }
        for id in ids {
            jobRepository.delete(id)
            warningCache.invalidate(jobID: id)
        }
    }

    func runDiagnostics() {
        diagnosticsTask?.cancel()
        let apiKey = settings.currentTranslationAPIKey
        let provider = settings.currentTranslationProvider
        let backend = settings.whisperBackend
        isRunningDiagnostics = true
        diagnosticsTask = Task { [weak self] in
            guard let self else { return }
            let results = await diagnosticsService.run(
                translationAPIKey: apiKey,
                translationProvider: provider,
                selectedBackend: backend
            )
            guard !Task.isCancelled else { return }
            diagnostics = results
            isRunningDiagnostics = false
            diagnosticsTask = nil
            if !didOfferSetupGuide {
                didOfferSetupGuide = true
                // Only a required diagnostic reports .failed (the selected
                // Python backend's missing module); missing optional tools
                // are warnings, so a fresh install never auto-opens this.
                if results.contains(where: { $0.state == .failed }) {
                    isShowingSetupGuide = true
                }
            }
        }
    }

    // MARK: - Queue

    /// Queues every job that still needs work and starts processing.
    func startAllPendingJobs() {
        queuePaused = false
        // Mutating @Published `jobs` through updateJob once per item emits a
        // full model change each time. It also searches the array for every
        // id, turning Start All into O(n²). Build the new array in one indexed
        // pass, publish it once, and persist the resulting snapshots together.
        var updatedJobs = jobs
        var queuedSnapshots: [TranscriptionJob] = []
        let now = Date()
        // jobNeedsWork is false for a job mid-sidecar-scan, but the click must
        // not be lost: jobViews keeps it out of both pumps until the scan
        // lands, and applyAdoptions preserves .queued through wasQueued, so
        // queuing it now is safe and it transcribes once the scan settles.
        for index in updatedJobs.indices
        where (jobNeedsWork(updatedJobs[index]) || subtitleScanPendingIDs.contains(updatedJobs[index].id))
            && updatedJobs[index].status != .queued
        {
            updatedJobs[index].status = .queued
            updatedJobs[index].progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            updatedJobs[index].updatedAt = now
            queuedSnapshots.append(updatedJobs[index])
        }
        if !queuedSnapshots.isEmpty {
            jobs = updatedJobs
            jobRepository.save(queuedSnapshots)
        }
        processQueue()
    }

    /// Starts exactly the selected job. Other queued jobs remain queued and
    /// the queue is paused before this job starts, so its completion cannot
    /// automatically advance into the rest of the batch. Start All resumes
    /// normal queue processing later.
    func startSelectedJob() {
        guard canStartSelectedJob,
            let id = selectedJobIDs.first,
            let job = self.job(withID: id)
        else { return }

        if jobs.contains(where: { $0.id != id && $0.status == .queued }) {
            queuePaused = true
        }

        if job.transcriptSegments.isEmpty {
            startTranscription(jobID: id)
        } else {
            startTranslation(jobID: id)
        }
    }

    /// Queues the useful subset of a sidebar selection as one UI and
    /// persistence update. Finished jobs that need no further work, already
    /// queued jobs, active jobs, and archived jobs are left untouched.
    func enqueueJobs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        queuePaused = false
        // See the comment in startAllPendingJobs: a job mid-sidecar-scan must
        // still be queueable, or the click is lost once the scan lands.
        let shouldQueue = { (job: TranscriptionJob) in
            (self.jobNeedsWork(job) || self.subtitleScanPendingIDs.contains(job.id)) && job.status != .queued
        }
        updateJobs(ids, where: shouldQueue) { job in
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }
        processQueue()
    }

    /// Retries only failed jobs that still have pipeline work to do. A failed
    /// burn-in with otherwise complete subtitles is deliberately excluded —
    /// retrying the transcription queue would be the wrong operation.
    func retryFailedJobs(_ ids: Set<UUID>) {
        let retryableIDs = Set(
            jobs.lazy
                .filter { ids.contains($0.id) && $0.status == .failed && self.jobNeedsWork($0) }
                .map(\.id)
        )
        enqueueJobs(retryableIDs)
    }

    func retrySelectedFailedStage() {
        guard let job = currentJob, !isSelectedJobRunning, job.progress.stage == .failed else { return }
        let failedStage = job.progress.failedStage
        if failedStage == .burningIn || job.progress.detail.hasPrefix("Burn-in failed:") {
            // Output URLs are not persisted. Reopen the existing native
            // options sheet instead of guessing a destination to overwrite.
            isShowingBurnInSheet = true
        } else if failedStage == .translating || job.progress.detail.hasPrefix("Translation failed:") {
            startTranslation(jobID: job.id)
        } else if job.transcriptSegments.isEmpty || job.progress.detail.hasPrefix("Transcription failed:")
            || [.preflight, .extractingAudio, .loadingModel, .transcribing].contains(failedStage)
        {
            startTranscription(jobID: job.id, force: !job.transcriptSegments.isEmpty)
        } else {
            // Legacy failures have no typed stage. Keep a finished transcript
            // intact and resume the remaining translation work.
            startTranslation(jobID: job.id)
        }
    }

    /// Adds one job to the queue (or starts it right away when nothing is
    /// running). Every caller is a user asking for more work, so an explicit
    /// stop is lifted.
    func enqueueJob(_ id: UUID) {
        guard let job = self.job(withID: id), !job.status.isRunning else { return }
        queuePaused = false
        updateJob(id) { job in
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }
        processQueue()
    }

    /// Archives terminal jobs older than the configured window. Runs once at
    /// launch so the sidebar and queue only carry recent, relevant jobs.
    private func autoArchiveOldJobs() {
        let days = settings.autoArchiveDays
        guard days > 0 else { return }
        let now = Date()
        for index in jobs.indices where jobs[index].archivedAt == nil {
            let job = jobs[index]
            if TranscriptionJob.shouldAutoArchive(
                status: job.status,
                finishedAt: job.finishedAt,
                updatedAt: job.updatedAt,
                olderThanDays: days,
                now: now
            ) {
                jobs[index].archivedAt = now
                jobRepository.save(jobs[index])
            }
        }
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        setArchived([id], archived)
    }

    /// Archives or restores every eligible member of a sidebar selection.
    /// Running and queued jobs keep their current state instead of being
    /// silently pulled out from under the pipeline.
    func setArchived(_ ids: Set<UUID>, _ archived: Bool) {
        let changedIDs = updateJobs(
            ids,
            where: { job in
                !job.status.isRunning && job.status != .queued
                    && (archived ? job.archivedAt == nil : job.archivedAt != nil)
            }
        ) { job in
            job.archivedAt = archived ? Date() : nil
        }
        guard !changedIDs.isEmpty else { return }

        selectedJobIDs.subtract(changedIDs)
        if let selectedJobID, changedIDs.contains(selectedJobID) {
            if let nextSelectedID = jobs.first(where: { selectedJobIDs.contains($0.id) })?.id {
                self.selectedJobID = nextSelectedID
            } else {
                selectJob(jobs.first(where: { archived ? $0.archivedAt == nil : $0.archivedAt != nil })?.id)
            }
        }
    }

    func jobNeedsWork(_ job: TranscriptionJob) -> Bool {
        if job.archivedAt != nil { return false }
        if subtitleScanPendingIDs.contains(job.id) { return false }
        if job.status.isRunning { return false }
        if job.status == .queued { return true }
        if job.transcriptSegments.isEmpty { return true }
        return job.translatedSegments.isEmpty && settings.isTranslationReady
    }

    /// Pumps both slots. The GPU takes the next queued job without a
    /// transcript; translation takes queued work items first, then queued
    /// jobs that already have a transcript. Each slot stays serial, but the
    /// two run independently, so the next transcription can start while the
    /// previous job is still translating.
    private func processQueue() {
        // Nothing runs from the queue until the history has been merged;
        // finishHydration pumps once it has.
        guard !isHydratingJobs else { return }
        defer { updateProcessingActivity() }
        pumpTranslation()
        pumpGPU()
        updateVolumeWaitingJobs()
        // A paused queue is not a finished queue: the old processQueue bailed
        // before the notification whenever queuePaused was set, and jobs are
        // usually still waiting. Jobs waiting on an offline volume also keep
        // the queue "unfinished" — no notification, no after-queue action.
        // A job mid-sidecar-scan is likewise not "finished": jobViews hides it
        // from the scheduler checks below, so without this the queue could
        // report itself empty (and even sleep the Mac) while a batch add is
        // still scanning.
        if !queuePaused, gpuJobID == nil, translationJobID == nil, !pipeline.hasQueuedTranslationWork, didProcessQueuedJob,
            jobsWaitingOnVolumes.isEmpty, subtitleScanPendingIDs.isEmpty,
            PipelineScheduler.nextGPUJob(jobs: jobViews, gpuBusy: false, queuePaused: queuePaused) == nil,
            PipelineScheduler.nextTranslationJob(jobs: jobViews, translationBusy: false, queuePaused: queuePaused) == nil
        {
            didProcessQueuedJob = false
            notify(title: "Cue", body: "All queued jobs finished.")
            performAfterQueueAction()
        }
    }

    /// Runs the user's configured end-of-queue action (Settings > "When the
    /// queue finishes"). The delay lets the notification post and gives a
    /// watching user a moment to object before the Mac sleeps.
    private func performAfterQueueAction() {
        guard settings.afterQueueAction == .sleep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.gpuJobID == nil, self.translationJobID == nil, !self.hasPendingWork else { return }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pmset", directoryHint: .notDirectory)
            process.arguments = ["sleepnow"]
            try? process.run()
        }
    }

    // MARK: - Queue summary (menu bar / sidebar)

    private struct QueueSnapshot {
        let runningCount: Int
        let queuedCount: Int
        let eta: TimeInterval?
    }

    /// Computes counts and ETA together so the sidebar's richer summary is
    /// still one linear scan. The two pipeline lanes run in parallel, so the
    /// estimate is the slower lane, not the sum.
    private var queueSnapshot: QueueSnapshot {
        var gpuHistory: [(end: Date, duration: TimeInterval)] = []
        var translationHistory: [(end: Date, duration: TimeInterval)] = []
        var pendingGPUCount = 0
        var pendingTranslationCount = 0
        var runningCount = 0
        var queuedCount = 0
        var gpuActiveFraction: Double?
        var translationActiveFraction: Double?

        // Keep only the ten newest samples while scanning. The old version
        // built multiple copies of the full job list and sorted all history on
        // every progress tick, even though QueueETA uses just ten durations.
        func retainRecent(
            _ sample: (end: Date, duration: TimeInterval),
            in samples: inout [(end: Date, duration: TimeInterval)]
        ) {
            let insertion = samples.firstIndex { $0.end > sample.end } ?? samples.endIndex
            samples.insert(sample, at: insertion)
            if samples.count > 10 {
                samples.removeFirst(samples.count - 10)
            }
        }

        for job in jobs where job.archivedAt == nil {
            if job.status.isRunning {
                runningCount += 1
            }
            if let start = job.transcriptionStartedAt, let end = job.transcriptionFinishedAt {
                retainRecent((end, end.timeIntervalSince(start)), in: &gpuHistory)
            }
            if let start = job.translationStartedAt, let end = job.finishedAt, end > start {
                retainRecent((end, end.timeIntervalSince(start)), in: &translationHistory)
            }
            if job.status == .queued {
                queuedCount += 1
                if job.transcriptSegments.isEmpty {
                    pendingGPUCount += 1
                } else {
                    pendingTranslationCount += 1
                }
            }
            if job.id == gpuJobID {
                gpuActiveFraction = job.progress.fraction ?? 0
            }
            if job.id == translationJobID {
                translationActiveFraction = job.progress.fraction ?? 0
            }
        }
        let gpuETA = QueueETA.estimate(
            recentDurations: gpuHistory.map(\.duration),
            pendingCount: pendingGPUCount,
            activeFraction: gpuJobID == nil ? nil : gpuActiveFraction ?? 0
        )
        let translationETA = QueueETA.estimate(
            recentDurations: translationHistory.map(\.duration),
            pendingCount: pendingTranslationCount,
            activeFraction: translationJobID == nil ? nil : translationActiveFraction ?? 0
        )
        let eta = [gpuETA, translationETA].compactMap { $0 }.max().flatMap { $0 >= 1 ? $0 : nil }
        return QueueSnapshot(runningCount: runningCount, queuedCount: queuedCount, eta: eta)
    }

    /// "~7m 12s left" for the menu bar; nil when idle or with no history.
    var queueETAText: String? {
        guard let eta = queueSnapshot.eta else { return nil }
        return "~\(JobTimingFormatter.format(eta)) left"
    }

    /// At-a-glance sidebar text such as
    /// "1 running · 24 queued · ~38m remaining".
    var queueSummaryText: String? {
        let snapshot = queueSnapshot
        guard snapshot.runningCount > 0 || snapshot.queuedCount > 0 else { return nil }
        var parts: [String] = []
        if queuePaused {
            parts.append("Queue paused")
        }
        if snapshot.runningCount > 0 {
            parts.append("\(snapshot.runningCount) running")
        }
        if snapshot.queuedCount > 0 {
            parts.append("\(snapshot.queuedCount) queued")
        }
        if !queuePaused, let eta = snapshot.eta {
            parts.append("~\(JobTimingFormatter.format(eta)) remaining")
        }
        return parts.joined(separator: " · ")
    }

    /// One-line queue summary for the menu bar item.
    var menuBarStatusText: String {
        let live = jobs.filter { $0.archivedAt == nil }
        let queuedCount = live.filter { $0.status == .queued }.count
        if let running = live.first(where: { $0.status.isRunning }) {
            let percent = running.progress.fraction.map { " — \(Int(($0 * 100).rounded()))%" } ?? ""
            let waiting = queuedCount > 0 ? " (\(queuedCount) queued)" : ""
            return "\(running.title)\(percent)\(waiting)"
        }
        if queuedCount > 0 {
            return queuePaused ? "Queue paused — \(queuedCount) waiting" : "\(queuedCount) queued"
        }
        return "Idle"
    }

    /// Stops taking new jobs; running jobs finish their current stage.
    func pauseQueue() {
        queuePaused = true
    }

    private var jobViews: [PipelineScheduler.JobView] {
        let mounted = SourceVolume.mountedVolumeNames()
        return jobs.filter { $0.archivedAt == nil && !subtitleScanPendingIDs.contains($0.id) }.map {
            PipelineScheduler.JobView(
                id: $0.id,
                orderIndex: $0.orderIndex,
                status: $0.status,
                hasTranscript: !$0.transcriptSegments.isEmpty,
                sourceAvailable: SourceVolume.isAvailable(path: $0.sourcePath, mountedVolumeNames: mounted)
            )
        }
    }

    /// Queued jobs whose source volume is currently unmounted. They keep
    /// their queue position but are skipped until the volume returns.
    private var jobsWaitingOnVolumes: [UUID] {
        let mounted = SourceVolume.mountedVolumeNames()
        return
            jobs
            .filter {
                $0.archivedAt == nil && $0.status == .queued
                    && !SourceVolume.isAvailable(path: $0.sourcePath, mountedVolumeNames: mounted)
            }
            .map(\.id)
    }

    private func updateVolumeWaitingJobs() {
        let waiting = jobsWaitingOnVolumes
        for id in waiting {
            guard let job = self.job(withID: id) else { continue }
            let volume = SourceVolume.volumeName(forPath: job.sourcePath) ?? "volume"
            let detail = "Waiting for “\(volume)” to reconnect."
            if job.progress.detail != detail {
                updateJob(id, debouncePersist: true) {
                    $0.progress = JobProgress(stage: .queued, detail: detail, fraction: nil)
                }
            }
        }
        guard !waiting.isEmpty, !volumeRetryScheduled else { return }
        volumeRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.volumeRetryScheduled = false
            self.processQueue()
        }
    }

    private func pumpGPU() {
        guard let id = PipelineScheduler.nextGPUJob(jobs: jobViews, gpuBusy: gpuJobID != nil, queuePaused: queuePaused),
            let index = index(of: id)
        else { return }
        didProcessQueuedJob = true
        startTranscriptionNow(at: index, force: false)
        // If the job could not start (e.g. a guard failed), fail it instead
        // of stalling the whole queue on a stuck "queued" entry.
        if gpuJobID == nil, self.job(withID: id)?.status == .queued {
            markFailed(id, message: "Could not start this job. Check the file and settings.")
            processQueue()
        }
    }

    private func pumpTranslation() {
        guard translationTask == nil else { return }
        if let item = pipeline.dequeueTranslationWork() {
            translationJobID = item.jobID
            translationTask = Task {
                await item.work()
                translationTask = nil
                translationJobID = nil
                processQueue()
            }
            return
        }
        guard let id = PipelineScheduler.nextTranslationJob(jobs: jobViews, translationBusy: false, queuePaused: queuePaused),
            let index = index(of: id)
        else { return }
        didProcessQueuedJob = true
        startTranslationNow(at: index)
        if translationJobID == nil, self.job(withID: id)?.status == .queued {
            markFailed(id, message: "Could not start this job. Check the file and settings.")
            processQueue()
        }
    }

    /// Queues work onto the translation slot ahead of any queued jobs.
    private func enqueueTranslationWork(jobID: UUID, _ work: @escaping @MainActor () async -> Void) {
        pipeline.enqueueTranslationWork(jobID: jobID, work: work)
    }

    /// Ends a job's streaming session: the driver, its remembered translation
    /// fraction, and any of its work items still waiting on the translation
    /// slot. Dropping the queued items matters even on the success path — a
    /// mid-stream pass that ended after the finish pass was queued can leave
    /// one more incremental item behind it, which would otherwise re-run
    /// against the already-completed job.
    private func endStreamingSession(for id: UUID) {
        drivers[id] = nil
        streamingTranslationFraction[id] = nil
        pipeline.removeTranslationWork(for: id)
    }

    // MARK: - Watch folders

    /// Reconciles running services with the settings list: starts services
    /// for newly enabled folders, stops removed/disabled ones, restarts a
    /// folder whose path changed. Idempotent, so callers just mutate
    /// `settings.watchFolders` and call this.
    func syncWatchFolders() {
        // Services read job fingerprints to block re-ingest; they start
        // once the history is in (finishHydration calls this again).
        guard !isHydratingJobs else { return }
        watchCoordinator.sync(folders: settings.watchFolders)
    }

    private func makeWatchService(folderID: UUID) -> WatchFolderService {
        let service = WatchFolderService()
        service.blockedFingerprints = { [weak self] in
            guard let self else { return [] }
            // Ledger entries plus every job's fingerprint, any status
            // (spec §2.3 rule 4): canceled or manual jobs block too.
            return self.watchLedger.fingerprints.union(self.jobs.map(\.sourceFingerprint))
        }
        service.ledgerPathsUnderFolder = { [weak self] folderPath in
            guard let self else { return [] }
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            return self.watchLedger.fingerprints
                .map(WatchFolderLedger.path(fromFingerprint:))
                .filter { $0.hasPrefix(prefix) }
        }
        service.onScanCompleted = { [weak self] folderPath, existingPaths in
            // Prune only entries under the folder that was actually scanned:
            // other folders' histories must survive untouched. A subfolder
            // that's transiently unreadable/unmounted drops out of the
            // enumeration too, so the scan re-verified every ledger entry
            // under this folder on disk (off the main thread) and folded the
            // survivors into existingPaths — otherwise they would be pruned
            // and re-ingested as duplicates the moment the subfolder came back.
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            self?.watchLedger.prune(fileExists: { path in
                !path.hasPrefix(prefix) || existingPaths.contains(path)
            })
        }
        service.onFilesReady = { [weak self] urls in
            self?.ingestWatchFolderFiles(urls, folderID: folderID)
        }
        return service
    }

    func addWatchFolder(path: String) {
        // Re-adding a watched path is a no-op, not a duplicate watcher.
        guard !settings.watchFolders.contains(where: { $0.path == path }) else { return }
        settings.watchFolders.append(WatchFolder(path: path))
        syncWatchFolders()
    }

    func removeWatchFolder(_ id: UUID) {
        settings.watchFolders.removeAll { $0.id == id }
        syncWatchFolders()
    }

    func setWatchFolderEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = settings.watchFolders.firstIndex(where: { $0.id == id }) else { return }
        settings.watchFolders[index].enabled = enabled
        syncWatchFolders()
    }

    func setWatchFolderProfile(_ id: UUID, _ profile: JobSettingsOverrides) {
        guard let index = settings.watchFolders.firstIndex(where: { $0.id == id }) else { return }
        settings.watchFolders[index].profile = profile
    }

    func clearWatchHistory(for id: UUID) {
        guard let folder = settings.watchFolders.first(where: { $0.id == id }) else { return }
        watchLedger.clear(underPath: folder.path)
    }

    /// Ingest deliberately does NOT go through enqueueJob: that clears
    /// queuePaused (spec §2.3/2.6 — arriving files must not override an
    /// explicit stop), and ignores autoStartAddedJobs, which governs
    /// interactive adds only.
    func ingestWatchFolderFiles(_ urls: [URL], folderID: UUID) {
        guard !urls.isEmpty else { return }
        // The profile is read at ingest time, so edits apply to the next
        // file without restarting the watcher.
        let profile =
            settings.watchFolders.first(where: { $0.id == folderID })?.profile
            ?? JobSettingsOverrides()
        // One base index for the batch and one repository save: a scan that
        // finds a whole season must not flush the store once per episode or
        // rescan every existing index per file.
        var nextIndex = QueueOrdering.indexForWatchAdd(existing: jobs.map(\.orderIndex))
        var newJobs: [TranscriptionJob] = []
        newJobs.reserveCapacity(urls.count)
        for url in urls {
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.origin = .watchFolder
            job.overrides = profile
            job.orderIndex = nextIndex
            nextIndex += 1
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            job.log = "Picked up from the watch folder: \(url.path(percentEncoded: false)).\n"
            newJobs.append(job)
        }
        jobs.append(contentsOf: newJobs)
        jobRepository.save(newJobs)
        adoptSidecars(for: newJobs.map(\.id))
        processQueue()
    }

    // MARK: - URL ingest

    /// Fetches happen off the pipeline entirely: they are network-bound,
    /// hold no GPU or translation slot, and run concurrently with each other
    /// and with the queue. A download only touches the queue once it has
    /// produced a real file, at which point it enters through the ordinary
    /// add path.
    func addRemoteMedia(from text: String) {
        guard let url = MediaDownloadService.normalizedWebURL(from: text) else {
            presentDownloadError(MediaDownloadError.notAWebURL(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }
        startRemoteMediaDownload(pageURL: url)
    }

    /// One gate for every URL entry point (the ⌘L dialog and the sidebar
    /// drop): a missing yt-dlp becomes an offer to install it in place, not
    /// a dead-end error row.
    private func startRemoteMediaDownload(pageURL: URL) {
        guard MediaDownloadService.isAvailable else {
            presentYtDlpOffer(pageURL: pageURL)
            return
        }
        startDownload(MediaDownload(pageURL: pageURL))
    }

    /// Asks for a URL, pre-filling anything web-shaped already on the
    /// clipboard — pasting a link is the whole interaction, so requiring a
    /// second ⌘V would be the only friction left. Availability is checked
    /// after Download, where a missing yt-dlp can become an install offer.
    func promptForRemoteMedia() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…"
        if let clipboard = NSPasteboard.general.string(forType: .string),
            let url = MediaDownloadService.normalizedWebURL(from: clipboard)
        {
            field.stringValue = url.absoluteString
        }

        let alert = NSAlert()
        alert.messageText = "Add from URL"
        alert.informativeText = "Paste a video or audio page address. Cue downloads it with yt-dlp, then queues it like any other file."
        alert.accessoryView = field
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        addRemoteMedia(from: entered)
    }

    func cancelDownload(_ id: UUID) {
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        downloads.removeAll { $0.id == id }
        updateProcessingActivity()
    }

    /// Clears a failed row. Running downloads go through cancelDownload so
    /// the yt-dlp process is actually stopped.
    func dismissDownload(_ id: UUID) {
        guard downloads.first(where: { $0.id == id })?.state.isFailed == true else { return }
        downloads.removeAll { $0.id == id }
    }

    func retryDownload(_ id: UUID) {
        guard let existing = downloads.first(where: { $0.id == id }), existing.state.isFailed else { return }
        downloads.removeAll { $0.id == id }
        startDownload(MediaDownload(pageURL: existing.pageURL))
    }

    // MARK: yt-dlp install

    /// Explains the missing tool and offers to install it. With Homebrew
    /// present the offer is one click; without it, the manual path is the
    /// only honest answer.
    private func presentYtDlpOffer(pageURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "yt-dlp is needed for web downloads"
        if YtDlpInstaller.homebrewURL() != nil {
            alert.informativeText =
                "Cue fetches video pages with yt-dlp, which is not installed yet. Install it now with Homebrew? The download is small and your link starts fetching as soon as it finishes."
            alert.addButton(withTitle: "Install yt-dlp")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            beginYtDlpInstall(pageURL: pageURL)
        } else {
            alert.informativeText =
                "Cue fetches video pages with yt-dlp, which is installed with Homebrew. Get Homebrew from brew.sh, run `brew install yt-dlp` in Terminal, then try the link again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Starts (or retries) an in-app Homebrew install of yt-dlp. A retry
    /// replaces a failed attempt; a request that is already running is left
    /// alone so two entry points can't double-start brew.
    func beginYtDlpInstall(pageURL: URL?) {
        guard YtDlpInstaller.homebrewURL() != nil else {
            presentDownloadError(YtDlpInstallError.homebrewMissing)
            return
        }
        if var request = ytDlpInstallRequest {
            guard request.phase.isFailed else { return }
            request.phase = .running
            request.detailLines = []
            if let pageURL { request.pageURL = pageURL }
            ytDlpInstallRequest = request
        } else {
            ytDlpInstallRequest = YtDlpInstallRequest(pageURL: pageURL)
        }
        ytDlpInstallTask?.cancel()
        ytDlpInstallTask = Task { [weak self] in
            await self?.runYtDlpInstall()
        }
        updateProcessingActivity()
    }

    func cancelYtDlpInstall() {
        ytDlpInstallTask?.cancel()
        ytDlpInstallTask = nil
        ytDlpInstallRequest = nil
        updateProcessingActivity()
    }

    private func runYtDlpInstall() async {
        do {
            try await YtDlpInstaller().install { [weak self] detail in
                self?.appendYtDlpInstallDetail(detail)
            }
            guard !Task.isCancelled else { return }
            let pending = ytDlpInstallRequest?.pageURL
            ytDlpInstallTask = nil
            ytDlpInstallRequest = nil
            updateProcessingActivity()
            // Refresh the setup guide's rows so its yt-dlp entry flips to
            // passed without the user having to press Check Again.
            runDiagnostics()
            if let pending {
                startDownload(MediaDownload(pageURL: pending))
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            updateYtDlpInstallRequest { $0.phase = .failed(error.localizedDescription) }
        }
    }

    private func appendYtDlpInstallDetail(_ line: String) {
        updateYtDlpInstallRequest { request in
            request.detailLines.append(line)
            // The sheet shows a bounded tail; brew's full log outlives it in
            // Terminal only when something goes wrong and we surface the
            // stderr tail in the failure phase anyway.
            if request.detailLines.count > 6 {
                request.detailLines.removeFirst(request.detailLines.count - 6)
            }
        }
    }

    private func updateYtDlpInstallRequest(_ mutate: (inout YtDlpInstallRequest) -> Void) {
        guard var request = ytDlpInstallRequest else { return }
        mutate(&request)
        ytDlpInstallRequest = request
    }

    private func startDownload(_ download: MediaDownload) {
        // Re-adding a link that is already downloading would fetch the same
        // bytes twice and land two jobs on the same content.
        guard !downloads.contains(where: { $0.pageURL == download.pageURL && !$0.state.isFailed }) else { return }
        downloads.append(download)
        updateProcessingActivity()

        let id = download.id
        let pageURL = download.pageURL
        let directory = settings.resolvedDownloadDirectory
        downloadTasks[id] = Task { [weak self] in
            do {
                let file = try await MediaDownloadService().download(url: pageURL, into: directory) { update in
                    self?.updateDownload(id) { record in
                        record.fraction = update.fraction
                        record.detail = update.detail
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.finishDownload(id, file: file, pageURL: pageURL)
            } catch is CancellationError {
                // cancelDownload already removed the row.
            } catch {
                self?.failDownload(id, message: error.localizedDescription)
            }
        }
    }

    private func finishDownload(_ id: UUID, file: URL, pageURL: URL) {
        downloadTasks[id] = nil
        downloads.removeAll { $0.id == id }
        addVideos(urls: [file], origin: .url, sourceNote: "Downloaded from \(pageURL.absoluteString).")
        updateProcessingActivity()
    }

    private func failDownload(_ id: UUID, message: String) {
        downloadTasks[id] = nil
        updateDownload(id) { download in
            download.state = .failed(message)
            download.fraction = nil
            download.detail = message
        }
        updateProcessingActivity()
    }

    private func updateDownload(_ id: UUID, mutate: (inout MediaDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        mutate(&downloads[index])
    }

    private func presentDownloadError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Can't Add That URL"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Terminal-state bookkeeping for watch jobs (spec §2.4): success and
    /// failure are recorded; cancel is not — the canceled job itself blocks
    /// re-ingest while it exists, and deleting it means "do it over".
    private func recordWatchOutcome(for id: UUID, success: Bool) {
        guard let job = self.job(withID: id), job.origin == .watchFolder else { return }
        watchLedger.record(job.sourceFingerprint, outcome: success ? .success : .failure)
    }

    // MARK: - Ordering

    /// Moves jobs for SwiftUI's onMove. Only the moved block is re-persisted,
    /// unless index precision is exhausted, which forces a full pass.
    func moveJobs(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        jobs.move(fromOffsets: source, toOffset: destination)
        let start = QueueOrdering.movedBlockStart(source: source, destination: destination)
        reindex(block: start..<(start + source.count))
    }

    func moveJobToTop(_ id: UUID) {
        guard let index = index(of: id) else { return }
        moveJobs(from: IndexSet(integer: index), to: 0)
    }

    func moveJobToBottom(_ id: UUID) {
        guard let index = index(of: id) else { return }
        moveJobs(from: IndexSet(integer: index), to: jobs.count)
    }

    func removeFromQueue(_ id: UUID) {
        removeJobsFromQueue([id])
    }

    /// Removes all queued members of a selection without repeatedly
    /// invalidating the entire sidebar.
    func removeJobsFromQueue(_ ids: Set<UUID>) {
        updateJobs(ids, where: { $0.status == .queued }) { job in
            job.status = .idle
            job.progress = .idle
        }
    }

    /// Undo support for Remove from Queue. A paused queue remains paused;
    /// otherwise restored jobs immediately rejoin normal scheduling.
    func restoreJobsToQueue(_ ids: Set<UUID>, queueWasPaused: Bool) {
        let restoredIDs = updateJobs(ids, where: { $0.status == .idle && $0.archivedAt == nil }) { job in
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }
        guard !restoredIDs.isEmpty else { return }
        queuePaused = queueWasPaused
        if !queueWasPaused {
            processQueue()
        }
    }

    /// Restamps exactly the moved block. Its outside neighbours kept their
    /// relative order, so their indices are trustworthy brackets; stale
    /// indices inside the block are overwritten without ever being read.
    private func reindex(block: Range<Int>) {
        guard !block.isEmpty, block.upperBound <= jobs.count else { return }
        let before = block.lowerBound > 0 ? jobs[block.lowerBound - 1].orderIndex : nil
        let after = block.upperBound < jobs.count ? jobs[block.upperBound].orderIndex : nil
        if QueueOrdering.needsRenormalization(before: before, after: after) {
            renormalizeAllIndices()
            return
        }
        var previous = before
        for i in block {
            let stamped = QueueOrdering.destinationIndex(before: previous, after: after)
            // Multi-item blocks halve the gap per item; bail to a full pass
            // the moment a midpoint stops landing strictly inside.
            let fitsBefore = previous.map { $0 < stamped } ?? true
            let fitsAfter = after.map { stamped < $0 } ?? true
            if !fitsBefore || !fitsAfter {
                renormalizeAllIndices()
                return
            }
            jobs[i].orderIndex = stamped
            persistJob(jobs[i].id)
            previous = stamped
        }
    }

    private func renormalizeAllIndices() {
        let indices = QueueOrdering.renormalized(count: jobs.count)
        for i in jobs.indices {
            jobs[i].orderIndex = indices[i]
            persistJob(jobs[i].id)
        }
    }

    func startTranscription(jobID: UUID? = nil, force: Bool = false) {
        guard let index = (jobID ?? selectedJobID).flatMap(index(of:)) else { return }
        let targetID = jobs[index].id
        guard !jobs[index].status.isRunning else { return }
        // Something else is running: queue this job instead of fighting for
        // the GPU.
        if gpuJobID != nil {
            enqueueJob(targetID)
            return
        }
        startTranscriptionNow(at: index, force: force)
    }

    private func startTranscriptionNow(at index: Int, force: Bool) {
        let jobID = jobs[index].id
        let videoURL = jobs[index].sourceURL

        let currentFingerprint = TranscriptionJob.fingerprint(for: videoURL)
        var resolved = JobSettingsSnapshot(settings: settings).applying(jobs[index].overrides)
        // Validate the pairing this job will actually run with (globals plus
        // its overrides) and repair the run's copy only: starting one job
        // must not rewrite the app-wide defaults behind the user's back.
        let validationMessage = AppSettingsStore.transcriptionValidationMessage(
            backend: resolved.whisperBackend, model: resolved.whisperModel)
        if validationMessage != nil {
            resolved.whisperModel = AppSettingsStore.normalizedWhisperModel(
                for: resolved.whisperBackend, current: resolved.whisperModel, force: true)
        }
        // Per-job autoTranslate wins over the global toggle (spec §0.3).
        let autoTranslate = jobs[index].overrides.autoTranslate ?? settings.autoTranslateAfterTranscription

        // An imported transcript satisfies the checks below by accident: its
        // settings snapshot describes the globals at add time, not a run that
        // produced these subtitles. Pressing Transcribe on one means "actually
        // run ASR".
        if !force,
            jobs[index].importedTranscriptSource == nil,
            !jobs[index].transcriptSegments.isEmpty,
            jobs[index].sourceFingerprint == currentFingerprint,
            jobs[index].settings.transcriptionIdentity == resolved.transcriptionIdentity
        {
            let hasTranslation = !jobs[index].translatedSegments.isEmpty
            // The run's clock starts now; transcription itself cost nothing.
            // The previous run's stamps must go, or its translation time is
            // reported again for this one.
            let now = Date()
            jobs[index].transcriptionStartedAt = now
            jobs[index].transcriptionFinishedAt = now
            jobs[index].translationStartedAt = nil
            jobs[index].finishedAt = nil
            jobs[index].status = hasTranslation ? .translationComplete : .transcriptionComplete
            jobs[index].progress = JobProgress(stage: .complete, detail: "Using existing transcript for unchanged file and settings.", fraction: 1)
            appendLog("Skipped transcription because this file and transcription settings already have a transcript.", to: jobID)
            recordWatchOutcome(for: jobID, success: true)
            // Same guard as the real completion path: auto-translating with
            // no usable provider would immediately mark this job as Failed.
            if autoTranslate && !hasTranslation && settings.isModelReady(resolved.openAIModel) {
                startTranslation(jobID: jobID)
            } else {
                processQueue()
            }
            return
        }

        let canResumeTranscription =
            !force
            && jobs[index].importedTranscriptSource == nil
            && jobs[index].transcriptSegments.isEmpty
            && !jobs[index].partialTranscriptSegments.isEmpty
            && jobs[index].sourceFingerprint == currentFingerprint
            && jobs[index].settings.transcriptionIdentity == resolved.transcriptionIdentity

        jobs[index].status = .transcribing
        jobs[index].progress = JobProgress(
            stage: .preflight,
            detail: canResumeTranscription ? "Resuming transcription." : "Starting transcription.",
            fraction: 0
        )
        if canResumeTranscription {
            jobs[index].translatedSegments = []
            // Keep partialTranslatedSegments so progressive translation can resume.
        } else {
            jobs[index].translatedSegments = []
            jobs[index].partialTranslatedSegments = []
            jobs[index].partialTranscriptSegments = []
            jobs[index].transcriptionResumeThrough = 0
        }
        // The imported files no longer describe this job's contents, so write-
        // back must stop pointing at them — and any write already queued for
        // them must be dropped too, exactly as startTranslationNow does for
        // the translation slot.
        cancelSubtitleSync(jobID: jobID, slot: .transcript)
        cancelSubtitleSync(jobID: jobID, slot: .translation)
        jobs[index].importedTranscriptSource = nil
        jobs[index].importedTranslationSource = nil
        if canResumeTranscription {
            jobs[index].transcriptionStartedAt = jobs[index].transcriptionStartedAt ?? Date()
        } else {
            jobs[index].transcriptionStartedAt = Date()
        }
        jobs[index].transcriptionFinishedAt = nil
        jobs[index].translationStartedAt = nil
        jobs[index].finishedAt = nil
        jobs[index].sourceFingerprint = currentFingerprint
        jobs[index].settings = resolved
        if let validationMessage {
            jobs[index].log += "Adjusted transcription settings: \(validationMessage)\n"
        }
        if canResumeTranscription {
            appendLog(
                "Resuming transcription from \(Int(jobs[index].transcriptionResumeThrough / 60)) minutes with \(resolved.whisperBackend.label) and model \(resolved.whisperModel).",
                to: jobID
            )
        } else {
            appendLog("Starting transcription with \(resolved.whisperBackend.label) and model \(resolved.whisperModel).", to: jobID)
        }

        let resumeThrough = jobs[index].transcriptionResumeThrough
        let existingPartialSegments = jobs[index].partialTranscriptSegments
        let resumeMergesPartials = canResumeTranscription

        // A translating job gets a driver up front, so streamed batches can be
        // translated behind the transcription frontier. A local server is the
        // exception: it competes with whisper for this machine's GPU, so it
        // only translates once transcription is done (one whole-transcript
        // pass, exactly like the sequential path).
        let willTranslate = autoTranslate && settings.isModelReady(resolved.openAIModel)
        if willTranslate {
            // Fresh per run, never persisted onto the job.
            let credentials = makeCredentials(for: resolved.openAIModel)
            let overlapAllowed = credentials.provider != .local
            drivers[jobID] = ProgressiveTranslationDriver(
                chunkSize: resolved.translationChunkMode.chunkSize,
                initialSegmentThreshold: resolved.translationChunkMode.initialStreamingSegments,
                targetInputTokens: resolved.translationChunkMode.targetInputTokens,
                overlapAllowed: overlapAllowed,
                translate: { [weak self] segments, existing, onPartial in
                    guard let self else { throw CancellationError() }
                    return try await self.translationService.translate(
                        segments: segments,
                        sourceLanguage: resolved.sourceLanguage,
                        settings: resolved,
                        credentials: credentials,
                        existingTranslations: existing,
                        progress: { [weak self] update in
                            self?.recordStreamingTranslationProgress(update, for: jobID)
                        },
                        onPartial: onPartial
                    )
                },
                onPartial: { [weak self] batch in
                    guard let self else { return }
                    self.updatePartialTranslation(batch, for: jobID)
                    // How far the translation has come is a count of segments,
                    // not what the service reports: every pass ends at
                    // fraction 1.0 but only covers what had streamed when it
                    // started, so the service number would sit at 100% from
                    // the first pass on.
                    if let driver = self.drivers[jobID] {
                        self.streamingTranslationFraction[jobID] =
                            Double(driver.partials.count) / Double(max(1, driver.streamed.count))
                    }
                },
                onNeedsTranslation: { [weak self] in
                    guard let self, let driver = self.drivers[jobID] else { return }
                    self.updateJob(jobID, debouncePersist: true) { job in
                        job.translationStartedAt = job.translationStartedAt ?? Date()
                    }
                    self.enqueueTranslationWork(jobID: jobID) { [weak self] in
                        // The session can end between queueing and running
                        // (stop, or a failed transcription): never translate
                        // for a job whose driver is gone.
                        guard self?.drivers[jobID] != nil else { return }
                        await driver.translateAvailable()
                    }
                    self.processQueue()
                }
            )
        }

        requestNotificationAuthorizationIfNeeded()
        gpuJobID = jobID
        updateProcessingActivity()
        gpuTask = Task {
            do {
                let result = try await transcriptionService.transcribe(
                    videoURL: videoURL,
                    settings: resolved,
                    resumeThrough: resumeThrough,
                    existingPartialSegments: existingPartialSegments,
                    progress: { [weak self] progress in
                        self?.updateProgress(progress, for: jobID)
                    },
                    onSegments: { [weak self] batch in
                        guard let self else { return }
                        // A Python backend's stderr can be buffered, so a segments
                        // line can arrive after the run already finished. Dropping
                        // it keeps cleared partials cleared instead of leaving
                        // stale ones on a completed job forever.
                        guard self.self.job(withID: jobID)?.status == .transcribing else { return }
                        self.updateJob(jobID, debouncePersist: true) { job in
                            if resumeMergesPartials {
                                job.partialTranscriptSegments = TranscriptionChunkPlanner.mergePartialSegments(
                                    existing: job.partialTranscriptSegments,
                                    batch: batch
                                )
                            } else {
                                job.partialTranscriptSegments += batch
                            }
                        }
                        self.drivers[jobID]?.ingest(batch)
                    },
                    onChunkComplete: { [weak self] chunkEnd in
                        self?.updateJob(jobID, debouncePersist: true) { job in
                            job.transcriptionResumeThrough = max(job.transcriptionResumeThrough, chunkEnd)
                        }
                    },
                    onMetrics: { [weak self] metrics in
                        self?.appendLog(metrics.logSummary, to: jobID)
                    })
                updateJob(jobID) { $0.transcriptionFinishedAt = Date() }
                // When a translation follows, the summary is generated from
                // the translated text instead, at the end of that step.
                var summary: String?
                if !willTranslate {
                    summary = await makeIntroSummary(
                        from: result.segments,
                        language: "the same language as the subtitles",
                        for: jobID
                    )
                }
                finishTranscription(result, summary: summary, for: jobID)
                if willTranslate {
                    // Free the GPU before handing off: the translation runs in
                    // its own slot, so the next queued job can start
                    // transcribing while this one translates.
                    gpuTask = nil
                    gpuJobID = nil
                    // Nothing awaits between the transcribe call and here, so
                    // a Stop that landed while this continuation was pending
                    // never surfaced as a CancellationError — check it by hand
                    // or the translation phase starts on a canceled job. A
                    // missing driver means the same thing: only a stop tears
                    // one down before its finish pass.
                    guard !Task.isCancelled, let driver = drivers[jobID] else {
                        markCanceled(jobID)
                        endStreamingSession(for: jobID)
                        processQueue()
                        return
                    }
                    // The finish pass reconciles whatever was translated
                    // during transcription onto the final transcript and
                    // translates the tail. It goes straight onto the
                    // translation slot's work queue rather than re-queueing
                    // the job: being pushed back for a busy slot is not the
                    // user asking for more work (spec §2.3/2.6), so the
                    // queue's paused state is left alone.
                    updateJob(jobID) { job in
                        job.status = .translating
                        job.translationStartedAt = job.translationStartedAt ?? Date()
                        job.progress = JobProgress(stage: .translating, detail: "Finishing translation.", fraction: nil)
                    }
                    appendLog(
                        "Starting translation from \(resolved.translationSourceLanguage) to \(resolved.translationTargetLanguage) with \(resolved.openAIModel) using \(resolved.translationChunkMode.label.lowercased()) chunks and \(resolved.translationParallelism) worker(s).",
                        to: jobID
                    )
                    enqueueTranslationWork(jobID: jobID) { [weak self] in
                        guard let self else { return }
                        do {
                            let final = self.self.job(withID: jobID)?.transcriptSegments ?? []
                            // Persist the reconciled partials *before* the
                            // finish pass runs. Mid-stream partials are keyed
                            // by streamed segment ids; if this pass fails or is
                            // canceled before its first result lands, those
                            // stale ids would survive on the job and a later
                            // manual Translate would seed them by id against
                            // the renumbered final transcript — silently
                            // pairing translations with the wrong cues. The
                            // reconciled set is what a retry should resume
                            // from, and it is the same remap `finish` does.
                            let reconciled = TranslationReconciliation.remap(
                                partials: driver.partials, streamed: driver.streamed, final: final)
                            self.updatePartialTranslation(reconciled, for: jobID)
                            let translated = try await driver.finish(finalTranscript: final)
                            let target = resolved.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                            let summary = await self.makeIntroSummary(
                                from: translated,
                                language: target.isEmpty ? "English" : target,
                                for: jobID
                            )
                            self.finishTranslation(translated, summary: summary, for: jobID)
                            self.recordCompletionTiming(for: jobID)
                        } catch is CancellationError {
                            self.markCanceled(jobID)
                        } catch {
                            // A request torn down by Stop can surface as a
                            // network error before the cancellation check.
                            if Task.isCancelled {
                                self.markCanceled(jobID)
                            } else {
                                self.markFailed(jobID, message: "Translation failed: \(error.localizedDescription)")
                            }
                        }
                        self.endStreamingSession(for: jobID)
                        self.notifyJobFinished(jobID)
                    }
                    processQueue()
                    return
                }
                // The job ends here (no translation step follows).
                recordCompletionTiming(for: jobID)
                autoExportSidecars(for: jobID)
                recordWatchOutcome(for: jobID, success: true)
                notifyJobFinished(jobID)
            } catch is CancellationError {
                markCanceled(jobID)
                // The partial transcript stays on the job (spec §6) so a retry
                // can resume from it, but the session is over: no finish pass
                // is coming, so the driver and its queued work must go.
                endStreamingSession(for: jobID)
            } catch {
                // A killed helper can surface its exit error in a race with
                // the cancellation check; don't overwrite "Canceled" with
                // "Failed" in that case.
                if Task.isCancelled {
                    markCanceled(jobID)
                } else {
                    markFailed(jobID, message: "Transcription failed: \(error.localizedDescription)")
                    notifyJobFinished(jobID)
                }
                endStreamingSession(for: jobID)
            }
            gpuTask = nil
            gpuJobID = nil
            processQueue()
        }
    }

    func startTranslation(jobID: UUID? = nil) {
        guard let index = (jobID ?? selectedJobID).flatMap(index(of:)),
            !jobs[index].transcriptSegments.isEmpty
        else { return }
        let targetID = jobs[index].id
        guard !jobs[index].status.isRunning else { return }
        if translationJobID != nil {
            enqueueJob(targetID)
            return
        }
        startTranslationNow(at: index)
    }

    private func startTranslationNow(at index: Int) {
        let jobID = jobs[index].id
        let segments = jobs[index].transcriptSegments
        let resolved = JobSettingsSnapshot(settings: settings).applying(jobs[index].overrides)
        // What this run starts from, all of it only for the *same* target
        // language (partials in another language must not be stitched in):
        // an interrupted run resumes from its saved partials; a translation
        // that covers only part of the transcript (an imported file with fewer
        // cues) is kept and the gaps are filled; a translation that already
        // covers every cue is redone in full — seeding from it made every
        // re-run a silent no-op.
        let sameTarget =
            jobs[index].settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            == resolved.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sameTarget {
            jobs[index].partialTranslatedSegments = []
        }
        let existingTranslations: [TranscriptionSegment]
        if !sameTarget {
            existingTranslations = []
        } else if !jobs[index].partialTranslatedSegments.isEmpty {
            existingTranslations = jobs[index].partialTranslatedSegments
        } else {
            let covered = Set(jobs[index].translatedSegments.map(\.id))
            let coversEveryCue = segments.allSatisfy { covered.contains($0.id) }
            existingTranslations = coversEveryCue ? [] : jobs[index].translatedSegments
        }
        jobs[index].status = .translating
        jobs[index].progress = JobProgress(stage: .translating, detail: "Starting translation.", fraction: 0)
        // This run replaces translatedSegments with machine output, so the
        // imported file no longer describes them and write-back must stop
        // pointing at it (same reasoning as startTranscriptionNow). The
        // changed-on-disk guard could not catch this: the file is untouched.
        cancelSubtitleSync(jobID: jobID, slot: .translation)
        jobs[index].importedTranslationSource = nil
        // Translating a job whose previous run already finished starts a new
        // run: the old run's clock must not carry over, or a Monday
        // transcript translated on Wednesday reports a two-day total. Within
        // a run (a resumed partial translation) the original start stands.
        if jobs[index].finishedAt != nil {
            jobs[index].transcriptionStartedAt = nil
            jobs[index].transcriptionFinishedAt = nil
            jobs[index].finishedAt = nil
            jobs[index].translationStartedAt = Date()
        } else {
            jobs[index].translationStartedAt = jobs[index].translationStartedAt ?? Date()
        }
        jobs[index].settings = jobs[index].settings.updatingTranslationFields(from: resolved)
        appendLog(
            "Starting translation from \(resolved.translationSourceLanguage) to \(resolved.translationTargetLanguage) with \(resolved.openAIModel) using \(resolved.translationChunkMode.label.lowercased()) chunks and \(resolved.translationParallelism) worker(s).",
            to: jobID
        )

        requestNotificationAuthorizationIfNeeded()
        translationJobID = jobID
        updateProcessingActivity()
        translationTask = Task {
            do {
                let result = try await translationService.translate(
                    segments: segments,
                    sourceLanguage: resolved.sourceLanguage,
                    settings: resolved,
                    credentials: makeCredentials(for: resolved.openAIModel),
                    existingTranslations: existingTranslations
                ) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
                } onPartial: { [weak self] partial in
                    self?.updatePartialTranslation(partial, for: jobID)
                }
                let target = resolved.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = await makeIntroSummary(
                    from: result,
                    language: target.isEmpty ? "English" : target,
                    for: jobID
                )
                finishTranslation(result, summary: summary, for: jobID)
                recordCompletionTiming(for: jobID)
            } catch is CancellationError {
                markCanceled(jobID)
            } catch {
                if Task.isCancelled {
                    markCanceled(jobID)
                } else {
                    markFailed(jobID, message: "Translation failed: \(error.localizedDescription)")
                }
            }
            notifyJobFinished(jobID)
            translationTask = nil
            translationJobID = nil
            processQueue()
        }
    }

    func cancelActiveJob() {
        // Stopping the current job also pauses the queue: a cancel means
        // "stop working", not "move on to the next one".
        if queuedJobCount > 0 {
            queuePaused = true
        }
        // Stop means stop: both slots and any pending translation work.
        // A streaming job whose finish pass is still queued owns neither slot
        // (its GPU slot was released at handoff), so dropping the queue would
        // strand it in Translating with nothing left to run it. Those jobs get
        // stamped canceled alongside the running ones.
        let affectedIDs = pipeline.cancelAll()
        // Cancel is an app-wide stop, so every streaming session dies with it.
        drivers.removeAll()
        streamingTranslationFraction.removeAll()
        // Only the actively running (or queued-for-work) jobs may be stamped
        // canceled; falling back to the selection could cancel a completed job.
        for id in affectedIDs {
            updateJob(id) { job in
                job.status = .canceled
                job.progress = JobProgress(stage: .canceled, detail: "Canceling current operation.", fraction: nil)
                job.log += "Cancel requested.\n"
            }
        }
    }

    func exportTranscript(format: SubtitleExportFormat = .srt) {
        guard !transcriptSegments.isEmpty else { return }
        export(segments: transcriptSegments, format: format, suggestedSuffix: ".original.\(format.fileExtension)")
    }

    func exportTranslation(format: SubtitleExportFormat = .srt) {
        guard !translatedSegments.isEmpty else { return }
        export(
            segments: translatedSegments,
            format: format,
            suggestedSuffix: ".translated.\(languageSuffix(translationTargetLabel)).\(format.fileExtension)"
        )
    }

    func exportBilingual(format: SubtitleExportFormat = .srt) {
        guard !transcriptSegments.isEmpty, !translatedSegments.isEmpty else { return }
        export(
            segments: bilingualSegments(),
            format: format,
            suggestedSuffix: ".bilingual.\(languageSuffix(translationTargetLabel)).\(format.fileExtension)"
        )
    }

    var defaultExportBaseName: String {
        selectedVideoURL?.deletingPathExtension().lastPathComponent ?? "subtitles"
    }

    /// Writes exactly the documents and formats picked in the export sheet.
    /// A single document in a single format keeps the plain base name; more
    /// than one file adds identifying suffixes.
    func performExport(_ options: ExportOptions) {
        var documents: [(suffix: String, segments: [TranscriptionSegment])] = []
        if options.includeOriginal && !transcriptSegments.isEmpty {
            documents.append(("original", transcriptSegments))
        }
        let target = languageSuffix(translationTargetLabel)
        if options.includeTranslation && !translatedSegments.isEmpty {
            documents.append(("translated.\(target)", translatedSegments))
        }
        if options.includeBilingual && !transcriptSegments.isEmpty && !translatedSegments.isEmpty {
            documents.append(("bilingual.\(target)", bilingualSegments()))
        }

        let fileCount = documents.count * options.formats.count + (options.includeLog ? 1 : 0)
        guard fileCount > 0 else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(fileCount) exported file(s)."
        panel.directoryURL = lastExportDirectoryURL()

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        settings.lastExportDirectory = folder.path

        let plan = exportCoordinator.plan(
            folder: folder,
            baseName: options.baseName,
            documents: documents.map { ExportCoordinator.Document(suffix: $0.suffix, segments: $0.segments) },
            formats: options.formats,
            includeLog: options.includeLog,
            summary: currentJob?.summary
        )

        // The folder picker skips NSSavePanel's built-in replace warning, so
        // confirm before silently overwriting anything that already exists.
        let existing = plan.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty, !confirmReplacingExistingFiles(existing.map { $0.lastPathComponent }) {
            return
        }

        do {
            for entry in plan.subtitleWrites {
                try SubtitleWriter.write(segments: entry.segments, format: entry.format, to: entry.url)
            }
            if let logURL = plan.logURL {
                try log.write(to: logURL, atomically: true, encoding: .utf8)
            }
            appendLog("Exported \(fileCount) file(s) to \(folder.path(percentEncoded: false)).")
        } catch {
            appendLog("Export failed: \(error.localizedDescription)")
            presentExportError("Export failed: \(error.localizedDescription)")
        }
    }

    /// Path separators in the base name would silently redirect (and usually
    /// fail) the writes.
    private func confirmReplacingExistingFiles(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText =
            names.count == 1
            ? "Replace \"\(names[0])\"?"
            : "Replace \(names.count) existing files?"
        alert.informativeText = "The chosen folder already contains \(names.joined(separator: ", ")). Exporting will replace the existing file(s)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Export problems must be visible without opening the Log tab. Other
    /// callers (e.g. the subtitle load panel) pass their own title so the
    /// dialog doesn't claim to be about an export that never happened.
    private func presentExportError(_ message: String, title: String = "Export Failed") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    /// SRT/VTT exports lead with the intro-summary cue when the job has one;
    /// plain-text, Markdown, and JSON exports are left untouched.
    private func applyingIntro(
        _ segments: [TranscriptionSegment],
        format: SubtitleExportFormat,
        job: TranscriptionJob?
    ) -> [TranscriptionSegment] {
        ExportCoordinator.applyingIntro(segments, format: format, summary: job?.summary)
    }

    private func bilingualSegments() -> [TranscriptionSegment] {
        bilingualSegments(transcript: transcriptSegments, translated: translatedSegments)
    }

    private func bilingualSegments(
        transcript: [TranscriptionSegment],
        translated: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        ExportCoordinator.bilingualSegments(transcript: transcript, translated: translated)
    }

    // MARK: - Burn-in

    enum BurnInDocument: String, CaseIterable, Identifiable {
        case original
        case translation
        case bilingual

        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "Original transcript"
            case .translation: return "Translation"
            case .bilingual: return "Bilingual captions"
            }
        }
    }

    struct BurnInRequest {
        let document: BurnInDocument
        let textSize: BurnInService.TextSize
        let output: URL
    }

    func startBurnIn(_ request: BurnInRequest) {
        guard let job = currentJob, canBurnIn else { return }
        let jobID = job.id

        let segments: [TranscriptionSegment]
        switch request.document {
        case .original:
            segments = applyingIntro(job.transcriptSegments, format: .srt, job: job)
        case .translation:
            segments = applyingIntro(job.translatedSegments, format: .srt, job: job)
        case .bilingual:
            segments = applyingIntro(
                bilingualSegments(transcript: job.transcriptSegments, translated: job.translatedSegments),
                format: .srt,
                job: job
            )
        }
        guard !segments.isEmpty else { return }

        // Restore whichever completed state the job had before burn-in.
        let restoredStatus: JobStatus =
            job.translatedSegments.isEmpty
            ? .transcriptionComplete
            : .translationComplete

        updateJob(jobID) { job in
            job.status = .burningIn
            job.progress = JobProgress(stage: .burningIn, detail: "Starting ffmpeg.", fraction: 0)
            job.log += "Burning \(request.document.label.lowercased()) into \(request.output.lastPathComponent).\n"
        }

        // Burn-in is the other heavyweight local consumer, so it takes the
        // GPU slot.
        gpuJobID = jobID
        updateProcessingActivity()
        gpuTask = Task {
            do {
                let duration = await Self.assetDurationSeconds(for: job.sourceURL)
                try await burnInService.burnIn(
                    source: job.sourceURL,
                    segments: segments,
                    textSize: request.textSize,
                    output: request.output,
                    durationSeconds: duration
                ) { [weak self] fraction, detail in
                    self?.updateJob(jobID, debouncePersist: true) { job in
                        job.progress = JobProgress(stage: .burningIn, detail: detail, fraction: fraction)
                    }
                }
                updateJob(jobID) { job in
                    job.status = restoredStatus
                    job.progress = JobProgress(stage: .complete, detail: "Burned-in video saved.", fraction: 1)
                    job.log += "Saved burned-in video to \(request.output.path(percentEncoded: false)).\n"
                }
                notifyJobFinished(jobID)
            } catch is CancellationError {
                updateJob(jobID) { job in
                    job.status = restoredStatus
                    job.progress = JobProgress(stage: .canceled, detail: "Burn-in canceled.", fraction: nil)
                    job.log += "Burn-in canceled; partial output deleted.\n"
                }
            } catch {
                // Burn-in failure does not invalidate the finished transcript
                // or translation — restore the completed status, log loudly.
                updateJob(jobID) { job in
                    job.status = restoredStatus
                    job.progress = JobProgress(stage: .failed, detail: "Burn-in failed: \(error.localizedDescription)", fraction: nil, failedStage: .burningIn)
                    job.log += "Burn-in failed: \(error.localizedDescription)\n"
                }
                presentExportError("Burn-in failed: \(error.localizedDescription)")
            }
            gpuTask = nil
            gpuJobID = nil
            processQueue()
        }
    }

    private nonisolated static func assetDurationSeconds(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        return duration.seconds.isFinite ? duration.seconds : 0
    }

    // MARK: - Subtitle import

    /// Scans each job's folder for subtitle sidecars and adopts what it finds.
    /// Jobs are already in the sidebar by now; scanning and parsing happen off
    /// the main actor so a large batch add stays responsive.
    private func adoptSidecars(for ids: [UUID]) {
        let requests: [(id: UUID, url: URL, source: String, target: String)] = ids.compactMap { id in
            guard let job = self.job(withID: id) else { return nil }
            let resolved = job.settings.applying(job.overrides)
            return (id, job.sourceURL, resolved.sourceLanguage, resolved.translationTargetLanguage)
        }
        guard !requests.isEmpty else { return }
        subtitleScanPendingIDs.formUnion(requests.map(\.id))

        // An n-file add of one folder listed that folder n times; the listing
        // is per folder, so do it once and match every video against it.
        let byFolder = Dictionary(grouping: requests, by: { $0.url.deletingLastPathComponent() })

        Task { [weak self] in
            for (folder, folderRequests) in byFolder {
                // SubtitleImporter is nonisolated, so this hops off the main
                // actor for the directory listing and the parse.
                let candidates = await Task.detached { SubtitleImporter.folderContents(of: folder) }.value
                for request in folderRequests {
                    let result = await Task.detached {
                        SubtitleImporter.importSidecars(
                            mediaURL: request.url,
                            candidates: candidates,
                            sourceLanguage: request.source,
                            translationTargetLanguage: request.target
                        )
                    }.value
                    guard let self else { return }
                    // Applied as it lands: holding the whole batch back until
                    // the last scan finished froze the queue with every job
                    // hidden from the sidebar and no sign of why.
                    self.applyAdoption(id: request.id, result: result)
                }
            }
        }
    }

    private func applyAdoption(id: UUID, result: SubtitleImporter.Result) {
        let translationReady = settings.isTranslationReady
        subtitleScanPendingIDs.remove(id)
        // The job leaves the pending set either way, so the queue must be
        // pumped even when nothing is adopted.
        defer { processQueue() }
        guard result.transcript != nil || result.translation != nil || !result.logLines.isEmpty else { return }
        // Adoption may only land on a job nothing has touched since the
        // scan began. Liveness alone is not enough: a hand-started run
        // (canStartSelectedJob/canTranscribe don't consult the pending
        // set) that completes or fails during the scan window leaves the
        // job neither active nor running, and adopting then replaces a
        // real transcript — or a failure — with the sidecar. `.idle` and
        // `.queued` are the only states an untouched job can be in.
        // Empty slots are checked too because an explicit Load Subtitles…
        // onto a queued job leaves it queued, so its status alone cannot
        // tell the two apart.
        guard let current = self.job(withID: id),
            current.status == .idle || current.status == .queued,
            !isJobActive(id),
            current.transcriptSegments.isEmpty,
            current.translatedSegments.isEmpty
        else { return }
        updateJob(id) { job in
            for line in result.logLines {
                job.log += line + "\n"
            }
            // A job auto-started or ingested by a watch folder is .queued.
            // PipelineScheduler only ever picks .queued jobs (both slots),
            // so clearing that status here would drop the job out of the
            // queue and it would never translate. Adopting a transcript
            // just moves it from the GPU slot's filter to the translation
            // slot's — hasTranscript is now true.
            let wasQueued = job.status == .queued
            if let transcript = result.transcript {
                job.transcriptSegments = transcript.segments
                job.importedTranscriptSource = transcript.source
                // Nothing ran, so the transcription clock stays unset.
                job.progress = JobProgress(stage: .complete, detail: "Loaded existing subtitles.", fraction: 1)
                job.status = wasQueued && translationReady ? .queued : .transcriptionComplete
            }
            // Second guard on the same invariant SubtitleImporter enforces:
            // a translation adopted without a transcript would be silently
            // discarded by the ASR run that the empty transcript triggers.
            if let translation = result.translation, !job.transcriptSegments.isEmpty {
                let aligned = TranslationReconciliation.alignedTranslations(translation.segments, to: job.transcriptSegments)
                guard aligned.count == translation.segments.count else {
                    job.log += "Could not pair \(translation.source.fileName) with the transcript: cue timings differ or are ambiguous. The file was left unchanged.\n"
                    return
                }
                job.translatedSegments = aligned
                job.importedTranslationSource = translation.source
                // Both slots filled: there is no work left, so leave the
                // queue rather than sit there waiting to be re-translated.
                job.status = .translationComplete
            }
        }
    }

    struct SubtitleLoadRequest: Identifiable {
        let id: UUID
        let document: SubtitleImporter.Document
        let jobID: UUID?
        let sourcePath: String?
        let updatedAt: Date?

        init(id: UUID, document: SubtitleImporter.Document, job: TranscriptionJob? = nil) {
            self.id = id
            self.document = document
            jobID = job?.id
            sourcePath = job?.sourcePath
            updatedAt = job?.updatedAt
        }
    }

    var canLoadSubtitles: Bool {
        currentJob != nil && !isSelectedJobRunning && !isReadingSubtitleFile && !isApplyingSubtitleLoad
    }

    /// A translation with no transcript is a state the rest of the app cannot
    /// represent — bilingual export and canTranslate both require one.
    var canLoadTranslationSubtitles: Bool {
        canLoadSubtitles && !transcriptSegments.isEmpty
    }

    func canApplySubtitleLoad(_ request: SubtitleLoadRequest, to slot: SubtitleSidecarScanner.Slot) -> Bool {
        guard let id = request.jobID, id == selectedJobID,
            let job = self.job(withID: id), job.sourcePath == request.sourcePath,
            job.updatedAt == request.updatedAt, !job.status.isRunning, !isJobActive(id)
        else { return false }
        return slot == .transcript || !job.transcriptSegments.isEmpty
    }

    func presentSubtitleLoadPanel() {
        guard canLoadSubtitles, let target = currentJob else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleSidecarScanner.supportedExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .plainText)
        }
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose an SRT or WebVTT subtitle file."
        panel.directoryURL = selectedVideoURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { [weak self] in
            await self?.loadSubtitleFile(at: url, for: target)
        }
    }

    func loadSubtitleFile(
        at url: URL, for target: TranscriptionJob,
        reader: @escaping @Sendable (URL) throws -> SubtitleImporter.Document = { try SubtitleImporter.importFile(at: $0, backingUp: false) }
    ) async {
        guard !isReadingSubtitleFile else { return }
        isReadingSubtitleFile = true
        defer { isReadingSubtitleFile = false }
        do {
            // Unlike auto-detect, this was an explicit request, so a failure
            // gets a dialog rather than a quiet log line. No backup yet: the
            // slot picker below can still be cancelled, and a cancelled load
            // must not leave a .bak beside the user's file.
            let document = try await Task.detached(priority: .userInitiated) { try reader(url) }.value
            subtitleLoadRequest = SubtitleLoadRequest(id: UUID(), document: document, job: target)
        } catch {
            presentExportError(
                "Could not read \(url.lastPathComponent): \(error.localizedDescription)",
                title: "Could Not Load Subtitles"
            )
        }
    }

    func applySubtitleLoad(
        _ request: SubtitleLoadRequest, to slot: SubtitleSidecarScanner.Slot,
        beforeBackup: @escaping @Sendable () -> Void = {}
    ) async {
        guard !isApplyingSubtitleLoad, canApplySubtitleLoad(request, to: slot), let id = request.jobID,
            let job = self.job(withID: id)
        else { return }
        let segments: [TranscriptionSegment]
        if slot == .translation {
            segments = TranslationReconciliation.alignedTranslations(request.document.segments, to: job.transcriptSegments)
            guard segments.count == request.document.segments.count else {
                presentExportError("The translation's cue timings do not match this transcript unambiguously. The file has not been changed.", title: "Could Not Pair Subtitles")
                return
            }
        } else {
            segments = request.document.segments
        }
        let existing = slot == .transcript ? job.transcriptSegments : job.translatedSegments
        if !existing.isEmpty, !confirmReplacingSegments(slot: slot) { return }
        // Both confirmation and disk I/O can let the queue or selection move.
        // Keep the sheet busy, perform the backup off-main, then revalidate.
        guard canApplySubtitleLoad(request, to: slot) else { return }
        isApplyingSubtitleLoad = true
        defer { isApplyingSubtitleLoad = false }
        let document = request.document
        let preparedSource = await Task.detached(priority: .userInitiated) { () -> ImportedSubtitleSource? in
            beforeBackup()
            var source = document.source
            guard source.matchesFileOnDisk() else { return nil }
            if !source.didBackup { source.didBackup = SubtitleImporter.backUpOriginal(at: source.url) }
            guard source.matchesFileOnDisk() else { return nil }
            return source
        }.value
        guard let source = preparedSource, canApplySubtitleLoad(request, to: slot) else { return }
        // A queued write for the slot being replaced would otherwise fire at
        // the newly loaded file moments later, rewriting it with renumbered
        // ids and normalized timestamps without the user editing anything.
        cancelSubtitleSync(jobID: id, slot: slot)
        if slot == .transcript { cancelSubtitleSync(jobID: id, slot: .translation) }
        // Mirrors applyAdoption: a .queued job must stay .queued when
        // translation is configured, or PipelineScheduler.nextTranslationJob
        // (which only checks status/hasTranscript, not readiness) would pick
        // it up and fail immediately with no translation host to talk to.
        let translationReady = settings.isTranslationReady
        updateJob(id) { job in
            switch slot {
            case .transcript:
                job.transcriptSegments = segments
                job.translatedSegments = []
                job.partialTranslatedSegments = []
                job.partialTranscriptSegments = []
                job.importedTranslationSource = nil
                job.summary = nil
                job.transcriptionResumeThrough = 0
                job.importedTranscriptSource = source
                let wasQueued = job.status == .queued
                if wasQueued {
                    job.status = translationReady ? .queued : .transcriptionComplete
                } else {
                    job.status = .transcriptionComplete
                }
                job.progress = JobProgress(stage: .complete, detail: "Loaded existing subtitles.", fraction: 1)
            case .translation:
                job.translatedSegments = segments
                job.importedTranslationSource = source
                job.status = .translationComplete
            }
            job.log += "Loaded subtitles from \(document.source.fileName) (\(document.segments.count) cues).\n"
        }
        subtitleLoadRequest = nil
        processQueue()
    }

    private func confirmReplacingSegments(slot: SubtitleSidecarScanner.Slot) -> Bool {
        let alert = NSAlert()
        alert.messageText = slot == .transcript ? "Replace the Transcript?" : "Replace the Translation?"
        alert.informativeText = "The segments currently in this tab will be replaced by the subtitle file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Imported subtitle sync

    private typealias SubtitleSyncKey = SubtitleFileWriter.Key

    /// Edits are written back on a debounce so a Replace All firing hundreds of
    /// edits produces one write, not hundreds.
    private static let subtitleSyncDebounce: TimeInterval = 1.5

    private func scheduleSubtitleSync(jobID: UUID, slot: SubtitleSidecarScanner.Slot) {
        let key = SubtitleSyncKey(jobID: jobID, slot: slot)
        subtitleSyncWorkItems[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.subtitleSyncWorkItems[key] = nil
            self?.writeBackImportedSubtitles(jobID: jobID, slot: slot)
        }
        subtitleSyncWorkItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.subtitleSyncDebounce, execute: item)
    }

    /// Waits for accepted writes on quit and at explicit durability barriers.
    func flushSubtitleSync() {
        enqueuePendingSubtitleSync()
        for result in subtitleFileWriter.flush() { applySubtitleWrite(result) }
    }

    private func enqueuePendingSubtitleSync() {
        let pending = subtitleSyncWorkItems
        subtitleSyncWorkItems.removeAll()
        for (key, item) in pending {
            item.cancel()
            writeBackImportedSubtitles(jobID: key.jobID, slot: key.slot)
        }
    }

    /// Drops a queued write so it cannot fire after the link it was made for
    /// is gone.
    private func cancelSubtitleSync(jobID: UUID, slot: SubtitleSidecarScanner.Slot) {
        subtitleSyncWorkItems.removeValue(forKey: SubtitleSyncKey(jobID: jobID, slot: slot))?.cancel()
        subtitleWriteRequests.removeValue(forKey: SubtitleSyncKey(jobID: jobID, slot: slot))?.cancellation.cancel()
    }

    func unlinkImportedSubtitles(slot: SubtitleSidecarScanner.Slot, jobID: UUID? = nil) {
        guard let id = jobID ?? selectedJobID else { return }
        cancelSubtitleSync(jobID: id, slot: slot)
        updateJob(id) { job in
            let name = job.importedSource(for: slot)?.fileName
            job.setImportedSource(nil, for: slot)
            if let name {
                job.log += "Stopped syncing edits to \(name).\n"
            }
        }
    }

    private func writeBackImportedSubtitles(jobID: UUID, slot: SubtitleSidecarScanner.Slot) {
        guard let job = self.job(withID: jobID),
            let source = job.importedSource(for: slot), !source.syncPaused
        else { return }
        let segments = slot == .transcript ? job.transcriptSegments : job.translatedSegments
        guard !segments.isEmpty else { return }
        let key = SubtitleSyncKey(jobID: jobID, slot: slot)
        let request = SubtitleFileWriter.Request(key: key, source: source, segments: segments)
        subtitleWriteRequests[key]?.cancellation.cancel()
        subtitleWriteRequests[key] = request
        subtitleFileWriter.write(request) { [weak self] result in
            Task { @MainActor [weak self] in self?.applySubtitleWrite(result) }
        }
    }

    private func applySubtitleWrite(_ result: SubtitleFileWriter.Completion) {
        let key = result.request.key
        guard subtitleWriteRequests[key]?.id == result.request.id else { return }
        subtitleWriteRequests.removeValue(forKey: key)
        guard let source = job(withID: key.jobID)?.importedSource(for: key.slot),
            source.path == result.request.source.path,
            source.importedAt == result.request.source.importedAt
        else { return }
        updateJob(key.jobID, debouncePersist: true) { job in
            job.setImportedSource(result.source, for: key.slot)
            if let line = result.logLine { job.log += line + "\n" }
        }
    }

    // MARK: - Sidecar auto-export

    /// Writes SRT files next to the source video when a job finishes, named
    /// with language codes (video.vi.srt) so media players auto-load them.
    private func autoExportSidecars(for id: UUID) {
        guard let job = self.job(withID: id),
            settings.autoExportSidecar || job.origin == .watchFolder
        else { return }

        // Follow the document choices remembered by the export sheet.
        let defaults = UserDefaults.standard
        let includeOriginal = defaults.object(forKey: "exportIncludeOriginal") as? Bool ?? true
        let includeTranslation = defaults.object(forKey: "exportIncludeTranslation") as? Bool ?? true
        let includeBilingual = defaults.object(forKey: "exportIncludeBilingual") as? Bool ?? false

        let protectedPaths = Set(
            [job.importedTranscriptSource, job.importedTranslationSource]
                .compactMap { $0?.url.standardizedFileURL.path }
        )

        do {
            let written = try exportCoordinator.writeSidecars(
                job: job,
                options: ExportCoordinator.SidecarOptions(
                    includeOriginal: includeOriginal,
                    includeTranslation: includeTranslation,
                    includeBilingual: includeBilingual,
                    protectedPaths: protectedPaths
                )
            )
            if !written.isEmpty {
                appendLog("Saved sidecar subtitles next to the video: \(written.joined(separator: ", ")).", to: id)
            }
        } catch {
            appendLog("Sidecar export failed: \(error.localizedDescription)", to: id)
        }
    }

    /// ISO-639-1 code for sidecar file names. Transcription languages are
    /// already codes ("ja"); translation targets are names ("Vietnamese").
    func exportLog() {
        guard let selectedVideoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = lastExportDirectoryURL()
        panel.nameFieldStringValue = selectedVideoURL.deletingPathExtension().lastPathComponent + ".log.txt"
        if panel.runModal() == .OK, let destination = panel.url {
            settings.lastExportDirectory = destination.deletingLastPathComponent().path
            do {
                try log.write(to: destination, atomically: true, encoding: .utf8)
                appendLog("Exported log to \(destination.path(percentEncoded: false)).")
            } catch {
                appendLog("Export log failed: \(error.localizedDescription)")
                presentExportError("Could not save the log: \(error.localizedDescription)")
            }
        }
    }

    func updateTranscriptSegment(_ segment: TranscriptionSegment, text: String) {
        updateSegment(segment, text: text, keyPath: \.transcriptSegments)
    }

    func updateSubtitleSegments(_ edited: [TranscriptionSegment], slot: SubtitleSidecarScanner.Slot) {
        guard let id = selectedJobID, let index = index(of: id), !edited.isEmpty else { return }
        let texts = Dictionary(edited.map { ($0.id, $0.text) }, uniquingKeysWith: { _, latest in latest })
        var job = jobs[index]
        let path: WritableKeyPath<TranscriptionJob, [TranscriptionSegment]> =
            slot == .transcript ? \.transcriptSegments : \.translatedSegments
        var changed = false
        for cueIndex in job[keyPath: path].indices {
            guard let text = texts[job[keyPath: path][cueIndex].id],
                text != job[keyPath: path][cueIndex].text else { continue }
            job[keyPath: path][cueIndex].text = text
            changed = true
        }
        guard changed else { return }
        job.updatedAt = Date()
        jobs[index] = job
        jobRepository.save(job, debounced: true)
        if let source = job.importedSource(for: slot), !source.syncPaused {
            scheduleSubtitleSync(jobID: id, slot: slot)
        }
    }

    func updateTranslatedSegment(_ segment: TranscriptionSegment, text: String) {
        updateSegment(segment, text: text, keyPath: \.translatedSegments)
    }

    /// Warnings for the segments a tab displays, memoised per job and slot
    /// so a streaming run does not re-evaluate the whole transcript on every
    /// progress tick.
    func qualityWarnings(for segments: [TranscriptionSegment], slot: SubtitleSidecarScanner.Slot) -> SubtitleWarnings {
        guard let jobID = selectedJobID, !segments.isEmpty else { return .empty }
        return warningCache.warnings(for: segments, key: SubtitleWarningCache.Key(jobID: jobID, slot: slot))
    }

    /// Change key for the player overlay and highlight. Every mutation that
    /// reaches a job goes through updateJob, which stamps updatedAt, and the
    /// counts catch the direct clears at run start, so this is a superset of
    /// "the displayed segments changed" without comparing the arrays on
    /// every render.
    struct OverlayRevision: Equatable {
        let jobID: UUID?
        let updatedAt: Date?
        let transcriptCount: Int
        let translationCount: Int
    }

    var overlayRevision: OverlayRevision {
        let job = currentJob
        return OverlayRevision(
            jobID: job?.id,
            updatedAt: job?.updatedAt,
            transcriptCount: displayTranscriptSegments.count,
            translationCount: displayTranslatedSegments.count
        )
    }

    private func finishTranscription(_ result: TranscriptionResult, summary: String?, for id: UUID) {
        updateJob(id) { job in
            job.transcriptSegments = result.segments
            // The cleaned transcript supersedes the streamed preview.
            job.partialTranscriptSegments = []
            job.transcriptionResumeThrough = 0
            job.translatedSegments = []
            job.summary = summary
            job.status = .transcriptionComplete
            job.progress = JobProgress(stage: .complete, detail: "Transcription complete.", fraction: 1)
            job.log += "Transcription finished via \(result.backend). Produced \(result.segments.count) subtitle segments.\n"
        }
    }

    private func finishTranslation(_ segments: [TranscriptionSegment], summary: String?, for id: UUID) {
        updateJob(id) { job in
            job.translatedSegments = segments
            job.partialTranslatedSegments = []
            job.summary = summary
            job.status = .translationComplete
            job.progress = JobProgress(stage: .complete, detail: "Translation complete.", fraction: 1)
            job.log += "Translation finished. Produced \(segments.count) translated segments.\n"
        }
        autoExportSidecars(for: id)
        recordWatchOutcome(for: id, success: true)
    }

    /// Stamps finishedAt, rewrites the completion detail with the total
    /// duration, and logs the phase breakdown (with overlap when the phases
    /// ran concurrently).
    private func recordCompletionTiming(for id: UUID) {
        updateJob(id) { job in
            let finished = Date()
            job.finishedAt = finished
            // A translation-only run has no transcription phase, so its clock
            // starts when the translation did.
            guard let started = job.transcriptionStartedAt ?? job.translationStartedAt else { return }
            let total = JobTimingFormatter.format(finished.timeIntervalSince(started))
            guard !total.isEmpty else { return }
            job.progress = JobProgress(stage: .complete, detail: job.progress.detail + " Done in \(total).", fraction: 1)
            if let tStart = job.transcriptionStartedAt, let tEnd = job.transcriptionFinishedAt {
                job.log += "Transcription took \(JobTimingFormatter.format(tEnd.timeIntervalSince(tStart))).\n"
            }
            if let xStart = job.translationStartedAt {
                job.log += "Translation took \(JobTimingFormatter.format(finished.timeIntervalSince(xStart))).\n"
                if let tEnd = job.transcriptionFinishedAt, xStart < tEnd {
                    job.log += "Translation overlapped transcription by \(JobTimingFormatter.format(tEnd.timeIntervalSince(xStart))).\n"
                }
            }
            job.log += "Job finished in \(total).\n"
        }
    }

    /// Generates (or regenerates) the intro summary for the selected job on
    /// demand — for jobs that finished before the toggle was on, or to redo
    /// a summary after editing segments.
    func generateSummaryNow() {
        guard canGenerateSummary, let job = currentJob else { return }
        let useTranslation = !job.translatedSegments.isEmpty
        let segments = useTranslation ? job.translatedSegments : job.transcriptSegments
        // Old jobs summarize in the language they were actually translated to
        // (the job snapshot), not whatever the current settings say.
        let target = job.settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let language =
            useTranslation
            ? (target.isEmpty ? "English" : target)
            : "the same language as the subtitles"
        let id = job.id
        let configurations = makeSummaryConfigurations()

        let summaryDetail = job.overrides.summaryDetail ?? settings.summaryDetail
        isGeneratingSummary = true
        Task {
            do {
                let result = try await translationService.summarize(
                    segments: segments,
                    language: language,
                    primary: configurations.primary,
                    fallback: configurations.fallback,
                    detail: summaryDetail
                )
                updateJob(id) { job in
                    job.summary = result.summary
                    if result.usedFallback {
                        job.log +=
                            "The primary summary model \(configurations.primary.model) declined the content; policy fallback \(result.model) succeeded.\n"
                    }
                    job.log += "Generated intro summary with \(result.model): \(result.summary)\n"
                }
            } catch {
                appendLog("Intro summary failed: \(error.localizedDescription)", to: id)
                let alert = NSAlert()
                alert.messageText = "Could Not Write Intro Summary"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
            isGeneratingSummary = false
        }
    }

    /// Best-effort intro-summary generation: a failure logs and returns nil
    /// rather than failing a job whose transcription/translation succeeded.
    private func makeIntroSummary(
        from segments: [TranscriptionSegment],
        language: String,
        for id: UUID
    ) async -> String? {
        guard let job = self.job(withID: id) else { return nil }
        let generateSummary = job.overrides.generateSummary ?? settings.generateSummary
        guard generateSummary, !segments.isEmpty else { return nil }
        guard settings.isSummaryReady else {
            let reason = settings.modelReadinessReason(settings.resolvedSummaryModel)
            appendLog("Skipped the intro summary because \(reason).", to: id)
            return nil
        }
        let summaryDetail = job.overrides.summaryDetail ?? settings.summaryDetail
        updateJob(id, debouncePersist: true) { job in
            job.progress = JobProgress(stage: job.progress.stage, detail: "Writing intro summary.", fraction: job.progress.fraction)
        }
        let configurations = makeSummaryConfigurations()
        do {
            let result = try await translationService.summarize(
                segments: segments,
                language: language,
                primary: configurations.primary,
                fallback: configurations.fallback,
                detail: summaryDetail
            )
            if result.usedFallback {
                appendLog(
                    "The primary summary model \(configurations.primary.model) declined the content; policy fallback \(result.model) succeeded.",
                    to: id
                )
            }
            appendLog("Generated intro summary with \(result.model): \(result.summary)", to: id)
            return result.summary
        } catch {
            appendLog("Intro summary failed (job still completed): \(error.localizedDescription)", to: id)
            return nil
        }
    }

    /// Secrets + prompt matched to one explicit model. Built fresh per run;
    /// never stored on the job.
    private func makeCredentials(for model: String) -> TranslationCredentials {
        let provider = TranslationProvider.infer(from: model)
        return TranslationCredentials(
            apiKey: settings.translationAPIKey(for: provider),
            prompt: settings.translationPrompt,
            provider: provider,
            localEndpoint: settings.localTranslationEndpoint
        )
    }

    private func makeSummaryConfigurations() -> (
        primary: SummaryModelConfiguration,
        fallback: SummaryModelConfiguration?
    ) {
        let primaryModel = settings.resolvedSummaryModel
        let primary = SummaryModelConfiguration(
            model: primaryModel,
            credentials: makeCredentials(for: primaryModel)
        )
        let fallback = settings.resolvedSummaryFallbackModel.map { model in
            SummaryModelConfiguration(model: model, credentials: makeCredentials(for: model))
        }
        return (primary, fallback)
    }

    private func markCanceled(_ id: UUID) {
        updateJob(id) { job in
            job.status = .canceled
            job.progress = JobProgress(stage: .canceled, detail: "Operation canceled.", fraction: nil)
            job.log += "Operation canceled.\n"
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        updateJob(id) { job in
            let stage = job.progress.failedStage ?? job.progress.stage
            job.status = .failed
            job.progress = JobProgress(stage: .failed, detail: message, fraction: nil, failedStage: stage)
            job.log += "\(message)\n"
        }
        recordWatchOutcome(for: id, success: false)
    }

    private func updateProgress(_ progress: JobProgress, for id: UUID) {
        var composed = progress
        if progress.stage == .transcribing,
            let translated = streamingTranslationFraction[id],
            let fraction = progress.fraction
        {
            composed = JobProgress(
                stage: .transcribing,
                detail: "Transcribing \(Int(fraction * 100))% · Translated \(Int(translated * 100))%",
                fraction: fraction
            )
        }
        let line = "\(composed.stage.label): \(composed.detail)\n"
        updateJob(id, debouncePersist: true) { job in
            job.progress = composed
            // Progress ticks repeat the same detail dozens of times per
            // chunk; one line per distinct message keeps the log readable.
            if !job.log.hasSuffix(line) {
                job.log += line
            }
        }
    }

    /// Translation progress from a streaming session. While the job is still
    /// transcribing it is dropped: it must not overwrite the transcription
    /// progress bar, and the two-line detail uses the count-based fraction
    /// recorded in the driver's onPartial instead. Once the job is translating
    /// it takes the normal path, minus the completion an incremental pass
    /// reports for itself — only finishTranslation may write the terminal
    /// state, or a job still awaiting its finish pass would read "complete".
    private func recordStreamingTranslationProgress(_ update: JobProgress, for id: UUID) {
        guard self.job(withID: id)?.status == .translating else { return }
        guard update.stage != .complete || drivers[id] == nil else { return }
        updateProgress(update, for: id)
    }

    private func updatePartialTranslation(_ segments: [TranscriptionSegment], for id: UUID) {
        updateJob(id, debouncePersist: true) { job in
            job.partialTranslatedSegments = segments
            job.log += "Saved partial translation: \(segments.count) segment(s).\n"
        }
    }

    private func appendLog(_ entry: String) {
        guard let id = selectedJobID else { return }
        appendLog(entry, to: id)
    }

    private func appendLog(_ entry: String, to id: UUID) {
        updateJob(id) { job in
            job.log += "\(entry)\n"
        }
    }

    // MARK: - Notifications

    /// Posts a completion notification when the app is in the background so
    /// long runs can be left unattended.
    private func notifyJobFinished(_ id: UUID) {
        guard let job = self.job(withID: id) else { return }
        notify(title: job.title, body: job.status.label)
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter requires a real app bundle, and there is
        // no point notifying while the user is looking at the app.
        guard Bundle.main.bundleIdentifier != nil,
            Bundle.main.bundleURL.pathExtension == "app",
            !NSApp.isActive
        else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }

    private func updateJob(_ id: UUID, debouncePersist: Bool = false, mutate: (inout TranscriptionJob) -> Void) {
        guard let index = index(of: id) else {
            return
        }
        mutate(&jobs[index])
        jobs[index].updatedAt = Date()
        // String.count walks grapheme clusters; the UTF-8 length is O(1) and
        // never smaller, so it is an exact pre-filter for the common case.
        if jobs[index].log.utf8.count > Self.maxLogLength, jobs[index].log.count > Self.maxLogLength {
            let tail = jobs[index].log.suffix(Self.maxLogLength * 3 / 4)
            jobs[index].log = "… earlier log trimmed …\n\(tail)"
        }
        if debouncePersist {
            jobRepository.save(jobs[index], debounced: true)
        } else {
            jobRepository.save(jobs[index])
        }
    }

    /// Applies the same user action to many jobs while publishing one new
    /// array value. The returned ids are the jobs that actually changed.
    @discardableResult
    private func updateJobs(
        _ ids: Set<UUID>,
        where shouldUpdate: (TranscriptionJob) -> Bool,
        mutate: (inout TranscriptionJob) -> Void
    ) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var updatedJobs = jobs
        var snapshots: [TranscriptionJob] = []
        var changedIDs = Set<UUID>()
        changedIDs.reserveCapacity(ids.count)
        let now = Date()

        for index in updatedJobs.indices
        where ids.contains(updatedJobs[index].id) && shouldUpdate(updatedJobs[index]) {
            mutate(&updatedJobs[index])
            updatedJobs[index].updatedAt = now
            snapshots.append(updatedJobs[index])
            changedIDs.insert(updatedJobs[index].id)
        }

        guard !snapshots.isEmpty else { return [] }
        jobs = updatedJobs
        jobRepository.save(snapshots)
        return changedIDs
    }

    private func updateSegment(
        _ segment: TranscriptionSegment,
        text: String,
        keyPath: WritableKeyPath<TranscriptionJob, [TranscriptionSegment]>
    ) {
        // A mutation that changes nothing must not schedule a write: an
        // untouched file should stay untouched, byte for byte.
        guard let id = selectedJobID,
            let job = self.job(withID: id),
            let existing = job[keyPath: keyPath].first(where: { $0.id == segment.id }),
            existing.text != text
        else { return }
        updateJob(id, debouncePersist: true) { job in
            guard let index = job[keyPath: keyPath].firstIndex(where: { $0.id == segment.id }) else {
                return
            }
            job[keyPath: keyPath][index].text = text
        }
        let slot: SubtitleSidecarScanner.Slot = keyPath == \TranscriptionJob.transcriptSegments ? .transcript : .translation
        if let source = self.job(withID: id)?.importedSource(for: slot), !source.syncPaused {
            scheduleSubtitleSync(jobID: id, slot: slot)
        }
    }

    private func export(segments: [TranscriptionSegment], format: SubtitleExportFormat, suggestedSuffix: String) {
        guard let selectedVideoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType(for: format)]
        panel.allowsOtherFileTypes = false
        panel.directoryURL = lastExportDirectoryURL()
        panel.nameFieldStringValue = selectedVideoURL.deletingPathExtension().lastPathComponent + suggestedSuffix
        if panel.runModal() == .OK, let destination = panel.url {
            let exportURL = normalizedExportURL(destination, expectedExtension: format.fileExtension)
            settings.lastExportDirectory = exportURL.deletingLastPathComponent().path
            do {
                try SubtitleWriter.write(
                    segments: applyingIntro(segments, format: format, job: currentJob),
                    format: format,
                    to: exportURL
                )
                appendLog("Exported subtitles to \(exportURL.path(percentEncoded: false)).")
            } catch {
                appendLog("Export failed: \(error.localizedDescription)")
                presentExportError("Could not save the subtitles: \(error.localizedDescription)")
            }
        }
    }

    private func contentType(for format: SubtitleExportFormat) -> UTType {
        switch format {
        case .srt:
            return UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
        case .vtt:
            return UTType(filenameExtension: "vtt", conformingTo: .plainText) ?? .plainText
        case .text:
            return .plainText
        case .markdown:
            return UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .json:
            return .json
        }
    }

    private func normalizedExportURL(_ url: URL, expectedExtension: String) -> URL {
        ExportCoordinator.normalizedURL(url, expectedExtension: expectedExtension)
    }

    private func lastExportDirectoryURL() -> URL? {
        let path = settings.lastExportDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private func languageSuffix(_ language: String) -> String {
        ExportCoordinator.languageSuffix(language)
    }

    private func persistJob(_ id: UUID) {
        guard let job = self.job(withID: id) else { return }
        jobRepository.save(job)
    }
}
