import AVFoundation
import Foundation

/// Drives one CLI stage against the same services the GUI uses. Nothing here
/// touches `AppModel`: the CLI has no queue, no persistence, and no windows —
/// it runs one job to completion and writes a manifest describing what it
/// produced.
@MainActor
struct CLIRunner {
    let arguments: CLIArguments
    let settings: AppSettingsStore
    let console: CLIConsole

    private var outputFormats: [SubtitleExportFormat] {
        get throws { try arguments.formats(default: [.srt]) }
    }

    // MARK: - Entry

    func run() async throws -> CLIManifest? {
        switch arguments.command {
        case .fetch:
            return try await runFetch()
        case .transcribe:
            return try await runTranscribe()
        case .translate:
            return try await runTranslate()
        case .summarize:
            return try await runSummarize()
        case .burnIn:
            return try await runBurnIn()
        case .pipeline:
            return try await runPipeline()
        case .doctor, .help, .version:
            return nil
        }
    }

    // MARK: - Settings resolution

    /// Globals first, then the CLI's own overrides. The store itself is
    /// never mutated: a scripted run must not quietly rewrite the settings
    /// the GUI will use next time.
    func resolvedSnapshot() throws -> JobSettingsSnapshot {
        var overrides = JobSettingsOverrides()
        if let language = arguments.value("--language") {
            overrides.sourceLanguage = language
        }
        if let context = arguments.value("--qwen-context") {
            overrides.qwenContext = context
        }
        if let target = arguments.value("--to") {
            overrides.translationTargetLanguage = target
        }
        if let raw = arguments.value("--preset") {
            guard let preset = TranscriptionPreset(rawValue: raw), preset != .custom else {
                throw CLIError.badValue("--preset", raw, TranscriptionPreset.allCases.map(\.rawValue))
            }
            overrides.transcriptionPreset = preset
        }
        if let raw = arguments.value("--quality") {
            guard let quality = TranscriptionQualityPreset(rawValue: raw), quality != .custom else {
                throw CLIError.badValue("--quality", raw, TranscriptionQualityPreset.allCases.map(\.rawValue))
            }
            overrides.transcriptionQualityPreset = quality
        }

        var snapshot = JobSettingsSnapshot(settings: settings).applying(overrides)

        // An explicit backend or model outranks whatever the preset expanded
        // to, and makes the pairing custom so nothing re-expands it later.
        if let raw = arguments.value("--backend") {
            guard let backend = WhisperBackend(rawValue: raw) else {
                throw CLIError.badValue("--backend", raw, WhisperBackend.allCases.map(\.rawValue))
            }
            snapshot.whisperBackend = backend
            snapshot.transcriptionPreset = .custom
        }
        if let model = asrModelOption {
            snapshot.whisperModel = model
            snapshot.transcriptionPreset = .custom
        }
        if let model = translationModelOption {
            snapshot.openAIModel = model
        }
        if let from = arguments.value("--from") {
            snapshot.translationSourceLanguage = from
        }
        if let parallelism = try arguments.intValue("--parallelism") {
            snapshot.translationParallelism = max(1, min(4, parallelism))
        }
        return snapshot
    }

    /// `--model` means the transcription model for transcription commands
    /// and the LLM for translate/summarize, which is what each command's
    /// user is thinking about. `--translation-model` is unambiguous
    /// everywhere and always wins.
    private var asrModelOption: String? {
        switch arguments.command {
        case .translate, .summarize:
            return nil
        default:
            return arguments.value("--model")
        }
    }

    private var translationModelOption: String? {
        if let explicit = arguments.value("--translation-model") { return explicit }
        switch arguments.command {
        case .translate, .summarize:
            return arguments.value("--model")
        default:
            return nil
        }
    }

