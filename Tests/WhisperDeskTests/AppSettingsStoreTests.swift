import Foundation
import Testing
@testable import WhisperDesk

@MainActor
struct AppSettingsStoreTests {
    /// Isolated UserDefaults suite so tests never touch the real app domain.
    private func makeSuite() -> (defaults: UserDefaults, name: String) {
        let name = "test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Builds a store with stubbed secret storage so tests never hit the
    /// real Keychain (a read of the app's items from the unsigned test
    /// runner could pop a consent dialog).
    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in })
    }

    @Test func freshInstallDefaultsToBuiltInEngine() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = makeStore(defaults: defaults)

        #expect(store.transcriptionPreset == .builtIn)
        #expect(store.whisperBackend == .native)
        #expect(store.whisperModel == ModelDownloader.defaultModel)
        // The first save() persists the defaults so later launches decode
        // the same configuration.
        #expect(defaults.string(forKey: "whisperBackend") == WhisperBackend.native.rawValue)
        #expect(defaults.string(forKey: "whisperModel") == ModelDownloader.defaultModel)
    }

    @Test func existingMLXInstallKeepsStoredSettings() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("mlx-whisper", forKey: "whisperBackend")
        defaults.set(AppSettingsStore.mlxTurboModel, forKey: "whisperModel")
        defaults.set("fastAppleSilicon", forKey: "transcriptionPreset")

        let store = makeStore(defaults: defaults)

        #expect(store.whisperBackend == .mlxWhisper)
        #expect(store.whisperModel == AppSettingsStore.mlxTurboModel)
        #expect(store.transcriptionPreset == .fastAppleSilicon)
        // Nothing about the stored decode path may change either.
        #expect(defaults.string(forKey: "whisperBackend") == "mlx-whisper")
        #expect(defaults.string(forKey: "whisperModel") == AppSettingsStore.mlxTurboModel)
        #expect(defaults.string(forKey: "transcriptionPreset") == "fastAppleSilicon")
    }

    @Test func storedAutoBackendStillDecodes() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("auto", forKey: "whisperBackend")
        defaults.set(AppSettingsStore.mlxTurboModel, forKey: "whisperModel")
        defaults.set("custom", forKey: "transcriptionPreset")

        let store = makeStore(defaults: defaults)

        #expect(store.whisperBackend == .auto)
        #expect(store.whisperModel == AppSettingsStore.mlxTurboModel)
        #expect(store.transcriptionPreset == .custom)
    }

    // MARK: - .auto dispatch resolution

    @Test func autoDispatchResolvesToNativeWithDefaultModel() {
        let resolved = TranscriptionService.resolveDispatch(
            backend: .auto,
            model: AppSettingsStore.mlxTurboModel
        )
        #expect(resolved.backend == .native)
        #expect(resolved.model == ModelDownloader.defaultModel)
    }

    @Test func autoDispatchKeepsStoredGGMLModel() {
        let resolved = TranscriptionService.resolveDispatch(backend: .auto, model: "ggml-small.bin")
        #expect(resolved.backend == .native)
        #expect(resolved.model == "ggml-small.bin")
    }

    @Test func explicitPythonBackendIsNotRedirected() {
        let resolved = TranscriptionService.resolveDispatch(
            backend: .mlxWhisper,
            model: AppSettingsStore.mlxTurboModel
        )
        #expect(resolved.backend == .mlxWhisper)
        #expect(resolved.model == AppSettingsStore.mlxTurboModel)
    }
}
