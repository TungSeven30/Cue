import SwiftUI
import Testing
@testable import Cue

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Holds a stubbed request open until the test lets it finish.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeSettings(endpoint: String = "http://127.0.0.1:1234") -> (AppSettingsStore, () -> Void) {
    let name = "cue-test-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    let settings = AppSettingsStore(defaults: suite, readSecret: { _ in nil }, writeSecret: { _, _ in true })
    settings.localTranslationEndpoint = endpoint
    return (settings, { suite.removePersistentDomain(forName: name) })
}

private let running = LocalServerModel(id: "qwen3-30b", ownedBy: "qwen", availability: .running)
private let advertised = LocalServerModel(id: "llama-3.1-8b", ownedBy: nil, availability: .advertised)

private struct StubError: LocalizedError {
    var errorDescription: String? { "Connection refused" }
}

/// The pieces of the Settings window that are logic rather than layout: which
/// pane is selected, what Restore Defaults means, and the shared local-server
/// connection the Models and Summary panes use.
@MainActor
struct SettingsPaneTests {
    // MARK: Navigation

    @Test func selectionRoundTripsThroughItsStorageKey() throws {
        let name = "cue-test-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        #expect(suite.string(forKey: SettingsPane.storageKey) == nil)
        for pane in SettingsPane.allCases {
            suite.set(pane.rawValue, forKey: SettingsPane.storageKey)
            let stored = try #require(suite.string(forKey: SettingsPane.storageKey))
            #expect(SettingsPane(rawValue: stored) == pane)
        }
    }

    @Test func unknownStoredPaneIsNotAPane() {
        // @AppStorage falls back to its default (.general) when the raw value
        // does not decode, so a stale value can never leave the window blank.
        #expect(SettingsPane(rawValue: "removedPane") == nil)
        #expect(SettingsPane(rawValue: "") == nil)
    }

    @Test func sidebarSelectionIgnoresNil() {
        let pane = Box(SettingsPane.models)
        let binding = Binding(get: { pane.value }, set: { pane.value = $0 })
        let optional = SettingsSelection.optionalBinding(for: binding)

        #expect(optional.wrappedValue == .models)
        optional.wrappedValue = nil
        #expect(pane.value == .models)
        optional.wrappedValue = .summary
        #expect(pane.value == .summary)
        #expect(optional.wrappedValue == .summary)
    }

    @Test func everyPaneHasAOneLineSummary() {
        let summaries = SettingsPane.allCases.map(\.summary)
        #expect(summaries.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
        #expect(Set(summaries).count == summaries.count)
    }

    @Test func windowMetricsMatchTheSpec() {
        #expect(SettingsWindowMetrics.defaultSize == CGSize(width: 880, height: 720))
        #expect(SettingsWindowMetrics.minSize == CGSize(width: 760, height: 540))
        #expect(SettingsWindowMetrics.minSize.width <= SettingsWindowMetrics.defaultSize.width)
        #expect(SettingsWindowMetrics.minSize.height <= SettingsWindowMetrics.defaultSize.height)
    }

    // MARK: Appearance

    @Test func restoreDefaultsIsDisabledOnlyAtTheDefaults() {
        #expect(AppearanceSelection.defaults.isDefault)
        #expect(AppearanceSelection.defaults.typography == .system)
        #expect(AppearanceSelection.defaults.textScale == .standard)
        #expect(AppearanceSelection.defaults.listDensity == .comfortable)

        for typography in AppTypography.allCases where typography != .system {
            var selection = AppearanceSelection.defaults
            selection.typography = typography
            #expect(!selection.isDefault)
        }
        for scale in TextScale.allCases where scale != .standard {
            var selection = AppearanceSelection.defaults
            selection.textScale = scale
            #expect(!selection.isDefault)
        }
        for density in ListDensity.allCases where density != .comfortable {
            var selection = AppearanceSelection.defaults
            selection.listDensity = density
            #expect(!selection.isDefault)
        }
    }

