import SwiftUI
import Testing
@testable import Cue

/// Opt-in renders of the whole Settings window for visual review. Set
/// `CUE_SNAPSHOT_DIR` and run `script/run_tests.sh`; without it these are
/// skipped. Every fixture uses a throwaway `UserDefaults` suite, no-op secret
/// closures, and a stubbed local-server fetch, so nothing touches the real
/// settings, the Keychain, or the network.
@MainActor
struct SettingsSnapshotTests {
    private let running = LocalServerModel(id: "qwen3-30b-a3b", ownedBy: "qwen", availability: .running)
    private let advertised = LocalServerModel(id: "llama-3.1-8b-instruct", ownedBy: nil, availability: .advertised)

    /// One render: which pane, at what text size / density / typeface, in which
    /// color scheme and window size, with optional store setup.
    private struct Shot {
        var name: String
        var pane: SettingsPane
        var scale: TextScale = .standard
        var density: ListDensity = .comfortable
        var typography: AppTypography = .system
        var scheme: ColorScheme = .light
        var size: CGSize = SettingsWindowMetrics.defaultSize
        /// A local server that already reported its models. `SettingsView`
        /// reloads the list when it opens, and the snapshot harness captures
        /// before that finishes, so the whole window would show a transient
        /// "Connecting…". Models and Summary are rendered alone instead, over
        /// the same server object, so the connected rows are what is captured.
        var connected = false
        var configure: (AppSettingsStore) -> Void = { _ in }
    }

