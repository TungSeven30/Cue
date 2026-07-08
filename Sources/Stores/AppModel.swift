import AppKit
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
    /// Set when the user cancels while jobs are still queued; Start All resumes.
    @Published var queuePaused = false
    private var didProcessQueuedJob = false
    private var dirtyJobIDs: Set<UUID> = []
    /// Keeps very chatty jobs from growing without bound in memory and on disk.
    private static let maxLogLength = 200_000

    private let transcriptionService = TranscriptionService()
    private let translationService = TranslationService()
    private let diagnosticsService = EnvironmentDiagnosticsService()
    private let jobStore = JobStore()
    private var activeTask: Task<Void, Never>?
    private(set) var activeJobID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var persistTask: Task<Void, Never>?

    init() {
        jobs = jobStore.loadJobs().sorted { $0.updatedAt > $1.updatedAt }
        selectedJobID = jobs.first?.id
        // `settings` is a nested ObservableObject; changes to its fields do not
        // fire AppModel's objectWillChange on their own, so forward them.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        runDiagnostics()
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

    /// Any job is currently running.
    var isProcessing: Bool {
        activeJobID != nil
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
            && !settings.currentTranslationAPIKey.isEmpty
    }

    var canCancel: Bool {
        isProcessing
    }

    var hasPendingWork: Bool {
        jobs.contains { jobNeedsWork($0) }
    }

    var queuedJobCount: Int {
        jobs.filter { $0.status == .queued }.count
    }

    var translationTargetLabel: String {
        let target = translatedSegments.isEmpty
            ? settings.translationTargetLanguage
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
        let failures = diagnostics.filter { $0.state == .failed }.count
        let warnings = diagnostics.filter { $0.state == .warning }.count
        if failures > 0 {
            return "\(failures) missing"
        }
        if warnings > 0 {
            return "\(warnings) warning"
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
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .audio]
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
        let newJobs = urls.map { url in
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.log = "Selected \(url.path(percentEncoded: false)).\n"
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

    func deleteJob(_ id: UUID) {
        // The running job cannot be deleted; cancel it first.
        guard id != activeJobID else { return }
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
                providerLabel: settings.currentTranslationProvider.label
            )
            isRunningDiagnostics = false
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
        return job.translatedSegments.isEmpty && !settings.currentTranslationAPIKey.isEmpty
    }

    /// Runs the next queued job. Serial on purpose: one model on the GPU at
    /// a time.
    private func processQueue() {
        guard activeJobID == nil, !queuePaused else { return }
        guard let next = jobs.first(where: { $0.status == .queued }) else {
            if didProcessQueuedJob {
                didProcessQueuedJob = false
                notify(title: "WhisperDesk", body: "All queued jobs finished.")
            }
            return
        }
        didProcessQueuedJob = true
        if next.transcriptSegments.isEmpty {
            startTranscription(jobID: next.id)
        } else {
            startTranslation(jobID: next.id)
        }
        // If the job could not start (e.g. a guard failed), fail it instead
        // of stalling the whole queue on a stuck "queued" entry.
        if activeJobID == nil, let job = jobs.first(where: { $0.id == next.id }), job.status == .queued {
            markFailed(next.id, message: "Could not start this job. Check the file and settings.")
            processQueue()
        }
    }

    func startTranscription(jobID: UUID? = nil, force: Bool = false) {
        guard let index = jobs.firstIndex(where: { $0.id == (jobID ?? selectedJobID) }) else { return }
        let targetID = jobs[index].id
        guard !jobs[index].status.isRunning else { return }
        // Something else is running: queue this job instead of fighting for
        // the GPU.
        if activeJobID != nil {
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
        if !force,
           !jobs[index].transcriptSegments.isEmpty,
           jobs[index].sourceFingerprint == currentFingerprint,
           jobs[index].settings.transcriptionProcessingVersion == JobSettingsSnapshot.currentTranscriptionProcessingVersion,
           jobs[index].settings.sourceLanguage == settings.sourceLanguage,
           jobs[index].settings.whisperModel == settings.whisperModel,
           jobs[index].settings.whisperBackend == settings.whisperBackend,
           jobs[index].settings.preprocessAudio == settings.preprocessAudio,
           jobs[index].settings.vadFilter == settings.vadFilter,
           jobs[index].settings.removeEmptySegments == settings.removeEmptySegments,
           jobs[index].settings.removeRepeatedText == settings.removeRepeatedText,
           jobs[index].settings.mergeShortSegments == settings.mergeShortSegments,
           jobs[index].settings.minSegmentDuration == settings.minSegmentDuration,
           jobs[index].settings.maxMergeGap == settings.maxMergeGap,
           jobs[index].settings.beamSize == settings.beamSize,
           jobs[index].settings.bestOf == settings.bestOf,
           jobs[index].settings.temperature == settings.temperature,
           jobs[index].settings.noSpeechThreshold == settings.noSpeechThreshold {
            let hasTranslation = !jobs[index].translatedSegments.isEmpty
            jobs[index].status = hasTranslation ? .translationComplete : .transcriptionComplete
            jobs[index].progress = JobProgress(stage: .complete, detail: "Using existing transcript for unchanged file and settings.", fraction: 1)
            appendLog("Skipped transcription because this file and transcription settings already have a transcript.", to: jobID)
            if settings.autoTranslateAfterTranscription && !hasTranslation {
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
        jobs[index].sourceFingerprint = currentFingerprint
        jobs[index].settings = JobSettingsSnapshot(settings: settings)
        if let validationMessage {
            jobs[index].log += "Adjusted transcription settings: \(validationMessage)\n"
        }
        appendLog("Starting transcription with \(settings.whisperBackend.label) and model \(settings.whisperModel).", to: jobID)

        activeJobID = jobID
        activeTask = Task {
            do {
                let result = try await transcriptionService.transcribe(videoURL: videoURL, settings: settings) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
                }
                finishTranscription(result, for: jobID)
                if settings.autoTranslateAfterTranscription && !settings.currentTranslationAPIKey.isEmpty {
                    activeTask = nil
                    activeJobID = nil
                    startTranslation(jobID: jobID)
                    return
                }
                // The job ends here (no translation step follows).
                autoExportSidecars(for: jobID)
                notifyJobFinished(jobID)
            } catch is CancellationError {
                markCanceled(jobID)
            } catch {
                markFailed(jobID, message: "Transcription failed: \(error.localizedDescription)")
                notifyJobFinished(jobID)
            }
            activeTask = nil
            activeJobID = nil
            processQueue()
        }
    }

    func startTranslation(jobID: UUID? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == (jobID ?? selectedJobID) }),
              !jobs[index].transcriptSegments.isEmpty
        else { return }
        let targetID = jobs[index].id
        guard !jobs[index].status.isRunning else { return }
        if activeJobID != nil {
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
        jobs[index].status = .translating
        jobs[index].progress = JobProgress(stage: .translating, detail: "Starting translation.", fraction: 0)
        jobs[index].settings = JobSettingsSnapshot(settings: settings)
        appendLog(
            "Starting translation from \(settings.translationSourceLanguage) to \(settings.translationTargetLanguage) with \(settings.openAIModel) using \(settings.translationChunkMode.label.lowercased()) chunks and \(settings.translationParallelism) worker(s).",
            to: jobID
        )

        activeJobID = jobID
        activeTask = Task {
            do {
                let result = try await translationService.translate(
                    segments: segments,
                    sourceLanguage: settings.sourceLanguage,
                    settings: settings,
                    existingTranslations: existingTranslations
                ) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
                } onPartial: { [weak self] partial in
                    self?.updatePartialTranslation(partial, for: jobID)
                }
                finishTranslation(result, for: jobID)
            } catch is CancellationError {
                markCanceled(jobID)
            } catch {
                markFailed(jobID, message: "Translation failed: \(error.localizedDescription)")
            }
            notifyJobFinished(jobID)
            activeTask = nil
            activeJobID = nil
            processQueue()
        }
    }

    func cancelActiveJob() {
        // Stopping the current job also pauses the queue: a cancel means
        // "stop working", not "move on to the next one".
        if queuedJobCount > 0 {
            queuePaused = true
        }
        activeTask?.cancel()
        if let id = activeJobID ?? selectedJobID {
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
        do {
            for document in documents {
                for format in options.formats {
                    let name = useSuffixes
                        ? "\(options.baseName).\(document.suffix).\(format.fileExtension)"
                        : "\(options.baseName).\(format.fileExtension)"
                    try SubtitleWriter.write(
                        segments: document.segments,
                        format: format,
                        to: folder.appendingPathComponent(name)
                    )
                }
            }
            if options.includeLog {
                try log.write(
                    to: folder.appendingPathComponent("\(options.baseName).log.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            appendLog("Exported \(fileCount) file(s) to \(folder.path(percentEncoded: false)).")
        } catch {
            appendLog("Export failed: \(error.localizedDescription)")
        }
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

    // MARK: - Sidecar auto-export

    /// Writes SRT files next to the source video when a job finishes, named
    /// with language codes (video.vi.srt) so media players auto-load them.
    private func autoExportSidecars(for id: UUID) {
        guard settings.autoExportSidecar,
              let job = jobs.first(where: { $0.id == id })
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
                try SubtitleWriter.writeSRT(segments: job.transcriptSegments, to: folder.appendingPathComponent(name))
                written.append(name)
            }
            if includeTranslation, !job.translatedSegments.isEmpty {
                let code = Self.sidecarLanguageCode(for: job.settings.translationTargetLanguage)
                    ?? languageSuffix(job.settings.translationTargetLanguage)
                let name = "\(base).\(code).srt"
                try SubtitleWriter.writeSRT(segments: job.translatedSegments, to: folder.appendingPathComponent(name))
                written.append(name)
            }
            if includeBilingual, !job.transcriptSegments.isEmpty, !job.translatedSegments.isEmpty {
                let name = "\(base).bilingual.srt"
                try SubtitleWriter.writeSRT(
                    segments: bilingualSegments(transcript: job.transcriptSegments, translated: job.translatedSegments),
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

    private func finishTranscription(_ result: TranscriptionResult, for id: UUID) {
        updateJob(id) { job in
            job.transcriptSegments = result.segments
            job.translatedSegments = []
            job.status = .transcriptionComplete
            job.progress = JobProgress(stage: .complete, detail: "Transcription complete.", fraction: 1)
            job.log += "Transcription finished via \(result.backend). Produced \(result.segments.count) subtitle segments.\n"
        }
    }

    private func finishTranslation(_ segments: [TranscriptionSegment], for id: UUID) {
        updateJob(id) { job in
            job.translatedSegments = segments
            job.partialTranslatedSegments = []
            job.status = .translationComplete
            job.progress = JobProgress(stage: .complete, detail: "Translation complete.", fraction: 1)
            job.log += "Translation finished. Produced \(segments.count) translated segments.\n"
        }
        autoExportSidecars(for: id)
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
                try SubtitleWriter.write(segments: segments, format: format, to: exportURL)
                appendLog("Exported subtitles to \(exportURL.path(percentEncoded: false)).")
            } catch {
                appendLog("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func contentType(for format: SubtitleExportFormat) -> UTType {
        switch format {
        case .srt:
            return UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
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
