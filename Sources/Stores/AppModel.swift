import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettingsStore()
    @Published var jobs: [TranscriptionJob] = []
    @Published var selectedJobID: UUID?
    @Published var diagnostics: [EnvironmentDiagnostic] = []
    @Published var isRunningDiagnostics = false
    @Published var isShowingExportSheet = false
    @Published var isShowingSetupGuide = false
    @Published var overridesEditorJobID: UUID?
    @Published var isGeneratingSummary = false
    @Published var isShowingBurnInSheet = false
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
    let playerController = PlayerController()
    private var didProcessQueuedJob = false
    private var dirtyJobIDs: Set<UUID> = []
    /// Keeps very chatty jobs from growing without bound in memory and on disk.
    private static let maxLogLength = 200_000

    private let transcriptionService = TranscriptionService()
    private let translationService = TranslationService()
    private let diagnosticsService = EnvironmentDiagnosticsService()
    private let jobStore = JobStore()
    private let burnInService = BurnInService()
    /// One service per enabled watch folder, keyed by the folder's id and
    /// reconciled against `settings.watchFolders` by syncWatchFolders().
    private(set) var watchServices: [UUID: WatchFolderService] = [:]
    private let watchLedger = WatchFolderLedger()
    /// The pipeline runs as two independently serial slots: the GPU slot
    /// (transcription and burn-in — the heavyweight local consumers) and the
    /// translation slot (network-bound). They may run at the same time on
    /// different jobs, which is what lets job B transcribe while job A is
    /// still translating.
    private var gpuTask: Task<Void, Never>?
    private(set) var gpuJobID: UUID?
    private var translationTask: Task<Void, Never>?
    private(set) var translationJobID: UUID?
    /// Translation work items that run ahead of queued jobs, in FIFO order.
    private var translationWorkQueue: [(jobID: UUID, work: @MainActor () async -> Void)] = []
    private var cancellables = Set<AnyCancellable>()
    private var persistTask: Task<Void, Never>?
    /// Held while any job is running so overnight batches survive idle sleep
    /// and App Nap (spec §2.7). Display sleep stays allowed.
    private var processingActivity: NSObjectProtocol?

    private func updateProcessingActivity() {
        if isProcessing {
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

    init() {
        isPlayerVisible = UserDefaults.standard.object(forKey: "isPlayerVisible") as? Bool ?? true
        jobs = jobStore.loadJobs().sorted { $0.orderIndex < $1.orderIndex }
        selectedJobID = jobs.first?.id
        // `settings` is a nested ObservableObject; changes to its fields do not
        // fire AppModel's objectWillChange on their own, so forward them.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Debounced edits and queued background writes must reach the disk
        // before the process exits, or the last ~400ms of changes are lost.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.flushPendingWork() }
            .store(in: &cancellables)
        // Diagnostics classify probes as required/optional based on the
        // selected backend, so a backend switch must re-run them or the
        // pill keeps a stale verdict. dropFirst skips the value replayed
        // on subscription (the runDiagnostics() below covers launch); the
        // sink fires during willSet, but runDiagnostics reads the setting
        // inside a Task, which runs after the assignment lands.
        settings.$whisperBackend
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
            settings.$openAIModel.dropFirst().removeDuplicates().map { _ in () },
            settings.$localTranslationEndpoint.dropFirst().removeDuplicates().map { _ in () },
            settings.$openAIAPIKey.dropFirst().removeDuplicates().map { _ in () },
            settings.$anthropicAPIKey.dropFirst().removeDuplicates().map { _ in () },
            settings.$googleAPIKey.dropFirst().removeDuplicates().map { _ in () }
        )
        .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.runDiagnostics() }
        .store(in: &cancellables)
        runDiagnostics()
        syncWatchFolders()
    }

    /// Writes every pending job mutation to disk synchronously. Called on
    /// app termination.
    func flushPendingWork() {
        persistTask?.cancel()
        persistTask = nil
        flushDirtyJobs()
        jobStore.flush()
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
            && settings.isTranslationReady
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
        jobs.contains { jobNeedsWork($0) }
    }

    var queuedJobCount: Int {
        jobs.filter { $0.status == .queued }.count
    }

    var translationTargetLabel: String {
        // For a not-yet-translated job, honor its override so the action
        // button names the language the run will actually produce.
        let target = translatedSegments.isEmpty
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
        return jobs.firstIndex { $0.id == selectedJobID }
    }

    func selectJob(_ id: UUID?) {
        selectedJobID = id
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
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more video or audio files to add as jobs."
        if panel.runModal() == .OK {
            addVideos(urls: panel.urls)
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

    /// Adds videos as separate jobs. Used by the file picker and drag-and-drop.
    func addVideos(urls: [URL]) {
        let batchIndices = QueueOrdering.indicesForBatchAdd(count: urls.count, existing: jobs.map(\.orderIndex))
        let newJobs = zip(urls, batchIndices).map { url, orderIndex in
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.log = "Selected \(url.path(percentEncoded: false)).\n"
            job.orderIndex = orderIndex
            return job
        }
        guard !newJobs.isEmpty else { return }
        jobs.insert(contentsOf: newJobs, at: 0)
        selectedJobID = newJobs.first?.id
        for job in newJobs {
            persistJob(job.id)
        }
        if settings.autoStartAddedJobs {
            for job in newJobs {
                enqueueJob(job.id)
            }
        }
    }

    func setOverrides(_ overrides: JobSettingsOverrides, for id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.status.isRunning else { return }
        updateJob(id) { job in
            job.overrides = overrides
            job.log += overrides.isEmpty
                ? "Cleared job-specific settings.\n"
                : "Set job-specific settings.\n"
        }
    }

    func deleteJob(_ id: UUID) {
        // The running job cannot be deleted; cancel it first.
        guard !isJobActive(id) else { return }
        jobs.removeAll { $0.id == id }
        dirtyJobIDs.remove(id)
        if selectedJobID == id {
            selectedJobID = jobs.first?.id
        }
        jobStore.deleteJob(id)
    }

    func runDiagnostics() {
        isRunningDiagnostics = true
        Task {
            diagnostics = await diagnosticsService.run(
                translationAPIKey: settings.currentTranslationAPIKey,
                translationProvider: settings.currentTranslationProvider,
                selectedBackend: settings.whisperBackend
            )
            isRunningDiagnostics = false
            if !didOfferSetupGuide {
                didOfferSetupGuide = true
                // Only a required diagnostic reports .failed (the selected
                // Python backend's missing module); missing optional tools
                // are warnings, so a fresh install never auto-opens this.
                if diagnostics.contains(where: { $0.state == .failed }) {
                    isShowingSetupGuide = true
                }
            }
        }
    }

    // MARK: - Queue

    /// Queues every job that still needs work and starts processing.
    func startAllPendingJobs() {
        queuePaused = false
        for job in jobs where jobNeedsWork(job) && job.status != .queued {
            updateJob(job.id) { job in
                job.status = .queued
                job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            }
        }
        processQueue()
    }

    /// Adds one job to the queue (or starts it right away when nothing is running).
    func enqueueJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.status.isRunning else { return }
        queuePaused = false
        updateJob(id) { job in
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
        }
        processQueue()
    }

    func jobNeedsWork(_ job: TranscriptionJob) -> Bool {
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
        defer { updateProcessingActivity() }
        pumpTranslation()
        pumpGPU()
        // A paused queue is not a finished queue: the old processQueue bailed
        // before the notification whenever queuePaused was set, and jobs are
        // usually still waiting.
        if !queuePaused, gpuJobID == nil, translationJobID == nil, translationWorkQueue.isEmpty, didProcessQueuedJob,
           PipelineScheduler.nextGPUJob(jobs: jobViews, gpuBusy: false, queuePaused: queuePaused) == nil,
           PipelineScheduler.nextTranslationJob(jobs: jobViews, translationBusy: false, queuePaused: queuePaused) == nil {
            didProcessQueuedJob = false
            notify(title: "WhisperDesk", body: "All queued jobs finished.")
        }
    }

    private var jobViews: [PipelineScheduler.JobView] {
        jobs.map {
            PipelineScheduler.JobView(
                id: $0.id,
                orderIndex: $0.orderIndex,
                status: $0.status,
                hasTranscript: !$0.transcriptSegments.isEmpty
            )
        }
    }

    private func pumpGPU() {
        guard let id = PipelineScheduler.nextGPUJob(jobs: jobViews, gpuBusy: gpuJobID != nil, queuePaused: queuePaused),
              let index = jobs.firstIndex(where: { $0.id == id })
        else { return }
        didProcessQueuedJob = true
        startTranscriptionNow(at: index, force: false)
        // If the job could not start (e.g. a guard failed), fail it instead
        // of stalling the whole queue on a stuck "queued" entry.
        if gpuJobID == nil, jobs.first(where: { $0.id == id })?.status == .queued {
            markFailed(id, message: "Could not start this job. Check the file and settings.")
            processQueue()
        }
    }

    private func pumpTranslation() {
        guard translationTask == nil else { return }
        if !translationWorkQueue.isEmpty {
            let item = translationWorkQueue.removeFirst()
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
              let index = jobs.firstIndex(where: { $0.id == id })
        else { return }
        didProcessQueuedJob = true
        startTranslationNow(at: index)
        if translationJobID == nil, jobs.first(where: { $0.id == id })?.status == .queued {
            markFailed(id, message: "Could not start this job. Check the file and settings.")
            processQueue()
        }
    }

    /// Queues work onto the translation slot ahead of any queued jobs.
    private func enqueueTranslationWork(jobID: UUID, _ work: @escaping @MainActor () async -> Void) {
        translationWorkQueue.append((jobID: jobID, work: work))
    }

    // MARK: - Watch folders

    /// Reconciles running services with the settings list: starts services
    /// for newly enabled folders, stops removed/disabled ones, restarts a
    /// folder whose path changed. Idempotent, so callers just mutate
    /// `settings.watchFolders` and call this.
    func syncWatchFolders() {
        let wanted = Dictionary(uniqueKeysWithValues: settings.watchFolders
            .filter { $0.enabled && !$0.path.isEmpty }
            .map { ($0.id, $0) })

        for (id, service) in watchServices where wanted[id] == nil {
            service.stop()
            watchServices[id] = nil
        }
        for (id, folder) in wanted {
            if let existing = watchServices[id] {
                if existing.watchedPath != folder.path {
                    existing.start(path: folder.path)
                }
            } else {
                let service = makeWatchService(folderID: id)
                // Forward the service's lastError changes so sidebar rows
                // re-render; the row itself cannot @ObservedObject an
                // Optional service.
                service.objectWillChange
                    .sink { [weak self] _ in self?.objectWillChange.send() }
                    .store(in: &cancellables)
                watchServices[id] = service
                service.start(path: folder.path)
            }
        }
        objectWillChange.send()
    }

    private func makeWatchService(folderID: UUID) -> WatchFolderService {
        let service = WatchFolderService()
        service.blockedFingerprints = { [weak self] in
            guard let self else { return [] }
            // Ledger entries plus every job's fingerprint, any status
            // (spec §2.3 rule 4): canceled or manual jobs block too.
            return self.watchLedger.fingerprints.union(self.jobs.map(\.sourceFingerprint))
        }
        service.onScanCompleted = { [weak self] folderPath, existingPaths in
            // Prune only entries under the folder that was actually scanned:
            // other folders' histories must survive untouched.
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
    private func ingestWatchFolderFiles(_ urls: [URL], folderID: UUID) {
        guard !urls.isEmpty else { return }
        // The profile is read at ingest time, so edits apply to the next
        // file without restarting the watcher.
        let profile = settings.watchFolders.first(where: { $0.id == folderID })?.profile
            ?? JobSettingsOverrides()
        for url in urls {
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.origin = .watchFolder
            job.overrides = profile
            job.orderIndex = QueueOrdering.indexForWatchAdd(existing: jobs.map(\.orderIndex))
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            job.log = "Picked up from the watch folder: \(url.path(percentEncoded: false)).\n"
            jobs.append(job)
            persistJob(job.id)
        }
        processQueue()
    }

    /// Terminal-state bookkeeping for watch jobs (spec §2.4): success and
    /// failure are recorded; cancel is not — the canceled job itself blocks
    /// re-ingest while it exists, and deleting it means "do it over".
    private func recordWatchOutcome(for id: UUID, success: Bool) {
        guard let job = jobs.first(where: { $0.id == id }), job.origin == .watchFolder else { return }
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
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        moveJobs(from: IndexSet(integer: index), to: 0)
    }

    func moveJobToBottom(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        moveJobs(from: IndexSet(integer: index), to: jobs.count)
    }

    func removeFromQueue(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .queued else { return }
        updateJob(id) { job in
            job.status = .idle
            job.progress = .idle
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
        guard let index = jobs.firstIndex(where: { $0.id == (jobID ?? selectedJobID) }) else { return }
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

        let validationMessage = settings.transcriptionValidationMessage
        if validationMessage != nil {
            settings.repairTranscriptionModelForBackend()
        }

        let currentFingerprint = TranscriptionJob.fingerprint(for: videoURL)
        let resolved = JobSettingsSnapshot(settings: settings).applying(jobs[index].overrides)
        // Per-job autoTranslate wins over the global toggle (spec §0.3).
        let autoTranslate = jobs[index].overrides.autoTranslate ?? settings.autoTranslateAfterTranscription

        if !force,
           !jobs[index].transcriptSegments.isEmpty,
           jobs[index].sourceFingerprint == currentFingerprint,
           jobs[index].settings.transcriptionIdentity == resolved.transcriptionIdentity {
            let hasTranslation = !jobs[index].translatedSegments.isEmpty
            // The run's clock starts now; transcription itself cost nothing.
            let now = Date()
            jobs[index].transcriptionStartedAt = now
            jobs[index].transcriptionFinishedAt = now
            jobs[index].status = hasTranslation ? .translationComplete : .transcriptionComplete
            jobs[index].progress = JobProgress(stage: .complete, detail: "Using existing transcript for unchanged file and settings.", fraction: 1)
            appendLog("Skipped transcription because this file and transcription settings already have a transcript.", to: jobID)
            recordWatchOutcome(for: jobID, success: true)
            // Same guard as the real completion path: auto-translating with
            // no usable provider would immediately mark this job as Failed.
            if autoTranslate && !hasTranslation && settings.isTranslationReady {
                startTranslation(jobID: jobID)
            } else {
                processQueue()
            }
            return
        }

        jobs[index].status = .transcribing
        jobs[index].progress = JobProgress(stage: .preflight, detail: "Starting transcription.", fraction: 0)
        jobs[index].translatedSegments = []
        jobs[index].partialTranslatedSegments = []
        jobs[index].transcriptionStartedAt = Date()
        jobs[index].transcriptionFinishedAt = nil
        jobs[index].translationStartedAt = nil
        jobs[index].finishedAt = nil
        jobs[index].sourceFingerprint = currentFingerprint
        jobs[index].settings = resolved
        if let validationMessage {
            jobs[index].log += "Adjusted transcription settings: \(validationMessage)\n"
        }
        appendLog("Starting transcription with \(resolved.whisperBackend.label) and model \(resolved.whisperModel).", to: jobID)

        gpuJobID = jobID
        updateProcessingActivity()
        gpuTask = Task {
            do {
                let result = try await transcriptionService.transcribe(videoURL: videoURL, settings: resolved) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
                }
                updateJob(jobID) { $0.transcriptionFinishedAt = Date() }
                let willTranslate = autoTranslate && settings.isTranslationReady
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
                    startTranslation(jobID: jobID)
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
            }
            gpuTask = nil
            gpuJobID = nil
            processQueue()
        }
    }

    func startTranslation(jobID: UUID? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == (jobID ?? selectedJobID) }),
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
        let existingTranslations = jobs[index].partialTranslatedSegments.isEmpty
            ? jobs[index].translatedSegments
            : jobs[index].partialTranslatedSegments
        let resolved = JobSettingsSnapshot(settings: settings).applying(jobs[index].overrides)
        jobs[index].status = .translating
        jobs[index].progress = JobProgress(stage: .translating, detail: "Starting translation.", fraction: 0)
        jobs[index].translationStartedAt = jobs[index].translationStartedAt ?? Date()
        jobs[index].settings = jobs[index].settings.updatingTranslationFields(from: resolved)
        appendLog(
            "Starting translation from \(resolved.translationSourceLanguage) to \(resolved.translationTargetLanguage) with \(resolved.openAIModel) using \(resolved.translationChunkMode.label.lowercased()) chunks and \(resolved.translationParallelism) worker(s).",
            to: jobID
        )

        translationJobID = jobID
        updateProcessingActivity()
        translationTask = Task {
            do {
                let result = try await translationService.translate(
                    segments: segments,
                    sourceLanguage: resolved.sourceLanguage,
                    settings: resolved,
                    credentials: makeTranslationCredentials(),
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
        gpuTask?.cancel()
        translationTask?.cancel()
        translationWorkQueue.removeAll()
        // Only the actively running jobs may be stamped canceled; falling back
        // to the selection could cancel a completed job.
        for id in [gpuJobID, translationJobID].compactMap({ $0 }) {
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

        let baseName = Self.sanitizedBaseName(options.baseName)
        let fileCount = documents.count * options.formats.count + (options.includeLog ? 1 : 0)
        guard fileCount > 0 else { return }
        let useSuffixes = documents.count * options.formats.count > 1 || options.includeLog

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

        var writes: [(url: URL, write: () throws -> Void)] = []
        for document in documents {
            for format in options.formats {
                let name = useSuffixes
                    ? "\(baseName).\(document.suffix).\(format.fileExtension)"
                    : "\(baseName).\(format.fileExtension)"
                let url = folder.appendingPathComponent(name)
                let segments = applyingIntro(document.segments, format: format, job: currentJob)
                writes.append((url, { try SubtitleWriter.write(segments: segments, format: format, to: url) }))
            }
        }
        if options.includeLog {
            let url = folder.appendingPathComponent("\(baseName).log.txt")
            let logText = log
            writes.append((url, { try logText.write(to: url, atomically: true, encoding: .utf8) }))
        }

        // The folder picker skips NSSavePanel's built-in replace warning, so
        // confirm before silently overwriting anything that already exists.
        let existing = writes.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty, !confirmReplacingExistingFiles(existing.map(\.lastPathComponent)) {
            return
        }

        do {
            for entry in writes {
                try entry.write()
            }
            appendLog("Exported \(fileCount) file(s) to \(folder.path(percentEncoded: false)).")
        } catch {
            appendLog("Export failed: \(error.localizedDescription)")
            presentExportError("Export failed: \(error.localizedDescription)")
        }
    }

    /// Path separators in the base name would silently redirect (and usually
    /// fail) the writes.
    private static func sanitizedBaseName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "subtitles" : cleaned
    }

    private func confirmReplacingExistingFiles(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "Replace \"\(names[0])\"?"
            : "Replace \(names.count) existing files?"
        alert.informativeText = "The chosen folder already contains \(names.joined(separator: ", ")). Exporting will replace the existing file(s)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Export problems must be visible without opening the Log tab.
    private func presentExportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
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
        guard format == .srt || format == .vtt else { return segments }
        return SubtitleWriter.segmentsPrependingIntro(job?.summary, to: segments)
    }

    private func bilingualSegments() -> [TranscriptionSegment] {
        bilingualSegments(transcript: transcriptSegments, translated: translatedSegments)
    }

    private func bilingualSegments(
        transcript: [TranscriptionSegment],
        translated: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        let translatedByID = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.text) })
        return transcript.map { source in
            TranscriptionSegment(
                id: source.id,
                start: source.start,
                end: source.end,
                text: "\(source.text)\n\(translatedByID[source.id] ?? "")"
            )
        }
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
        let restoredStatus: JobStatus = job.translatedSegments.isEmpty
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
                    job.progress = JobProgress(stage: .failed, detail: "Burn-in failed: \(error.localizedDescription)", fraction: nil)
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

    // MARK: - Sidecar auto-export

    /// Writes SRT files next to the source video when a job finishes, named
    /// with language codes (video.vi.srt) so media players auto-load them.
    private func autoExportSidecars(for id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              settings.autoExportSidecar || job.origin == .watchFolder
        else { return }

        // Follow the document choices remembered by the export sheet.
        let defaults = UserDefaults.standard
        let includeOriginal = defaults.object(forKey: "exportIncludeOriginal") as? Bool ?? true
        let includeTranslation = defaults.object(forKey: "exportIncludeTranslation") as? Bool ?? true
        let includeBilingual = defaults.object(forKey: "exportIncludeBilingual") as? Bool ?? false

        let folder = job.sourceURL.deletingLastPathComponent()
        let base = job.sourceURL.deletingPathExtension().lastPathComponent
        var written: [String] = []
        do {
            if includeOriginal, !job.transcriptSegments.isEmpty {
                let code = Self.sidecarLanguageCode(for: job.settings.sourceLanguage) ?? "original"
                let name = "\(base).\(code).srt"
                try SubtitleWriter.writeSRT(
                    segments: applyingIntro(job.transcriptSegments, format: .srt, job: job),
                    to: folder.appendingPathComponent(name)
                )
                written.append(name)
            }
            if includeTranslation, !job.translatedSegments.isEmpty {
                let code = Self.sidecarLanguageCode(for: job.settings.translationTargetLanguage)
                    ?? languageSuffix(job.settings.translationTargetLanguage)
                let name = "\(base).\(code).srt"
                try SubtitleWriter.writeSRT(
                    segments: applyingIntro(job.translatedSegments, format: .srt, job: job),
                    to: folder.appendingPathComponent(name)
                )
                written.append(name)
            }
            if includeBilingual, !job.transcriptSegments.isEmpty, !job.translatedSegments.isEmpty {
                let name = "\(base).bilingual.srt"
                try SubtitleWriter.writeSRT(
                    segments: applyingIntro(
                        bilingualSegments(transcript: job.transcriptSegments, translated: job.translatedSegments),
                        format: .srt,
                        job: job
                    ),
                    to: folder.appendingPathComponent(name)
                )
                written.append(name)
            }
            if !written.isEmpty {
                appendLog("Saved sidecar subtitles next to the video: \(written.joined(separator: ", ")).", to: id)
            }
        } catch {
            appendLog("Sidecar export failed: \(error.localizedDescription)", to: id)
        }
    }

    /// ISO-639-1 code for sidecar file names. Transcription languages are
    /// already codes ("ja"); translation targets are names ("Vietnamese").
    private static func sidecarLanguageCode(for language: String) -> String? {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let codes: [String: String] = [
            "english": "en", "japanese": "ja", "chinese": "zh", "korean": "ko",
            "spanish": "es", "french": "fr", "german": "de", "indonesian": "id",
            "thai": "th", "vietnamese": "vi",
        ]
        if normalized.isEmpty || normalized == "auto" { return nil }
        if codes.values.contains(normalized) { return normalized }
        return codes[normalized]
    }

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

    func updateTranslatedSegment(_ segment: TranscriptionSegment, text: String) {
        updateSegment(segment, text: text, keyPath: \.translatedSegments)
    }

    func qualityWarnings(for segments: [TranscriptionSegment]) -> [SubtitleQualityWarning] {
        segments.flatMap { segment -> [SubtitleQualityWarning] in
            var warnings: [SubtitleQualityWarning] = []
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Empty text"))
            }
            if segment.end <= segment.start {
                warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Invalid timing"))
            }
            if segment.end - segment.start > 8 {
                warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Long duration"))
            }
            if trimmed.count > 90 {
                warnings.append(SubtitleQualityWarning(segmentID: segment.id, message: "Long subtitle text"))
            }
            return warnings
        }
    }

    private func finishTranscription(_ result: TranscriptionResult, summary: String?, for id: UUID) {
        updateJob(id) { job in
            job.transcriptSegments = result.segments
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
            job.finishedAt = Date()
            guard let started = job.transcriptionStartedAt, let finished = job.finishedAt else { return }
            let total = JobTimingFormatter.format(finished.timeIntervalSince(started))
            guard !total.isEmpty else { return }
            job.progress = JobProgress(stage: .complete, detail: job.progress.detail + " Done in \(total).", fraction: 1)
            if let tEnd = job.transcriptionFinishedAt {
                job.log += "Transcription took \(JobTimingFormatter.format(tEnd.timeIntervalSince(started))).\n"
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
        let language = useTranslation
            ? (target.isEmpty ? "English" : target)
            : "the same language as the subtitles"
        let id = job.id
        let resolvedSettings = JobSettingsSnapshot(settings: settings).applying(job.overrides)

        isGeneratingSummary = true
        Task {
            do {
                let summary = try await translationService.summarize(
                    segments: segments,
                    language: language,
                    settings: resolvedSettings,
                    credentials: makeTranslationCredentials(),
                    detail: settings.summaryDetail
                )
                updateJob(id) { job in
                    job.summary = summary
                    job.log += "Generated intro summary: \(summary)\n"
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
        guard settings.generateSummary, !segments.isEmpty else { return nil }
        guard settings.isTranslationReady else {
            let reason = settings.currentTranslationProvider == .local
                ? "no local server URL is configured"
                : "no \(settings.currentTranslationProvider.label) API key is configured"
            appendLog("Skipped the intro summary because \(reason).", to: id)
            return nil
        }
        updateJob(id, debouncePersist: true) { job in
            job.progress = JobProgress(stage: job.progress.stage, detail: "Writing intro summary.", fraction: job.progress.fraction)
        }
        let overrides = jobs.first(where: { $0.id == id })?.overrides ?? JobSettingsOverrides()
        do {
            let summary = try await translationService.summarize(
                segments: segments,
                language: language,
                settings: JobSettingsSnapshot(settings: settings).applying(overrides),
                credentials: makeTranslationCredentials(),
                detail: settings.summaryDetail
            )
            appendLog("Generated intro summary: \(summary)", to: id)
            return summary
        } catch {
            appendLog("Intro summary failed (job still completed): \(error.localizedDescription)", to: id)
            return nil
        }
    }

    /// Secrets + prompt for the current translation model. Built fresh per
    /// run; never stored on the job.
    private func makeTranslationCredentials() -> TranslationCredentials {
        let provider = settings.currentTranslationProvider
        return TranslationCredentials(
            apiKey: settings.translationAPIKey(for: provider),
            prompt: settings.translationPrompt,
            provider: provider,
            localEndpoint: settings.localTranslationEndpoint
        )
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
            job.status = .failed
            job.progress = JobProgress(stage: .failed, detail: message, fraction: nil)
            job.log += "\(message)\n"
        }
        recordWatchOutcome(for: id, success: false)
    }

    private func updateProgress(_ progress: JobProgress, for id: UUID) {
        updateJob(id, debouncePersist: true) { job in
            job.progress = progress
            job.log += "\(progress.stage.label): \(progress.detail)\n"
        }
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
        guard let job = jobs.first(where: { $0.id == id }) else { return }
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
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&jobs[index])
        jobs[index].updatedAt = Date()
        if jobs[index].log.count > Self.maxLogLength {
            let tail = jobs[index].log.suffix(Self.maxLogLength * 3 / 4)
            jobs[index].log = "… earlier log trimmed …\n\(tail)"
        }
        if debouncePersist {
            schedulePersist(id)
        } else {
            dirtyJobIDs.insert(id)
            persistTask?.cancel()
            persistTask = nil
            flushDirtyJobs()
        }
    }

    private func updateSegment(
        _ segment: TranscriptionSegment,
        text: String,
        keyPath: WritableKeyPath<TranscriptionJob, [TranscriptionSegment]>
    ) {
        guard let id = selectedJobID else { return }
        updateJob(id, debouncePersist: true) { job in
            guard let index = job[keyPath: keyPath].firstIndex(where: { $0.id == segment.id }) else {
                return
            }
            job[keyPath: keyPath][index].text = text
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
        let expected = expectedExtension.lowercased()
        if url.pathExtension.lowercased() == expected {
            return url
        }

        let withoutAddedExtension = url.deletingPathExtension()
        if withoutAddedExtension.pathExtension.lowercased() == expected {
            return withoutAddedExtension
        }

        return withoutAddedExtension.appendingPathExtension(expectedExtension)
    }

    private func lastExportDirectoryURL() -> URL? {
        let path = settings.lastExportDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private func languageSuffix(_ language: String) -> String {
        let normalized = language
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return normalized.isEmpty ? "translation" : normalized
    }

    private func persistJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        jobStore.saveJob(job)
    }

    /// Coalesces rapid mutations (segment keystrokes, progress ticks) into a
    /// single disk write per dirty job instead of rewriting the whole
    /// history per keystroke.
    private func schedulePersist(_ id: UUID) {
        dirtyJobIDs.insert(id)
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.flushDirtyJobs()
        }
    }

    private func flushDirtyJobs() {
        for id in dirtyJobIDs {
            persistJob(id)
        }
        dirtyJobIDs.removeAll()
    }
}