    @discardableResult
    private func render(_ shot: Shot) async throws -> URL? {
        let suiteName = "cue-test-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(shot.pane.rawValue, forKey: SettingsPane.storageKey)
        suite.set(shot.typography.rawValue, forKey: DisplayPreferenceKey.typography)
        suite.set(shot.scale.rawValue, forKey: DisplayPreferenceKey.textScale)
        suite.set(shot.density.rawValue, forKey: DisplayPreferenceKey.listDensity)

        let settings = AppSettingsStore(defaults: suite, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        shot.configure(settings)

        let models = [running, advertised]
        let server = LocalServerConnection(
            models: shot.connected ? models : [],
            status: shot.connected ? .connected(models.count, confirmedRunning: false) : .idle,
            fetch: { _ in models }
        )
        var size = shot.size
        let content: AnyView
        switch (shot.connected, shot.pane) {
        case (true, .models):
            size.width -= SettingsWindowMetrics.sidebarWidth + 1
            content = AnyView(ModelsSettingsPane(settings: settings, server: server))
        case (true, .summary):
            size.width -= SettingsWindowMetrics.sidebarWidth + 1
            content = AnyView(SummarySettingsPane(settings: settings, server: server))
        default:
            content = AnyView(SettingsView(settings: settings, server: server))
        }
        let view =
            content
            .cueDisplayPreferences()
            .defaultAppStorage(suite)
        return try await ViewSnapshot.capture(view, name: shot.name, size: size, colorScheme: shot.scheme)
    }

    // MARK: Every pane, light, 100% / Comfortable

    @Test(.enabled(if: ViewSnapshot.isEnabled), arguments: SettingsPane.allCases)
    func rendersEveryPaneAtDefaults(pane: SettingsPane) async throws {
        let url = try await render(Shot(name: "settings-\(pane.rawValue)-100-light", pane: pane))
        #expect(url != nil)
    }

    // MARK: Appearance

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAppearanceAtLargest() async throws {
        let url = try await render(Shot(name: "settings-appearance-150-light", pane: .appearance, scale: .largest))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAppearanceInDarkMode() async throws {
        let url = try await render(Shot(name: "settings-appearance-100-dark", pane: .appearance, scheme: .dark))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAppearanceWithEachDensity() async throws {
        for density in [ListDensity.compact, .detailed] {
            let url = try await render(
                Shot(name: "settings-appearance-100-\(density.rawValue)", pane: .appearance, density: density)
            )
            #expect(url != nil)
        }
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAppearanceWithEachTypeface() async throws {
        for typography in [AppTypography.serif, .monospaced] {
            let url = try await render(
                Shot(
                    name: "settings-appearance-115-\(typography.rawValue)",
                    pane: .appearance,
                    scale: .large,
                    density: .detailed,
                    typography: typography
                )
            )
            #expect(url != nil)
        }
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAppearanceAtLargestInTheSmallestWindow() async throws {
        let url = try await render(
            Shot(name: "settings-appearance-150-minsize", pane: .appearance, scale: .largest, size: SettingsWindowMetrics.minSize)
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAppearanceAtSmaller() async throws {
        let url = try await render(Shot(name: "settings-appearance-90-light", pane: .appearance, scale: .smaller))
        #expect(url != nil)
    }

    // MARK: Models (wrapping)

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersModelsAtLarger() async throws {
        let url = try await render(Shot(name: "settings-models-130-light", pane: .models, scale: .larger))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersModelsAtLargerWithEveryOptionOpen() async throws {
        // Advanced open, a Faster Whisper backend with an MLX model (so the
        // validation message and Repair show), and a connected local server.
        let url = try await render(
            Shot(
                name: "settings-models-130-advanced-local",
                pane: .models,
                scale: .larger,
                connected: true,
                configure: { settings in
                    settings.showAdvancedControls = true
                    settings.whisperBackend = .fasterWhisper
                    settings.whisperModel = "mlx-community/whisper-large-v3-turbo"
                    settings.openAIModel = "local/qwen3-30b-a3b"
                }
            )
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersModelsWithOpenRouter() async throws {
        let url = try await render(
            Shot(
                name: "settings-models-100-openrouter",
                pane: .models,
                configure: { $0.openAIModel = "openrouter/qwen/qwen3.8-max" }
            )
        )
        #expect(url != nil)
    }

    // MARK: Other panes with everything visible

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTranscribeWithAdvancedOpen() async throws {
        let url = try await render(
            Shot(
                name: "settings-transcribe-100-advanced",
                pane: .transcribe,
                configure: { settings in
                    settings.showAdvancedControls = true
                    settings.whisperBackend = .fasterWhisper
                }
            )
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTranscribeForQwenAtLargest() async throws {
        let url = try await render(
            Shot(
                name: "settings-transcribe-150-qwen",
                pane: .transcribe,
                scale: .largest,
                configure: { settings in
                    settings.whisperBackend = .qwen3ASR
                    settings.qwenContext = "Shinji Rei Misato NERV"
                }
            )
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersSummaryWithLocalModels() async throws {
        let url = try await render(
            Shot(
                name: "settings-summary-100-local",
                pane: .summary,
                connected: true,
                configure: { settings in
                    settings.generateSummary = true
                    settings.summaryModel = "local/qwen3-30b-a3b"
                    settings.summaryFallbackModel = "claude-opus-5"
                }
            )
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersGeneralAndTranslateAtLargest() async throws {
        for pane in [SettingsPane.general, .translate] {
            let url = try await render(Shot(name: "settings-\(pane.rawValue)-150-light", pane: pane, scale: .largest))
            #expect(url != nil)
        }
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAPIKeysWithASaveError() async throws {
        let url = try await render(
            Shot(
                name: "settings-apiKeys-100-error",
                pane: .apiKeys,
                configure: {
                    $0.secretPersistenceError =
                        "The OpenAI API key could not be saved to Keychain. Cue will retry; the key may be lost if the app quits first."
                }
            )
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersGeneralInDarkMode() async throws {
        let url = try await render(Shot(name: "settings-general-100-dark", pane: .general, scheme: .dark))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAWideWindowWithTheTitleAlignedToTheForm() async throws {
        // Wider than the form's own maximum width, where the form centers
        // itself: the title block must move with it, not stay pinned left.
        let url = try await render(
            Shot(name: "settings-general-100-wide", pane: .general, size: CGSize(width: 1240, height: 660))
        )
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTheLongPanesInFull() async throws {
        // The default window scrolls these; a tall window shows the part
        // below the fold so it can be reviewed too.
        let tall = CGSize(width: SettingsWindowMetrics.defaultSize.width, height: 1_100)
        let shots = [
            Shot(name: "settings-translate-100-full", pane: .translate, size: tall),
            Shot(
                name: "settings-summary-100-full",
                pane: .summary,
                size: tall,
                configure: { $0.generateSummary = true }
            ),
            Shot(
                name: "settings-transcribe-100-advanced-full",
                pane: .transcribe,
                size: tall,
                configure: { settings in
                    settings.showAdvancedControls = true
                    settings.whisperBackend = .fasterWhisper
                }
            ),
        ]
        for shot in shots {
            let url = try await render(shot)
            #expect(url != nil)
        }
    }
}
