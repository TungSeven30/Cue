import Foundation

enum AfterQueueAction: String, CaseIterable, Identifiable, Codable, Hashable {
    case doNothing
    case sleep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doNothing: return "Do nothing"
        case .sleep: return "Sleep the Mac"
        }
    }
}

enum WhisperBackend: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto
    case mlxWhisper = "mlx-whisper"
    case fasterWhisper = "faster-whisper"
    case qwen3ASR = "qwen3-asr"
    case native = "whisper-cpp"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .mlxWhisper:
            return "MLX Whisper"
        case .fasterWhisper:
            return "Faster Whisper"
        case .qwen3ASR:
            return "Qwen3 ASR"
        case .native:
            return "Built-in (whisper.cpp)"
        }
    }
}

enum TranscriptionPreset: String, CaseIterable, Identifiable, Codable, Hashable {
    // Declaration order drives allCases and therefore picker order; raw
    // values (the persisted case names) are unaffected by ordering.
    case builtIn
    case bestAccuracy
    case fastAppleSilicon
    case mostCompatible
    case higherAccuracy
    case draft
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .builtIn: return "Built-in (no setup)"
        case .bestAccuracy: return "Best Accuracy (Qwen3)"
        case .fastAppleSilicon: return "Fast Apple Silicon"
        case .mostCompatible: return "Most Compatible"
        case .higherAccuracy: return "Higher Accuracy (Whisper)"
        case .draft: return "Small/Fast Draft"
        case .custom: return "Custom"
        }
    }

    var backend: WhisperBackend? {
        switch self {
        case .builtIn: return .native
        case .bestAccuracy: return .qwen3ASR
        case .fastAppleSilicon, .higherAccuracy: return .mlxWhisper
        case .mostCompatible, .draft: return .fasterWhisper
        case .custom: return nil
        }
    }

    var model: String? {
        switch self {
        case .builtIn: return ModelDownloader.defaultModel
        case .bestAccuracy: return AppSettingsStore.qwen3DefaultModel
        case .fastAppleSilicon: return "mlx-community/whisper-large-v3-turbo"
        case .mostCompatible: return "large-v3-turbo"
        case .higherAccuracy: return "mlx-community/whisper-large-v3"
        case .draft: return "small"
        case .custom: return nil
        }
    }
}

enum TranslationChunkMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case safer
    case balanced
    case faster

    var id: String { rawValue }

    var label: String {
        switch self {
        case .safer: return "Safer"
        case .balanced: return "Balanced"
        case .faster: return "Faster"
        }
    }

    var chunkSize: Int {
        switch self {
        case .safer: return 40
        case .balanced: return 80
        case .faster: return 120
        }
    }

    /// Approximate input budget for one LLM request. Segment counts remain a
    /// hard safety cap, but text size is the better predictor of provider
    /// latency and output-limit failures (especially for CJK subtitles).
    var targetInputTokens: Int {
        switch self {
        case .safer: return 1_800
        case .balanced: return 3_200
        case .faster: return 5_000
        }
    }

    /// Start cloud translation after the first useful streamed Qwen batch
    /// instead of waiting for a full offline-sized translation chunk.
    var initialStreamingSegments: Int {
        switch self {
        case .safer: return 12
        case .balanced: return 16
        case .faster: return 20
        }
    }
}

enum TranscriptionQualityPreset: String, CaseIterable, Identifiable, Codable, Hashable {
    case qwenMovie
    case fast
    case balanced
    case movieDialogue
    case noisyAudio
    case maximumAccuracy
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .qwenMovie: return "Qwen Movie"
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .movieDialogue: return "Movie Dialogue"
        case .noisyAudio: return "Noisy Audio"
        case .maximumAccuracy: return "Maximum Accuracy"
        case .custom: return "Custom"
        }
    }
}

/// The decoding/cleanup parameter set a quality preset stands for, as a pure
/// value so job-settings resolution can use it without mutating the store.
struct TranscriptionQualityParameters: Hashable {
    var preprocessAudio: Bool
    var vadFilter: Bool
    var removeEmptySegments: Bool
    var removeRepeatedText: Bool
    var mergeShortSegments: Bool
    var minSegmentDuration: Double
    var maxMergeGap: Double
    var beamSize: Int
    var bestOf: Int
    var temperature: Double
    var noSpeechThreshold: Double
}

extension TranscriptionQualityPreset {
    static func available(for backend: WhisperBackend) -> [TranscriptionQualityPreset] {
        if backend == .qwen3ASR {
            return [.qwenMovie, .custom]
        }
        return allCases.filter { $0 != .qwenMovie }
    }

