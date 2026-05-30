import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    JobConfigurationView(model: model)
                    DiagnosticsView(diagnostics: model.diagnostics, isRunning: model.isRunningDiagnostics)
                    TranscriptView(
                        title: "Original Transcript",
                        segments: model.transcriptSegments,
                        warnings: model.qualityWarnings(for: model.transcriptSegments),
                        onEdit: model.updateTranscriptSegment
                    )
                    TranscriptView(
                        title: "English Translation",
                        segments: model.translatedSegments,
                        warnings: model.qualityWarnings(for: model.translatedSegments),
                        onEdit: model.updateTranslatedSegment
                    )
                    LogView(log: model.log)
                }
                .padding(24)
            }
            .navigationTitle("WhisperDesk")
        }
    }
}

private struct DiagnosticsView: View {
    let diagnostics: [EnvironmentDiagnostic]
    let isRunning: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("System Check")
                        .font(.headline)
                    Spacer()
                    Text(isRunning ? "Checking..." : "\(diagnostics.count) checks")
                        .foregroundStyle(.secondary)
                }

                if diagnostics.isEmpty {
                    Text("Run a system check to verify local dependencies and translation setup.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(diagnostics) { diagnostic in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(diagnostic.title)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(diagnostic.state.label)
                                        .font(.caption)
                                        .foregroundStyle(color(for: diagnostic.state))
                                }
                                Text(diagnostic.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if diagnostic.state != .passed {
                                    Text(diagnostic.recovery)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func color(for state: DiagnosticState) -> Color {
        switch state {
        case .passed:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }
}
