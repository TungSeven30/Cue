import Foundation

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
}

enum TranscriptionQualityPreset: String, CaseIterable, Identifiable, Codable, Hashable {
    case fast
    case balanced
    case movieDialogue
    case noisyAudio
    case maximumAccuracy
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .movieDialogue: return "Movie Dialogue"
        case .noisyAudio: return "Noisy Audio"
        case .maximumAccuracy: return "Maximum Accuracy"
        case .custom: return "Custom"
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
                SettingsPreset(label: "Faster Small", value: "small")
            ]
        case .mlxWhisper:
            return [
                SettingsPreset(label: "Large v3 Turbo", value: AppSettingsStore.mlxTurboModel),
                SettingsPreset(label: "Large v3", value: "mlx-community/whisper-large-v3"),
                SettingsPreset(label: "Medium", value: "mlx-community/whisper-medium"),
                SettingsPreset(label: "Small", value: "mlx-community/whisper-small")
            ]
        case .fasterWhisper:
            return [
                SettingsPreset(label: "Large v3 Turbo", value: AppSettingsStore.fasterTurboModel),
                SettingsPreset(label: "Large v3", value: "large-v3"),
                SettingsPreset(label: "Large v2", value: "large-v2"),
                SettingsPreset(label: "Medium", value: "medium"),
                SettingsPreset(label: "Small", value: "small"),
                SettingsPreset(label: "Base", value: "base"),
                SettingsPreset(label: "Tiny", value: "tiny")
            ]
        case .qwen3ASR:
            return [
                SettingsPreset(label: "Qwen3 ASR 1.7B (best)", value: AppSettingsStore.qwen3DefaultModel),
                SettingsPreset(label: "Qwen3 ASR 0.6B (fast)", value: "Qwen/Qwen3-ASR-0.6B")
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
        SettingsPreset(label: "Vietnamese", value: "vi")
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
        SettingsPreset(label: "Vietnamese", value: "Vietnamese")
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
        SettingsPreset(label: "Vietnamese", value: "Vietnamese")
    ]

    // The provider (OpenAI, Anthropic, Google) is inferred from the model
    // name; each provider uses its own API key from Settings.
    static let translationModels: [SettingsPreset] = [
        SettingsPreset(label: "GPT-5.6 Sol", value: "gpt-5.6-sol"),
        SettingsPreset(label: "GPT-5.6 Terra", value: "gpt-5.6-terra"),
        SettingsPreset(label: "GPT-5.6 Luna", value: "gpt-5.6-luna"),
        SettingsPreset(label: "GPT-5.5", value: "gpt-5.5"),
        SettingsPreset(label: "Claude Opus 5", value: "claude-opus-5"),
        SettingsPreset(label: "Claude Sonnet 5", value: "claude-sonnet-5"),
        SettingsPreset(label: "Claude Haiku 4.5", value: "claude-haiku-4-5"),
        SettingsPreset(label: "Gemini 3.1 Pro", value: "gemini-3.1-pro-preview"),
        SettingsPreset(label: "Gemini 3.6 Flash", value: "gemini-3.6-flash"),
        SettingsPreset(label: "Gemini 3.5 Flash-Lite", value: "gemini-3.5-flash-lite")
    ]
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
    @Published var whisperModel: String { didSet { save() } }
    @Published var whisperBackend: WhisperBackend {
        didSet {
            if !isApplyingPreset {
                transcriptionPreset = .custom
            }
            normalizeModelForSelectedBackend()
            save()
        }
    }
    /// The translation model. Despite the name (kept for stored-settings
    /// compatibility) it can be an OpenAI, Anthropic, or Google model; the
    /// provider is inferred from the model name.
    @Published var openAIModel: String { didSet { save() } }
    @Published var openAIAPIKey: String { didSet { save() } }
    @Published var anthropicAPIKey: String { didSet { save() } }
    @Published var googleAPIKey: String { didSet { save() } }
    @Published var translationSourceLanguage: String { didSet { save() } }
    @Published var translationTargetLanguage: String { didSet { save() } }
    @Published var translationPrompt: String { didSet { save() } }
    @Published var autoTranslateAfterTranscription: Bool { didSet { save() } }
    /// Generate a spoiler-free intro from the subtitles when a job finishes,
    /// shown as the first cue of SRT/VTT exports.
    @Published var generateSummary: Bool { didSet { save() } }
    @Published var autoStartAddedJobs: Bool { didSet { save() } }
    @Published var autoExportSidecar: Bool { didSet { save() } }
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
    nonisolated static let mlxTurboModel = "mlx-community/whisper-large-v3-turbo"
    nonisolated static let fasterTurboModel = "large-v3-turbo"
    nonisolated static let qwen3DefaultModel = "Qwen/Qwen3-ASR-1.7B"
    static let defaultTranslationPrompt = """
    You are a professional subtitle translator. Translate faithfully and naturally for the target audience.
    Preserve meaning, tone, names, numbers, and cultural context. Keep each subtitle concise, readable, and aligned to the original timing.
    Do not add explanations, notes, censorship, markdown, or extra segments.
    """

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        transcriptionPreset = TranscriptionPreset(rawValue: defaults.string(forKey: "transcriptionPreset") ?? "") ?? .fastAppleSilicon
        transcriptionQualityPreset = TranscriptionQualityPreset(rawValue: defaults.string(forKey: "transcriptionQualityPreset") ?? "") ?? .balanced
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "auto"
        whisperModel = defaults.string(forKey: "whisperModel") ?? Self.mlxTurboModel
        whisperBackend = WhisperBackend(rawValue: defaults.string(forKey: "whisperBackend") ?? "auto") ?? .auto
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-5.5"
        translationSourceLanguage = defaults.string(forKey: "translationSourceLanguage") ?? "auto"
        translationTargetLanguage = defaults.string(forKey: "translationTargetLanguage") ?? "English"
        translationPrompt = defaults.string(forKey: "translationPrompt") ?? Self.defaultTranslationPrompt
        autoTranslateAfterTranscription = defaults.bool(forKey: "autoTranslateAfterTranscription")
        generateSummary = defaults.bool(forKey: "generateIntroSummary")
        autoStartAddedJobs = defaults.object(forKey: "autoStartAddedJobs") as? Bool ?? true
        autoExportSidecar = defaults.bool(forKey: "autoExportSidecar")
        showAdvancedControls = defaults.bool(forKey: "showAdvancedControls")
        translationChunkMode = TranslationChunkMode(rawValue: defaults.string(forKey: "translationChunkMode") ?? "") ?? .balanced
        translationParallelism = max(1, min(4, defaults.object(forKey: "translationParallelism") as? Int ?? 2))
        lastExportDirectory = defaults.string(forKey: "lastExportDirectory") ?? ""
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
        if let stored = KeychainStore.read(account: Self.apiKeyAccount) {
            resolvedOpenAIKey = stored
        } else if let legacy = defaults.string(forKey: "openAIAPIKey"), !legacy.isEmpty {
            resolvedOpenAIKey = legacy
            KeychainStore.write(legacy, account: Self.apiKeyAccount)
            defaults.removeObject(forKey: "openAIAPIKey")
        } else {
            resolvedOpenAIKey = ""
            defaults.removeObject(forKey: "openAIAPIKey")
        }
        openAIAPIKey = resolvedOpenAIKey
        persistedAPIKey = resolvedOpenAIKey

        let resolvedAnthropicKey = KeychainStore.read(account: Self.anthropicKeyAccount) ?? ""
        anthropicAPIKey = resolvedAnthropicKey
        persistedAnthropicKey = resolvedAnthropicKey
        let resolvedGoogleKey = KeychainStore.read(account: Self.googleKeyAccount) ?? ""
        googleAPIKey = resolvedGoogleKey
        persistedGoogleKey = resolvedGoogleKey

        normalizeModelForSelectedBackend()
        save()
    }

    private var isApplyingPreset = false
    private var isApplyingQualityPreset = false
    private var persistedAPIKey = ""
    private var persistedAnthropicKey = ""
    private var persistedGoogleKey = ""

    var currentTranslationProvider: TranslationProvider {
        TranslationProvider.infer(from: openAIModel)
    }

    var currentTranslationAPIKey: String {
        translationAPIKey(for: currentTranslationProvider)
    }

    func translationAPIKey(for provider: TranslationProvider) -> String {
        switch provider {
        case .openai: return openAIAPIKey
        case .anthropic: return anthropicAPIKey
        case .google: return googleAPIKey
        }
    }

    private func save() {
        defaults.set(transcriptionPreset.rawValue, forKey: "transcriptionPreset")
        defaults.set(transcriptionQualityPreset.rawValue, forKey: "transcriptionQualityPreset")
        defaults.set(sourceLanguage, forKey: "sourceLanguage")
        defaults.set(whisperModel, forKey: "whisperModel")
        defaults.set(whisperBackend.rawValue, forKey: "whisperBackend")
        defaults.set(openAIModel, forKey: "openAIModel")
        defaults.set(translationSourceLanguage, forKey: "translationSourceLanguage")
        defaults.set(translationTargetLanguage, forKey: "translationTargetLanguage")
        defaults.set(translationPrompt, forKey: "translationPrompt")
        defaults.set(autoTranslateAfterTranscription, forKey: "autoTranslateAfterTranscription")
        defaults.set(generateSummary, forKey: "generateIntroSummary")
        defaults.set(autoStartAddedJobs, forKey: "autoStartAddedJobs")
        defaults.set(autoExportSidecar, forKey: "autoExportSidecar")
        defaults.set(showAdvancedControls, forKey: "showAdvancedControls")
        defaults.set(translationChunkMode.rawValue, forKey: "translationChunkMode")
        defaults.set(translationParallelism, forKey: "translationParallelism")
        defaults.set(lastExportDirectory, forKey: "lastExportDirectory")
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
            KeychainStore.write(openAIAPIKey, account: Self.apiKeyAccount)
            persistedAPIKey = openAIAPIKey
        }
        if anthropicAPIKey != persistedAnthropicKey {
            KeychainStore.write(anthropicAPIKey, account: Self.anthropicKeyAccount)
            persistedAnthropicKey = anthropicAPIKey
        }
        if googleAPIKey != persistedGoogleKey {
            KeychainStore.write(googleAPIKey, account: Self.googleKeyAccount)
            persistedGoogleKey = googleAPIKey
        }
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
        isApplyingQualityPreset = true
        switch transcriptionQualityPreset {
        case .fast:
            preprocessAudio = false
            vadFilter = true
            removeEmptySegments = true
            removeRepeatedText = true
            mergeShortSegments = false
            minSegmentDuration = 0.45
            maxMergeGap = 0.25
            beamSize = 3
            bestOf = 3
            temperature = 0
            noSpeechThreshold = 0.6
        case .balanced:
            preprocessAudio = true
            vadFilter = true
            removeEmptySegments = true
            removeRepeatedText = true
            mergeShortSegments = true
            minSegmentDuration = 0.7
            maxMergeGap = 0.45
            beamSize = 5
            bestOf = 5
            temperature = 0
            noSpeechThreshold = 0.6
        case .movieDialogue:
            preprocessAudio = true
            vadFilter = true
            removeEmptySegments = true
            removeRepeatedText = true
            mergeShortSegments = true
            minSegmentDuration = 0.9
            maxMergeGap = 0.65
            beamSize = 6
            bestOf = 6
            temperature = 0
            noSpeechThreshold = 0.5
        case .noisyAudio:
            preprocessAudio = true
            vadFilter = true
            removeEmptySegments = true
            removeRepeatedText = true
            mergeShortSegments = true
            minSegmentDuration = 1.0
            maxMergeGap = 0.8
            beamSize = 7
            bestOf = 7
            temperature = 0
            noSpeechThreshold = 0.45
        case .maximumAccuracy:
            preprocessAudio = true
            vadFilter = true
            removeEmptySegments = true
            removeRepeatedText = true
            mergeShortSegments = true
            minSegmentDuration = 0.8
            maxMergeGap = 0.5
            beamSize = 8
            bestOf = 8
            temperature = 0
            noSpeechThreshold = 0.5
        case .custom:
            break
        }
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
            if force || trimmedModel.isEmpty || trimmedModel.hasPrefix("mlx-community/whisper-") || trimmedModel.hasPrefix("Qwen/") || trimmedModel.hasPrefix("ggml-") {
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
}