    /// `nil` for `.custom`, which means "whatever the individual fields say".
    var parameters: TranscriptionQualityParameters? {
        switch self {
        case .qwenMovie:
            // Qwen uses greedy decoding and its own long-audio handling, so
            // Whisper beam/VAD/no-speech knobs are deliberately neutral here.
            // Clean digital movie audio stays untouched and legitimate spoken
            // repetition is preserved.
            return TranscriptionQualityParameters(
                preprocessAudio: false, vadFilter: false, removeEmptySegments: true,
                removeRepeatedText: false, mergeShortSegments: true,
                minSegmentDuration: 0.9, maxMergeGap: 0.65,
                beamSize: 1, bestOf: 1, temperature: 0, noSpeechThreshold: 0.5)
        case .fast:
            return TranscriptionQualityParameters(
                preprocessAudio: false, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: false,
                minSegmentDuration: 0.45, maxMergeGap: 0.25,
                beamSize: 3, bestOf: 3, temperature: 0, noSpeechThreshold: 0.6)
        case .balanced:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 0.7, maxMergeGap: 0.45,
                beamSize: 5, bestOf: 5, temperature: 0, noSpeechThreshold: 0.6)
        case .movieDialogue:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 0.9, maxMergeGap: 0.65,
                beamSize: 6, bestOf: 6, temperature: 0, noSpeechThreshold: 0.5)
        case .noisyAudio:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 1.0, maxMergeGap: 0.8,
                beamSize: 7, bestOf: 7, temperature: 0, noSpeechThreshold: 0.45)
        case .maximumAccuracy:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 0.8, maxMergeGap: 0.5,
                beamSize: 8, bestOf: 8, temperature: 0, noSpeechThreshold: 0.5)
        case .custom:
            return nil
        }
    }
}

/// How thorough the spoiler-free intro summary should be.
enum SummaryDetail: String, CaseIterable, Identifiable, Codable, Hashable {
    case brief
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brief: return "Brief"
        case .detailed: return "Detailed"
        }
    }
}

struct SettingsPreset: Identifiable, Hashable {
    let label: String
    let value: String

    var id: String { value }
}

enum AppSettingPresets {
    static func whisperModels(for backend: WhisperBackend) -> [SettingsPreset] {
        switch backend {
        case .auto:
            return [
                SettingsPreset(label: "MLX Large v3 Turbo", value: AppSettingsStore.mlxTurboModel),
                SettingsPreset(label: "MLX Large v3", value: "mlx-community/whisper-large-v3"),
                SettingsPreset(label: "Faster Large v3 Turbo", value: AppSettingsStore.fasterTurboModel),
                SettingsPreset(label: "Faster Large v3", value: "large-v3"),
                SettingsPreset(label: "Faster Medium", value: "medium"),
                SettingsPreset(label: "Faster Small", value: "small"),
            ]
        case .mlxWhisper:
            return [
                SettingsPreset(label: "Large v3 Turbo", value: AppSettingsStore.mlxTurboModel),
                SettingsPreset(label: "Large v3", value: "mlx-community/whisper-large-v3"),
                SettingsPreset(label: "Medium", value: "mlx-community/whisper-medium"),
                SettingsPreset(label: "Small", value: "mlx-community/whisper-small"),
            ]
        case .fasterWhisper:
            return [
                SettingsPreset(label: "Large v3 Turbo", value: AppSettingsStore.fasterTurboModel),
                SettingsPreset(label: "Large v3", value: "large-v3"),
                SettingsPreset(label: "Large v2", value: "large-v2"),
                SettingsPreset(label: "Medium", value: "medium"),
                SettingsPreset(label: "Small", value: "small"),
                SettingsPreset(label: "Base", value: "base"),
                SettingsPreset(label: "Tiny", value: "tiny"),
            ]
        case .qwen3ASR:
            return [
                SettingsPreset(label: "Qwen3 ASR 1.7B (best)", value: AppSettingsStore.qwen3DefaultModel),
                SettingsPreset(label: "Qwen3 ASR 0.6B (fast)", value: "Qwen/Qwen3-ASR-0.6B"),
            ]
        case .native:
            return ModelDownloader.models.map { model in
                SettingsPreset(label: nativeModelLabel(for: model), value: model)
            }
        }
    }

    private static func nativeModelLabel(for model: String) -> String {
        switch model {
        case "ggml-large-v3-turbo-q5_0.bin": return "Large v3 Turbo (quantized, recommended)"
        case "ggml-large-v3-turbo.bin": return "Large v3 Turbo"
        case "ggml-medium.bin": return "Medium"
        case "ggml-small.bin": return "Small"
        case "ggml-base.bin": return "Base"
        case "ggml-tiny.bin": return "Tiny"
        default: return model
        }
    }

    static let transcriptionLanguages: [SettingsPreset] = [
        SettingsPreset(label: "Auto", value: "auto"),
        SettingsPreset(label: "English", value: "en"),
        SettingsPreset(label: "Japanese", value: "ja"),
        SettingsPreset(label: "Chinese", value: "zh"),
        SettingsPreset(label: "Korean", value: "ko"),
        SettingsPreset(label: "Spanish", value: "es"),
        SettingsPreset(label: "French", value: "fr"),
        SettingsPreset(label: "German", value: "de"),
        SettingsPreset(label: "Indonesian", value: "id"),
        SettingsPreset(label: "Thai", value: "th"),
        SettingsPreset(label: "Vietnamese", value: "vi"),
    ]

