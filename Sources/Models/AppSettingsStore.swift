import Foundation

enum WhisperBackend: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto
    case mlxWhisper = "mlx-whisper"
    case fasterWhisper = "faster-whisper"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .mlxWhisper:
            return "MLX Whisper"
        case .fasterWhisper:
            return "Faster Whisper"
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var sourceLanguage: String { didSet { save() } }
    @Published var whisperModel: String { didSet { save() } }
    @Published var whisperBackend: WhisperBackend { didSet { save() } }
    @Published var openAIModel: String { didSet { save() } }
    @Published var openAIAPIKey: String { didSet { save() } }

    private let defaults: UserDefaults
    private static let apiKeyAccount = "openAIAPIKey"

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "auto"
        whisperModel = defaults.string(forKey: "whisperModel") ?? "mlx-community/whisper-large-v3-turbo"
        whisperBackend = WhisperBackend(rawValue: defaults.string(forKey: "whisperBackend") ?? "auto") ?? .auto
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-5.2"

        // The API key lives in the Keychain. Migrate any legacy plaintext key
        // that earlier builds stored in UserDefaults, then scrub it.
        if let stored = KeychainStore.read(account: Self.apiKeyAccount) {
            openAIAPIKey = stored
        } else if let legacy = defaults.string(forKey: "openAIAPIKey"), !legacy.isEmpty {
            openAIAPIKey = legacy
            KeychainStore.write(legacy, account: Self.apiKeyAccount)
            defaults.removeObject(forKey: "openAIAPIKey")
        } else {
            openAIAPIKey = ""
            defaults.removeObject(forKey: "openAIAPIKey")
        }
    }

    private func save() {
        defaults.set(sourceLanguage, forKey: "sourceLanguage")
        defaults.set(whisperModel, forKey: "whisperModel")
        defaults.set(whisperBackend.rawValue, forKey: "whisperBackend")
        defaults.set(openAIModel, forKey: "openAIModel")
        KeychainStore.write(openAIAPIKey, account: Self.apiKeyAccount)
    }
}
