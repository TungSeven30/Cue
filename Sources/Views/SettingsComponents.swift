import AppKit
import SwiftUI

// MARK: - Window

/// Sizes shared by the Settings scene in `CueApp`, `SettingsView`, and the
/// snapshot tests, so the window and what the tests render cannot drift apart.
enum SettingsWindowMetrics {
    static let minSize = CGSize(width: 760, height: 540)
    static let defaultSize = CGSize(width: 880, height: 720)
    static let sidebarWidth: CGFloat = 210
    /// How wide a pane's content gets before the window is just margin. A
    /// grouped `Form` stops growing at about 704 pt of cards and centers itself
    /// with at least 20 pt on each side; the title block above it is held to
    /// the same 744 pt column, so the two stay aligned in a wide window.
    static let paneContentMaxWidth: CGFloat = 744
}

// MARK: - Navigation

extension SettingsPane {
    /// One line under the pane title.
    var summary: String {
        switch self {
        case .general: "Queue behavior, downloads, and the menu bar icon."
        case .appearance: "Typeface, text size, and list density for every Cue window."
        case .models: "The engines and models Cue uses to transcribe and translate."
        case .transcribe: "Language, quality, and how speech becomes subtitles."
        case .translate: "Languages, batching, and the prompt used to translate subtitles."
        case .summary: "A short introduction generated when each job finishes."
        case .apiKeys: "Cloud providers need a key. Local models don't."
        }
    }
}

private struct SettingsNavigateKey: EnvironmentKey {
    // Computed, not stored: a stored closure would have to be Sendable to be a
    // legal `static let` under Swift 6.
    static var defaultValue: @MainActor (SettingsPane) -> Void { { _ in } }
}

extension EnvironmentValues {
    /// Switches the Settings sidebar to another pane. Panes use it for
    /// cross-links such as "Choose in Models".
    var settingsNavigate: @MainActor (SettingsPane) -> Void {
        get { self[SettingsNavigateKey.self] }
        set { self[SettingsNavigateKey.self] = newValue }
    }
}

enum SettingsSelection {
    /// The sidebar `List` selects through an optional binding, and AppKit can
    /// report nil while a row is being re-selected. The window must never end
    /// up with no pane, so nil is ignored.
    static func optionalBinding(for pane: Binding<SettingsPane>) -> Binding<SettingsPane?> {
        Binding(
            get: { pane.wrappedValue },
            set: { newValue in
                if let newValue { pane.wrappedValue = newValue }
            }
        )
    }
}

// MARK: - Pane chrome

/// Common frame for every pane: a title block above a grouped form that
/// scrolls. `trailing` sits at the end of the title block (a pane-level
/// action such as Restore Defaults).
struct SettingsPaneScaffold<Trailing: View, Content: View>: View {
    let pane: SettingsPane
    private let trailing: Trailing
    private let content: Content

    init(
        pane: SettingsPane,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.pane = pane
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form { content }
                .formStyle(.grouped)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .cueFont(.title2, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(pane.summary)
                    .cueFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: SettingsWindowMetrics.paneContentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

extension SettingsPaneScaffold where Trailing == EmptyView {
    init(pane: SettingsPane, @ViewBuilder content: () -> Content) {
        self.init(pane: pane, trailing: { EmptyView() }, content: content)
    }
}

/// A grouped section's header. A Form sets its headers in semibold, but any
/// Text size other than 100% replaces the window's font and takes that weight
/// with it, so the weight is set here: headers stay apart from the rows they
/// title at every size.
struct SettingsSectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .cueFont(.body, weight: .semibold)
    }
}

/// Section footer text: short, secondary, wraps instead of truncating.
struct SettingsFootnote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .cueFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row that names a setting owned by another pane and jumps there.
struct SettingsPaneLinkRow: View {
    @Environment(\.settingsNavigate) private var navigate
    let title: String
    var value: String?
    let pane: SettingsPane
    let buttonTitle: String

    var body: some View {
        LabeledContent {
            Button(buttonTitle) { navigate(pane) }
                .buttonStyle(.link)
                .accessibilityHint("Opens the \(pane.title) pane")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let value, !value.isEmpty {
                    Text(value)
                        .cueFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

// MARK: - Shared pickers

/// A picker over `SettingsPreset`s that still shows a stored value the presets
/// do not list, as "Custom".
struct SettingsPresetPicker: View {
    let title: String
    let presets: [SettingsPreset]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.value)
            }
            if !presets.map(\.value).contains(selection) {
                Text("Custom").tag(selection)
            }
        }
    }
}

/// A model picker for the translation and summary models. A concrete local
/// instance id is routing detail, not a separate provider, so the picker keeps
/// showing "Local server" after a running model is chosen instead of a
/// confusing generic "Custom" value.
struct ProviderModelPicker: View {
    let title: String
    let presets: [SettingsPreset]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: providerSelection) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.value)
            }
            if !presets.map(\.value).contains(selection),
                TranslationProvider.infer(from: selection) != .local
            {
                Text(Self.label(for: selection)).tag(selection)
            }
        }
    }

    private var providerSelection: Binding<String> {
        let selection = $selection
        return Binding {
            let model = selection.wrappedValue
            return TranslationProvider.infer(from: model) == .local ? "local/" : model
        } set: { model in
            if model == "local/", TranslationProvider.infer(from: selection.wrappedValue) == .local {
                return
            }
            selection.wrappedValue = model
        }
    }

    static func label(for model: String) -> String {
        switch TranslationProvider.infer(from: model) {
        case .openai: return "OpenAI model"
        case .anthropic: return "Anthropic model"
        case .google: return "Google model"
        case .local: return "Local server (LM Studio / Ollama)"
        case .openRouter: return "OpenRouter model"
        case .groq: return "Groq model"
        case .cerebras: return "Cerebras model"
        }
    }
}