    static let translationSourceLanguages: [SettingsPreset] = [
        SettingsPreset(label: "Auto", value: "auto"),
        SettingsPreset(label: "English", value: "English"),
        SettingsPreset(label: "Japanese", value: "Japanese"),
        SettingsPreset(label: "Chinese", value: "Chinese"),
        SettingsPreset(label: "Korean", value: "Korean"),
        SettingsPreset(label: "Spanish", value: "Spanish"),
        SettingsPreset(label: "French", value: "French"),
        SettingsPreset(label: "German", value: "German"),
        SettingsPreset(label: "Indonesian", value: "Indonesian"),
        SettingsPreset(label: "Thai", value: "Thai"),
        SettingsPreset(label: "Vietnamese", value: "Vietnamese"),
    ]

    static let translationTargetLanguages: [SettingsPreset] = [
        SettingsPreset(label: "English", value: "English"),
        SettingsPreset(label: "Japanese", value: "Japanese"),
        SettingsPreset(label: "Chinese", value: "Chinese"),
        SettingsPreset(label: "Korean", value: "Korean"),
        SettingsPreset(label: "Spanish", value: "Spanish"),
        SettingsPreset(label: "French", value: "French"),
        SettingsPreset(label: "German", value: "German"),
        SettingsPreset(label: "Indonesian", value: "Indonesian"),
        SettingsPreset(label: "Thai", value: "Thai"),
        SettingsPreset(label: "Vietnamese", value: "Vietnamese"),
    ]

    // The provider (OpenAI, Anthropic, Google, OpenRouter, Groq, Cerebras)
    // is inferred from the model name; each provider uses its own API key
    // from Settings.
    static let translationModels: [SettingsPreset] = [
        SettingsPreset(label: "GPT-5.6 Sol", value: "gpt-5.6-sol"),
        SettingsPreset(label: "GPT-5.6 Terra", value: "gpt-5.6-terra"),
        SettingsPreset(label: "GPT-5.6 Luna", value: "gpt-5.6-luna"),
        SettingsPreset(label: "GPT-5.5", value: "gpt-5.5"),
        SettingsPreset(label: "Claude Fable 5", value: "claude-fable-5"),
        SettingsPreset(label: "Claude Opus 5", value: "claude-opus-5"),
        SettingsPreset(label: "Claude Sonnet 5", value: "claude-sonnet-5"),
        SettingsPreset(label: "Claude Haiku 4.5", value: "claude-haiku-4-5"),
        SettingsPreset(label: "Gemini 3.1 Pro", value: "gemini-3.1-pro-preview"),
        SettingsPreset(label: "Gemini 3.6 Flash", value: "gemini-3.6-flash"),
        SettingsPreset(label: "Gemini 3.5 Flash-Lite", value: "gemini-3.5-flash-lite"),
        SettingsPreset(label: "Groq: GPT-OSS 120B", value: "groq/openai/gpt-oss-120b"),
        SettingsPreset(label: "Groq: GPT-OSS 20B", value: "groq/openai/gpt-oss-20b"),
        SettingsPreset(label: "Groq: Qwen 3.8 27B", value: "groq/qwen/qwen3.8-27b"),
        SettingsPreset(label: "Cerebras: GPT-OSS 120B", value: "cerebras/gpt-oss-120b"),
        SettingsPreset(label: "Cerebras: Gemma 4 31B", value: "cerebras/gemma-4-31b"),
        SettingsPreset(label: "Local server (LM Studio / Ollama)", value: "local/"),
        SettingsPreset(label: "OpenRouter: Qwen 3.8 Max", value: "openrouter/qwen/qwen3.8-max"),
        SettingsPreset(label: "OpenRouter: Qwen 3.8 Flash", value: "openrouter/qwen/qwen3.8-flash"),
        SettingsPreset(label: "OpenRouter: Qwen 3.7 Flash", value: "openrouter/qwen/qwen3.7-flash"),
    ]

    static let summaryModels: [SettingsPreset] =
        [
            SettingsPreset(label: "Same as translation", value: "")
        ] + translationModels

