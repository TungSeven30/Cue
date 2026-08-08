import Foundation
import Testing
@testable import Cue

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
        AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
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
        // The init-time save() must persist the stored value back, not
        // rewrite it.
        #expect(defaults.string(forKey: "whisperBackend") == "auto")
    }

    @Test func unknownBackendStringDecodesToAutoNotFreshInstall() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("not-a-backend", forKey: "whisperBackend")

        let store = makeStore(defaults: defaults)

        // A present-but-unknown value takes the legacy decode path (the
        // `?? .auto` fallback); the fresh-install defaults fire only when
        // the key is genuinely absent.
        #expect(store.whisperBackend == .auto)
        #expect(store.transcriptionPreset == .fastAppleSilicon)
        #expect(store.whisperModel == AppSettingsStore.mlxTurboModel)
    }

    @Test func freshInstallDefaultsLocalTranslationEndpoint() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = makeStore(defaults: defaults)

        #expect(store.localTranslationEndpoint == "http://localhost:1234/v1")
    }

    @Test func localTranslationEndpointPersistsAcrossLaunches() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = makeStore(defaults: defaults)
        store.localTranslationEndpoint = "http://192.168.1.20:1234/v1"

        let reloaded = makeStore(defaults: defaults)
        #expect(reloaded.localTranslationEndpoint == "http://192.168.1.20:1234/v1")
    }

    @Test func translationReadinessIsProviderAware() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = makeStore(defaults: defaults)
        // No API keys are configured (secrets are stubbed to nil).
        store.openAIModel = "local/qwen3.6-35b"
        #expect(store.isTranslationReady)

        store.localTranslationEndpoint = "   "
        #expect(!store.isTranslationReady)

        store.openAIModel = "gpt-5.5"
        #expect(!store.isTranslationReady)

        store.openAIAPIKey = "sk-test"
        #expect(store.isTranslationReady)
    }

    @Test func summaryModelCanDifferFromTranslationAndPersists() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = makeStore(defaults: defaults)
        store.openAIModel = "gpt-5.5"
        store.summaryModel = "local/qwen3.6-35b"
        store.summaryFallbackModel = "claude-haiku-4-5"

        #expect(store.resolvedSummaryModel == "local/qwen3.6-35b")
        #expect(store.currentSummaryProvider == .local)
        #expect(store.isSummaryReady)
        #expect(!store.isTranslationReady)

        let reloaded = makeStore(defaults: defaults)
        #expect(reloaded.summaryModel == "local/qwen3.6-35b")
        #expect(reloaded.summaryFallbackModel == "claude-haiku-4-5")
    }

    @Test func blankSummaryModelInheritsTranslationAndDuplicateFallbackIsIgnored() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = makeStore(defaults: defaults)
        store.openAIModel = "local/qwen"
        store.summaryModel = "   "
        store.summaryFallbackModel = "local/qwen"

        #expect(store.resolvedSummaryModel == "local/qwen")
        #expect(store.resolvedSummaryFallbackModel == nil)
        #expect(store.isSummaryReady)
    }

    @Test func failedLegacySecretMigrationKeepsPlaintextFallback() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("sk-legacy", forKey: "openAIAPIKey")

        let store = AppSettingsStore(
            defaults: defaults,
            readSecret: { _ in nil },
            writeSecret: { _, _ in false }
        )

        #expect(store.openAIAPIKey == "sk-legacy")
        #expect(defaults.string(forKey: "openAIAPIKey") == "sk-legacy")
        #expect(store.secretPersistenceError != nil)
    }

    @Test func failedSecretEditRetriesOnNextSave() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        var attempts = 0
        let store = AppSettingsStore(
            defaults: defaults,
            readSecret: { _ in nil },
            writeSecret: { _, _ in
                attempts += 1
                return false
            }
        )

        store.openAIAPIKey = "sk-new"
        let afterEdit = attempts
        store.translationTargetLanguage = "French"

        #expect(afterEdit >= 1)
        #expect(attempts > afterEdit)
        #expect(store.secretPersistenceError != nil)
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

    // The store's normalization makes an `.auto` + GGML pairing unreachable
    // through the app today; resolveDispatch handles it anyway so it does
    // not depend on that invariant (hand-edited plists exist).
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
