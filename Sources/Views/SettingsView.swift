import SwiftUI

/// The Settings window: a fixed-width sidebar of panes beside the selected
/// pane's form, like System Settings.
///
/// The selected pane lives in `@AppStorage(SettingsPane.storageKey)` so another
/// surface can write a pane's raw value and then call `openSettings()`; this
/// view follows the change whether or not the window was already open.
///
/// The two columns are a plain `HStack`, not a `NavigationSplitView`. In the
/// snapshot harness a split view with a grouped `Form` as its detail was laid
/// out at the form's ideal height (940 pt in a 660 pt window), which pushed
/// the sidebar's first rows and the pane title off the top. It would also add
/// a sidebar toggle, which a fixed list of seven panes has no use for.
struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @AppStorage(SettingsPane.storageKey) private var selectedPane: SettingsPane = .general
    /// Owned here, not by a pane, so the model list survives switching panes
    /// and the Models and Summary panes share one connection.
    @StateObject private var server: LocalServerConnection

    init(settings: AppSettingsStore, server: LocalServerConnection? = nil) {
        self.settings = settings
        _server = StateObject(wrappedValue: server ?? LocalServerConnection())
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsWindowMetrics.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
        .frame(
            minWidth: SettingsWindowMetrics.minSize.width,
            idealWidth: SettingsWindowMetrics.defaultSize.width,
            maxWidth: .infinity,
            minHeight: SettingsWindowMetrics.minSize.height,
            idealHeight: SettingsWindowMetrics.defaultSize.height,
            maxHeight: .infinity
        )
        .environment(\.settingsNavigate) { pane in selectedPane = pane }
        .onChange(of: settings.localTranslationEndpoint) { _, _ in
            server.reset()
        }
        .onChange(of: settings.openAIModel) { _, model in
            server.loadIfNeeded(for: model, settings: settings)
        }
        .onChange(of: settings.summaryModel) { _, model in
            server.loadIfNeeded(for: model, settings: settings)
        }
        .onChange(of: settings.summaryFallbackModel) { _, model in
            server.loadIfNeeded(for: model, settings: settings)
        }
        .task {
            if SettingsLocalModels.anySelected(settings) {
                server.load(settings: settings)
            }
        }
    }

    private var sidebar: some View {
        List(selection: SettingsSelection.optionalBinding(for: $selectedPane)) {
            ForEach(SettingsPane.allCases) { pane in
                // A sidebar row ignores the window's root font, and a font set
                // on the Label itself, so the title and icon follow Text size
                // one by one, like the pane beside them.
                Label {
                    Text(pane.title).cueFont(.body)
                } icon: {
                    Image(systemName: pane.systemImage).cueFont(.body)
                }
                .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Settings sections")
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane {
        case .general:
            GeneralSettingsPane(settings: settings)
        case .appearance:
            AppearanceSettingsPane()
        case .models:
            ModelsSettingsPane(settings: settings, server: server)
        case .transcribe:
            TranscribeSettingsPane(settings: settings)
        case .translate:
            TranslateSettingsPane(settings: settings)
        case .summary:
            SummarySettingsPane(settings: settings, server: server)
        case .apiKeys:
            APIKeysSettingsPane(settings: settings)
        }
    }
}