    static let summaryFallbackModels: [SettingsPreset] =
        [
            SettingsPreset(label: "No fallback", value: "")
        ] + translationModels
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var transcriptionPreset: TranscriptionPreset {
        didSet {
            applyTranscriptionPreset()
            save()
        }
    }
    @Published var transcriptionQualityPreset: TranscriptionQualityPreset {
        didSet {
            applyQualityPreset()
            save()
        }
    }
    @Published var sourceLanguage: String { didSet { save() } }
    /// Space-separated names and terms supplied to Qwen's context prompt.
    @Published var qwenContext: String { didSet { save() } }
    @Published var whisperModel: String { didSet { save() } }
    @Published var whisperBackend: WhisperBackend {
        didSet {
            if !isApplyingPreset {
                transcriptionPreset = .custom
            }
            normalizeModelForSelectedBackend()
            normalizeQualityPresetForSelectedBackend()
            save()
        }
    }
    /// The translation model. Despite the name (kept for stored-settings
    /// compatibility) it can be an OpenAI, Anthropic, Google, OpenRouter,
    /// Groq, or Cerebras model; the provider is inferred from the model name.
    @Published var openAIModel: String { didSet { save() } }
    @Published var openAIAPIKey: String { didSet { save() } }
    @Published var anthropicAPIKey: String { didSet { save() } }
    @Published var googleAPIKey: String { didSet { save() } }
    @Published var openRouterAPIKey: String { didSet { save() } }
    @Published var groqAPIKey: String { didSet { save() } }
    @Published var cerebrasAPIKey: String { didSet { save() } }
    @Published var secretPersistenceError: String? = nil
    /// Base URL of the OpenAI-compatible server used by `local/` models.
    @Published var localTranslationEndpoint: String { didSet { save() } }
    @Published var translationSourceLanguage: String { didSet { save() } }
    @Published var translationTargetLanguage: String { didSet { save() } }
    @Published var translationPrompt: String { didSet { save() } }
    @Published var autoTranslateAfterTranscription: Bool { didSet { save() } }
    /// Generate a spoiler-free intro from the subtitles when a job finishes,
    /// shown as the first cue of SRT/VTT exports.
    @Published var generateSummary: Bool { didSet { save() } }
    @Published var summaryDetail: SummaryDetail { didSet { save() } }
    /// Empty means use the translation model. A non-empty value selects an
    /// independent cloud or local model for summaries.
    @Published var summaryModel: String { didSet { save() } }
    /// Empty disables fallback. A configured model is tried only after an
    /// explicit policy/safety refusal from the primary summary model.
    @Published var summaryFallbackModel: String { didSet { save() } }
    @Published var autoStartAddedJobs: Bool { didSet { save() } }
    @Published var autoExportSidecar: Bool { didSet { save() } }
    /// Days after which finished jobs are auto-archived at launch; 0 = never.
    @Published var autoArchiveDays: Int { didSet { save() } }
    /// What to do when the queue drains (sleep the Mac for overnight runs).
    @Published var afterQueueAction: AfterQueueAction { didSet { save() } }
    @Published var watchFolders: [WatchFolder] { didSet { save() } }
    @Published var showAdvancedControls: Bool { didSet { save() } }
    @Published var translationChunkMode: TranslationChunkMode { didSet { save() } }
    @Published var translationParallelism: Int {
        didSet {
            let clamped = max(1, min(4, translationParallelism))
            if translationParallelism != clamped {
                translationParallelism = clamped
                return
            }
            save()
        }
    }
    @Published var lastExportDirectory: String { didSet { save() } }
    /// Where yt-dlp downloads land. Empty means the built-in default
    /// (~/Movies/Cue Downloads); a stored path is used verbatim.
    @Published var downloadDirectory: String { didSet { save() } }
    @Published var preprocessAudio: Bool { didSet { markCustomQualityAndSave() } }
    @Published var vadFilter: Bool { didSet { markCustomQualityAndSave() } }
    @Published var removeEmptySegments: Bool { didSet { markCustomQualityAndSave() } }
    @Published var removeRepeatedText: Bool { didSet { markCustomQualityAndSave() } }
    @Published var mergeShortSegments: Bool { didSet { markCustomQualityAndSave() } }
    @Published var minSegmentDuration: Double { didSet { markCustomQualityAndSave() } }
    @Published var maxMergeGap: Double { didSet { markCustomQualityAndSave() } }
    @Published var beamSize: Int {
        didSet {
            let clamped = max(1, min(10, beamSize))
            if beamSize != clamped {
                beamSize = clamped
                return
            }
            markCustomQualityAndSave()
        }
    }
    @Published var bestOf: Int {
        didSet {
            let clamped = max(1, min(10, bestOf))
            if bestOf != clamped {
                bestOf = clamped
                return
            }
            markCustomQualityAndSave()
        }
    }
    @Published var temperature: Double {
        didSet {
            let clamped = max(0, min(1, temperature))
            if temperature != clamped {
                temperature = clamped
                return
            }
            markCustomQualityAndSave()
        }
    }
    @Published var noSpeechThreshold: Double {
        didSet {
            let clamped = max(0, min(1, noSpeechThreshold))
            if noSpeechThreshold != clamped {
                noSpeechThreshold = clamped
                return
            }
            markCustomQualityAndSave()
        }
    }

