import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettingsStore()
    @Published var jobs: [TranscriptionJob] = []
    @Published var selectedJobID: UUID?
    @Published var diagnostics: [EnvironmentDiagnostic] = []
    @Published var isRunningDiagnostics = false

    private let transcriptionService = TranscriptionService()
    private let translationService = OpenAITranslationService()
    private let diagnosticsService = EnvironmentDiagnosticsService()
    private let jobStore = JobStore()
    private var activeTask: Task<Void, Never>?
    private var activeJobID: UUID?
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

    var canTranscribe: Bool {
        currentJob != nil && !isBusy
    }

    var canTranslate: Bool {
        !transcriptSegments.isEmpty && !isBusy && !settings.openAIAPIKey.isEmpty
    }

    var canCancel: Bool {
        isBusy
    }

    var isBusy: Bool {
        isRunningTranscription || isRunningTranslation
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
        return "Export All"
    }

    var primaryActionSystemImage: String {
        if currentJob == nil { return "folder" }
        if transcriptSegments.isEmpty { return "waveform" }
        if translatedSegments.isEmpty { return "character.bubble" }
        return "square.and.arrow.up"
    }

    var canPerformPrimaryAction: Bool {
        if currentJob == nil { return !isBusy }
        if transcriptSegments.isEmpty { return canTranscribe }
        if translatedSegments.isEmpty { return canTranslate }
        return !isBusy
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
        guard !isBusy else { return }
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
            exportAll()
        }
    }

    /// Adds a video as a new job. Used by the file picker and drag-and-drop.
    func addVideo(url: URL) {
        addVideos(urls: [url])
    }

    /// Adds videos as separate queued jobs. Used by the file picker and drag-and-drop.
    func addVideos(urls: [URL]) {
        let newJobs = urls.map { url in
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.log = "Selected \(url.path(percentEncoded: false)).\n"
            return job
        }
        guard !newJobs.isEmpty else { return }
        jobs.insert(contentsOf: newJobs, at: 0)
        if !isBusy {
            selectedJobID = newJobs.first?.id
        }
        persistJobs()
    }

    func deleteJob(_ id: UUID) {
        guard !isBusy else { return }
        jobs.removeAll { $0.id == id }
        if selectedJobID == id {
            selectedJobID = jobs.first?.id
        }
        persistJobs()
    }

    func runDiagnostics() {
        isRunningDiagnostics = true
        Task {
            diagnostics = await diagnosticsService.run(openAIAPIKey: settings.openAIAPIKey)
            isRunningDiagnostics = false
        }
    }

    func startTranscription(force: Bool = false) {
        guard let index = currentJobIndex, !isBusy else { return }
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
            jobs[index].progress = JobProgress(stage: .complete, detail: "Using existing transcript for unchanged file and settings.", fraction: 1)
            appendLog("Skipped transcription because this file and transcription settings already have a transcript.")
            if settings.autoTranslateAfterTranscription && jobs[index].translatedSegments.isEmpty {
                startTranslation()
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
        appendLog("Starting transcription with \(settings.whisperBackend.label) and model \(settings.whisperModel).")
        persistJobs()

        activeJobID = jobID
        activeTask = Task {
            do {
                let result = try await transcriptionService.transcribe(videoURL: videoURL, settings: settings) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
                }
                finishTranscription(result, for: jobID)
                if settings.autoTranslateAfterTranscription && !settings.openAIAPIKey.isEmpty {
                    activeTask = nil
                    activeJobID = nil
                    startTranslation()
                    return
                }
            } catch is CancellationError {
                markCanceled(jobID)
            } catch {
                markFailed(jobID, message: "Transcription failed: \(error.localizedDescription)")
            }
            activeTask = nil
            activeJobID = nil
        }
    }

    func startTranslation() {
        guard let index = currentJobIndex, !jobs[index].transcriptSegments.isEmpty, !isBusy else { return }
        let jobID = jobs[index].id
        let segments = jobs[index].transcriptSegments
        let existingTranslations = jobs[index].partialTranslatedSegments.isEmpty
            ? jobs[index].translatedSegments
            : jobs[index].partialTranslatedSegments
        jobs[index].status = .translating
        jobs[index].progress = JobProgress(stage: .translating, detail: "Starting translation.", fraction: 0)
        jobs[index].settings = JobSettingsSnapshot(settings: settings)
        appendLog(
            "Starting translation from \(settings.translationSourceLanguage) to \(settings.translationTargetLanguage) with \(settings.openAIModel) using \(settings.translationChunkMode.label.lowercased()) chunks and \(settings.translationParallelism) worker(s)."
        )
        persistJobs()

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
            activeTask = nil
            activeJobID = nil
        }
    }

    func cancelActiveJob() {
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
        let merged = transcriptSegments.map { source in
            let translated = translatedSegments.first { $0.id == source.id }?.text ?? ""
            return TranscriptionSegment(id: source.id, start: source.start, end: source.end, text: "\(source.text)\n\(translated)")
        }
        export(
            segments: merged,
            format: format,
            suggestedSuffix: ".bilingual.\(languageSuffix(translationTargetLabel)).\(format.fileExtension)"
        )
    }

    func exportAll() {
        guard let selectedVideoURL, !transcriptSegments.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.directoryURL = lastExportDirectoryURL()

        if panel.runModal() == .OK, let folder = panel.url {
            settings.lastExportDirectory = folder.path
            let base = selectedVideoURL.deletingPathExtension().lastPathComponent
            do {
                try SubtitleWriter.writeSRT(
                    segments: transcriptSegments,
                    to: folder.appendingPathComponent("\(base).original.srt")
                )
                try SubtitleWriter.writeText(
                    segments: transcriptSegments,
                    to: folder.appendingPathComponent("\(base).original.txt")
                )
                try SubtitleWriter.writeMarkdown(
                    segments: transcriptSegments,
                    to: folder.appendingPathComponent("\(base).original.md")
                )
                try SubtitleWriter.writeJSON(
                    segments: transcriptSegments,
                    to: folder.appendingPathComponent("\(base).original.json")
                )

                if !translatedSegments.isEmpty {
                    let target = languageSuffix(translationTargetLabel)
                    try SubtitleWriter.writeSRT(
                        segments: translatedSegments,
                        to: folder.appendingPathComponent("\(base).translated.\(target).srt")
                    )
                    try SubtitleWriter.writeText(
                        segments: translatedSegments,
                        to: folder.appendingPathComponent("\(base).translated.\(target).txt")
                    )
                    try SubtitleWriter.writeMarkdown(
                        segments: translatedSegments,
                        to: folder.appendingPathComponent("\(base).translated.\(target).md")
                    )
                    try SubtitleWriter.writeJSON(
                        segments: translatedSegments,
                        to: folder.appendingPathComponent("\(base).translated.\(target).json")
                    )
                    let bilingual = transcriptSegments.map { source in
                        let translated = translatedSegments.first { $0.id == source.id }?.text ?? ""
                        return TranscriptionSegment(id: source.id, start: source.start, end: source.end, text: "\(source.text)\n\(translated)")
                    }
                    try SubtitleWriter.writeSRT(
                        segments: bilingual,
                        to: folder.appendingPathComponent("\(base).bilingual.\(target).srt")
                    )
                }

                try log.write(to: folder.appendingPathComponent("\(base).log.txt"), atomically: true, encoding: .utf8)
                appendLog("Exported all artifacts to \(folder.path(percentEncoded: false)).")
            } catch {
                appendLog("Export all failed: \(error.localizedDescription)")
            }
        }
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
        updateJob(id) { job in
            job.log += "\(entry)\n"
        }
    }

    private func updateJob(_ id: UUID, debouncePersist: Bool = false, mutate: (inout TranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&jobs[index])
        jobs[index].updatedAt = Date()
        jobs.sort { $0.updatedAt > $1.updatedAt }
        selectedJobID = id
        if debouncePersist {
            schedulePersist()
        } else {
            persistJobs()
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

    private func persistJobs() {
        persistTask?.cancel()
        persistTask = nil
        jobStore.saveJobs(jobs)
    }

    /// Coalesces rapid mutations (segment keystrokes, progress ticks) into a
    /// single disk write so we don't rewrite the whole history per keystroke.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.jobStore.saveJobs(self.jobs)
        }
    }
}
