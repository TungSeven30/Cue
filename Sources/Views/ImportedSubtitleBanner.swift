import AppKit
import SwiftUI

/// Shows that a tab's segments came from a file on disk, and that edits are
/// being written back to it. With automatic write-back, this is how the user
/// finds out — and how they stop it.
struct ImportedSubtitleBanner: View {
    @EnvironmentObject private var model: AppModel
    let slot: SubtitleSidecarScanner.Slot

    var body: some View {
        if let job = model.currentJob, let source = job.importedSource(for: slot) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(source))
                    .foregroundStyle(statusColor(source))
                Text("Imported from \(source.fileName)")
                    .font(.caption)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(statusText(source))
                    .font(.caption)
                    .foregroundStyle(statusColor(source))

                Spacer()

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                }
                .buttonStyle(.link)
                .font(.caption)

                Button("Unlink") {
                    model.unlinkImportedSubtitles(slot: slot, jobID: job.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Stop writing edits back to this file")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusIcon(_ source: ImportedSubtitleSource) -> String {
        if source.lastSyncError != nil { return "exclamationmark.triangle.fill" }
        return source.syncPaused ? "pause.circle.fill" : "arrow.triangle.2.circlepath"
    }

    private func statusColor(_ source: ImportedSubtitleSource) -> Color {
        source.lastSyncError != nil || source.syncPaused ? .orange : .secondary
    }

    private func statusText(_ source: ImportedSubtitleSource) -> String {
        if let error = source.lastSyncError { return "Sync failed: \(error)" }
        return source.syncPaused ? "Sync paused — file changed outside Cue" : "Syncing"
    }
}