    private let defaults: UserDefaults
    private static let apiKeyAccount = "openAIAPIKey"
    private static let anthropicKeyAccount = "anthropicAPIKey"
    private static let googleKeyAccount = "googleAPIKey"
    private static let openRouterKeyAccount = "openRouterAPIKey"
    private static let groqKeyAccount = "groqAPIKey"
    private static let cerebrasKeyAccount = "cerebrasAPIKey"
    nonisolated static let mlxTurboModel = "mlx-community/whisper-large-v3-turbo"
    nonisolated static let fasterTurboModel = "large-v3-turbo"
    nonisolated static let qwen3DefaultModel = "Qwen/Qwen3-ASR-1.7B"
    /// LM Studio's default server address.
    nonisolated static let defaultLocalTranslationEndpoint = "http://localhost:1234/v1"
    static let defaultTranslationPrompt = """
        You are a professional subtitle translator. Translate faithfully and naturally for the target audience.
        Preserve meaning, tone, names, numbers, and cultural context. Keep each subtitle concise, readable, and aligned to the original timing.
        Do not add explanations, notes, censorship, markdown, or extra segments.
        """

    init(
        defaults: UserDefaults = .standard,
        readSecret: @escaping (String) -> String? = { KeychainStore.read(account: $0) },
        writeSecret: @escaping (String, String) -> Bool = { KeychainStore.write($0, account: $1) }
    ) {
        self.defaults = defaults
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        // save() always writes the whisperBackend key, so its absence means a
        // fresh install: default to the zero-setup built-in engine. Any stored
        // value — including legacy "auto" or an unknown string — takes the
        // existing decode path so nothing changes for current users.
        if defaults.string(forKey: "whisperBackend") == nil {
            transcriptionPreset = .builtIn
            whisperModel = ModelDownloader.defaultModel
            whisperBackend = .native
        } else {
            transcriptionPreset = TranscriptionPreset(rawValue: defaults.string(forKey: "transcriptionPreset") ?? "") ?? .fastAppleSilicon
            whisperModel = defaults.string(forKey: "whisperModel") ?? Self.mlxTurboModel
            whisperBackend = WhisperBackend(rawValue: defaults.string(forKey: "whisperBackend") ?? "auto") ?? .auto
        }
        transcriptionQualityPreset = TranscriptionQualityPreset(rawValue: defaults.string(forKey: "transcriptionQualityPreset") ?? "") ?? .balanced
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "auto"
        qwenContext = defaults.string(forKey: "qwenContext") ?? ""
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-5.5"
        localTranslationEndpoint = defaults.string(forKey: "localTranslationEndpoint") ?? Self.defaultLocalTranslationEndpoint
        translationSourceLanguage = defaults.string(forKey: "translationSourceLanguage") ?? "auto"
        translationTargetLanguage = defaults.string(forKey: "translationTargetLanguage") ?? "English"
        translationPrompt = defaults.string(forKey: "translationPrompt") ?? Self.defaultTranslationPrompt
        autoTranslateAfterTranscription = defaults.bool(forKey: "autoTranslateAfterTranscription")
        generateSummary = defaults.bool(forKey: "generateIntroSummary")
        summaryDetail = SummaryDetail(rawValue: defaults.string(forKey: "summaryDetail") ?? "") ?? .brief
        summaryModel = defaults.string(forKey: "summaryModel") ?? ""
        summaryFallbackModel = defaults.string(forKey: "summaryFallbackModel") ?? ""
        autoStartAddedJobs = defaults.object(forKey: "autoStartAddedJobs") as? Bool ?? true
        autoExportSidecar = defaults.bool(forKey: "autoExportSidecar")
        autoArchiveDays = defaults.object(forKey: "autoArchiveDays") as? Int ?? 30
        afterQueueAction = AfterQueueAction(rawValue: defaults.string(forKey: "afterQueueAction") ?? "") ?? .doNothing
        if let data = defaults.data(forKey: "watchFolders"),
            let decoded = try? JSONDecoder().decode([WatchFolder].self, from: data)
        {
            watchFolders = decoded
        } else if let legacyPath = defaults.string(forKey: "watchFolderPath"), !legacyPath.isEmpty {
            // One-time migration from the single-folder era (v2.2.x): the
            // legacy folder becomes the first list entry, keeping its
            // enabled state and profile.
            var migrated = WatchFolder(path: legacyPath)
            migrated.enabled = defaults.bool(forKey: "watchFolderEnabled")
            if let profileData = defaults.data(forKey: "watchFolderProfile"),
                let profile = try? JSONDecoder().decode(JobSettingsOverrides.self, from: profileData)
            {
                migrated.profile = profile
            }
            watchFolders = [migrated]
        } else {
            watchFolders = []
        }
        showAdvancedControls = defaults.bool(forKey: "showAdvancedControls")
        translationChunkMode = TranslationChunkMode(rawValue: defaults.string(forKey: "translationChunkMode") ?? "") ?? .balanced
        translationParallelism = max(1, min(4, defaults.object(forKey: "translationParallelism") as? Int ?? 2))
        lastExportDirectory = defaults.string(forKey: "lastExportDirectory") ?? ""
        downloadDirectory = defaults.string(forKey: "downloadDirectory") ?? ""
        preprocessAudio = defaults.object(forKey: "preprocessAudio") as? Bool ?? true
        vadFilter = defaults.object(forKey: "vadFilter") as? Bool ?? true
        removeEmptySegments = defaults.object(forKey: "removeEmptySegments") as? Bool ?? true
        removeRepeatedText = defaults.object(forKey: "removeRepeatedText") as? Bool ?? true
        mergeShortSegments = defaults.object(forKey: "mergeShortSegments") as? Bool ?? true
        minSegmentDuration = defaults.object(forKey: "minSegmentDuration") as? Double ?? 0.7
        maxMergeGap = defaults.object(forKey: "maxMergeGap") as? Double ?? 0.45
        beamSize = max(1, min(10, defaults.object(forKey: "beamSize") as? Int ?? 5))
        bestOf = max(1, min(10, defaults.object(forKey: "bestOf") as? Int ?? 5))
        temperature = max(0, min(1, defaults.object(forKey: "temperature") as? Double ?? 0))
        noSpeechThreshold = max(0, min(1, defaults.object(forKey: "noSpeechThreshold") as? Double ?? 0.6))

        // The API keys live in the Keychain. Migrate any legacy plaintext key
        // that earlier builds stored in UserDefaults, then scrub it.
        let resolvedOpenAIKey: String
        if let stored = readSecret(Self.apiKeyAccount) {
            resolvedOpenAIKey = stored
        } else if let legacy = defaults.string(forKey: "openAIAPIKey"), !legacy.isEmpty {
            resolvedOpenAIKey = legacy
            // Never erase the only durable copy until Keychain confirms the
            // replacement. A denied/locked Keychain retries next launch.
            if writeSecret(legacy, Self.apiKeyAccount) {
                defaults.removeObject(forKey: "openAIAPIKey")
            } else {
                secretPersistenceError = "The OpenAI API key could not be moved to Keychain. The existing settings copy was kept and Cue will retry."
            }
        } else {
            resolvedOpenAIKey = ""
            defaults.removeObject(forKey: "openAIAPIKey")
        }
        openAIAPIKey = resolvedOpenAIKey
        persistedAPIKey = resolvedOpenAIKey

        let resolvedAnthropicKey = readSecret(Self.anthropicKeyAccount) ?? ""
        anthropicAPIKey = resolvedAnthropicKey
        persistedAnthropicKey = resolvedAnthropicKey
        let resolvedGoogleKey = readSecret(Self.googleKeyAccount) ?? ""
        googleAPIKey = resolvedGoogleKey
        persistedGoogleKey = resolvedGoogleKey
        let resolvedOpenRouterKey = readSecret(Self.openRouterKeyAccount) ?? ""
        openRouterAPIKey = resolvedOpenRouterKey
        persistedOpenRouterKey = resolvedOpenRouterKey
        let resolvedGroqKey = readSecret(Self.groqKeyAccount) ?? ""
        groqAPIKey = resolvedGroqKey
        persistedGroqKey = resolvedGroqKey
        let resolvedCerebrasKey = readSecret(Self.cerebrasKeyAccount) ?? ""
        cerebrasAPIKey = resolvedCerebrasKey
        persistedCerebrasKey = resolvedCerebrasKey

        normalizeModelForSelectedBackend()
        normalizeQualityPresetForSelectedBackend()
        save()
    }

