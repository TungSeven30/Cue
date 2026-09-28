import Foundation

/// Sections of the Settings window's sidebar. Shared so other surfaces (the
/// ⌘K palette) can open Settings on a given pane: write the raw value to
/// `storageKey`, then call `openSettings`. Raw values are persisted.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case models
    case transcribe
    case translate
    case summary
    case apiKeys

    static let storageKey = "settingsSelectedPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .models: "Models"
        case .transcribe: "Transcribe"
        case .translate: "Translate"
        case .summary: "Summary"
        case .apiKeys: "API Keys"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "textformat.size"
        case .models: "cpu"
        case .transcribe: "waveform"
        case .translate: "character.bubble"
        case .summary: "text.alignleft"
        case .apiKeys: "key"
        }
    }

    /// Extra words search matches on besides the title.
    var keywords: [String] {
        switch self {
        case .general:
            ["queue", "auto start", "archive", "downloads folder", "menu bar", "when finished", "sleep"]
        case .appearance:
            ["font", "typography", "text size", "scale", "density", "compact", "detailed", "display"]
        case .models:
            ["whisper", "qwen", "engine", "backend", "model", "llm", "openrouter", "local server", "lm studio"]
        case .transcribe:
            ["language", "quality", "names", "terms", "decoding", "advanced", "speech"]
        case .translate:
            ["target language", "translation", "chunks", "prompt", "srt", "sidecar"]
        case .summary:
            ["intro summary", "summary model", "fallback"]
        case .apiKeys:
            ["openai", "anthropic", "google", "gemini", "openrouter", "groq", "cerebras", "keychain", "key"]
        }
    }
}
