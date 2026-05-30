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
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.log = "Selected \(url.path(percentEncoded: false)).\n"
            jobs.insert(job, at: 0)
            selectedJobID = job.id
            persistJobs()
        }
    }

    func runDiagnostics() {
        isRunningDiagnostics = true
        Task {
            diagnostics = await diagnosticsService.run(openAIAPIKey: settings.openAIAPIKey)
            isRunningDiagnostics = false
        }
    }

    func startTranscription() {
        guard let index = currentJobIndex, !isBusy else { return }
        let jobID = jobs[index].id
        let videoURL = jobs[index].sourceURL
        jobs[index].status = .transcribing
        jobs[index].progress = JobProgress(stage: .preflight, detail: "Starting transcription.", fraction: 0)
        jobs[index].translatedSegments = []
        jobs[index].settings = JobSettingsSnapshot(settings: settings)
        appendLog("Starting transcription with \(settings.whisperBackend.label) and model \(settings.whisperModel).")
        persistJobs()

        activeJobID = jobID
        activeTask = Task {
            do {
                let result = try await transcriptionService.transcribe(videoURL: videoURL, settings: settings) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
                }
                finishTranscription(result, for: jobID)
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
        jobs[index].status = .translating
        jobs[index].progress = JobProgress(stage: .translating, detail: "Starting translation.", fraction: 0)
        jobs[index].settings = JobSettingsSnapshot(settings: settings)
        appendLog("Starting translation with \(settings.openAIModel).")
        persistJobs()

        activeJobID = jobID
        activeTask = Task {
            do {
                let result = try await translationService.translate(
                    segments: segments,
                    sourceLanguage: settings.sourceLanguage,
                    settings: settings
                ) { [weak self] progress in
                    self?.updateProgress(progress, for: jobID)
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

    func exportTranscript() {
        guard !transcriptSegments.isEmpty else { return }
        export(segments: transcriptSegments, suggestedSuffix: ".original.srt")
    }

    func exportTranslation() {
        guard !translatedSegments.isEmpty else { return }
        export(segments: translatedSegments, suggestedSuffix: ".translated.en.srt")
    }

    func exportBilingual() {
        guard !transcriptSegments.isEmpty, !translatedSegments.isEmpty else { return }
        let merged = transcriptSegments.map { source in
            let translated = translatedSegments.first { $0.id == source.id }?.text ?? ""
            return TranscriptionSegment(id: source.id, start: source.start, end: source.end, text: "\(source.text)\n\(translated)")
        }
        export(segments: merged, suggestedSuffix: ".bilingual.srt")
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

    private func export(segments: [TranscriptionSegment], suggestedSuffix: String) {
        guard let selectedVideoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = selectedVideoURL.deletingPathExtension().lastPathComponent + suggestedSuffix
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                try SubtitleWriter.writeSRT(segments: segments, to: destination)
                appendLog("Exported subtitles to \(destination.path(percentEncoded: false)).")
            } catch {
                appendLog("Export failed: \(error.localizedDescription)")
            }
        }
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