    private let readSecret: (String) -> String?
    private let writeSecret: (String, String) -> Bool
    private var isApplyingPreset = false
    private var isApplyingQualityPreset = false
    private var persistedAPIKey = ""
    private var persistedAnthropicKey = ""
    private var persistedGoogleKey = ""
    private var persistedOpenRouterKey = ""
    private var persistedGroqKey = ""
    private var persistedCerebrasKey = ""

    var currentTranslationProvider: TranslationProvider {
        TranslationProvider.infer(from: openAIModel)
    }

    var currentTranslationAPIKey: String {
        translationAPIKey(for: currentTranslationProvider)
    }

    var resolvedSummaryModel: String {
        let selected = summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? openAIModel.trimmingCharacters(in: .whitespacesAndNewlines) : selected
    }

    var resolvedSummaryFallbackModel: String? {
        let fallback = summaryFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, fallback != resolvedSummaryModel else { return nil }
        return fallback
    }

    var currentSummaryProvider: TranslationProvider {
        TranslationProvider.infer(from: resolvedSummaryModel)
    }

    /// Whether the selected translation model can actually run: cloud
    /// providers need their API key, the local provider needs a server URL
    /// (and never a key). UI gates and auto-translate checks read this
    /// instead of testing `currentTranslationAPIKey` directly.
    var isTranslationReady: Bool {
        isModelReady(openAIModel)
    }