// MARK: - Slider row

/// Title and value on one line, the slider full width beneath. Stacking keeps
/// the slider usable when a large text size makes the title long.
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// `String(format:)` pattern for the value readout, for example `%.1fs`.
    let format: String

    private var valueText: String { String(format: format, value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: $value, in: range, step: step) { Text(title) }
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

// MARK: - Local server

/// The Settings window's view of the local OpenAI-compatible server (LM Studio,
/// Ollama): which models it reports and whether the last connection worked.
/// `SettingsView` owns one, so the list survives switching panes and the
/// Models and Summary panes share it.
@MainActor
final class LocalServerConnection: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case connected(Int, confirmedRunning: Bool)
        case failed(String)
    }

    typealias Fetch = @Sendable (String) async throws -> [LocalServerModel]

    @Published private(set) var models: [LocalServerModel]
    @Published private(set) var status: Status
    private let fetch: Fetch

    init(
        models: [LocalServerModel] = [],
        status: Status = .idle,
        fetch: @escaping Fetch = { endpoint in try await LocalModelCatalog.fetch(endpoint: endpoint) }
    ) {
        self.models = models
        self.status = status
        self.fetch = fetch
    }

    var modelsAreConfirmedRunning: Bool {
        !models.isEmpty && models.allSatisfy { $0.availability == .running }
    }

    func reset() {
        models = []
        status = .idle
    }

    /// Asks the server at the current endpoint for its models. A reply that
    /// arrives after the endpoint changed is dropped.
    @discardableResult
    func load(settings: AppSettingsStore) -> Task<Void, Never> {
        let endpoint = settings.localTranslationEndpoint
        status = .loading
        let fetch = fetch
        return Task {
            do {
                let fetched = try await fetch(endpoint)
                guard endpoint == settings.localTranslationEndpoint else { return }
                models = fetched
                status = .connected(fetched.count, confirmedRunning: modelsAreConfirmedRunning)
            } catch {
                guard endpoint == settings.localTranslationEndpoint else { return }
                models = []
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Loads the list when a local model was just chosen and nothing is loaded
    /// or loading yet.
    @discardableResult
    func loadIfNeeded(for model: String, settings: AppSettingsStore) -> Task<Void, Never>? {
        guard SettingsLocalModels.isLocal(model), models.isEmpty, status != .loading else { return nil }
        return load(settings: settings)
    }
}

/// Which of the selected models talk to the local server.
enum SettingsLocalModels {
    static func isLocal(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && TranslationProvider.infer(from: trimmed) == .local
    }

    @MainActor
    static func summaryIsLocal(_ settings: AppSettingsStore) -> Bool { isLocal(settings.summaryModel) }

    @MainActor
    static func fallbackIsLocal(_ settings: AppSettingsStore) -> Bool { isLocal(settings.summaryFallbackModel) }

    @MainActor
    static func anySelected(_ settings: AppSettingsStore) -> Bool {
        settings.currentTranslationProvider == .local || summaryIsLocal(settings) || fallbackIsLocal(settings)
    }
}

/// Local server URL, a Load Models button, and the connection status: the
/// rows shared by the Models pane and the Summary pane.
struct LocalServerConnectionRows: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var server: LocalServerConnection

    private var endpointIsBlank: Bool {
        settings.localTranslationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TextField("Local server URL", text: $settings.localTranslationEndpoint)
            .onSubmit { server.load(settings: settings) }
            .help("The LM Studio address on this Mac or another Mac, for example http://192.168.0.196:1234")
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            LocalServerStatusLabel(status: server.status)
            Spacer(minLength: 8)
            Button {
                server.load(settings: settings)
            } label: {
                if server.status == .loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(server.models.isEmpty ? "Load Models" : "Reload", systemImage: "arrow.clockwise")
                }
            }
            .disabled(endpointIsBlank || server.status == .loading)
        }
    }
}

struct LocalServerStatusLabel: View {
    let status: LocalServerConnection.Status

    var body: some View {
        switch status {
        case .idle:
            Label("Enter the LM Studio address, then load its models.", systemImage: "network")
                .foregroundStyle(.secondary)
                .cueFont(.caption)
        case .loading:
            Label("Connecting to the local server…", systemImage: "network")
                .foregroundStyle(.secondary)
                .cueFont(.caption)
        case .connected(let count, let confirmedRunning):
            Label(
                confirmedRunning
                    ? "Connected — \(count) model instance\(count == 1 ? "" : "s") running"
                    : "Connected — server reports \(count) text-generation model\(count == 1 ? "" : "s")",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .cueFont(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .cueFont(.caption)
        }
    }
}

/// Picks one of the models the local server reported. The stored value keeps
/// its `local/` prefix; the picker shows the bare id.
struct LocalModelPicker: View {
    let title: String
    @Binding var selection: String
    let models: [LocalServerModel]

    var body: some View {
        Picker(title, selection: modelIDSelection) {
            Text("Choose a model…").tag("")
            ForEach(models) { model in
                if model.availability == .running {
                    Label(model.id, systemImage: "play.circle.fill").tag(model.id)
                } else {
                    Text(model.id).tag(model.id)
                }
            }
        }
        .help("Choose a model reported by the local server. LM Studio models marked as running are confirmed loaded instances.")
    }

    private var modelIDSelection: Binding<String> {
        let selection = $selection
        return Binding {
            let selected = selection.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard selected.lowercased().hasPrefix("local/") else { return "" }
            return String(selected.dropFirst("local/".count))
        } set: { modelID in
            guard !modelID.isEmpty else { return }
            selection.wrappedValue = "local/\(modelID)"
        }
    }
}