    private func manifestSettings(_ snapshot: JobSettingsSnapshot) -> CLIManifest.Settings {
        CLIManifest.Settings(
            sourceLanguage: snapshot.sourceLanguage,
            backend: snapshot.whisperBackend.rawValue,
            model: snapshot.whisperModel,
            qualityPreset: snapshot.transcriptionQualityPreset.rawValue,
            translationTargetLanguage: snapshot.translationTargetLanguage,
            translationModel: snapshot.openAIModel,
            summaryModel: settings.resolvedSummaryModel
        )
    }

    // MARK: - Input

    /// Where a stage writes. `--output-dir` wins; otherwise files land next
    /// to the media, which is what makes sidecar-style output the default.
    func outputDirectory(for source: URL) throws -> URL {
        guard let raw = arguments.value("--output-dir") else {
            return source.deletingLastPathComponent()
        }
        let directory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Resolves this stage's input into a manifest: an existing manifest is
    /// read back, a subtitle file becomes a transcript, a web address is
    /// fetched, and a media path starts a fresh one.
    func loadInput() async throws -> CLIManifest {
        guard let input = arguments.input else {
            throw CLIError.usage("\(arguments.command.rawValue) needs an input (a file, a URL, or a .cue.json manifest).")
        }
        let snapshot = try resolvedSnapshot()

        if let pageURL = MediaDownloadService.normalizedWebURL(from: input) {
            let file = try await fetchMedia(pageURL)
            var manifest = CLIManifest(
                stage: "fetch",
                source: CLIManifest.Source(path: file.path, pageURL: pageURL.absoluteString),
                settings: manifestSettings(snapshot)
            )
            manifest.note("Fetched \(pageURL.absoluteString) with yt-dlp.")
            return manifest
        }

        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound(url.path)
        }

        if CLIManifest.looksLikeManifest(url.path) {
            var manifest = try CLIManifest.read(contentsOf: url)
            // Translation-facing settings come from this invocation, so a
            // chained `--to Vietnamese` takes effect. The transcription-side
            // fields stay as recorded: they describe what actually produced
            // the transcript in the manifest, exactly as
            // JobSettingsSnapshot.updatingTranslationFields(from:) preserves
            // them in the app.
            let resolved = manifestSettings(snapshot)
            manifest.settings.translationTargetLanguage = resolved.translationTargetLanguage
            manifest.settings.translationModel = resolved.translationModel
            manifest.settings.summaryModel = resolved.summaryModel
            guard FileManager.default.fileExists(atPath: manifest.source.path) else {
                throw CLIError.notFound(manifest.source.path)
            }
            return manifest
        }

        let extensionName = url.pathExtension.lowercased()
        if extensionName == "srt" || extensionName == "vtt" {
            var manifest = CLIManifest(
                stage: "read",
                source: CLIManifest.Source(path: url.path, pageURL: nil),
                settings: manifestSettings(snapshot),
                transcript: try SubtitleReader.read(contentsOf: url)
            )
            manifest.note("Read \(manifest.transcript.count) cues from \(url.lastPathComponent).")
            return manifest
        }

        return CLIManifest(
            stage: "input",
            source: CLIManifest.Source(path: url.path, pageURL: nil),
            settings: manifestSettings(snapshot)
        )
    }