    var isSummaryReady: Bool {
        isModelReady(resolvedSummaryModel)
    }

    func isModelReady(_ model: String) -> Bool {
        let provider = TranslationProvider.infer(from: model)
        switch provider {
        case .local:
            return !localTranslationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openai, .anthropic, .google, .openRouter, .groq, .cerebras:
            return !translationAPIKey(for: provider).isEmpty
        }
    }

    func modelReadinessReason(_ model: String) -> String {
        let provider = TranslationProvider.infer(from: model)
        if provider == .local {
            return "no local server URL is configured"
        }
        return "no \(provider.label) API key is configured"
    }

    func translationAPIKey(for provider: TranslationProvider) -> String {
        switch provider {
        case .openai: return openAIAPIKey
        case .anthropic: return anthropicAPIKey
        case .google: return googleAPIKey
        case .openRouter: return openRouterAPIKey
        case .groq: return groqAPIKey
        case .cerebras: return cerebrasAPIKey
        // Local servers need no API key.
        case .local: return ""
        }
    }

    private func save() {
        defaults.set(transcriptionPreset.rawValue, forKey: "transcriptionPreset")
        defaults.set(transcriptionQualityPreset.rawValue, forKey: "transcriptionQualityPreset")
        defaults.set(sourceLanguage, forKey: "sourceLanguage")
        defaults.set(qwenContext, forKey: "qwenContext")
        defaults.set(whisperModel, forKey: "whisperModel")
        defaults.set(whisperBackend.rawValue, forKey: "whisperBackend")
        defaults.set(openAIModel, forKey: "openAIModel")
        defaults.set(localTranslationEndpoint, forKey: "localTranslationEndpoint")
        defaults.set(translationSourceLanguage, forKey: "translationSourceLanguage")
        defaults.set(translationTargetLanguage, forKey: "translationTargetLanguage")
        defaults.set(translationPrompt, forKey: "translationPrompt")
        defaults.set(autoTranslateAfterTranscription, forKey: "autoTranslateAfterTranscription")
        defaults.set(generateSummary, forKey: "generateIntroSummary")
        defaults.set(summaryDetail.rawValue, forKey: "summaryDetail")
        defaults.set(summaryModel, forKey: "summaryModel")
        defaults.set(summaryFallbackModel, forKey: "summaryFallbackModel")
        defaults.set(autoStartAddedJobs, forKey: "autoStartAddedJobs")
        defaults.set(autoExportSidecar, forKey: "autoExportSidecar")
        defaults.set(autoArchiveDays, forKey: "autoArchiveDays")
        defaults.set(afterQueueAction.rawValue, forKey: "afterQueueAction")
        if let data = try? JSONEncoder().encode(watchFolders) {
            defaults.set(data, forKey: "watchFolders")
        }
        defaults.set(showAdvancedControls, forKey: "showAdvancedControls")
        defaults.set(translationChunkMode.rawValue, forKey: "translationChunkMode")
        defaults.set(translationParallelism, forKey: "translationParallelism")
        defaults.set(lastExportDirectory, forKey: "lastExportDirectory")
        defaults.set(downloadDirectory, forKey: "downloadDirectory")
        defaults.set(preprocessAudio, forKey: "preprocessAudio")
        defaults.set(vadFilter, forKey: "vadFilter")
        defaults.set(removeEmptySegments, forKey: "removeEmptySegments")
        defaults.set(removeRepeatedText, forKey: "removeRepeatedText")
        defaults.set(mergeShortSegments, forKey: "mergeShortSegments")
        defaults.set(minSegmentDuration, forKey: "minSegmentDuration")
        defaults.set(maxMergeGap, forKey: "maxMergeGap")
        defaults.set(beamSize, forKey: "beamSize")
        defaults.set(bestOf, forKey: "bestOf")
        defaults.set(temperature, forKey: "temperature")
        defaults.set(noSpeechThreshold, forKey: "noSpeechThreshold")
        // save() runs on every settings mutation; only touch the Keychain
        // when a key itself changed so typing elsewhere (e.g. the prompt
        // editor) does not trigger a Keychain write per keystroke.
        if openAIAPIKey != persistedAPIKey {
            if writeSecret(openAIAPIKey, Self.apiKeyAccount) {
                persistedAPIKey = openAIAPIKey
            } else {
                secretPersistenceError = "The OpenAI API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
            }
        }
        if anthropicAPIKey != persistedAnthropicKey {
            if writeSecret(anthropicAPIKey, Self.anthropicKeyAccount) {
                persistedAnthropicKey = anthropicAPIKey
            } else {
                secretPersistenceError = "The Anthropic API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
            }
        }
        if openRouterAPIKey != persistedOpenRouterKey {
            if writeSecret(openRouterAPIKey, Self.openRouterKeyAccount) {
                persistedOpenRouterKey = openRouterAPIKey
            } else {
                secretPersistenceError = "The OpenRouter API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
            }
        }
        if googleAPIKey != persistedGoogleKey {
            if writeSecret(googleAPIKey, Self.googleKeyAccount) {
                persistedGoogleKey = googleAPIKey
            } else {
                secretPersistenceError = "The Google API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
            }
        }
        if groqAPIKey != persistedGroqKey {
            if writeSecret(groqAPIKey, Self.groqKeyAccount) {
                persistedGroqKey = groqAPIKey
            } else {
                secretPersistenceError = "The Groq API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
            }
        }
        if cerebrasAPIKey != persistedCerebrasKey {
            if writeSecret(cerebrasAPIKey, Self.cerebrasKeyAccount) {
                persistedCerebrasKey = cerebrasAPIKey
            } else {
                secretPersistenceError = "The Cerebras API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
            }
        }
    }

