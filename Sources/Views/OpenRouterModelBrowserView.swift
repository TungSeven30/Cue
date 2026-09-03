import SwiftUI

/// Searchable picker over OpenRouter's live model catalog. Browsing needs no
/// API key — only running translations does — so this always works.
struct OpenRouterModelBrowserView: View {
    @ObservedObject var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var models: [OpenRouterModel] = []
    @State private var searchText = ""
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenRouter Models")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            TextField("Search by name or id", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 8)

            Group {
                if isLoading {
                    ProgressView("Loading the model catalog…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Retry") { load() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleModels.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Models Match")
                            .font(.headline)
                        Text("No OpenRouter models found matching “\(searchText)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Clear Search") {
                            searchText = ""
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visibleModels, selection: $selectedID) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.name)
                                    .lineLimit(1)
                                Spacer()
                                if isCurrent(model) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text("\(model.id) — \(model.priceLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(model.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 320)

            HStack {
                Text("\(visibleModels.count) models")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Model") { useSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedID == nil)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear { load() }
    }

    @State private var selectedID: String?

    private var visibleModels: [OpenRouterModel] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func isCurrent(_ model: OpenRouterModel) -> Bool {
        settings.openAIModel == "openrouter/\(model.id)"
    }

    private func useSelected() {
        guard let selectedID else { return }
        settings.openAIModel = "openrouter/\(selectedID)"
        dismiss()
    }

    private func load() {
        isLoading = true
        loadError = nil
        Task {
            do {
                let fetched = try await OpenRouterModelCatalog.fetch()
                models = fetched
                // Pre-select the model already in use so Return re-confirms it.
                if settings.openAIModel.hasPrefix("openrouter/") {
                    selectedID = String(settings.openAIModel.dropFirst("openrouter/".count))
                }
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }
}