    private func fetchMedia(_ pageURL: URL) async throws -> URL {
        let directory =
            arguments.value("--output-dir").map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
            } ?? settings.resolvedDownloadDirectory
        let reporter = console.progressReporter(stage: "fetch")
        return try await MediaDownloadService().download(url: pageURL, into: directory) { update in
            reporter.report(fraction: update.fraction, detail: update.detail)
        }
    }

    // MARK: - Stages

    private func runFetch() async throws -> CLIManifest {
        var manifest = try await loadInput()
        guard manifest.source.pageURL != nil else {
            throw CLIError.usage("fetch needs an http(s) URL.")
        }
        manifest.stage = "fetch"
        try writeManifest(manifest)
        return manifest
    }

    private func runTranscribe() async throws -> CLIManifest {
        var manifest = try await loadInput()
        try await transcribe(into: &manifest)
        try writeSubtitles(&manifest, roles: [.original])
        try writeManifest(manifest)
        return manifest
    }

    private func runTranslate() async throws -> CLIManifest {
        var manifest = try await loadInput()
        try await translate(into: &manifest)
        try writeSubtitles(&manifest, roles: translationRoles)
        try writeManifest(manifest)
        return manifest
    }

    private func runSummarize() async throws -> CLIManifest {
        var manifest = try await loadInput()
        try await summarize(into: &manifest)
        try writeManifest(manifest)
        return manifest
    }

    private func runBurnIn() async throws -> CLIManifest {
        var manifest = try await loadInput()
        try await burnIn(into: &manifest)
        try writeManifest(manifest)
        return manifest
    }

    /// The full chain in one process, reusing the cached audio and the
    /// already-loaded model rather than paying for a cold start per stage.
    private func runPipeline() async throws -> CLIManifest {
        var manifest = try await loadInput()
        if manifest.transcript.isEmpty {
            try await transcribe(into: &manifest)
        }
        let wantsTranslation = arguments.value("--to") != nil || settings.autoTranslateAfterTranscription
        if wantsTranslation {
            try await translate(into: &manifest)
        }
        if arguments.flag("--summary") || settings.generateSummary {
            try await summarize(into: &manifest)
        }
        var roles: [DocumentRole] = [.original]
        if !manifest.translation.isEmpty {
            roles.append(contentsOf: translationRoles)
        }
        try writeSubtitles(&manifest, roles: roles)
        if arguments.flag("--burn-in") {
            try await burnIn(into: &manifest)
        }
        manifest.stage = "pipeline"
        try writeManifest(manifest)
        return manifest
    }

    // MARK: - Stage bodies

    private func transcribe(into manifest: inout CLIManifest) async throws {
        let snapshot = try resolvedSnapshot()
        let source = manifest.sourceURL
        let reporter = console.progressReporter(stage: "transcribe")
        let result = try await TranscriptionService().transcribe(
            videoURL: source,
            settings: snapshot,
            progress: { progress in
                reporter.report(fraction: progress.fraction, detail: progress.detail)
            },
            onSegments: nil,
            onMetrics: { metrics in
                console.note(metrics.logSummary)
            }
        )
        guard !result.segments.isEmpty else {
            throw CLIError.stageFailed("Transcription produced no segments.")
        }
        manifest.stage = "transcribe"
        manifest.transcript = result.segments
        // A re-transcription invalidates any translation carried in from an
        // earlier manifest: the ids it was keyed to no longer exist.
        manifest.translation = []
        manifest.settings = manifestSettings(snapshot)
        manifest.note("Transcribed \(result.segments.count) segments with \(result.backend).")
    }

    private func translate(into manifest: inout CLIManifest) async throws {
        guard !manifest.transcript.isEmpty else {
            throw CLIError.stageFailed("Nothing to translate — run `cue transcribe` first, or pass an .srt file.")
        }
        var snapshot = try resolvedSnapshot()
        // The transcript was produced in the language the manifest records;
        // the global setting may since have changed.
        if arguments.value("--language") == nil {
            snapshot.sourceLanguage = manifest.settings.sourceLanguage
        }
        let credentials = makeCredentials(for: snapshot.openAIModel)
        guard credentials.provider == .local || !credentials.apiKey.isEmpty else {
            throw CLIError.stageFailed(
                "No \(credentials.provider.label) API key. Add one in Cue's Settings, or pass --translation-model local/<model>."
            )
        }
        let reporter = console.progressReporter(stage: "translate")
        let translated = try await TranslationService().translate(
            segments: manifest.transcript,
            sourceLanguage: snapshot.sourceLanguage,
            settings: snapshot,
            credentials: credentials,
            existingTranslations: manifest.translation,
            progress: { progress in
                reporter.report(fraction: progress.fraction, detail: progress.detail)
            },
            onPartial: { _ in }
        )
        manifest.stage = "translate"
        manifest.translation = translated
        // Only the translation-facing fields move: the rest still describe
        // the run that produced the transcript.
        manifest.settings.translationTargetLanguage = snapshot.translationTargetLanguage
        manifest.settings.translationModel = snapshot.openAIModel
        manifest.note("Translated \(translated.count) segments into \(snapshot.translationTargetLanguage) with \(snapshot.openAIModel).")
    }

    private func summarize(into manifest: inout CLIManifest) async throws {
        let snapshot = try resolvedSnapshot()
        let segments = manifest.translation.isEmpty ? manifest.transcript : manifest.translation
        guard !segments.isEmpty else {
            throw CLIError.stageFailed("Nothing to summarize — run `cue transcribe` first.")
        }
        // Same rule as the app: an untranslated job is summarized in the
        // film's own language, a translated one in the target language.
        let language =
            manifest.translation.isEmpty
            ? "the same language as the subtitles"
            : (snapshot.translationTargetLanguage.isEmpty ? "English" : snapshot.translationTargetLanguage)

        let primaryModel = arguments.value("--model") ?? settings.resolvedSummaryModel
        let primary = SummaryModelConfiguration(model: primaryModel, credentials: makeCredentials(for: primaryModel))
        let fallback = settings.resolvedSummaryFallbackModel.map { model in
            SummaryModelConfiguration(model: model, credentials: makeCredentials(for: model))
        }
        var detail = settings.summaryDetail
        if let raw = arguments.value("--detail") {
            guard let parsed = SummaryDetail(rawValue: raw) else {
                throw CLIError.badValue("--detail", raw, SummaryDetail.allCases.map(\.rawValue))
            }
            detail = parsed
        }

        console.note("[summarize]      writing intro summary with \(primaryModel)")
        let result = try await TranslationService().summarize(
            segments: segments,
            language: language,
            primary: primary,
            fallback: fallback,
            detail: detail
        )
        manifest.stage = "summarize"
        manifest.summary = result.summary
        manifest.settings.summaryModel = result.model
        manifest.note(
            result.usedFallback
                ? "Summarized with the policy fallback model \(result.model)."
                : "Summarized with \(result.model)."
        )
    }

    private func burnIn(into manifest: inout CLIManifest) async throws {
        let source = manifest.sourceURL
        let role = try burnInRole(manifest)
        let segments = documentSegments(role, in: manifest)
        guard !segments.isEmpty else {
            throw CLIError.stageFailed("Nothing to burn in — the \(role.rawValue) document is empty.")
        }
        var textSize = BurnInService.TextSize.medium
        if let raw = arguments.value("--text-size") {
            guard let parsed = BurnInService.TextSize(rawValue: raw) else {
                throw CLIError.badValue("--text-size", raw, BurnInService.TextSize.allCases.map(\.rawValue))
            }
            textSize = parsed
        }
        let output =
            arguments.value("--output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? source.deletingPathExtension().appendingPathExtension("burned.mp4")

        let duration = await Self.durationSeconds(of: source)
        let reporter = console.progressReporter(stage: "burn-in")
        try await BurnInService().burnIn(
            source: source,
            segments: ExportCoordinator.applyingIntro(segments, format: .srt, summary: manifest.summary),
            textSize: textSize,
            output: output,
            durationSeconds: duration,
            progress: { fraction, detail in
                reporter.report(fraction: fraction, detail: detail)
            }
        )
        manifest.stage = "burn-in"
        manifest.record(outputs: [CLIManifest.Output(role: "video", format: "mp4", path: output.path)])
        manifest.note("Burned \(role.rawValue) subtitles into \(output.lastPathComponent).")
    }

    // MARK: - Documents and output

    enum DocumentRole: String, CaseIterable {
        case original
        case translated
        case bilingual
    }

    private var translationRoles: [DocumentRole] {
        arguments.flag("--bilingual") ? [.translated, .bilingual] : [.translated]
    }

    private func burnInRole(_ manifest: CLIManifest) throws -> DocumentRole {
        guard let raw = arguments.value("--document") else {
            return manifest.translation.isEmpty ? .original : .translated
        }
        guard let role = DocumentRole(rawValue: raw) else {
            throw CLIError.badValue("--document", raw, DocumentRole.allCases.map(\.rawValue))
        }
        return role
    }

    private func documentSegments(_ role: DocumentRole, in manifest: CLIManifest) -> [TranscriptionSegment] {
        switch role {
        case .original:
            return manifest.transcript
        case .translated:
            return manifest.translation
        case .bilingual:
            guard !manifest.transcript.isEmpty, !manifest.translation.isEmpty else { return [] }
            return ExportCoordinator.bilingualSegments(
                transcript: manifest.transcript,
                translated: manifest.translation
            )
        }
    }

    private func writeSubtitles(_ manifest: inout CLIManifest, roles: [DocumentRole]) throws {
        let source = manifest.sourceURL
        let directory = try outputDirectory(for: source)
        let base = source.deletingPathExtension().lastPathComponent
        let formats = try outputFormats
        let target = ExportCoordinator.languageSuffix(manifest.settings.translationTargetLanguage ?? "")

        var documents: [ExportCoordinator.Document] = []
        var documentRoles: [DocumentRole] = []
        for role in roles {
            let segments = documentSegments(role, in: manifest)
            guard !segments.isEmpty else { continue }
            let suffix = role == .original ? "original" : "\(role.rawValue).\(target)"
            documentRoles.append(role)
            documents.append(ExportCoordinator.Document(suffix: suffix, segments: segments))
        }
        guard !documents.isEmpty else { return }

        // Same planner the GUI's export sheet uses, so a scripted export and
        // a hand export name their files identically.
        let plan = ExportCoordinator().plan(
            folder: directory,
            baseName: base,
            documents: documents,
            formats: formats,
            includeLog: false,
            summary: manifest.summary
        )
        // plan() emits one row per format for each document, in document
        // order, so the row index maps back to the role that produced it.
        // Filenames cannot be used for this: a single-document, single-format
        // export is named without a role suffix at all.
        var written: [CLIManifest.Output] = []
        for (index, entry) in plan.subtitleWrites.enumerated() {
            try SubtitleWriter.write(segments: entry.segments, format: entry.format, to: entry.url)
            let role = documentRoles[min(index / max(formats.count, 1), documentRoles.count - 1)]
            written.append(
                CLIManifest.Output(role: role.rawValue, format: entry.format.rawValue, path: entry.url.path)
            )
            console.note("[write] \(entry.url.path)")
        }
        manifest.record(outputs: written)
    }

    private func writeManifest(_ manifest: CLIManifest) throws {
        let directory = try outputDirectory(for: manifest.sourceURL)
        let url = CLIManifest.manifestURL(
            inDirectory: directory,
            baseName: manifest.sourceURL.deletingPathExtension().lastPathComponent
        )
        try manifest.write(to: url)
        console.note("[write] \(url.path)")
    }

    // MARK: - Helpers

    private func makeCredentials(for model: String) -> TranslationCredentials {
        let provider = TranslationProvider.infer(from: model)
        return TranslationCredentials(
            apiKey: settings.translationAPIKey(for: provider),
            prompt: settings.translationPrompt,
            provider: provider,
            localEndpoint: settings.localTranslationEndpoint
        )
    }

    nonisolated static func durationSeconds(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}

enum CLIError: LocalizedError {
    case usage(String)
    case notFound(String)
    case badValue(String, String, [String])
    case stageFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .notFound(let path):
            return "No such file: \(path)"
        case .badValue(let option, let value, let allowed):
            return "\(option) does not accept \(value). Try one of: \(allowed.joined(separator: ", "))."
        case .stageFailed(let message):
            return message
        }
    }

    /// 2 for "you typed it wrong", 1 for "it ran and failed" — the usual
    /// split, so a script can tell a bad invocation from a bad run.
    var exitCode: Int32 {
        switch self {
        case .usage, .badValue, .notFound:
            return 2
        case .stageFailed:
            return 1
        }
    }
}