    @Test func appearanceDefaultsMatchTheWindowRootDefaults() throws {
        // The window roots read these keys with the same defaults; an empty
        // store must decode to `AppearanceSelection.defaults`.
        let name = "cue-test-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let stored = AppearanceSelection(
            typography: suite.string(forKey: DisplayPreferenceKey.typography).flatMap(AppTypography.init(rawValue:)) ?? .system,
            textScale: suite.string(forKey: DisplayPreferenceKey.textScale).flatMap(TextScale.init(rawValue:)) ?? .standard,
            listDensity: suite.string(forKey: DisplayPreferenceKey.listDensity).flatMap(ListDensity.init(rawValue:)) ?? .comfortable
        )
        #expect(stored == .defaults)
    }

    // MARK: Model labels

    @Test func providerModelLabelsNameTheProvider() {
        #expect(ProviderModelPicker.label(for: "gpt-5.5") == "OpenAI model")
        #expect(ProviderModelPicker.label(for: "claude-opus-5") == "Anthropic model")
        #expect(ProviderModelPicker.label(for: "gemini-3-pro") == "Google model")
        #expect(ProviderModelPicker.label(for: "openrouter/qwen/qwen3.8-max") == "OpenRouter model")
        #expect(ProviderModelPicker.label(for: "groq/openai/gpt-oss-120b") == "Groq model")
        #expect(ProviderModelPicker.label(for: "cerebras/gpt-oss-120b") == "Cerebras model")
        #expect(ProviderModelPicker.label(for: "local/qwen3-30b") == "Local server (LM Studio / Ollama)")
    }

    @Test func localModelDetectionMatchesTheProviderPrefix() {
        #expect(SettingsLocalModels.isLocal("local/qwen3-30b"))
        #expect(SettingsLocalModels.isLocal("  LOCAL/qwen3-30b  "))
        #expect(!SettingsLocalModels.isLocal(""))
        #expect(!SettingsLocalModels.isLocal("   "))
        #expect(!SettingsLocalModels.isLocal("gpt-5.5"))
        #expect(!SettingsLocalModels.isLocal("openrouter/local/thing"))
    }

    @Test func anyLocalSelectionCoversTranslationSummaryAndFallback() {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }

        #expect(!SettingsLocalModels.anySelected(settings))
        settings.summaryFallbackModel = "local/llama"
        #expect(SettingsLocalModels.anySelected(settings))
        settings.summaryFallbackModel = ""
        settings.summaryModel = "local/llama"
        #expect(SettingsLocalModels.anySelected(settings))
        settings.summaryModel = ""
        settings.openAIModel = "local/llama"
        #expect(SettingsLocalModels.anySelected(settings))
    }

    // MARK: Local server connection

    @Test func loadPublishesModelsAndStatus() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let server = LocalServerConnection(fetch: { _ in [running, advertised] })

        #expect(server.status == .idle)
        await server.load(settings: settings).value

        #expect(server.models == [running, advertised])
        #expect(server.status == .connected(2, confirmedRunning: false))
        #expect(!server.modelsAreConfirmedRunning)
    }

    @Test func runningOnlyModelsAreConfirmedRunning() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let server = LocalServerConnection(fetch: { _ in [running] })

        await server.load(settings: settings).value

        #expect(server.status == .connected(1, confirmedRunning: true))
        #expect(server.modelsAreConfirmedRunning)
    }

    @Test func failedLoadClearsModelsAndReportsTheError() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let server = LocalServerConnection(models: [running], status: .connected(1, confirmedRunning: true), fetch: { _ in throw StubError() })

        await server.load(settings: settings).value

        #expect(server.models.isEmpty)
        #expect(server.status == .failed("Connection refused"))
    }

    @Test func loadUsesTheCurrentEndpoint() async {
        let (settings, cleanup) = makeSettings(endpoint: "http://192.168.0.5:1234")
        defer { cleanup() }
        let requested = Box<String?>(nil)
        let server = LocalServerConnection(fetch: { endpoint in
            requested.value = endpoint
            return [running]
        })

        await server.load(settings: settings).value

        #expect(requested.value == "http://192.168.0.5:1234")
    }

    @Test func aReplyForAnOldEndpointIsDropped() async {
        let (settings, cleanup) = makeSettings(endpoint: "http://old:1234")
        defer { cleanup() }
        let gate = Gate()
        let server = LocalServerConnection(fetch: { _ in
            await gate.wait()
            return [running]
        })

        let task = server.load(settings: settings)
        #expect(server.status == .loading)

        // What SettingsView does when the URL field changes mid-request.
        settings.localTranslationEndpoint = "http://new:1234"
        server.reset()
        await gate.open()
        await task.value

        #expect(server.models.isEmpty)
        #expect(server.status == .idle)
    }

    @Test func loadIfNeededOnlyLoadsWhenALocalModelIsChosenAndNothingIsLoaded() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let calls = Box(0)
        let gate = Gate()
        let server = LocalServerConnection(fetch: { _ in
            calls.value += 1
            await gate.wait()
            return [running]
        })

        #expect(server.loadIfNeeded(for: "gpt-5.5", settings: settings) == nil)
        #expect(server.loadIfNeeded(for: "", settings: settings) == nil)
        #expect(calls.value == 0)

        let first = server.loadIfNeeded(for: "local/qwen3-30b", settings: settings)
        #expect(first != nil)
        // Already loading: a second local choice must not start a second request.
        #expect(server.loadIfNeeded(for: "local/llama", settings: settings) == nil)

        await gate.open()
        await first?.value
        #expect(calls.value == 1)
        // Models are loaded: choosing another local model does not reload.
        #expect(server.loadIfNeeded(for: "local/llama", settings: settings) == nil)
    }

    @Test func resetForgetsModelsAndStatus() {
        let server = LocalServerConnection(models: [running], status: .connected(1, confirmedRunning: true))
        server.reset()
        #expect(server.models.isEmpty)
        #expect(server.status == .idle)
    }
}