    /// The folder yt-dlp writes into, with the stored path taking priority
    /// over the built-in default and `~` expanded.
    var resolvedDownloadDirectory: URL {
        let trimmed = downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MediaDownloadService.defaultDirectory() }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    func resetTranslationPrompt() {
        translationPrompt = Self.defaultTranslationPrompt
    }

    var transcriptionValidationMessage: String? {
        let model = whisperModel.trimmingCharacters(in: .whitespacesAndNewlines)
        switch whisperBackend {
        case .fasterWhisper:
            return model.hasPrefix("mlx-community/") || model.hasPrefix("Qwen/") || model.hasPrefix("ggml-")
                ? "Faster Whisper needs a Faster Whisper model such as \(Self.fasterTurboModel)."
                : nil
        case .mlxWhisper:
            return model.hasPrefix("mlx-community/")
                ? nil
                : "MLX Whisper works best with an MLX model such as \(Self.mlxTurboModel)."
        case .qwen3ASR:
            return model.hasPrefix("Qwen/Qwen3-ASR")
                ? nil
                : "Qwen3 ASR needs a Qwen3 model such as \(Self.qwen3DefaultModel)."
        case .native:
            return model.hasPrefix("ggml-")
                ? nil
                : "The built-in engine needs a GGML model such as \(ModelDownloader.defaultModel)."
        case .auto:
            return nil
        }
    }

    func repairTranscriptionModelForBackend() {
        normalizeModelForSelectedBackend(force: true)
    }

    private func applyTranscriptionPreset() {
        guard let backend = transcriptionPreset.backend, let model = transcriptionPreset.model else {
            return
        }
        isApplyingPreset = true
        whisperBackend = backend
        whisperModel = model
        isApplyingPreset = false
    }

    private func applyQualityPreset() {
        guard !isApplyingQualityPreset else { return }
        guard let params = transcriptionQualityPreset.parameters else { return }
        isApplyingQualityPreset = true
        preprocessAudio = params.preprocessAudio
        vadFilter = params.vadFilter
        removeEmptySegments = params.removeEmptySegments
        removeRepeatedText = params.removeRepeatedText
        mergeShortSegments = params.mergeShortSegments
        minSegmentDuration = params.minSegmentDuration
        maxMergeGap = params.maxMergeGap
        beamSize = params.beamSize
        bestOf = params.bestOf
        temperature = params.temperature
        noSpeechThreshold = params.noSpeechThreshold
        isApplyingQualityPreset = false
    }

    private func markCustomQualityAndSave() {
        if !isApplyingQualityPreset {
            transcriptionQualityPreset = .custom
        }
        save()
    }

    private func normalizeModelForSelectedBackend(force: Bool = false) {
        let trimmedModel = whisperModel.trimmingCharacters(in: .whitespacesAndNewlines)

        switch whisperBackend {
        case .auto, .mlxWhisper:
            if force || trimmedModel.isEmpty || trimmedModel == Self.fasterTurboModel || trimmedModel.hasPrefix("Qwen/") || trimmedModel.hasPrefix("ggml-") {
                whisperModel = Self.mlxTurboModel
            }
        case .fasterWhisper:
            if force || trimmedModel.isEmpty || trimmedModel.hasPrefix("mlx-community/whisper-") || trimmedModel.hasPrefix("Qwen/")
                || trimmedModel.hasPrefix("ggml-")
            {
                whisperModel = Self.fasterTurboModel
            }
        case .qwen3ASR:
            if force || !trimmedModel.hasPrefix("Qwen/Qwen3-ASR") {
                whisperModel = Self.qwen3DefaultModel
            }
        case .native:
            if force || !trimmedModel.hasPrefix("ggml-") {
                whisperModel = ModelDownloader.defaultModel
            }
        }
    }

    private func normalizeQualityPresetForSelectedBackend() {
        if whisperBackend == .qwen3ASR {
            if transcriptionQualityPreset != .qwenMovie, transcriptionQualityPreset != .custom {
                transcriptionQualityPreset = .qwenMovie
            }
        } else if transcriptionQualityPreset == .qwenMovie {
            transcriptionQualityPreset = .balanced
        }
    }
}
